import AppKit
import ApplicationServices
import SwiftUI

enum DockItemKind: Equatable {
    case app, folder, other
}

struct DockHoverItem {
    let kind: DockItemKind
    let app: NSRunningApplication?
    let url: URL?
    let title: String
    let frameAX: CGRect
}

/// Watches the real Dock through AX. Never hides it, restarts it or writes its prefs.
@MainActor
final class DockObserver {
    var onHover: (@MainActor (DockHoverItem?) -> Void)?
    /// Dock item currently under the pointer (AX selection). The gesture tap reads this.
    private(set) var current: DockHoverItem?

    private var observer: AXObserver?
    private var dockList: AXUIElement?
    private var retryTimer: Timer?
    private var workspaceTokens: [NSObjectProtocol] = []

    func start() {
        attach()
        let nc = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.dock" else { return }
            MainActor.assumeIsolated { self?.scheduleAttach(after: 1.5) }
        })
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.dock" else { return }
            MainActor.assumeIsolated {
                self?.detach()
                self?.current = nil
                self?.onHover?(nil)
            }
        })
    }

    private func scheduleAttach(after delay: TimeInterval) {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach() }
        }
    }

    private func attach() {
        detach()
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            scheduleAttach(after: 2); return
        }
        let pid = dock.processIdentifier
        let axDock = AXUIElementCreateApplication(pid)
        guard let list = AX.elements(axDock, kAXChildrenAttribute)?.first(where: { AX.string($0, kAXRoleAttribute) == kAXListRole }) else {
            scheduleAttach(after: 2); return
        }

        var obs: AXObserver?
        let created = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<DockObserver>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.selectionChanged() }
        }, &obs)
        guard created == .success, let obs else { scheduleAttach(after: 2); return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, list, kAXSelectedChildrenChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        dockList = list
    }

    /// Frame of the Dock's icon list, in AX coordinates.
    func dockFrameAX() -> CGRect? {
        guard let dockList else { return nil }
        return AX.frame(dockList)
    }

    /// Union of the item frames: the actual row of icons inside the Dock glass.
    func itemsFrameAX() -> CGRect? {
        guard let dockList, let items = AX.elements(dockList, kAXChildrenAttribute) else { return nil }
        let frames = items.compactMap { AX.frame($0) }.filter { $0.width > 4 && $0.height > 4 }
        guard var u = frames.first else { return nil }
        for f in frames.dropFirst() { u = u.union(f) }
        return u
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        dockList = nil
    }

    fileprivate func selectionChanged() {
        guard let list = dockList,
              let item = AX.elements(list, kAXSelectedChildrenAttribute)?.first else {
            current = nil
            onHover?(nil); return
        }
        let subrole = AX.string(item, kAXSubroleAttribute)
        let title = AX.string(item, kAXTitleAttribute) ?? ""
        let frame = AX.frame(item) ?? .zero
        let url = AX.url(item, kAXURLAttribute)

        let hovered: DockHoverItem
        switch subrole {
        case "AXApplicationDockItem":
            var app: NSRunningApplication?
            if let path = url?.standardizedFileURL.path {
                app = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == path }
            }
            if app == nil {
                app = NSWorkspace.shared.runningApplications.first { $0.localizedName == title && $0.activationPolicy == .regular }
            }
            hovered = DockHoverItem(kind: .app, app: app, url: url, title: title, frameAX: frame)
        case "AXFolderDockItem":
            hovered = DockHoverItem(kind: .folder, app: nil, url: url, title: title, frameAX: frame)
        default:
            hovered = DockHoverItem(kind: .other, app: nil, url: url, title: title, frameAX: frame)
        }
        current = hovered
        onHover?(hovered)
    }
}

enum DockOrientation {
    case bottom, left, right

    static func detect(anchor: CGRect, screen: CGRect) -> DockOrientation {
        if anchor.midY - screen.minY < screen.height * 0.3 { return .bottom }
        return anchor.midX < screen.midX ? .left : .right
    }
}

/// Preview settings, fed from UserDefaults by AppDelegate.applyPrefs.
struct PreviewSettings: Equatable {
    var delay: TimeInterval = 0.18
    var scale: CGFloat = 1
    /// Switch to list mode above this many windows; 0 = never.
    var listAfter = 8
    var showsMusic = true
    var excluded: Set<String> = []
}

@MainActor
final class PreviewController {
    var isEnabled = true { didSet { if !isEnabled { hide() } } }
    var settings = PreviewSettings()
    /// Fired when the panel opens (closes the folder popup).
    var onShow: (@MainActor () -> Void)?

    private let panel: FloatingPanel
    private let model: PreviewModel
    private let music: MusicController
    private var hosting: NSHostingView<PreviewView>?

    private var currentPID: pid_t?
    private var hoveredPID: pid_t?
    private var anchorAX: CGRect = .zero
    private var anchor: CGRect = .zero
    private var orientation: DockOrientation = .bottom
    private var generation = 0
    private var pendingTimer: Timer?
    private var pollTimer: Timer?
    private var pollTicks = 0
    private var mouseMonitor: Any?

    init(music: MusicController) {
        self.music = music
        panel = FloatingPanel()
        model = PreviewModel()
        let view = PreviewView(model: model, music: music,
                               onSelect: { [weak self] w in self?.select(w) },
                               onClose: { [weak self] w in self?.close(w) },
                               onMinimize: { [weak self] w in self?.minimize(w) },
                               onAppAction: { [weak self] a in self?.appAction(a) })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.hosting = hosting
    }

    var isVisible: Bool { panel.isVisible }

    func dockHoverChanged(_ item: DockHoverItem?) {
        guard isEnabled else { return }
        pendingTimer?.invalidate()
        guard let item, item.kind == .app, let app = item.app else { hoveredPID = nil; return }
        if let bid = app.bundleIdentifier, settings.excluded.contains(bid) { hoveredPID = nil; hide(); return }

        hoveredPID = app.processIdentifier
        let delay: TimeInterval = panel.isVisible ? 0.05 : settings.delay
        pendingTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.show(app: app, anchorAX: item.frameAX, force: false) }
        }
    }

    private func isPlayer(_ app: NSRunningApplication) -> Bool {
        guard settings.showsMusic, music.hasTrack, let src = music.source else { return false }
        return app.bundleIdentifier == src.bundleID
    }

    private func show(app: NSRunningApplication, anchorAX newAnchor: CGRect, force: Bool) {
        guard isEnabled, force || hoveredPID == app.processIdentifier else { return }
        let windows = WindowEnumerator.sortedWindows(for: app)
        let player = isPlayer(app)
        guard !windows.isEmpty || player else { hide(); return }

        generation += 1
        let gen = generation
        anchorAX = newAnchor
        anchor = Geometry.cocoa(fromAX: newAnchor)
        let screen = Geometry.screen(containing: CGPoint(x: anchor.midX, y: anchor.midY))
        orientation = DockOrientation.detect(anchor: anchor, screen: screen.frame)

        let scale = settings.scale
        let listMode = settings.listAfter > 0 && windows.count > settings.listAfter
        let cardW = Layout.cardWidth * scale
        let maxCols = max(1, Int((screen.visibleFrame.width - 80) / (cardW + Layout.spacing)))
        let cols = max(1, min(windows.count, maxCols, 5))

        if currentPID != app.processIdentifier { model.thumbnails = [:] }
        model.appName = app.localizedName ?? ""
        model.appIcon = app.icon
        model.windows = windows
        model.columns = cols
        model.scale = scale
        model.listMode = listMode
        model.showsPlayer = player
        currentPID = app.processIdentifier

        var size: CGSize
        if windows.isEmpty {
            size = CGSize(width: Layout.playerWidth, height: Layout.padding * 2)
        } else if listMode {
            let rows = CGFloat(min(windows.count, Layout.maxListRows))
            size = CGSize(width: Layout.listWidth,
                          height: Layout.padding * 2 + rows * Layout.listRowHeight + (rows - 1) * 2)
        } else {
            size = Layout.gridSize(count: windows.count, columns: cols, scale: scale)
        }
        size.height += Layout.headerHeight + 8
        if player {
            size.height += Layout.playerHeight + 8
            size.width = max(size.width, Layout.playerWidth)
        }
        size.width = max(size.width, Layout.minPreviewWidth)
        place(size: size, screen: screen.frame)
        if !panel.isVisible { onShow?() }
        panel.orderFrontRegardless()
        startTracking()
        if !listMode { loadThumbnails(gen) }
    }

    private func place(size: CGSize, screen: CGRect) {
        let gap: CGFloat = 8
        var o: CGPoint
        switch orientation {
        case .bottom: o = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
        case .left:   o = CGPoint(x: anchor.maxX + gap, y: anchor.midY - size.height / 2)
        case .right:  o = CGPoint(x: anchor.minX - gap - size.width, y: anchor.midY - size.height / 2)
        }
        o.x = min(max(o.x, screen.minX + 8), screen.maxX - size.width - 8)
        o.y = min(max(o.y, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrame(CGRect(origin: o, size: size), display: true)
        panel.invalidateShadow()
    }

    private func loadThumbnails(_ gen: Int) {
        guard !model.listMode else { return }
        let ids = model.windows.map(\.windowID).filter { $0 != 0 }
        let maxSize = CGSize(width: Layout.cardWidth * model.scale - 8, height: Layout.thumbHeight * model.scale - 8)
        Task { @MainActor [weak self] in
            for id in ids {
                let img = await ThumbnailProvider.shared.thumbnail(windowID: id, maxSize: maxSize)
                guard let self, self.generation == gen else { return }
                if let img { self.model.thumbnails[id] = img }
            }
        }
    }

    // MARK: tracking / hiding

    private func startTracking() {
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        }
        if mouseMonitor == nil {
            // a global monitor doesn't see clicks on our own panel, so any click it sees closes it
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    private func stopTracking() {
        pollTimer?.invalidate(); pollTimer = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    private func bridgeRect() -> CGRect {
        let u = anchor.union(panel.frame)
        switch orientation {
        case .bottom: return CGRect(x: anchor.minX - 30, y: u.minY, width: anchor.width + 60, height: u.height)
        case .left, .right: return CGRect(x: u.minX, y: anchor.minY - 30, width: u.width, height: anchor.height + 60)
        }
    }

    private func poll() {
        guard panel.isVisible else { stopTracking(); return }

        pollTicks += 1
        if pollTicks % 15 == 0 { loadThumbnails(generation) }   // live refresh every ~1.5 s

        let m = NSEvent.mouseLocation
        if panel.frame.insetBy(dx: -6, dy: -6).contains(m) { return }
        if bridgeRect().contains(m) { return }
        if hoveredPID != nil, anchor.insetBy(dx: -30, dy: -30).contains(m) { return }
        if let h = hoveredPID, h != currentPID { return }  // moving to another icon, content is about to change
        hide()
    }

    func hide() {
        pendingTimer?.invalidate()
        generation += 1
        panel.orderOut(nil)
        currentPID = nil
        stopTracking()
    }

    // MARK: actions

    private func select(_ w: WindowInfo) {
        hide()
        WindowActions.focus(w)
    }

    private func refreshSoon() {
        guard let pid = currentPID else { return }
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentPID == pid,
                      let app = NSRunningApplication(processIdentifier: pid) else { return }
                self.show(app: app, anchorAX: self.anchorAX, force: true)
            }
        }
    }

    private func close(_ w: WindowInfo) {
        WindowActions.close(w)
        refreshSoon()
    }

    private func minimize(_ w: WindowInfo) {
        if w.isMinimized { WindowActions.focus(w); hide(); return }
        WindowActions.minimize(w)
        refreshSoon()
    }

    private func appAction(_ a: PreviewAppAction) {
        guard let pid = currentPID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        switch a {
        case .minimizeAll:
            for w in model.windows where !w.isMinimized && !w.isOnOtherSpace { WindowActions.minimize(w) }
            refreshSoon()
        case .closeAll:
            for w in model.windows { WindowActions.close(w) }
            refreshSoon()
        case .hide:
            hide(); app.hide()
        case .quit:
            hide(); app.terminate()
        }
    }
}
