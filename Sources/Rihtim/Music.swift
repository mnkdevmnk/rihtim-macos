import AppKit
import SwiftUI

enum MusicSource: String, Sendable {
    case music = "Music"
    case spotify = "Spotify"

    var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    var displayName: String { self == .music ? "Apple Music" : "Spotify" }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
}

enum OSAScript {
    /// Runs osascript as a child process. Call it off the main thread.
    static func run(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Turns AppleScript output like «data JPEG FFD8...» into Data.
    static func parseDataLiteral(_ s: String) -> Data? {
        guard let start = s.range(of: "«data "), let end = s.range(of: "»", options: .backwards),
              start.upperBound < end.lowerBound else { return nil }
        let body = s[start.upperBound..<end.lowerBound]
        guard body.count > 4 else { return nil }
        let hex = Array(body.dropFirst(4).utf8)
        var data = Data(capacity: hex.count / 2)
        var i = 0
        while i + 1 < hex.count {
            guard let hi = hexValue(hex[i]), let lo = hexValue(hex[i + 1]) else { return nil }
            data.append(hi << 4 | lo)
            i += 2
        }
        return data
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }
}

struct NowPlayingSnapshot: Sendable {
    let source: MusicSource
    let state: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let position: Double
    let artworkURL: String?
}

enum MusicQuery {
    static func snapshot(_ s: MusicSource) -> NowPlayingSnapshot? {
        // Sending AppleScript to an app that isn't running launches it, so check first.
        guard s.isRunning else { return nil }
        let durationExpr = s == .spotify ? "((duration of t) / 1000)" : "(duration of t)"
        let extra = s == .spotify ? " & \"||\" & (artwork url of t)" : ""
        let script = """
        tell application "\(s.rawValue)"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as string) & "||" & (name of t) & "||" & (artist of t) & "||" & (album of t) & "||" & \(durationExpr) & "||" & (player position)\(extra)
        end tell
        """
        guard let out = OSAScript.run(script) else { return nil }
        if out == "stopped" { return nil }
        let parts = out.components(separatedBy: "||")
        guard parts.count >= 6 else { return nil }
        func num(_ x: String) -> Double {
            Double(x.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return NowPlayingSnapshot(source: s, state: parts[0], title: parts[1], artist: parts[2], album: parts[3],
                                  duration: num(parts[4]), position: num(parts[5]),
                                  artworkURL: parts.count > 6 ? parts[6] : nil)
    }

    static func artworkData(for snap: NowPlayingSnapshot) -> Data? {
        switch snap.source {
        case .spotify:
            guard let s = snap.artworkURL, let url = URL(string: s) else { return nil }
            return try? Data(contentsOf: url)
        case .music:
            let script = """
            tell application "Music"
                try
                    return data of artwork 1 of current track
                end try
            end tell
            """
            guard let out = OSAScript.run(script) else { return nil }
            return OSAScript.parseDataLiteral(out)
        }
    }
}

/// Listens to Apple Music and Spotify via distributed notifications; controls go through AppleScript.
@MainActor
final class MusicController: ObservableObject {
    @Published private(set) var source: MusicSource?
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var duration: Double = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?

    var hasTrack: Bool { source != nil && !title.isEmpty }

    private var snapshots: [MusicSource: NowPlayingSnapshot] = [:]
    private var artworkKey = ""
    private var tokens: [NSObjectProtocol] = []
    private var ticker: Timer?

    init() {
        let dnc = DistributedNotificationCenter.default()
        tokens.append(dnc.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(.music) }
        })
        tokens.append(dnc.addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(.spotify) }
        })
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                if bid == MusicSource.music.bundleID { self.snapshots[.music] = nil; self.choose() }
                if bid == MusicSource.spotify.bundleID { self.snapshots[.spotify] = nil; self.choose() }
            }
        })
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, self.duration > 0 else { return }
                self.position = min(self.position + 1, self.duration)
            }
        }
        refresh(.music)
        refresh(.spotify)
    }

    func refresh(_ s: MusicSource) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snap = MusicQuery.snapshot(s)
            guard let self else { return }
            Task { @MainActor in self.apply(s, snap) }
        }
    }

    private func apply(_ s: MusicSource, _ snap: NowPlayingSnapshot?) {
        snapshots[s] = snap
        choose()
    }

    private func choose() {
        let candidates = [MusicSource.spotify, .music].compactMap { snapshots[$0] }
        let pick = candidates.first { $0.state == "playing" }
            ?? candidates.first { $0.source == source }
            ?? candidates.first
        guard let pick else {
            source = nil; title = ""; artist = ""; album = ""
            isPlaying = false; artwork = nil; artworkKey = ""; duration = 0; position = 0
            return
        }
        source = pick.source
        title = pick.title
        artist = pick.artist
        album = pick.album
        duration = pick.duration
        position = pick.position
        isPlaying = pick.state == "playing"

        let key = "\(pick.source.rawValue)|\(pick.title)|\(pick.album)"
        if key != artworkKey {
            artworkKey = key
            artwork = nil
            loadArtwork(pick, key: key)
        }
    }

    private func loadArtwork(_ snap: NowPlayingSnapshot, key: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = MusicQuery.artworkData(for: snap)
            guard let self else { return }
            Task { @MainActor in
                guard self.artworkKey == key, let data else { return }
                self.artwork = NSImage(data: data)
            }
        }
    }

    // MARK: controls

    func playPause() { isPlaying.toggle(); command("playpause") }
    func next() { command("next track") }
    func previous() { command("previous track") }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        let t = duration * max(0, min(1, fraction))
        position = t
        command("set player position to \(t)")
    }

    func openApp() {
        guard let s = source,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func command(_ cmd: String) {
        guard let s = source ?? [MusicSource.spotify, .music].first(where: { $0.isRunning }) else { return }
        let script = "tell application \"\(s.rawValue)\" to \(cmd)"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = OSAScript.run(script)
            guard let self else { return }
            Task { @MainActor in self.refresh(s) }
        }
    }
}

// MARK: - Views

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(Color.white.opacity(0.12))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }
}

struct MusicPill: View {
    @ObservedObject var music: MusicController
    let height: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            Artwork(image: music.artwork, size: height - 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(music.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(music.artist).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                PillButton(symbol: "backward.fill") { music.previous() }
                PillButton(symbol: music.isPlaying ? "pause.fill" : "play.fill", size: 16) { music.playPause() }
                PillButton(symbol: "forward.fill") { music.next() }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .modifier(PanelBackground(radius: height * 0.32))
    }
}

struct MusicPopover: View {
    @ObservedObject var music: MusicController

    private var progress: CGFloat {
        music.duration > 0 ? CGFloat(min(1, music.position / music.duration)) : 0
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Artwork(image: music.artwork, size: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text(music.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text(music.artist).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                    Text(music.album).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                    Text(music.source?.displayName ?? "").font(.system(size: 10, weight: .medium)).foregroundColor(.green)
                }
                Spacer(minLength: 0)
            }

            VStack(spacing: 4) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(Color.white).frame(width: g.size.width * progress)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                        music.seek(to: Double(v.location.x / max(g.size.width, 1)))
                    })
                }
                .frame(height: 5)
                HStack {
                    Text(Fmt.time(music.position))
                    Spacer()
                    Text(Fmt.time(music.duration))
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            }

            HStack(spacing: 26) {
                PillButton(symbol: "backward.fill", size: 18) { music.previous() }
                PillButton(symbol: music.isPlaying ? "pause.fill" : "play.fill", size: 24) { music.playPause() }
                PillButton(symbol: "forward.fill", size: 18) { music.next() }
            }

            Button(action: { music.openApp() }) {
                Text(L("Open the app")).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PanelBackground(radius: 18))
    }
}
