import AppKit
import Combine
import SwiftUI

/// Settings › Windows › Snapping
struct WindowSnapPage: View {
    @AppStorage(Prefs.snapKeys) private var keys = true
    @AppStorage(Prefs.snapDrag) private var drag = true
    @AppStorage(Prefs.snapGap) private var gap = 0.0
    @AppStorage(Prefs.snapCycle) private var cycle = true
    @AppStorage(Prefs.snapRestoreOnDrag) private var restoreOnDrag = true
    @AppStorage(Prefs.snapTopMaximize) private var topMax = true
    @AppStorage(Prefs.snapFlash) private var flash = true
    @AppStorage(Prefs.snapNeedsCmd) private var needsCmd = true
    @AppStorage(Prefs.snapSpaceDrag) private var spaceDrag = true
    @AppStorage(Prefs.snapSpaceDelay) private var spaceDelay = 0.45
    @State private var nativeTiling = WindowSnapPage.systemEdgeTiling
    @State private var revision = 0
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Is macOS 15+'s own edge tiling on? With both active you get two previews.
    static var systemEdgeTiling: Bool {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else { return false }
        let v = UserDefaults(suiteName: "com.apple.WindowManager")?.object(forKey: "EnableTilingByEdgeDrag") as? Bool
        return v ?? true
    }

    var body: some View {
        Form {
            Section(L("Drag to edge")) {
                Toggle(L("Snap windows dragged to a screen edge"), isOn: $drag)
                Toggle(L("Hold ⌘ to snap"), isOn: $needsCmd).disabled(!drag)
                Toggle(L("Top edge: maximize (top half when off)"), isOn: $topMax).disabled(!drag)
                Toggle(L("Dragging a snapped window restores its old size"), isOn: $restoreOnDrag)
                Text((needsCmd ? L("With ⌘ held:") + " " : "") + L("left / right edge: half · corners: quarter · bottom edge: thirds (left, center, right). The target is outlined in blue before you let go."))
                    .font(.caption).foregroundColor(.secondary)
            }
            Section(L("Between desktops")) {
                Toggle(L("Rest on the left / right edge to take the window to the next desktop"), isOn: $spaceDrag)
                    .disabled(!drag || !needsCmd)
                LabeledContent(L("Delay")) {
                    HStack {
                        Slider(value: $spaceDelay, in: 0.15...1.2, step: 0.05)
                        Text(L("%.2f s", spaceDelay)).monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                .disabled(!drag || !needsCmd || !spaceDrag)
                Text(needsCmd ? L("Drag to the edge without ⌘: a blue strip shows up, wait and the desktop switches with the window coming along. Stay on the edge to keep going. From the keyboard: ⌃⌥⇧ ← / →.")
                              : L("This needs \"Hold ⌘ to snap\" above to be on. From the keyboard: ⌃⌥⇧ ← / →."))
                    .font(.caption).foregroundColor(.secondary)
                Text(L("Uses the macOS \"Move left / right a space\" shortcut (Keyboard › Shortcuts › Mission Control); if it's off, Rıhtım turns it on briefly."))
                    .font(.caption).foregroundColor(.secondary)
                if drag && nativeTiling {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("macOS's own edge tiling is on too, so you may see two previews on top of each other."))
                            Text(L("You can turn off \"Drag windows to screen edges to tile\" in System Settings › Desktop & Dock."))
                                .font(.caption).foregroundColor(.secondary)
                            Button(L("Open Desktop & Dock settings")) {
                                if let u = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
                                    NSWorkspace.shared.open(u)
                                }
                            }
                        }
                    }
                }
            }
            Section(L("Appearance")) {
                LabeledContent(L("Gap between windows")) {
                    HStack {
                        Slider(value: $gap, in: 0...30, step: 1)
                        Text(gap == 0 ? L("none") : "\(Int(gap)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                Toggle(L("Pressing a half shortcut again cycles ½ → ⅔ → ⅓"), isOn: $cycle)
                Toggle(L("Briefly flash the target after a shortcut"), isOn: $flash)
            }
            Section(L("Shortcuts")) {
                Toggle(L("Use keyboard shortcuts"), isOn: $keys)
                ForEach(0..<5, id: \.self) { g in
                    ForEach(SnapAction.allCases.filter { $0.group == g }) { a in
                        ShortcutRow(action: a, revision: $revision)
                    }
                    .disabled(!keys)
                }
                HStack {
                    Text(L("Click a shortcut, then press the new keys. ⎋ cancels, ⌫ removes the shortcut."))
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button(L("Reset all to defaults")) {
                        for a in SnapAction.allCases { UserDefaults.standard.removeObject(forKey: a.prefKey) }
                        revision += 1
                        WindowSnapper.shared?.reloadHotKeys()
                    }
                }
            }
        }
        .onReceive(tick) { _ in nativeTiling = WindowSnapPage.systemEdgeTiling }
    }
}

private struct ShortcutRow: View {
    let action: SnapAction
    @Binding var revision: Int
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        let _ = revision
        HStack {
            Label(action.title, systemImage: action.symbol)
            Spacer()
            Button(recording ? L("Press keys…") : (action.shortcut?.display ?? "—")) {
                recording ? stop() : startRecording()
            }
            .font(.system(.body, design: .rounded).monospacedDigit())
            .frame(minWidth: 96)
            if UserDefaults.standard.string(forKey: action.prefKey) != nil {
                Button {
                    UserDefaults.standard.removeObject(forKey: action.prefKey)
                    changed()
                } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless)
                .help(L("Default: %@", action.defaultShortcut?.display ?? L("none")))
            }
        }
        .onDisappear { stop() }
    }

    private func startRecording() {
        recording = true
        WindowSnapper.shared?.suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }                                    // ⎋
            if e.keyCode == 51, e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                UserDefaults.standard.set("", forKey: action.prefKey)                     // ⌫ = remove
                stop(); changed(); return nil
            }
            guard let s = Shortcut.from(event: e) else { NSSound.beep(); return nil }
            // Clear the same keys from any other action.
            for other in SnapAction.allCases where other != action && other.shortcut.map({ $0.code == s.code && $0.mods == s.mods }) == true {
                UserDefaults.standard.set("", forKey: other.prefKey)
            }
            UserDefaults.standard.set(s.string, forKey: action.prefKey)
            stop(); changed()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            WindowSnapper.shared?.suspend(false)
        }
    }

    private func changed() {
        revision += 1
        WindowSnapper.shared?.reloadHotKeys()
    }
}
