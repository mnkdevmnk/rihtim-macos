import AppKit
import SwiftUI

enum SwitcherTrigger: String {
    case command, option
    var flag: CGEventFlags { self == .command ? .maskCommand : .maskAlternate }
    var otherMods: CGEventFlags { self == .command ? [.maskAlternate, .maskControl] : [.maskCommand, .maskControl] }
}

struct SwitcherApp: Identifiable {
    var id: pid_t { app.processIdentifier }
    let app: NSRunningApplication
    let name: String
    let icon: NSImage?
}

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var apps: [SwitcherApp] = []
    @Published var selectedApp = 0
    @Published var windows: [WindowInfo] = []
    @Published var selectedWindow = -1
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    @Published var columns = 1
    @Published var tileSize: CGFloat = 76
    @Published var previewSize: CGSize = .zero

    var selectedName: String { apps.indices.contains(selectedApp) ? apps[selectedApp].name : "" }
    var selectedIcon: NSImage? { apps.indices.contains(selectedApp) ? apps[selectedApp].icon : nil }
}

enum SwitcherLayout {
    static let tileSpacing: CGFloat = 6
    static let rowPadding: CGFloat = 12
    static let maxTile: CGFloat = 76
    static let labelHeight: CGFloat = 32
    static let gap: CGFloat = 12
}

/// Most-recently-used app order, so ⌘⇥ lands on the previous app.
@MainActor
final class AppRecency {
    private var order: [pid_t] = []
    private var token: NSObjectProtocol?

    init() {
        if let front = NSWorkspace.shared.frontmostApplication { order = [front.processIdentifier] }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            guard let pid else { return }
            MainActor.assumeIsolated { self?.touch(pid) }
        }
    }

    func touch(_ pid: pid_t) {
        order.removeAll { $0 == pid }
        order.insert(pid, at: 0)
    }

    func sorted(_ apps: [NSRunningApplication]) -> [NSRunningApplication] {
        var rank: [pid_t: Int] = [:]
        for (i, pid) in order.enumerated() where rank[pid] == nil { rank[pid] = i }
        return apps.enumerated().sorted { a, b in
            (rank[a.element.processIdentifier] ?? Int.max, a.offset) < (rank[b.element.processIdentifier] ?? Int.max, b.offset)
        }.map(\.element)
    }
}

enum AppActions {
    static func activate(_ app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        let wins = WindowEnumerator.windows(for: app)
        if !wins.isEmpty, wins.allSatisfy(\.isMinimized) {
            WindowActions.focus(wins[0])
            return
        }
        AX.set(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute, kCFBooleanTrue)
        app.activate(options: [])
    }
}

struct AppTile: View {
    let app: SwitcherApp
    let size: CGFloat
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color.white.opacity(isSelected ? 0.22 : 0))
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .strokeBorder(Color.white.opacity(isSelected ? 0.55 : 0), lineWidth: 1.5)
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: size * 0.8, height: size * 0.8)
                    .opacity(app.app.isHidden ? 0.45 : 1)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
    }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    let onPickApp: @MainActor (Int) -> Void
    let onPickWindow: @MainActor (Int) -> Void

    var body: some View {
        VStack(spacing: SwitcherLayout.gap) {
            if !model.windows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if let icon = model.selectedIcon {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        }
                        Text(model.selectedName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    }
                    .frame(height: Layout.headerHeight)

                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(Layout.cardWidth), spacing: Layout.spacing),
                                             count: max(model.columns, 1)),
                              alignment: .leading, spacing: Layout.spacing) {
                        ForEach(Array(model.windows.enumerated()), id: \.element.id) { item in
                            WindowCard(window: item.element,
                                       thumbnail: model.thumbnails[item.element.windowID],
                                       isSelected: item.offset == model.selectedWindow,
                                       showsClose: false,
                                       onSelect: { onPickWindow(item.offset) },
                                       onClose: {})
                        }
                    }
                }
                .padding(Layout.padding)
                .frame(width: model.previewSize.width, height: model.previewSize.height, alignment: .topLeading)
                .modifier(PanelBackground(radius: 20))
            }

            HStack(spacing: SwitcherLayout.tileSpacing) {
                ForEach(Array(model.apps.enumerated()), id: \.element.id) { item in
                    AppTile(app: item.element, size: model.tileSize, isSelected: item.offset == model.selectedApp)
                        .onTapGesture { onPickApp(item.offset) }
                }
            }
            .padding(SwitcherLayout.rowPadding)
            .modifier(PanelBackground(radius: 22))

            Text(model.selectedName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 22)
                .frame(height: SwitcherLayout.labelHeight)
                .modifier(PanelBackground(radius: SwitcherLayout.labelHeight / 2))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// App switcher. While the trigger (⌘ or ⌥) is held:
/// ⇥ / ⇧⇥ or ← → : pick app · ↑ ↓ or ` : pick a window of that app
/// Q: quit app · H: hide · W: close window · Esc: cancel · release trigger: switch
@MainActor
final class SwitcherController {
    var isEnabled = true { didSet { applyHotKeyState(); if !isEnabled { cancel() } } }
    var trigger: SwitcherTrigger = .command { didSet { applyHotKeyState(); cancel() } }

    private let panel: FloatingPanel
    private let model: SwitcherModel
    private let recency: AppRecency
    private var hosting: NSHostingView<SwitcherView>?
    private var tap: CFMachPort?

    private var isActive = false
    private var populated = false
    private var commitPending = false
    private var pendingAppSteps = 0
    private var generation = 0
    private var windowCache: [pid_t: [WindowInfo]] = [:]
    private var showTimer: Timer?

    init() {
        panel = FloatingPanel()
        model = SwitcherModel()
        recency = AppRecency()
        let view = SwitcherView(model: model,
                                onPickApp: { [weak self] i in self?.pickApp(i) },
                                onPickWindow: { [weak self] i in self?.pickWindow(i) })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.hosting = hosting
    }

    /// Returns false without Accessibility permission.
    @discardableResult
    func start() -> Bool {
        if tap == nil {
            let mask = (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue))
                     | (CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue))
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let me = Unmanaged<SwitcherController>.fromOpaque(refcon).takeUnretainedValue()
                    let swallow = MainActor.assumeIsolated { me.handle(type: type, event: event) }
                    return swallow ? nil : Unmanaged.passUnretained(event)
                },
                userInfo: refcon
            ) else { return false }

            self.tap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        applyHotKeyState()
        return true
    }

    var commandTabTakenOver: Bool { isEnabled && trigger == .command && tap != nil && SymbolicHotKeys.isAvailable }

    private func applyHotKeyState() {
        SymbolicHotKeys.setCommandTabEnabled(!(isEnabled && trigger == .command && tap != nil))
    }

    /// true = swallow the event
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case .flagsChanged:
            if isActive && !event.flags.contains(trigger.flag) { commit() }
            return false

        case .keyDown:
            let flags = event.flags
            let key = event.getIntegerValueField(.keyboardEventKeycode)

            if key == 48, flags.contains(trigger.flag), flags.intersection(trigger.otherMods).isEmpty {
                guard isEnabled else { return false }
                let back = flags.contains(.maskShift)
                if isActive { stepApp(back ? -1 : 1) } else { activate(backwards: back) }
                return true
            }

            guard isActive else { return false }
            switch key {
            case 53: cancel()                                        // esc
            case 123: stepApp(-1)                                    // ←
            case 124: stepApp(1)                                     // →
            case 126: stepWindow(-1)                                 // ↑
            case 125: stepWindow(1)                                  // ↓
            case 50: stepWindow(flags.contains(.maskShift) ? -1 : 1) // `
            case 36, 76: commit()                                    // return
            case 12: quitSelectedApp()                               // Q
            case 4: hideSelectedApp()                                // H
            case 13: closeSelectedWindow()                           // W
            default: break
            }
            return true

        default:
            return false
        }
    }

    // MARK: flow

    private func activate(backwards: Bool) {
        isActive = true
        populated = false
        commitPending = false
        pendingAppSteps = 0
        windowCache = [:]
        generation += 1
        let gen = generation
        Task { @MainActor [weak self] in self?.populate(backwards: backwards, gen: gen) }
    }

    private func populate(backwards: Bool, gen: Int) {
        guard isActive, gen == generation else { return }
        let me = getpid()
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated
        }
        let apps = recency.sorted(running).map { SwitcherApp(app: $0, name: $0.localizedName ?? "", icon: $0.icon) }
        guard !apps.isEmpty else { cancel(); return }

        model.apps = apps
        model.windows = []
        model.thumbnails = [:]
        let n = apps.count
        let start = backwards ? n - 1 : min(1, n - 1)
        populated = true
        let index = ((start + pendingAppSteps) % n + n) % n
        pendingAppSteps = 0

        if commitPending {          // quick ⌘⇥: switch without showing the UI
            model.selectedApp = index
            commit()
            return
        }
        selectApp(index)

        showTimer?.invalidate()
        showTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.generation == gen else { return }
                self.layoutAndShow()
            }
        }
    }

    private func selectApp(_ i: Int) {
        guard model.apps.indices.contains(i) else { return }
        model.selectedApp = i
        model.selectedWindow = -1
        let pid = model.apps[i].app.processIdentifier
        model.windows = windowCache[pid] ?? []
        model.columns = min(max(model.windows.count, 1), 4)
        if panel.isVisible { layoutAndShow() }
        let gen = generation
        Task { @MainActor [weak self] in self?.loadWindows(index: i, gen: gen) }
    }

    private func loadWindows(index: Int, gen: Int) {
        guard isActive, gen == generation, model.selectedApp == index, model.apps.indices.contains(index) else { return }
        let app = model.apps[index].app
        let pid = app.processIdentifier
        let wins: [WindowInfo]
        if let cached = windowCache[pid] {
            wins = cached
        } else {
            wins = WindowEnumerator.sortedWindows(for: app)
            windowCache[pid] = wins
        }
        guard isActive, gen == generation, model.selectedApp == index else { return }
        model.windows = wins
        model.columns = min(max(wins.count, 1), 4)
        if panel.isVisible { layoutAndShow() }
        loadThumbnails(gen: gen, pid: pid)
    }

    private func loadThumbnails(gen: Int, pid: pid_t) {
        let ids = model.windows.map(\.windowID).filter { $0 != 0 }
        let maxSize = CGSize(width: Layout.cardWidth - 8, height: Layout.thumbHeight - 8)
        Task { @MainActor [weak self] in
            for id in ids {
                let img = await ThumbnailProvider.shared.thumbnail(windowID: id, maxSize: maxSize)
                guard let self, self.isActive, self.generation == gen,
                      self.model.apps.indices.contains(self.model.selectedApp),
                      self.model.apps[self.model.selectedApp].app.processIdentifier == pid else { return }
                if let img { self.model.thumbnails[id] = img }
            }
        }
    }

    private func layoutAndShow() {
        let screen = Geometry.screen(containing: NSEvent.mouseLocation)
        let vis = screen.visibleFrame
        let n = CGFloat(max(model.apps.count, 1))
        let maxRow = vis.width - 80
        let fit = (maxRow - SwitcherLayout.rowPadding * 2 - (n - 1) * SwitcherLayout.tileSpacing) / n
        model.tileSize = max(28, min(SwitcherLayout.maxTile, fit))

        let rowW = SwitcherLayout.rowPadding * 2 + n * model.tileSize + (n - 1) * SwitcherLayout.tileSpacing
        let rowH = SwitcherLayout.rowPadding * 2 + model.tileSize
        var w = max(rowW, 220)
        var h = rowH + SwitcherLayout.gap + SwitcherLayout.labelHeight

        if model.windows.isEmpty {
            model.previewSize = .zero
        } else {
            var p = Layout.gridSize(count: model.windows.count, columns: model.columns)
            p.height += Layout.headerHeight + 8
            model.previewSize = p
            w = max(w, p.width)
            h += p.height + SwitcherLayout.gap
        }

        let origin = CGPoint(x: vis.midX - w / 2, y: max(vis.minY + 8, vis.midY - h / 2))
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: w, height: h)), display: true)
        panel.invalidateShadow()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    // MARK: navigation

    private func stepApp(_ d: Int) {
        guard populated else { pendingAppSteps += d; return }
        let n = model.apps.count
        guard n > 0 else { return }
        selectApp(((model.selectedApp + d) % n + n) % n)
    }

    private func stepWindow(_ d: Int) {
        guard populated, !model.windows.isEmpty else { return }
        let n = model.windows.count
        if model.selectedWindow < 0 {
            model.selectedWindow = d > 0 ? 0 : n - 1
        } else {
            model.selectedWindow = ((model.selectedWindow + d) % n + n) % n
        }
    }

    private func pickApp(_ i: Int) {
        guard isActive else { return }
        model.selectedApp = i
        model.selectedWindow = -1
        commit()
    }

    private func pickWindow(_ i: Int) {
        guard isActive else { return }
        model.selectedWindow = i
        commit()
    }

    private func quitSelectedApp() {
        guard populated, model.apps.indices.contains(model.selectedApp) else { return }
        let removed = model.apps.remove(at: model.selectedApp)
        removed.app.terminate()
        if model.apps.isEmpty { cancel(); return }
        selectApp(min(model.selectedApp, model.apps.count - 1))
        layoutAndShow()
    }

    private func hideSelectedApp() {
        guard populated, model.apps.indices.contains(model.selectedApp) else { return }
        model.apps[model.selectedApp].app.hide()
        model.objectWillChange.send()
    }

    private func closeSelectedWindow() {
        guard populated, model.windows.indices.contains(model.selectedWindow),
              model.apps.indices.contains(model.selectedApp) else { return }
        let w = model.windows.remove(at: model.selectedWindow)
        WindowActions.close(w)
        windowCache[model.apps[model.selectedApp].app.processIdentifier] = model.windows
        model.selectedWindow = model.windows.isEmpty ? -1 : min(model.selectedWindow, model.windows.count - 1)
        model.columns = min(max(model.windows.count, 1), 4)
        layoutAndShow()
    }

    private func commit() {
        guard isActive else { return }
        guard populated else { commitPending = true; return }
        let app = model.apps.indices.contains(model.selectedApp) ? model.apps[model.selectedApp].app : nil
        let win = model.windows.indices.contains(model.selectedWindow) ? model.windows[model.selectedWindow] : nil
        cancel()
        Task { @MainActor in
            if let win {
                WindowActions.focus(win)
            } else if let app {
                AppActions.activate(app)
            }
        }
    }

    func cancel() {
        isActive = false
        populated = false
        commitPending = false
        pendingAppSteps = 0
        generation += 1
        showTimer?.invalidate()
        showTimer = nil
        panel.orderOut(nil)
    }
}
