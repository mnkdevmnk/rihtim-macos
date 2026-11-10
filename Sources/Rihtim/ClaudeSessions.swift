import AppKit
import SwiftUI

/// Claude Code sessions, from the CLI and the desktop app's Code tab.
/// Source: `~/.claude/projects/<project>/<session>.jsonl`. Read-only, nothing is sent
/// anywhere. Only the tail of each file is read (title, last step).
struct ClaudeSession: Identifiable, Equatable {
    enum State: Equatable {
        case working          // writing or running a tool right now
        case needsPermission  // made a tool call with no result yet and the file went quiet
        case yourTurn         // finished its reply, waiting on the user
        case idle             // untouched for a while

        var title: String {
            switch self {
            case .working: return L("Working")
            case .needsPermission: return L("Needs permission")
            case .yourTurn: return L("Your turn")
            case .idle: return L("Done")
            }
        }
        var color: Color {
            switch self {
            case .working: return .blue
            case .needsPermission: return .orange
            case .yourTurn: return .green
            case .idle: return .secondary
            }
        }
        var symbol: String {
            switch self {
            case .working: return "ellipsis.circle.fill"
            case .needsPermission: return "hand.raised.fill"
            case .yourTurn: return "arrowshape.turn.up.left.fill"
            case .idle: return "checkmark.circle"
            }
        }
        var needsAction: Bool { self == .needsPermission || self == .yourTurn }
    }

    let id: String
    let title: String
    let project: String
    let cwd: String
    let lastPrompt: String
    let modified: Date
    let state: State
    let fromDesktop: Bool
}

private enum SessionReader {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

    static func scan(maxAge: TimeInterval, limit: Int) -> [ClaudeSession] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var files: [(URL, Date)] = []
        let cutoff = Date().addingTimeInterval(-maxAge)
        for d in dirs {
            guard let list = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in list where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if m > cutoff { files.append((f, m)) }
            }
        }
        files.sort { $0.1 > $1.1 }
        return files.prefix(limit).compactMap { parse($0.0, modified: $0.1) }
    }

    /// Lines from the last ~256 KB of the file.
    private static func tailLines(_ url: URL, bytes: Int = 256 * 1024) -> [Substring] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) ?? String(data: data.dropFirst(1), encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }      // partial line
        return lines
    }

    private static func parse(_ url: URL, modified: Date) -> ClaudeSession? {
        let lines = tailLines(url)
        guard !lines.isEmpty else { return nil }
        var title: String?
        var lastPrompt: String?
        var cwd: String?
        var state: ClaudeSession.State?
        var desktop = false
        let age = Date().timeIntervalSince(modified)
        let fresh = age < 20

        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = d["type"] as? String else { continue }
            switch type {
            case "custom-title":
                if title == nil { title = d["customTitle"] as? String }
            case "last-prompt":
                if lastPrompt == nil { lastPrompt = d["lastPrompt"] as? String }
            case "user", "assistant":
                if cwd == nil { cwd = d["cwd"] as? String }
                if let e = d["entrypoint"] as? String, e.lowercased().contains("desktop") { desktop = true }
                guard state == nil, (d["isSidechain"] as? Bool) != true, (d["isMeta"] as? Bool) != true,
                      let msg = d["message"] as? [String: Any] else { continue }
                let kinds: [String]
                if let c = msg["content"] as? [[String: Any]] { kinds = c.compactMap { $0["type"] as? String } }
                else { kinds = ["text"] }
                if type == "assistant" {
                    if kinds.contains("tool_use") {
                        state = fresh ? .working : .needsPermission
                    } else if kinds.contains("text") {
                        state = fresh && (msg["stop_reason"] as? String) == nil ? .working : .yourTurn
                    }
                    // only a "thinking" block: still going, keep looking further back
                    if state == nil, fresh { state = .working }
                } else {
                    // user message or tool result: the model is up next
                    state = fresh ? .working : .idle
                }
            default:
                break
            }
            if title != nil && lastPrompt != nil && cwd != nil && state != nil { break }
        }
        var st = state ?? .idle
        if st == .yourTurn && age > 6 * 3600 { st = .idle }          // an old "your turn" isn't pending work anymore
        if st == .needsPermission && age > 2 * 3600 { st = .idle }
        let path = cwd ?? ""
        let project = path.isEmpty ? url.deletingLastPathComponent().lastPathComponent : URL(fileURLWithPath: path).lastPathComponent
        let prompt = clean(lastPrompt ?? "")
        return ClaudeSession(id: url.deletingPathExtension().lastPathComponent,
                             title: title.map(clean) ?? (prompt.isEmpty ? project : String(prompt.prefix(60))),
                             project: project, cwd: path, lastPrompt: prompt,
                             modified: modified, state: st, fromDesktop: desktop)
    }

    private static func clean(_ s: String) -> String {
        var t = s
        while let r = t.range(of: "<[a-z_-]+>[\\s\\S]*?</[a-z_-]+>", options: .regularExpression) { t.removeSubrange(r) }
        return t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class ClaudeSessions: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []
    private var timer: Timer?
    private var fast = false
    private var loading = false

    var waitingCount: Int { sessions.filter { $0.state.needsAction }.count }
    var workingCount: Int { sessions.filter { $0.state == .working }.count }

    func start() {
        guard timer == nil else { return }
        refresh()
        schedule()
    }

    /// Refresh every 3 s while the notch is open, every 20 s otherwise.
    func setFast(_ on: Bool) {
        guard on != fast else { return }
        fast = on
        if on { refresh() }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: fast ? 3 : 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task { [weak self] in
            let list = await Task.detached(priority: .utility) { SessionReader.scan(maxAge: 3 * 86400, limit: 10) }.value
            guard let self else { return }
            if list != self.sessions { self.sessions = list }
            self.loading = false
        }
    }

    func open(_ s: ClaudeSession) {
        let ids = ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        if let app = ids.lazy.compactMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }).first {
            app.activate()
        } else if let url = ids.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else {
            copyResume(s)
        }
    }

    func copyResume(_ s: ClaudeSession) {
        let cmd = s.cwd.isEmpty ? "claude --resume \(s.id)" : "cd \"\(s.cwd)\" && claude --resume \(s.id)"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd, forType: .string)
    }
}

struct ClaudeSessionsView: View {
    @ObservedObject var sessions: ClaudeSessions
    @ObservedObject var usage: ClaudeUsage

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ClaudeMark(size: 12)
                    Text(L("Sessions")).font(.system(size: 12, weight: .semibold))
                    if sessions.waitingCount > 0 {
                        Text(L("%d waiting", sessions.waitingCount))
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.85)))
                            .foregroundColor(.black)
                    }
                    Spacer()
                }
                if sessions.sessions.isEmpty {
                    Text(L("No Claude Code sessions in the last 3 days.")).font(.system(size: 11)).foregroundColor(.secondary)
                }
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(sessions.sessions) { s in row(s) }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                UsageDetail(usage: usage, showsHeader: true)
            }
            .frame(width: 200)
        }
    }

    private func row(_ s: ClaudeSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: s.state.symbol).font(.system(size: 12)).foregroundColor(s.state.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(s.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Text("\(s.project) · \(s.state.title) · \(s.modified.formatted(.relative(presentation: .named).locale(L10n.locale)))")
                    .font(.system(size: 9.5)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(s.state.needsAction ? 0.1 : 0.04)))
        .contentShape(Rectangle())
        .onTapGesture { sessions.open(s) }
        .contextMenu {
            Button(L("Bring Claude to front")) { sessions.open(s) }
            Button(L("Copy resume command for Terminal")) { sessions.copyResume(s) }
        }
        .help(s.lastPrompt.isEmpty ? s.title : L("Last message: %@", String(s.lastPrompt.prefix(200))))
    }
}
