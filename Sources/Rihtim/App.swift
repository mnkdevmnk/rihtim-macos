import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var dock: DockObserver!
    private var previews: PreviewController!
    private var gestures: DockGestures!
    private var folders: FolderPopController!
    private var switcher: SwitcherController!
    private var music: MusicController!
    private var system: SystemMonitor!
    private var batteries: BatteryMonitor!
    private var bar: WidgetBarController!
    private var notch: NotchController!
    private var caffeine: Caffeine!
    private var usage: ClaudeUsage!
    private var calendar: CalendarMonitor!
    private var weather: WeatherMonitor!
    private var settingsWindow: SettingsWindowController!
    private var menuBar: MenuBarController!
    private var brightness: BrightnessBoost!
    private var mediaKeys: MediaKeyController!
    private var snapper: WindowSnapper!
    private var permissionTimer: Timer?
    private var prefsToken: NSObjectProtocol?
    private var started = false
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        // If the last run crashed, the system ⌘⇥ may still be off.
        SymbolicHotKeys.setCommandTabEnabled(true)

        dock = DockObserver()
        music = MusicController()
        previews = PreviewController(music: music)
        gestures = DockGestures(dock: dock)
        folders = FolderPopController()
        snapper = WindowSnapper()
        switcher = SwitcherController()
        system = SystemMonitor()
        batteries = BatteryMonitor()
        caffeine = Caffeine()
        usage = ClaudeUsage()
        calendar = CalendarMonitor()
        weather = WeatherMonitor()
        bar = WidgetBarController(dock: dock, music: music, system: system, batteries: batteries,
                                  caffeine: caffeine, usage: usage, calendar: calendar, weather: weather)
        brightness = BrightnessBoost()
        notch = NotchController(music: music, system: system, batteries: batteries,
                                caffeine: caffeine, usage: usage, weather: weather, calendar: calendar,
                                brightness: brightness)
        menuBar = MenuBarController(system: system, batteries: batteries)
        menuBar.openSettings = { [weak self] m in self?.settingsWindow.show(page: .mb(m)) }
        settingsWindow = SettingsWindowController(models: SettingsModels(
            music: music, system: system, batteries: batteries, caffeine: caffeine,
            usage: usage, calendar: calendar, weather: weather,
            shelf: notch.shelf, clipboard: notch.clipboard, sessions: notch.sessions,
            brightness: brightness, notch: notch, menuStats: menuBar.stats,
            relaunch: { [weak self] in self?.relaunch() }))
        notch.openSettings = { [weak self] in self?.settingsWindow.show() }
        mediaKeys = MediaKeyController(brightness: brightness)
        mediaKeys.onHUD = { [weak self] kind, level, label, muted in
            self?.notch.showHUD(kind, level: level, label: label, muted: muted)
        }
        dock.onHover = { [weak self] item in
            self?.previews.dockHoverChanged(item)
            self?.folders.dockHoverChanged(item)
        }
        previews.onShow = { [weak self] in self?.folders.hide() }
        folders.onShow = { [weak self] in self?.previews.hide() }
        gestures.onAction = { [weak self] in self?.previews.hide() }
        DockReveal.shared.onDockHidden = { [weak self] in self?.previews.hide(); self?.folders.hide() }

        applyPrefs()
        prefsToken = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPrefs() }
        }

        system.start()
        batteries.start()
        usage.start()
        weather.start()
        notch.start()   // doesn't need AX
        setupStatusItem()

        Diag.log("launch AX=\(Permissions.hasAccessibility) version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "") lang=\(L10n.code)")
        if Permissions.hasAccessibility {
            startServices()
        } else {
            Permissions.promptAccessibility()
            permissionTimer = Timer.scheduledTimer(timeInterval: 1, target: self,
                                                   selector: #selector(checkPermission),
                                                   userInfo: nil, repeats: true)
        }
        if !Permissions.hasScreenRecording { Permissions.requestScreenRecording() }

        if !defaults.bool(forKey: Prefs.onboarded) {
            defaults.set(true, forKey: Prefs.onboarded)
            settingsWindow.show()
        }
    }

    /// Opening the .app again from Finder / Launchpad shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        SymbolicHotKeys.setCommandTabEnabled(true)
        brightness?.shutdown()
        caffeine?.shutdown()
    }

    /// Pushes everything from UserDefaults into the components; only assigns what changed.
    private func applyPrefs() {
        let d = defaults
        func assign<T: Equatable>(_ current: T, _ new: T, _ set: (T) -> Void) { if current != new { set(new) } }

        assign(previews.isEnabled, d.bool(forKey: Prefs.previews)) { previews.isEnabled = $0 }
        assign(previews.settings, Prefs.previewSettings()) { previews.settings = $0 }
        let click = DockClickAction(rawValue: d.string(forKey: Prefs.dockClick) ?? "") ?? .minimize
        assign(gestures.clickAction, click) { gestures.clickAction = $0 }
        assign(gestures.scrollEnabled, d.bool(forKey: Prefs.dockScroll)) { gestures.scrollEnabled = $0 }
        assign(gestures.quitClickEnabled, d.bool(forKey: Prefs.dockQuitClick)) { gestures.quitClickEnabled = $0 }
        assign(folders.isEnabled, d.bool(forKey: Prefs.dockFolders)) { folders.isEnabled = $0 }
        folders.sort = FolderSort(rawValue: d.string(forKey: Prefs.dockFolderSort) ?? "") ?? .added
        WindowEnumerator.includeOtherSpaces = d.bool(forKey: Prefs.otherSpaces)
        let trig = SwitcherTrigger(rawValue: d.string(forKey: Prefs.switcherTrigger) ?? "") ?? .command
        assign(switcher.trigger, trig) { switcher.trigger = $0 }
        assign(switcher.isEnabled, d.bool(forKey: Prefs.switcher)) { switcher.isEnabled = $0 }

        var enabled = Set<PopoverKind>()
        var sides: [PopoverKind: BarSide] = [:]
        for k in PopoverKind.allCases {
            if d.bool(forKey: k.enabledKey) { enabled.insert(k) }
            sides[k] = BarSide(rawValue: d.string(forKey: k.sideKey) ?? "") ?? k.defaultSide
        }
        assign(bar.settings.enabled, enabled) { bar.settings.enabled = $0 }
        assign(bar.settings.sides, sides) { bar.settings.sides = $0 }
        assign(bar.isEnabled, d.bool(forKey: Prefs.bar)) { bar.isEnabled = $0 }
        assign(notch.isEnabled, d.bool(forKey: Prefs.notch)) { notch.isEnabled = $0 }
        // Only grab the keys with Accessibility and the notch on, otherwise let macOS handle them.
        mediaKeys.isEnabled = started && d.bool(forKey: Prefs.notch) && d.bool(forKey: Prefs.notchHUD)
        notch.config = Prefs.notchConfig()
        bar.revealDelay = d.double(forKey: Prefs.barRevealDelay)
        bar.revealDuration = d.double(forKey: Prefs.barRevealDuration)
        notch.bannersEnabled = d.bool(forKey: Prefs.notchBanners)
        notch.eyeBreakEnabled = d.bool(forKey: Prefs.notchEyeBreak)
        assign(notch.clipboard.isEnabled, d.bool(forKey: Prefs.notchClipboard)) { notch.clipboard.isEnabled = $0 }
        assign(bar.settings.style, Prefs.barStyle()) { bar.settings.style = $0 }
        assign(bar.settings.compactAlways, d.bool(forKey: Prefs.barCompact)) { bar.settings.compactAlways = $0 }

        snapper.gap = CGFloat(min(max(d.double(forKey: Prefs.snapGap), 0), 40))
        snapper.cycles = d.bool(forKey: Prefs.snapCycle)
        snapper.restoreOnDrag = d.bool(forKey: Prefs.snapRestoreOnDrag)
        snapper.dragTopMaximizes = d.bool(forKey: Prefs.snapTopMaximize)
        snapper.showsFlash = d.bool(forKey: Prefs.snapFlash)
        snapper.snapNeedsCommand = d.bool(forKey: Prefs.snapNeedsCmd)
        snapper.spaceDragEnabled = d.bool(forKey: Prefs.snapSpaceDrag)
        snapper.spaceDelay = min(max(d.double(forKey: Prefs.snapSpaceDelay), 0.15), 1.5)
        assign(snapper.hotkeysEnabled, d.bool(forKey: Prefs.snapKeys)) { snapper.hotkeysEnabled = $0 }
        assign(snapper.dragEnabled, d.bool(forKey: Prefs.snapDrag)) { snapper.dragEnabled = $0 }

        let menuOn = MenuModule.allCases.filter { d.bool(forKey: $0.enabledKey) }
        menuBar.zones = Prefs.zones()
        menuBar.apply(enabled: menuOn)

        // Only ask for calendar access when the calendar widget is on
        // (the notch's Calendar tab can also ask the first time).
        if d.bool(forKey: Prefs.bar) && enabled.contains(.calendar) { calendar.start() }
        assign(calendar.selectedIDs, Prefs.stringSet(Prefs.calendarIDs)) { calendar.selectedIDs = $0 }
        calendar.openLinks = d.bool(forKey: Prefs.calendarOpenLinks)

        assign(batteries.hiddenNames, Prefs.stringSet(Prefs.batteryHidden)) { batteries.hiddenNames = $0 }
        let pin = d.string(forKey: Prefs.batteryPinned).flatMap { $0.isEmpty ? nil : $0 }
        assign(batteries.pinnedName, pin) { batteries.pinnedName = $0 }
        batteries.alertLevel = d.integer(forKey: Prefs.batteryAlertLevel)
        assign(batteries.alertsEnabled, d.bool(forKey: Prefs.batteryAlerts)) { batteries.alertsEnabled = $0 }
    }

    private func startServices() {
        Diag.log("starting services AX=\(Permissions.hasAccessibility)")
        guard !started else { return }
        started = true
        dock.start()
        gestures.start()
        if !switcher.start() { NSLog("Rihtim: couldn't create event tap (Accessibility permission?)") }
        bar.start()
        snapper.start()
        applyPrefs()   // the media key tap needs Accessibility
    }

    @objc private func checkPermission() {
        guard Permissions.hasAccessibility else { return }
        permissionTimer?.invalidate()
        permissionTimer = nil
        startServices()
    }

    // MARK: status menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Rıhtım")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "Rıhtım", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(pref(L("Dock previews"), Prefs.previews))
        menu.addItem(pref(L("Windows on other desktops"), Prefs.otherSpaces, indent: 1))
        menu.addItem(pref(L("Dock folder contents"), Prefs.dockFolders))
        menu.addItem(pref(L("Scroll on icon: hide / show"), Prefs.dockScroll))
        menu.addItem(pref(L("⌘ + right-click: quit"), Prefs.dockQuitClick))
        menu.addItem(pref(L("App switcher"), Prefs.switcher))
        let cmd = toggle(L("⌘⇥ (replaces the system one)"), switcher.trigger == .command, #selector(useCommandTrigger), indent: 1)
        cmd.isEnabled = switcher.isEnabled && SymbolicHotKeys.isAvailable
        menu.addItem(cmd)
        let opt = toggle("⌥⇥", switcher.trigger == .option, #selector(useOptionTrigger), indent: 1)
        opt.isEnabled = switcher.isEnabled
        menu.addItem(opt)

        menu.addItem(.separator())
        menu.addItem(pref(L("Widgets next to the Dock"), Prefs.bar))
        for k in PopoverKind.allCases {
            let i = pref(k.title, k.enabledKey, indent: 1)
            i.isEnabled = bar.isEnabled
            menu.addItem(i)
        }
        menu.addItem(pref(L("Notch island"), Prefs.notch))
        menu.addItem(pref(L("Window snapping shortcuts"), Prefs.snapKeys))
        menu.addItem(pref(L("Snap when dragged to an edge"), Prefs.snapDrag))
        menu.addItem(.separator())
        let mbHeader = NSMenuItem(title: L("Menu bar modules"), action: nil, keyEquivalent: "")
        mbHeader.isEnabled = false
        menu.addItem(mbHeader)
        for m in MenuModule.allCases { menu.addItem(pref(m.title, m.enabledKey, indent: 1)) }

        menu.addItem(.separator())
        let sleepTitle = caffeine.isActive ? L("Coffee: %@", caffeine.shortStatus) : L("Coffee (keep awake)")
        let sleepItem = NSMenuItem(title: sleepTitle, action: nil, keyEquivalent: "")
        let sleepMenu = NSMenu()
        sleepMenu.autoenablesItems = false
        let off = action(L("Off"), #selector(caffeineOff))
        off.state = caffeine.isActive ? .off : .on
        sleepMenu.addItem(off)
        for (i, d) in Caffeine.durations.enumerated() {
            let item = action(d.0, #selector(caffeineSelect(_:)))
            item.tag = i
            item.state = caffeine.isMode(d.1) ? .on : .off
            sleepMenu.addItem(item)
        }
        sleepMenu.addItem(.separator())
        sleepMenu.addItem(toggle(L("Keep the display on too"), caffeine.keepDisplayOn, #selector(caffeineDisplay)))
        sleepMenu.addItem(toggle(L("Milk: keep running with the lid closed"), caffeine.milk, #selector(caffeineMilk)))
        sleepItem.submenu = sleepMenu
        menu.addItem(sleepItem)

        if BrightnessBoost.isSupported {
            let b = toggle(brightness.isActive ? L("Extra brightness: on (%@)", Fmt.pct(Int((brightness.factor - 1) * 100))) : L("Extra brightness"),
                           brightness.isActive, #selector(toggleBrightness))
            menu.addItem(b)
        }

        let usageItem = NSMenuItem(title: "Claude \(usage.planName): \(usage.summary)", action: nil, keyEquivalent: "")
        let usageMenu = NSMenu()
        usageMenu.autoenablesItems = false
        if usage.status != .ok {
            let msg = NSMenuItem(title: usage.status.message, action: nil, keyEquivalent: "")
            msg.isEnabled = false
            usageMenu.addItem(msg)
        }
        for (title, w) in [(L("5-hour"), usage.fiveHour), (L("Weekly"), usage.sevenDay),
                           (L("Weekly Opus"), usage.sevenDayOpus), (L("Weekly Sonnet"), usage.sevenDaySonnet)] {
            guard let w else { continue }
            var t = "\(title): \(Fmt.pct(Int(w.percent.rounded())))"
            if let r = w.resetsAt { t += "  ·  " + L("resets in %@", Fmt.until(r)) }
            let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            i.isEnabled = false
            usageMenu.addItem(i)
        }
        usageMenu.addItem(.separator())
        usageMenu.addItem(action(L("Refresh now"), #selector(refreshUsage)))
        usageItem.submenu = usageMenu
        menu.addItem(usageItem)

        menu.addItem(.separator())
        let ax = Permissions.hasAccessibility
        let axItem = action(ax ? L("Accessibility: granted ✓") : L("Grant Accessibility…"), #selector(openAccessibility))
        axItem.isEnabled = !ax
        menu.addItem(axItem)
        let sr = Permissions.hasScreenRecording
        let srItem = action(sr ? L("Screen Recording: granted ✓") : L("Grant Screen Recording… (live previews)"), #selector(openScreenRecording))
        srItem.isEnabled = !sr
        menu.addItem(srItem)
        if !sr { menu.addItem(action(L("I've granted it, restart"), #selector(relaunchAction))) }

        menu.addItem(.separator())
        let settings = action(L("Settings…"), #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: L("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ sel: Selector, indent: Int = 0) -> NSMenuItem {
        let i = action(title, sel)
        i.state = on ? .on : .off
        i.indentationLevel = indent
        return i
    }

    /// Menu item that flips a Bool pref; the key sits in representedObject.
    private func pref(_ title: String, _ key: String, indent: Int = 0) -> NSMenuItem {
        let i = toggle(title, defaults.bool(forKey: key), #selector(togglePref(_:)), indent: indent)
        i.representedObject = key
        return i
    }

    // MARK: actions

    @objc private func togglePref(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        defaults.set(!defaults.bool(forKey: key), forKey: key)
    }

    @objc private func useCommandTrigger() { defaults.set(SwitcherTrigger.command.rawValue, forKey: Prefs.switcherTrigger) }
    @objc private func useOptionTrigger() { defaults.set(SwitcherTrigger.option.rawValue, forKey: Prefs.switcherTrigger) }

    @objc private func caffeineOff() { caffeine.deactivate() }

    @objc private func caffeineSelect(_ sender: NSMenuItem) {
        caffeine.select(Caffeine.durations[sender.tag].1)
    }

    @objc private func caffeineDisplay() { caffeine.keepDisplayOn.toggle() }
    @objc private func caffeineMilk() { caffeine.milk.toggle() }
    @objc private func refreshUsage() { usage.refresh() }
    @objc private func toggleBrightness() { brightness.toggle() }
    @objc private func openSettings() { settingsWindow.show() }

    @objc private func openAccessibility() {
        Permissions.promptAccessibility()
        Permissions.openPane("Privacy_Accessibility")
    }

    @objc private func openScreenRecording() {
        Permissions.requestScreenRecording()
        Permissions.openPane("Privacy_ScreenCapture")
    }

    @objc private func relaunchAction() { relaunch() }

    func relaunch() {
        SymbolicHotKeys.setCommandTabEnabled(true)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
