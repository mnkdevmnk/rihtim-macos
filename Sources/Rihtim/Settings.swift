import AppKit
import Combine
import IOKit
import ServiceManagement
import SwiftUI

/// Preference keys and defaults. The app listens for UserDefaults changes and re-applies
/// everything from here; the settings window and the status menu write the same keys.
enum Prefs {
    static let previews = "previewsEnabled"
    static let otherSpaces = "otherSpaces"
    static let switcher = "switcherEnabled"
    static let switcherTrigger = "switcherTrigger"
    static let bar = "barEnabled"
    static let notch = "notchEnabled"
    static let calendarIDs = "calendar.ids"
    static let calendarOpenLinks = "calendar.openLinks"
    static let batteryHidden = "battery.hidden"
    static let batteryPinned = "battery.pinned"
    static let batteryAlerts = "battery.alerts"
    static let batteryAlertLevel = "battery.alertLevel"
    static let onboarded = "onboarded"
    static let barCompact = "bar.compact"
    static let menuInterval = "menu.interval"
    static let menuZones = "menu.zones"
    static let notchBanners = "notch.banners"
    static let notchEyeBreak = "notch.eyeBreak"
    static let notchClipboard = "notch.clipboard"
    static let notchLeft = "notch.left"
    static let notchRight = "notch.right"
    static let notchTabs = "notch.tabs"
    static let notchWidth = "notch.width"
    static let notchSoftness = "notch.softness"
    static let notchHoverDelay = "notch.hoverDelay"
    static let notchHome = "notch.home"
    static let notchHUD = "notch.hud"
    static let notchAutoSize = "notch.autoSize"
    /// Percent per key press (⇧ = a quarter of it).
    static let stepVolume = "keys.stepVolume"
    static let stepBrightness = "keys.stepBrightness"
    static let stepKeyboard = "keys.stepKeyboard"
    static let barRevealDelay = "bar.revealDelay"
    static let barRevealDuration = "bar.revealDuration"
    static let barHeightMode = "bar.heightMode"
    static let barHeightAdjust = "bar.heightAdjust"
    static let barManualHeight = "bar.manualHeight"
    static let barOffsetY = "bar.offsetY"
    static let barGap = "bar.gap"
    static let barRadius = "bar.radius"
    static let barGlass = "bar.glass"
    static let barTint = "bar.tint"
    static let barSeparators = "bar.separators"
    /// Dock glass height as measured by the app (used by the settings preview).
    static let barMeasuredDock = "bar.measuredDock"

    static func barStyle() -> BarStyle {
        let d = UserDefaults.standard
        var s = BarStyle()
        s.heightMode = BarHeightMode(rawValue: d.string(forKey: barHeightMode) ?? "") ?? .dock
        s.heightAdjust = CGFloat(min(max(d.double(forKey: barHeightAdjust), -30), 30))
        s.manualHeight = CGFloat(min(max(d.double(forKey: barManualHeight), 28), 120))
        s.offsetY = CGFloat(min(max(d.double(forKey: barOffsetY), -30), 30))
        s.gap = CGFloat(min(max(d.double(forKey: barGap), 0), 40))
        s.radius = CGFloat(min(max(d.double(forKey: barRadius), 0), 0.5))
        var g = GlassKind(rawValue: d.string(forKey: barGlass) ?? "") ?? .regular
        if !GlassKind.liquidAvailable { g = .frosted }
        s.glass = g
        s.tint = CGFloat(min(max(d.double(forKey: barTint), -0.6), 0.6))
        s.separators = d.bool(forKey: barSeparators)
        return s
    }

    static let previewDelay = "preview.delay"
    static let previewScale = "preview.scale"
    static let previewListAfter = "preview.listAfter"
    static let previewMusic = "preview.music"
    static let previewExcluded = "preview.excluded"
    static let dockClick = "dock.click"
    static let dockScroll = "dock.scroll"
    static let dockQuitClick = "dock.quitClick"
    static let dockFolders = "dock.folders"
    static let dockFolderSort = "dock.folderSort"
    static let snapKeys = "snap.keys"
    static let snapDrag = "snap.drag"
    static let snapGap = "snap.gap"
    static let snapCycle = "snap.cycle"
    static let snapRestoreOnDrag = "snap.restoreOnDrag"
    static let snapTopMaximize = "snap.topMaximize"
    static let snapFlash = "snap.flash"
    static let snapNeedsCmd = "snap.needsCmd"
    static let snapSpaceDrag = "snap.spaceDrag"
    static let snapSpaceDelay = "snap.spaceDelay"

    static func previewSettings() -> PreviewSettings {
        let d = UserDefaults.standard
        var s = PreviewSettings()
        s.delay = min(max(d.double(forKey: previewDelay), 0), 1.5)
        s.scale = CGFloat(min(max(d.double(forKey: previewScale), 0.6), 1.6))
        s.listAfter = max(0, d.integer(forKey: previewListAfter))
        s.showsMusic = d.bool(forKey: previewMusic)
        s.excluded = stringSet(previewExcluded)
        return s
    }

    static func list<T: RawRepresentable>(_ key: String, _: T.Type) -> [T] where T.RawValue == String {
        (UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",").compactMap { T(rawValue: String($0)) }
    }

    static func notchConfig() -> NotchConfig {
        let d = UserDefaults.standard
        var c = NotchConfig()
        c.left = list(notchLeft, WingItem.self)
        c.right = list(notchRight, WingItem.self)
        let tabs = list(notchTabs, NotchTab.self)
        c.tabs = tabs.isEmpty ? [.home] : NotchTab.allCases.filter { tabs.contains($0) }
        c.expandedWidth = CGFloat(min(max(d.double(forKey: notchWidth), 440), NotchLayout.maxExpandedWidth))
        c.softness = CGFloat(min(max(d.double(forKey: notchSoftness), 0.3), 2))
        c.hoverDelay = min(max(d.double(forKey: notchHoverDelay), 0), 1)
        c.home = list(notchHome, HomeWidget.self)
        c.autoSize = d.bool(forKey: notchAutoSize)
        return c
    }

    static func zones() -> [TimeZone] {
        (UserDefaults.standard.string(forKey: menuZones) ?? "")
            .split(separator: ",")
            .compactMap { TimeZone(identifier: $0.trimmingCharacters(in: .whitespaces)) }
    }

    static func register() {
        var d: [String: Any] = [
            previews: true, otherSpaces: true, switcher: true,
            switcherTrigger: SwitcherTrigger.command.rawValue,
            bar: true, notch: true,
            calendarOpenLinks: false,
            batteryAlerts: true, batteryAlertLevel: 20,
            barCompact: false, menuInterval: 2.0,
            menuZones: "Europe/Istanbul, America/New_York, Asia/Tokyo",
            notchBanners: true, notchEyeBreak: false, notchClipboard: true,
            notchLeft: "music,coffee", notchRight: "claude,cpu",
            notchTabs: NotchTab.allCases.map(\.rawValue).joined(separator: ","),
            notchWidth: 660.0, notchSoftness: 1.0, notchHoverDelay: 0.12,
            notchHome: "music,system,usage,coffee", notchAutoSize: true, notchHUD: true,
            stepVolume: 6.25, stepBrightness: 6.25, stepKeyboard: 6.25,
            barRevealDelay: 0.5, barRevealDuration: 0.35,
            barHeightMode: BarHeightMode.dock.rawValue, barHeightAdjust: 0.0, barManualHeight: 60.0,
            barOffsetY: 0.0, barGap: 8.0, barRadius: 0.42, barGlass: GlassKind.regular.rawValue,
            barTint: 0.0, barSeparators: true, barMeasuredDock: 70.0,
            previewDelay: 0.18, previewScale: 1.0, previewListAfter: 8, previewMusic: true,
            dockClick: DockClickAction.minimize.rawValue, dockScroll: true, dockQuitClick: true,
            dockFolders: true, dockFolderSort: FolderSort.added.rawValue,
            snapKeys: true, snapDrag: true, snapGap: 0.0, snapCycle: true,
            snapRestoreOnDrag: true, snapTopMaximize: true, snapFlash: true,
            snapNeedsCmd: true, snapSpaceDrag: true, snapSpaceDelay: 0.45,
        ]
        for m in MenuModule.allCases {
            d[m.enabledKey] = m.defaultOn
        }
        for k in PopoverKind.allCases {
            d[k.enabledKey] = true
            d[k.sideKey] = k.defaultSide.rawValue
        }
        UserDefaults.standard.register(defaults: d)
    }

    static func stringSet(_ key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func setStringSet(_ key: String, _ value: Set<String>) {
        UserDefaults.standard.set(Array(value).sorted(), forKey: key)
    }
}

struct SettingsModels {
    let music: MusicController
    let system: SystemMonitor
    let batteries: BatteryMonitor
    let caffeine: Caffeine
    let usage: ClaudeUsage
    let calendar: CalendarMonitor
    let weather: WeatherMonitor
    let shelf: NotchShelf
    let clipboard: ClipboardHistory
    let sessions: ClaudeSessions
    let brightness: BrightnessBoost
    let notch: NotchController
    let menuStats: MenuStats
    let relaunch: @MainActor () -> Void
}

// MARK: - Window

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let models: SettingsModels

    init(models: SettingsModels) { self.models = models }

    func show(page: SettingsPage? = nil) {
        if let page { SettingsNav.shared.page = page }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(m: models))
            let w = NSWindow(contentViewController: host)
            w.title = L("Rıhtım Settings")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.setContentSize(NSSize(width: 900, height: 680))
            w.contentMinSize = NSSize(width: 680, height: 480)
            w.setFrameAutosaveName("RihtimSettings")
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        // Show a Dock icon while Settings is open so it's reachable with ⌘⇥.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Views

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, calendar, weather, batteries, extras
    case notch, notch_closed, notch_open, notch_media, notch_extras
    case dock, dock_actions, widgets
    case windows
    case dashboard
    case mb_cpu, mb_gpu, mb_ram, mb_disk, mb_sensors, mb_network, mb_battery, mb_bluetooth, mb_clock
    var id: String { rawValue }

    static let rihtim: [SettingsPage] = [.general, .calendar, .weather, .batteries, .extras]
    static let notchPages: [SettingsPage] = [.notch, .notch_closed, .notch_open, .notch_media, .notch_extras]
    static let dockPages: [SettingsPage] = [.dock, .dock_actions, .widgets]
    static let windowPages: [SettingsPage] = [.windows]
    static let menuBar: [SettingsPage] = [.dashboard] + MenuModule.allCases.map(SettingsPage.mb)

    static func mb(_ m: MenuModule) -> SettingsPage { SettingsPage(rawValue: "mb_" + m.rawValue) ?? .dashboard }
    var module: MenuModule? { rawValue.hasPrefix("mb_") ? MenuModule(rawValue: String(rawValue.dropFirst(3))) : nil }

    var title: String {
        if let module { return module.title }
        switch self {
        case .general: return L("General")
        case .dock: return L("Previews and ⌘⇥")
        case .dock_actions: return L("Icon gestures and folders")
        case .widgets: return L("Widget strip")
        case .windows: return L("Snapping")
        case .notch: return L("General and preview")
        case .notch_closed: return L("Closed")
        case .notch_open: return L("Open and tabs")
        case .notch_media: return L("Volume and brightness")
        case .notch_extras: return L("Banners, clipboard, shelf")
        case .calendar: return L("Calendar")
        case .weather: return L("Weather")
        case .batteries: return L("Batteries")
        case .extras: return L("Coffee and Claude")
        case .dashboard: return L("Dashboard")
        default: return ""
        }
    }
    var symbol: String {
        if let module { return module.symbol }
        switch self {
        case .general: return "gearshape"
        case .dock: return "dock.rectangle"
        case .dock_actions: return "cursorarrow.click.2"
        case .widgets: return "square.grid.2x2"
        case .windows: return "rectangle.split.2x1"
        case .notch: return "rectangle.topthird.inset.filled"
        case .notch_closed: return "capsule"
        case .notch_open: return "rectangle.expand.vertical"
        case .notch_media: return "sun.max"
        case .notch_extras: return "bell.badge"
        case .calendar: return "calendar"
        case .weather: return "cloud.sun"
        case .batteries: return "battery.75percent"
        case .extras: return "cup.and.saucer"
        case .dashboard: return "square.grid.3x3.fill"
        default: return "circle"
        }
    }
}

/// Which settings page is showing (lets the menu bar jump straight to a module).
@MainActor
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var page: SettingsPage? = .general
}

struct SettingsView: View {
    let m: SettingsModels
    @ObservedObject private var nav = SettingsNav.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.page) {
                Section("Rıhtım") {
                    ForEach(SettingsPage.rihtim) { p in Label(p.title, systemImage: p.symbol).tag(p) }
                }
                Section("Notch") {
                    ForEach(SettingsPage.notchPages) { p in Label(p.title, systemImage: p.symbol).tag(p) }
                }
                Section("Dock") {
                    ForEach(SettingsPage.dockPages) { p in Label(p.title, systemImage: p.symbol).tag(p) }
                }
                Section(L("Windows")) {
                    ForEach(SettingsPage.windowPages) { p in Label(p.title, systemImage: p.symbol).tag(p) }
                }
                Section(L("Menu bar")) {
                    ForEach(SettingsPage.menuBar) { p in Label(p.title, systemImage: p.symbol).tag(p) }
                }
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            let page = nav.page ?? .general
            Group {
                if let module = page.module {
                    ModuleSettingsPage(module: module, stats: m.menuStats, system: m.system, batteries: m.batteries)
                        .id(module)
                } else {
                    switch page {
                    case .general: GeneralPage(relaunch: m.relaunch)
                    case .dock: DockPage()
                    case .dock_actions: DockActionsPage()
                    case .widgets: WidgetsPage()
                    case .windows: WindowSnapPage()
                    case .notch, .notch_closed, .notch_open, .notch_media, .notch_extras: NotchPage(m: m, page: page).id(page)
                    case .calendar: CalendarPage(calendar: m.calendar)
                    case .weather: WeatherPage(weather: m.weather)
                    case .batteries: BatteriesPage(batteries: m.batteries)
                    case .extras: ExtrasPage(caffeine: m.caffeine, usage: m.usage)
                    default: StatsDashboard(stats: m.menuStats, system: m.system) { nav.page = .mb($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(page.module != nil ? "" : (SettingsPage.notchPages.contains(page) ? "Notch · \(page.title)"
                             : SettingsPage.dockPages.contains(page) ? "Dock · \(page.title)"
                             : SettingsPage.windowPages.contains(page) ? L("Windows") + " · \(page.title)" : page.title))
        }
        .frame(minWidth: 680, minHeight: 480)
    }
}

private struct GeneralPage: View {
    let relaunch: @MainActor () -> Void
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var ax = Permissions.hasAccessibility
    @State private var sr = Permissions.hasScreenRecording
    @State private var loginError: String?
    @AppStorage(L10n.prefKey) private var language = AppLanguage.system.rawValue
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var languageChanged: Bool {
        L10n.resolve(language) != L10n.code
    }

    var body: some View {
        Form {
            Section {
                Toggle(L("Launch at login"), isOn: Binding(get: { login }, set: setLogin))
                if let loginError { Text(loginError).font(.caption).foregroundColor(.red) }
            }
            Section(L("Language")) {
                Picker(L("Language"), selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0.rawValue) }
                }
                if languageChanged {
                    HStack {
                        Text(L("Restart Rıhtım to switch the language.")).font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button(L("Restart now")) { relaunch() }
                    }
                }
            }
            Section(L("Permissions")) {
                permission(L("Accessibility"), L("Needed to watch the Dock, for windows and for ⌘⇥."), ax) {
                    Permissions.promptAccessibility(); Permissions.openPane("Privacy_Accessibility")
                }
                permission(L("Screen Recording"), L("For live window thumbnails."), sr) {
                    Permissions.requestScreenRecording(); Permissions.openPane("Privacy_ScreenCapture")
                }
                if !sr || !ax {
                    Button(L("I've granted it, restart")) { relaunch() }
                }
            }
            Section {
                LabeledContent(L("Version"), value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                LabeledContent(L("Source code")) {
                    Link("github.com/mnkdevmnk/rihtim-macos", destination: URL(string: "https://github.com/mnkdevmnk/rihtim-macos")!)
                }
                Button(L("Quit Rıhtım"), role: .destructive) { NSApp.terminate(nil) }
            }
        }
        .onReceive(tick) { _ in
            ax = Permissions.hasAccessibility
            sr = Permissions.hasScreenRecording
            login = SMAppService.mainApp.status == .enabled
        }
    }

    private func permission(_ title: String, _ detail: String, _ ok: Bool, _ action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if ok {
                Label(L("Granted"), systemImage: "checkmark.circle.fill").foregroundColor(.green)
            } else {
                Button(L("Grant…"), action: action)
            }
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription + ". " + L("The app has to be in /Applications.")
        }
        login = SMAppService.mainApp.status == .enabled
    }
}

private struct DockPage: View {
    @AppStorage(Prefs.previews) private var previews = true
    @AppStorage(Prefs.otherSpaces) private var otherSpaces = true
    @AppStorage(Prefs.switcher) private var switcher = true
    @AppStorage(Prefs.switcherTrigger) private var trigger = SwitcherTrigger.command.rawValue
    @AppStorage(Prefs.previewDelay) private var delay = 0.18
    @AppStorage(Prefs.previewScale) private var scale = 1.0
    @AppStorage(Prefs.previewListAfter) private var listAfter = 8
    @AppStorage(Prefs.previewMusic) private var music = true
    @State private var excluded = Prefs.stringSet(Prefs.previewExcluded)

    var body: some View {
        Form {
            Section(L("Dock previews")) {
                Toggle(L("Show windows when hovering a Dock icon"), isOn: $previews)
                Toggle(L("Include windows on other desktops (Spaces)"), isOn: $otherSpaces)
                    .disabled(!previews)
                Toggle(L("Show the playing track and controls on the Music / Spotify icon"), isOn: $music)
                    .disabled(!previews)
                Text(L("Clicking a window on another desktop switches macOS to that desktop. Hover a card: yellow minimizes, red closes. Header buttons: minimize all, close all, hide, quit."))
                    .font(.caption).foregroundColor(.secondary)
            }
            Section(L("Appearance")) {
                LabeledContent(L("Open delay")) {
                    HStack {
                        Slider(value: $delay, in: 0...1, step: 0.05)
                        Text(delay == 0 ? L("instant") : L("%.2f s", delay))
                            .monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                Picker(L("Preview size"), selection: $scale) {
                    Text(L("Small")).tag(0.75)
                    Text(L("Medium")).tag(1.0)
                    Text(L("Large")).tag(1.3)
                    Text(L("Extra large")).tag(1.6)
                }
                Picker(L("Switch to list view"), selection: $listAfter) {
                    Text(L("Never")).tag(0)
                    ForEach([4, 6, 8, 12, 16], id: \.self) { n in Text(L("More than %d windows", n)).tag(n) }
                }
            }
            .disabled(!previews)
            Section(L("Apps without previews")) {
                if excluded.isEmpty {
                    Text(L("None")).foregroundColor(.secondary)
                }
                ForEach(excluded.sorted(), id: \.self) { bid in
                    HStack {
                        if let icon = AppLookup.icon(bid) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                        Text(AppLookup.name(bid))
                        Spacer()
                        Button(L("Remove")) { excluded.remove(bid); save() }
                    }
                }
                Menu(L("Add app")) {
                    ForEach(AppLookup.runningRegular().filter { !excluded.contains($0.id) }) { a in
                        Button(a.name) { excluded.insert(a.id); save() }
                    }
                }
                .fixedSize()
            }
            .disabled(!previews)
            Section(L("App switcher")) {
                Toggle(L("Use Rıhtım's switcher"), isOn: $switcher)
                Picker(L("Shortcut"), selection: $trigger) {
                    Text(L("⌘⇥ (replaces the system one)")).tag(SwitcherTrigger.command.rawValue)
                    Text("⌥⇥").tag(SwitcherTrigger.option.rawValue)
                }
                .disabled(!switcher)
                Text(L("While ⌘ is held: ⇥ / ⇧⇥ / ← → app · ↑ ↓ window · Q quit · H hide · W close · Esc cancel"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func save() { Prefs.setStringSet(Prefs.previewExcluded, excluded) }
}

/// Size and glass settings for the widget strip, with a live preview.
private struct BarStyleSection: View {
    @AppStorage(Prefs.barHeightMode) private var mode = BarHeightMode.dock.rawValue
    @AppStorage(Prefs.barHeightAdjust) private var adjust = 0.0
    @AppStorage(Prefs.barManualHeight) private var manual = 60.0
    @AppStorage(Prefs.barOffsetY) private var offsetY = 0.0
    @AppStorage(Prefs.barGap) private var gap = 8.0
    @AppStorage(Prefs.barRadius) private var radius = 0.42
    @AppStorage(Prefs.barGlass) private var glass = GlassKind.regular.rawValue
    @AppStorage(Prefs.barTint) private var tint = 0.0
    @AppStorage(Prefs.barSeparators) private var separators = true
    @AppStorage(Prefs.barMeasuredDock) private var dockH = 70.0

    private var barH: Double {
        min(max(mode == BarHeightMode.manual.rawValue ? manual : dockH + adjust, 28), 120).rounded()
    }

    var body: some View {
        Section(L("Appearance")) {
            preview
            Picker(L("Height"), selection: $mode) {
                Text(L("Match the Dock")).tag(BarHeightMode.dock.rawValue)
                Text(L("Manual")).tag(BarHeightMode.manual.rawValue)
            }
            .pickerStyle(.segmented)
            if mode == BarHeightMode.dock.rawValue {
                slider(L("Fine-tune"), $adjust, -20...20, 1) { v in v == 0 ? L("exact") : String(format: "%+.0f pt", v) }
            } else {
                slider(L("Height"), $manual, 28...120, 1) { String(format: "%.0f pt", $0) }
            }
            slider(L("Vertical offset"), $offsetY, -20...20, 1) { v in v == 0 ? L("centered") : String(format: "%+.0f pt", v) }
            slider(L("Distance to the Dock"), $gap, 0...40, 1) { String(format: "%.0f pt", $0) }
            slider(L("Corner rounding"), $radius, 0...0.5, 0.01) { String(format: "%.0f pt", $0 * barH) }
            Picker(L("Glass"), selection: $glass) {
                ForEach(GlassKind.allCases.filter { GlassKind.liquidAvailable || $0 == .frosted }) { g in
                    Text(g.title).tag(g.rawValue)
                }
            }
            slider(L("Tint"), $tint, -0.6...0.6, 0.05) { v in
                abs(v) < 0.01 ? L("none") : (v > 0 ? L("dark %@", Fmt.pct(Int(v * 100))) : L("light %@", Fmt.pct(Int(-v * 100))))
            }
            Toggle(L("Separator lines between widgets"), isOn: $separators)
            HStack {
                Text(L("Measured Dock glass: %d pt · strip: %d pt", Int(dockH), Int(barH)))
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(L("Reset to defaults")) {
                    mode = BarHeightMode.dock.rawValue; adjust = 0; manual = 70; offsetY = 0; gap = 8
                    radius = 0.42; glass = GlassKind.regular.rawValue; tint = 0; separators = true
                }
            }
        }
    }

    /// Scaled mock-up of the strip next to the Dock. Changes also apply to the real strip right away.
    private var preview: some View {
        let k = GlassKind(rawValue: glass) ?? .regular
        let dockGlassH = CGFloat(dockH)
        let h = CGFloat(barH)
        let s: CGFloat = 0.8
        return ZStack {
            LinearGradient(colors: [Color(red: 0.25, green: 0.35, blue: 0.6), Color(red: 0.75, green: 0.45, blue: 0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(alignment: .center, spacing: CGFloat(gap) * s) {
                HStack(spacing: 0) {
                    ForEach(0..<3) { i in
                        if i > 0 {
                            Capsule().fill(Color.primary.opacity(separators ? 0.18 : 0))
                                .frame(width: 1, height: h * s * 0.5).padding(.horizontal, 3)
                        }
                        Image(systemName: ["music.note", "cpu", "battery.75percent"][i])
                            .font(.system(size: 13 * s * h / 60))
                            .frame(width: 58 * s)
                    }
                }
                .frame(height: h * s)
                .background(GlassBackground(cornerRadius: h * s * CGFloat(radius), kind: k, tint: CGFloat(tint)).id(k))
                .offset(y: -CGFloat(offsetY) * s)

                HStack(spacing: 6 * s) {
                    ForEach(["safari", "folder", "terminal", "gearshape"], id: \.self) { sym in
                        RoundedRectangle(cornerRadius: 10 * s, style: .continuous)
                            .fill(Color.white.opacity(0.25))
                            .frame(width: (dockGlassH - 10) * s, height: (dockGlassH - 10) * s)
                            .overlay(Image(systemName: sym).font(.system(size: 16 * s)).foregroundColor(.white))
                    }
                }
                .padding(.horizontal, 6 * s)
                .frame(height: dockGlassH * s)
                .background(GlassBackground(cornerRadius: dockGlassH * s * 0.42))
                .overlay(alignment: .top) {
                    Text("Dock").font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.8)).offset(y: -14)
                }
            }
        }
        .frame(height: max(dockGlassH, h) * s + 50)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .listRowInsets(EdgeInsets())
    }

    private func slider(_ title: String, _ v: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double,
                        _ fmt: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: v, in: range, step: step)
                Text(fmt(v.wrappedValue)).monospacedDigit().frame(width: 78, alignment: .trailing)
            }
        }
    }
}

/// App name / icon from a bundle ID.
enum AppLookup {
    struct Entry: Identifiable { let id: String; let name: String }

    static func name(_ bid: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
           let n = app.localizedName { return n }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bid
    }

    static func icon(_ bid: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func runningRegular() -> [Entry] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap { a -> Entry? in
                guard let bid = a.bundleIdentifier, seen.insert(bid).inserted else { return nil }
                return Entry(id: bid, name: a.localizedName ?? bid)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct DockActionsPage: View {
    @AppStorage(Prefs.dockClick) private var click = DockClickAction.minimize.rawValue
    @AppStorage(Prefs.dockScroll) private var scroll = true
    @AppStorage(Prefs.dockQuitClick) private var quitClick = true
    @AppStorage(Prefs.dockFolders) private var folders = true
    @AppStorage(Prefs.dockFolderSort) private var folderSort = FolderSort.added.rawValue

    var body: some View {
        Form {
            Section(L("Dock icon gestures")) {
                Picker(L("Clicking the frontmost app's icon"), selection: $click) {
                    ForEach(DockClickAction.allCases) { a in Text(a.title).tag(a.rawValue) }
                }
                Toggle(L("Scroll on an icon: down hides, up shows"), isOn: $scroll)
                Toggle(L("⌘ + right-click quits, ⌥⌘ + right-click force quits"), isOn: $quitClick)
                Text(L("Rıhtım never touches the real Dock; it reads mouse events and only acts while the pointer is over an app icon. Scrolling follows your finger direction, respecting natural scrolling."))
                    .font(.caption).foregroundColor(.secondary)
            }
            Section(L("Dock folders")) {
                Toggle(L("Show folder contents on hover"), isOn: $folders)
                Picker(L("Sort by"), selection: $folderSort) {
                    ForEach(FolderSort.allCases) { s in Text(s.title).tag(s.rawValue) }
                }
                .disabled(!folders)
                Text(L("Click a file to open it · click the magnifier to show it in Finder · drag it into another app. macOS asks for permission the first time for Downloads/Documents."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

private struct WidgetsPage: View {
    @AppStorage(Prefs.bar) private var bar = true
    @AppStorage(Prefs.barCompact) private var compact = false
    @AppStorage(Prefs.barRevealDelay) private var revealDelay = 0.5
    @AppStorage(Prefs.barRevealDuration) private var revealDuration = 0.35

    var body: some View {
        Form {
            Section {
                Toggle(L("Widget strip next to the Dock"), isOn: $bar)
                Toggle(L("Always compact (icon + value)"), isOn: $compact).disabled(!bar)
                Text(L("When space runs out widgets go compact on their own, then the lowest-priority ones get hidden. Battery goes last."))
                    .font(.caption).foregroundColor(.secondary)
            }
            BarStyleSection().disabled(!bar)
            Section(L("Sync with an auto-hiding Dock")) {
                Slider(value: $revealDelay, in: 0...1.5, step: 0.05) { Text(L("Open delay: %.2f s", revealDelay)) }
                Slider(value: $revealDuration, in: 0.1...1, step: 0.05) { Text(L("Slide duration: %.2f s", revealDuration)) }
                Text(L("If Rıhtım can read the Dock's position it simply follows it and these don't matter. Otherwise it mimics the Dock with this timing."))
                    .font(.caption).foregroundColor(.secondary)
            }.disabled(!bar)
            Section(L("Widgets in the Dock strip")) {
                ForEach(PopoverKind.allCases) { k in WidgetRow(kind: k).disabled(!bar) }
            }
            Text(L("Widgets only show while the Dock is at the bottom. With an auto-hiding Dock they appear when the pointer hits the bottom edge. If there's no room, that side's strip is hidden."))
                .font(.caption).foregroundColor(.secondary)
        }
    }
}

private struct WidgetRow: View {
    let kind: PopoverKind
    @AppStorage private var on: Bool
    @AppStorage private var side: String

    init(kind: PopoverKind) {
        self.kind = kind
        _on = AppStorage(wrappedValue: true, kind.enabledKey)
        _side = AppStorage(wrappedValue: kind.defaultSide.rawValue, kind.sideKey)
    }

    var body: some View {
        HStack {
            Toggle(isOn: $on) { Label(kind.title, systemImage: kind.symbol) }
            Spacer()
            Picker("", selection: $side) {
                ForEach(BarSide.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .labelsHidden()
            .frame(width: 140)
            .disabled(!on)
        }
    }
}

private struct CalendarPage: View {
    @ObservedObject var calendar: CalendarMonitor
    @AppStorage(Prefs.calendarOpenLinks) private var openLinks = false
    @State private var selected = Prefs.stringSet(Prefs.calendarIDs)

    var body: some View {
        Form {
            Section {
                switch calendar.access {
                case .granted: Label(L("Calendar access granted"), systemImage: "checkmark.circle.fill").foregroundColor(.green)
                case .denied:
                    HStack {
                        Text(L("Calendar access is off"))
                        Spacer()
                        Button(L("Open Settings")) { Permissions.openPane("Privacy_Calendars") }
                    }
                case .unknown:
                    Button(L("Request calendar access")) { calendar.start() }
                }
                Toggle(L("Open the meeting link when it starts (Zoom, Meet, Teams…)"), isOn: $openLinks)
            }
            Section(L("Calendars to show")) {
                if calendar.calendars.isEmpty { Text(L("No calendars found")).foregroundColor(.secondary) }
                ForEach(calendar.calendars) { c in
                    Toggle(isOn: Binding(get: { isOn(c) }, set: { set(c, $0) })) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(nsColor: c.color)).frame(width: 9, height: 9)
                            Text(c.title)
                            Text(c.source).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                if !selected.isEmpty {
                    Button(L("Reset (all except birthdays and holidays)")) {
                        selected = []
                        Prefs.setStringSet(Prefs.calendarIDs, [])
                    }
                }
            }
        }
    }

    private func isOn(_ c: CalInfo) -> Bool { selected.isEmpty ? !c.isNoise : selected.contains(c.id) }

    private func set(_ c: CalInfo, _ on: Bool) {
        if selected.isEmpty { selected = Set(calendar.calendars.filter { !$0.isNoise }.map(\.id)) }
        if on { selected.insert(c.id) } else { selected.remove(c.id) }
        if selected.isEmpty { selected = ["-"] }      // nothing selected
        Prefs.setStringSet(Prefs.calendarIDs, selected)
    }
}

private struct WeatherPage: View {
    @ObservedObject var weather: WeatherMonitor
    @State private var query = ""
    @State private var results: [GeoPlace] = []
    @State private var searching = false

    var body: some View {
        Form {
            Section(L("Location")) {
                LabeledContent(L("Current"), value: "\(weather.place.name) · \(weather.place.detail)")
                HStack {
                    TextField(L("Search for a city"), text: $query).onSubmit(search)
                    Button(L("Search"), action: search).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                    if searching { ProgressView().controlSize(.small) }
                }
                ForEach(results) { p in
                    Button(action: { weather.setPlace(p); results = []; query = "" }) {
                        HStack {
                            Text(p.name)
                            Text(p.detail).foregroundColor(.secondary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                if let n = weather.now {
                    LabeledContent(L("Now"), value: "\(Int(n.temp.rounded()))° · \(WeatherCode.text(n.code))")
                }
                Button(L("Refresh now")) { weather.refresh() }
                Text(L("Data: Open-Meteo (no API key or location permission needed). Refreshes every 15 minutes."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        Task {
            results = await weather.search(q)
            searching = false
        }
    }
}

private struct BatteriesPage: View {
    @ObservedObject var batteries: BatteryMonitor
    @AppStorage(Prefs.batteryAlerts) private var alerts = true
    @AppStorage(Prefs.batteryAlertLevel) private var level = 20
    @AppStorage(Prefs.batteryPinned) private var pinned = ""
    @State private var hidden = Prefs.stringSet(Prefs.batteryHidden)

    var body: some View {
        Form {
            Section(L("Devices")) {
                if batteries.allDevices.isEmpty { Text(L("No devices found")).foregroundColor(.secondary) }
                ForEach(batteries.allDevices) { d in
                    HStack {
                        Image(systemName: d.symbol).frame(width: 20)
                        Text(d.name)
                        Text(d.mainPercent.map { Fmt.pct($0) } ?? "–").foregroundColor(.secondary)
                        Spacer()
                        Button(action: { pinned = pinned == d.name ? "" : d.name }) {
                            Image(systemName: pinned == d.name ? "pin.fill" : "pin")
                        }
                        .buttonStyle(.borderless)
                        .help(L("Pin to the front"))
                        Toggle(L("Show"), isOn: Binding(get: { !hidden.contains(d.name) }, set: { show in
                            if show { hidden.remove(d.name) } else { hidden.insert(d.name) }
                            Prefs.setStringSet(Prefs.batteryHidden, hidden)
                        }))
                        .labelsHidden()
                    }
                }
                Button(L("Refresh")) { batteries.refreshNow() }
            }
            Section(L("Alert")) {
                Toggle(L("Notify when a battery runs low"), isOn: $alerts)
                Stepper(L("Threshold: %@", Fmt.pct(level)), value: $level, in: 5...50, step: 5).disabled(!alerts)
            }
        }
    }
}

private struct ExtrasPage: View {
    @ObservedObject var caffeine: Caffeine
    @ObservedObject var usage: ClaudeUsage

    var body: some View {
        Form {
            Section(L("Coffee (keep awake)")) {
                HStack {
                    CaffeineIcon(active: caffeine.isActive)
                    Text(caffeine.isActive ? L("Coffee on: %@", caffeine.shortStatus) : L("Coffee off, the Mac sleeps as usual"))
                    Spacer()
                    Button(caffeine.isActive ? L("Turn off") : L("Turn on indefinitely")) { caffeine.toggle() }
                }
                Picker(L("Duration"), selection: Binding(get: { caffeine.isActive ? (caffeine.selectedMinutes ?? 0) : -1 },
                                                  set: { v in v < 0 ? caffeine.deactivate() : caffeine.select(v == 0 ? nil : v) })) {
                    Text(L("Off")).tag(-1)
                    ForEach(Caffeine.durations, id: \.0) { title, minutes in Text(title).tag(minutes ?? 0) }
                }
                .pickerStyle(.segmented)
                Toggle(L("Keep the display on too"), isOn: $caffeine.keepDisplayOn)
            }
            Section(L("Espresso (lid closed)")) {
                Toggle(L("Espresso: keep running with the lid closed"), isOn: $caffeine.espresso)
                if caffeine.espressoActive {
                    Label(L("Lid sleep is off. Downloads, builds and Claude keep running with the lid closed."), systemImage: "cup.and.heat.waves.fill")
                        .foregroundColor(.orange)
                }
                if let err = caffeine.espressoError {
                    Label(err, systemImage: "exclamationmark.triangle").foregroundColor(.secondary)
                }
                Stepper(L("Turn off on battery at %@", Fmt.pct(caffeine.espressoMinBattery)),
                        value: $caffeine.espressoMinBattery, in: 5...50, step: 5)
                Text(L("Turns Coffee on and runs `pmset disablesleep` so the Mac doesn't sleep when the lid closes. Asks for your password once (a sudoers rule that allows only that command). Lid sleep comes back when Coffee ends, on quit, and after a crash. Don't put the Mac in a bag while Espresso is on: it can get hot."))
                    .font(.caption).foregroundColor(.secondary)
            }
            Section(L("Claude usage")) {
                UsageDetail(usage: usage)
                Text(L("Uses Claude Code's login from the Keychain. Rıhtım never renews it; if it expires, just run `claude` once in a terminal."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

private struct NotchPage: View {
    let m: SettingsModels
    let page: SettingsPage
    @ObservedObject private var shelf: NotchShelf
    @ObservedObject private var clipboard: ClipboardHistory
    @ObservedObject private var brightness: BrightnessBoost

    init(m: SettingsModels, page: SettingsPage) {
        self.m = m
        self.page = page
        _shelf = ObservedObject(wrappedValue: m.shelf)
        _clipboard = ObservedObject(wrappedValue: m.clipboard)
        _brightness = ObservedObject(wrappedValue: m.brightness)
    }
    @AppStorage(Prefs.notch) private var notch = true
    @AppStorage(Prefs.notchBanners) private var banners = true
    @AppStorage(Prefs.notchEyeBreak) private var eyeBreak = false
    @AppStorage(Prefs.notchClipboard) private var clip = true
    @AppStorage(Prefs.notchWidth) private var width = 660.0
    @AppStorage(Prefs.notchSoftness) private var softness = 1.0
    @AppStorage(Prefs.notchHoverDelay) private var hoverDelay = 0.12
    @AppStorage(Prefs.notchAutoSize) private var autoSize = true
    @AppStorage(Prefs.notchHUD) private var hud = true
    @AppStorage(Prefs.stepVolume) private var stepVolume = 6.25
    @AppStorage(Prefs.stepBrightness) private var stepBrightness = 6.25
    @AppStorage(Prefs.stepKeyboard) private var stepKeyboard = 6.25

    private func stepRow(_ title: String, _ value: Binding<Double>) -> some View {
        Slider(value: value, in: 1...25, step: 0.25) {
            Text(title + ": " + L("%@%% per press", String(format: "%g", value.wrappedValue)))
        }
    }

    var body: some View {
        Form {
            switch page {
            case .notch_closed:
                Section(L("Preview")) { NotchPreview(m: m, startExpanded: false) }
                Section(L("Left side when closed")) { WingPicker(key: Prefs.notchLeft) }.disabled(!notch)
                Section(L("Right side when closed")) { WingPicker(key: Prefs.notchRight) }.disabled(!notch)
            case .notch_open:
                Section(L("Preview")) { NotchPreview(m: m, startExpanded: true) }
                Section(L("Cards on the Home tab")) {
                    OrderedPicker<HomeWidget>(key: Prefs.notchHome, title: \.title, symbol: \.symbol)
                    Text(L("The notch widens as you add cards (you can also set it by hand on the General page)."))
                        .font(.caption).foregroundColor(.secondary)
                }.disabled(!notch)
                Section(L("Tabs")) { TabPicker() }.disabled(!notch)
            case .notch_media:
                Section(L("Volume and brightness HUD")) {
                    Toggle(L("Show the volume and brightness HUD in the notch (instead of macOS's)"), isOn: $hud)
                    Text(L("Rıhtım catches the volume, brightness and mute keys and shows them. Brightness keys change the display; ⌥ + brightness keys change the keyboard backlight. At 100% brightness, ⌘ + up goes into extra; while in extra, down lowers the extra first. ⇧ (⌥⇧ for volume) makes a quarter step. Turn this off to get the macOS HUD back."))
                        .font(.caption).foregroundColor(.secondary)
                }.disabled(!notch)
                Section(L("Step per key press")) {
                    stepRow(L("Volume"), $stepVolume)
                    stepRow(L("Display brightness"), $stepBrightness)
                    stepRow(L("Keyboard backlight (⌥)"), $stepKeyboard)
                        .disabled(!KeyboardBacklight.isAvailable)
                    if !KeyboardBacklight.isAvailable {
                        Text(L("No backlit keyboard found.")).font(.caption).foregroundColor(.secondary)
                    }
                    HStack {
                        Text(L("6.25% = 16 steps, like macOS.")).font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button(L("Reset")) { stepVolume = 6.25; stepBrightness = 6.25; stepKeyboard = 6.25 }
                    }
                }.disabled(!notch || !hud)
                Section(L("Extra brightness (EDR)")) {
                if BrightnessBoost.isSupported {
                    Toggle(L("Push the display past the SDR limit"), isOn: Binding(get: { brightness.isActive },
                                                                            set: { $0 ? brightness.start() : brightness.stop() }))
                    Slider(value: $brightness.factor, in: 1.1...BrightnessBoost.maxFactor, step: 0.05) {
                        Text(L("Boost: %@", Fmt.pct(Int((brightness.factor - 1) * 100))))
                    }
                    Text(L("First bring brightness to 100%% the normal way, then hold ⌘ and press brightness up to go past 100%% (like Sapphire); the level shows in the notch. Lowering regular brightness turns extra brightness off. This display offers up to %.1f× EDR headroom, and the boost never goes beyond what it can give at the moment. Uses more battery.", BrightnessBoost.maxFactor))
                        .font(.caption).foregroundColor(.secondary)
                    Text(L("Panic switch: ⌃⌥⌘B or Esc three times. The display returns to normal on its own when Rıhtım quits."))
                        .font(.caption).foregroundColor(.orange)
                } else {
                    Text(L("This display has no EDR (HDR) headroom, so extra brightness isn't available.")).foregroundColor(.secondary)
                }
            }
            case .notch_extras:
                Section(L("Live banners")) {
                    Toggle(L("Show when the charger is plugged/unplugged, a device connects, or Coffee changes"), isOn: $banners)
                    Toggle(L("20-20-20 eye break (every 20 minutes, look away for 20 seconds)"), isOn: $eyeBreak)
                }.disabled(!notch)
                Section(L("Clipboard history")) {
                    Toggle(L("Remember copied text (last 40, never written to disk)"), isOn: $clip)
                    Text(L("Copies that password managers mark as concealed are never kept.")).font(.caption).foregroundColor(.secondary)
                    Button(L("Clear history (%d)", clipboard.items.count)) { clipboard.clear() }
                }.disabled(!notch)
                Section(L("File shelf")) {
                    Text(L("Files on the shelf aren't copied, only their locations are remembered. %d files right now.", shelf.files.count))
                        .font(.caption).foregroundColor(.secondary)
                    Button(L("Empty the shelf")) { shelf.clear() }
                }
            default:
                Section(L("Preview")) { NotchPreview(m: m, startExpanded: true) }
                Section {
                    Toggle(L("Notch island"), isOn: $notch)
                    Text(L("Opens when the pointer reaches the notch. Dragging a file to the notch opens the shelf. More settings in the Notch section on the left."))
                        .font(.caption).foregroundColor(.secondary)
                }
                Section(L("Appearance")) {
                    Toggle(L("Width follows the cards"), isOn: $autoSize)
                    Slider(value: $width, in: 440...max(1000, (NSScreen.main?.frame.width ?? 1200) - 40), step: 10) { Text(L("Open width: %d pt", Int(width))) }
                        .disabled(autoSize)
                    Slider(value: $softness, in: 0.3...2, step: 0.1) { Text(L("Corner softness: %.1f×", softness)) }
                    Slider(value: $hoverDelay, in: 0...0.6, step: 0.02) { Text(L("Open delay: %.2f s", hoverDelay)) }
                }.disabled(!notch)
            }
        }
    }
}

/// Items on one wing: tick and reorder (▲▼).
private struct WingPicker: View {
    let key: String
    @AppStorage private var raw: String

    init(key: String) {
        self.key = key
        _raw = AppStorage(wrappedValue: "", key)
    }

    private var items: [WingItem] { raw.split(separator: ",").compactMap { WingItem(rawValue: String($0)) } }
    private func save(_ list: [WingItem]) { raw = list.map(\.rawValue).joined(separator: ",") }

    var body: some View {
        let chosen = items
        ForEach(chosen + WingItem.allCases.filter { !chosen.contains($0) }) { item in
            HStack {
                Toggle(item.title, isOn: Binding(get: { chosen.contains(item) }, set: { on in
                    var l = items
                    if on { l.append(item) } else { l.removeAll { $0 == item } }
                    save(l)
                }))
                Spacer()
                if let i = chosen.firstIndex(of: item) {
                    Button(action: { var l = chosen; l.swapAt(i, i - 1); save(l) }) { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(i == 0)
                    Button(action: { var l = chosen; l.swapAt(i, i + 1); save(l) }) { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(i == chosen.count - 1)
                }
            }
        }
        Text(L("Items only show when they have data (no album art if nothing is playing). The notch grows to fit."))
            .font(.caption).foregroundColor(.secondary)
    }
}

private struct TabPicker: View {
    @AppStorage(Prefs.notchTabs) private var raw = ""

    var body: some View {
        let on = Set(raw.split(separator: ",").map(String.init))
        ForEach(NotchTab.allCases) { t in
            Toggle(isOn: Binding(get: { on.contains(t.rawValue) }, set: { v in
                var s = on
                if v { s.insert(t.rawValue) } else { s.remove(t.rawValue) }
                if s.isEmpty { s = [NotchTab.home.rawValue] }
                raw = NotchTab.allCases.map(\.rawValue).filter { s.contains($0) }.joined(separator: ",")
            })) { Label(t.title, systemImage: t.symbol) }
        }
    }
}

/// Live preview of the notch as settings change: this Mac's real screen width and notch
/// size, real data, scaled down to fit the window. On a notched screen the dashed red
/// area is the camera; without a notch Rıhtım draws a black one.
private struct NotchPreview: View {
    let m: SettingsModels
    @StateObject private var model = NotchModel()
    @State private var expanded: Bool
    @State private var avail: CGFloat = 600

    init(m: SettingsModels, startExpanded: Bool) {
        self.m = m
        _expanded = State(initialValue: startExpanded)
    }

    var body: some View {
        let screenW = model.screenWidth
        let totalH = model.notchHeight + model.bodyHeight + 24
        let scale = min(1, max(avail, 200) / screenW)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $expanded) {
                    Text(L("Collapsed")).tag(false)
                    Text(L("Expanded")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Spacer()
                Text(DeviceInfo.summary(hasNotch: model.hasNotch, notch: CGSize(width: model.notchWidth, height: model.notchHeight),
                                        screenWidth: screenW))
                    .font(.caption).foregroundColor(.secondary)
            }

            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.35, green: 0.2, blue: 0.6), Color(red: 0.95, green: 0.45, blue: 0.3)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // fake menu bar
                HStack {
                    Text("  Finder   " + L("File") + "   " + L("Edit") + "   " + L("View")).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(Date.now, style: .time).font(.system(size: 13, weight: .medium)).padding(.trailing, 12)
                }
                .foregroundColor(.white)
                .frame(height: model.notchHeight)
                .background(Color.black.opacity(0.18))
                NotchView(model: model, music: m.music, system: m.system, batteries: m.batteries,
                          caffeine: m.caffeine, usage: m.usage, weather: m.weather, calendar: m.calendar,
                          shelf: m.shelf, clipboard: m.clipboard, sessions: m.sessions, brightness: m.brightness)
                if model.hasNotch {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .frame(width: model.notchWidth, height: model.notchHeight)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: screenW, height: totalH)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: screenW * scale, height: totalH * scale, alignment: .topLeading)

            Text(model.hasNotch
                 ? L("The dashed red area is the camera housing; anything there is hidden on the real screen. You can click the tabs in the preview.")
                 : L("This screen has no notch, so Rıhtım draws a black one in the middle of the menu bar."))
                .font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { avail = g.size.width }
                .onChange(of: g.size.width) { _, w in avail = w }
        })
        .onAppear(perform: sync)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in sync() }
        .onChange(of: expanded) { _, v in model.expanded = v }
    }

    private func sync() {
        let c = Prefs.notchConfig()
        if model.config != c {
            model.config = c
            if !c.tabs.contains(model.tab) { model.tab = c.tabs.first ?? .home }
        }
        let real = m.notch.model
        model.notchWidth = real.notchWidth
        model.notchHeight = real.notchHeight
        model.screenWidth = real.screenWidth
        model.hasNotch = real.hasNotch
        if model.expanded != expanded { model.expanded = expanded }
    }
}

/// Something like "MacBook Air · Mac16,12".
enum DeviceInfo {
    static let modelName: String = {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        defer { if entry != 0 { IOObjectRelease(entry) } }
        if entry != 0, let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data,
           let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")), !s.isEmpty {
            return s
        }
        return "Mac"
    }()

    static let identifier: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }()

    static func summary(hasNotch: Bool, notch: CGSize, screenWidth: CGFloat) -> String {
        let n = hasNotch ? L("notch %d×%d pt", Int(notch.width), Int(notch.height)) : L("no notch (fake notch)")
        return "\(modelName) · \(identifier) · \(Int(screenWidth)) pt · \(n)"
    }
}

/// Pick-and-reorder list (▲▼), stored as a comma separated string.
private struct OrderedPicker<T: RawRepresentable & CaseIterable & Identifiable & Hashable>: View where T.RawValue == String, T.AllCases: RandomAccessCollection {
    let key: String
    let title: KeyPath<T, String>
    let symbol: KeyPath<T, String>
    @AppStorage private var raw: String

    init(key: String, title: KeyPath<T, String>, symbol: KeyPath<T, String>) {
        self.key = key
        self.title = title
        self.symbol = symbol
        _raw = AppStorage(wrappedValue: "", key)
    }

    private var items: [T] { raw.split(separator: ",").compactMap { T(rawValue: String($0)) } }
    private func save(_ list: [T]) { raw = list.map(\.rawValue).joined(separator: ",") }

    var body: some View {
        let chosen = items
        ForEach(chosen + T.allCases.filter { !chosen.contains($0) }) { item in
            HStack {
                Toggle(isOn: Binding(get: { chosen.contains(item) }, set: { on in
                    var l = items
                    if on { l.append(item) } else { l.removeAll { $0 == item } }
                    save(l)
                })) { Label(item[keyPath: title], systemImage: item[keyPath: symbol]) }
                Spacer()
                if let i = chosen.firstIndex(of: item) {
                    Button(action: { var l = chosen; l.swapAt(i, i - 1); save(l) }) { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(i == 0)
                    Button(action: { var l = chosen; l.swapAt(i, i + 1); save(l) }) { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(i == chosen.count - 1)
                }
            }
        }
    }
}
