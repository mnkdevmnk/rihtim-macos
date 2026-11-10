import AppKit
import SwiftUI

/// Usage limits of a Claude subscription (Pro/Max): the 5-hour window and the weekly one.
///
/// Reads the OAuth login Claude Code keeps in the Keychain ("Claude Code-credentials")
/// and calls the same `api/oauth/usage` endpoint as Claude Code's `/usage` screen.
/// The token is never refreshed here: refreshing rotates the refresh token and would
/// log Claude Code out. If it has expired, running `claude` once in a terminal fixes it.
struct UsageWindow: Equatable, Sendable {
    let percent: Double          // 0…100
    let resetsAt: Date?
}

enum UsageStatus: Equatable {
    case loading, ok, noLogin, expired
    case error(String)

    var message: String {
        switch self {
        case .loading: return L("Loading…")
        case .ok: return ""
        case .noLogin: return L("Can't update: not logged in to Claude Code. Run claude in a terminal and log in.")
        case .expired: return L("Can't update: the Claude Code login has expired. Run claude in a terminal; that renews it and Rıhtım picks it up within a few minutes.")
        case .error(let e): return L("Couldn't fetch: %@", e)
        }
    }
}

private struct OAuthCreds: Sendable {
    let token: String
    let expiresAt: Date?
    let plan: String?
}

private enum ClaudeAPI {
    /// Goes through the `security` tool instead of SecItem: it's already on the access
    /// list of Claude Code's Keychain item, so the user isn't prompted every time.
    static func readCredentials() -> OAuthCreds? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let o = obj["claudeAiOauth"] as? [String: Any],
              let token = o["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let exp = (o["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return OAuthCreds(token: token, expiresAt: exp, plan: o["subscriptionType"] as? String)
    }

    enum Result: Sendable {
        case ok([String: UsageWindow])
        case unauthorized
        case failed(String)
    }

    static func fetch(token: String) async -> Result {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("Rihtim/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return .unauthorized }
            guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed("HTTP \(code)")
            }
            var out: [String: UsageWindow] = [:]
            for (key, value) in obj {
                guard let d = value as? [String: Any], let u = d["utilization"] as? Double else { continue }
                out[key] = UsageWindow(percent: u, resetsAt: (d["resets_at"] as? String).flatMap(parseDate))
            }
            return .ok(out)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

@MainActor
final class ClaudeUsage: ObservableObject {
    @Published private(set) var fiveHour: UsageWindow?
    @Published private(set) var sevenDay: UsageWindow?
    @Published private(set) var sevenDayOpus: UsageWindow?
    @Published private(set) var sevenDaySonnet: UsageWindow?
    @Published private(set) var status: UsageStatus = .loading
    @Published private(set) var plan: String?
    @Published private(set) var updatedAt: Date?

    private var timer: Timer?
    private var inFlight = false

    var hasData: Bool { fiveHour != nil || sevenDay != nil }

    /// Show the help text on errors or when the last good update is over 20 minutes old.
    var needsHelp: Bool {
        if status == .loading { return false }
        if status != .ok { return true }
        return updatedAt.map { Date().timeIntervalSince($0) > 20 * 60 } ?? true
    }

    /// Runs a tiny .command file that starts `claude` in Terminal, which renews its own
    /// login. Usage is retried a few times afterwards.
    func openClaudeInTerminal() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rihtim", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("renew-claude-login.command")
        let message = L("Rıhtım: starting Claude Code. Its login renews once it opens; you can close this window afterwards.")
            .replacingOccurrences(of: "\"", with: "'")
        let script = """
        #!/bin/zsh -l
        echo "\(message)"
        claude
        """
        try? script.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
        for delay in [20.0, 60.0, 120.0] {
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }
    var planName: String { plan.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Claude" }

    func start() {
        guard timer == nil else { return }
        refresh()
        // The endpoint is rate limited; every 5 minutes is plenty.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        Task { [weak self] in
            let creds = await Task.detached { ClaudeAPI.readCredentials() }.value
            guard let self else { return }
            defer { self.inFlight = false }
            guard let creds else { self.status = .noLogin; return }
            self.plan = creds.plan
            if let exp = creds.expiresAt, exp < Date() { self.status = .expired; return }
            switch await ClaudeAPI.fetch(token: creds.token) {
            case .ok(let windows):
                self.fiveHour = windows["five_hour"]
                self.sevenDay = windows["seven_day"]
                self.sevenDayOpus = windows["seven_day_opus"]
                self.sevenDaySonnet = windows["seven_day_sonnet"]
                self.updatedAt = Date()
                self.status = .ok
            case .unauthorized:
                self.status = .expired
            case .failed(let e):
                self.status = .error(e)
            }
        }
    }

    /// One line for the menu bar and the notch.
    var summary: String {
        guard hasData else { return status == .loading ? "…" : "—" }
        var parts: [String] = []
        if let fiveHour { parts.append(L("5h %@", Fmt.pct(Int(fiveHour.percent.rounded())))) }
        if let sevenDay { parts.append(L("week %@", Fmt.pct(Int(sevenDay.percent.rounded())))) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Views

/// Fill bar, green → orange → red as it fills up.
struct UsageMeter: View {
    let percent: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(UsageMeter.color(percent))
                    .frame(width: max(0, min(1, percent / 100)) * g.size.width)
            }
        }
    }
    static func color(_ p: Double) -> Color { p >= 85 ? .red : (p >= 60 ? .orange : .green) }
}

struct UsageRow: View {
    let title: String
    let window: UsageWindow?
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: compact ? 9.5 : 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: compact ? 34 : 64, alignment: .leading)
            UsageMeter(percent: window?.percent ?? 0).frame(height: compact ? 4 : 6)
            Text(window.map { Fmt.pct(Int($0.percent.rounded())) } ?? "–")
                .font(.system(size: compact ? 10 : 12, weight: .semibold, design: .rounded))
                .frame(width: compact ? 32 : 40, alignment: .trailing)
        }
    }
}

struct ClaudeMark: View {
    var size: CGFloat = 15
    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .bold))
            .foregroundColor(Color(red: 0.85, green: 0.47, blue: 0.34))
    }
}

/// Pill in the Dock strip.
struct UsagePill: View {
    @ObservedObject var usage: ClaudeUsage
    let height: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(red: 0.85, green: 0.47, blue: 0.34).opacity(0.18))
                ClaudeMark()
            }
            .frame(width: height - 22, height: height - 22)
            if usage.hasData {
                VStack(spacing: 4) {
                    UsageRow(title: L("5h"), window: usage.fiveHour, compact: true)
                    UsageRow(title: L("Week"), window: usage.sevenDay, compact: true)
                }
                .opacity(usage.status == .ok ? 1 : 0.5)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(usage.planName).font(.system(size: 12, weight: .semibold))
                    Text(usage.status == .loading ? L("Loading…") : L("Not logged in")).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .modifier(PanelBackground(radius: height * 0.32))
    }
}

/// Detail view, used by the Dock popover and the notch card.
struct UsageDetail: View {
    @ObservedObject var usage: ClaudeUsage
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                HStack(spacing: 6) {
                    ClaudeMark(size: 13)
                    Text("Claude \(usage.planName)").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button(action: { usage.refresh() }) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help(L("Refresh now"))
                }
            }
            if usage.hasData {
                block(L("5-hour"), usage.fiveHour)
                block(L("Weekly"), usage.sevenDay)
                if let o = usage.sevenDayOpus { block(L("Weekly Opus"), o) }
                if let s = usage.sevenDaySonnet { block(L("Weekly Sonnet"), s) }
            }
            if usage.needsHelp {
                VStack(alignment: .leading, spacing: 5) {
                    Text(usage.status == .ok ? L("Hasn't updated in a while. Running claude in a terminal is enough.") : usage.status.message)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(action: { usage.openClaudeInTerminal() }) {
                            Label(L("Open claude in Terminal"), systemImage: "terminal")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        if let updatedAt = usage.updatedAt {
                            Text(L("Last data %@", Fmt.clock(updatedAt)))
                                .font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                }
            } else if let updatedAt = usage.updatedAt {
                Text(L("Updated %@", Fmt.clock(updatedAt)))
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func block(_ title: String, _ w: UsageWindow?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                if let r = w?.resetsAt {
                    Text(L("resets in %@", Fmt.until(r))).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Text(w.map { Fmt.pct(Int($0.percent.rounded())) } ?? "–")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
            UsageMeter(percent: w?.percent ?? 0).frame(height: 6)
        }
    }
}

struct UsagePopover: View {
    @ObservedObject var usage: ClaudeUsage
    var body: some View {
        UsageDetail(usage: usage)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(PanelBackground())
    }
}

extension Fmt {
    /// "2h 15m", "40m", "3d 4h"
    static func until(_ d: Date) -> String {
        let s = Int(max(0, d.timeIntervalSinceNow))
        let h = s / 3600, m = (s % 3600) / 60
        if h >= 24 { return L("%dd %dh", h / 24, h % 24) }
        if h > 0 { return L("%dh %dm", h, m) }
        return L("%dm", max(m, 1))
    }
}
