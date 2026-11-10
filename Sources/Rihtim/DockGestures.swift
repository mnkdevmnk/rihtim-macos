import AppKit

/// What clicking the frontmost app's Dock icon does.
enum DockClickAction: String, CaseIterable, Identifiable {
    case none, minimize, hide
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return L("Nothing (macOS default)")
        case .minimize: return L("Minimize its windows")
        case .hide: return L("Hide the app")
        }
    }
}

/// Mouse gestures on Dock icons. The Dock itself is left alone: events come in through a
/// CGEventTap and are only handled when the pointer is really over an app icon
/// (AX selection + frame).
///  - click the frontmost app's icon → minimize / hide
///  - scroll on an icon: down → hide, up → show and bring to front
///  - ⌘ + right-click → quit, ⌥⌘ + right-click → force quit (no Dock menu)
@MainActor
final class DockGestures {
    var clickAction: DockClickAction = .minimize { didSet { update() } }
    var scrollEnabled = true { didSet { update() } }
    var quitClickEnabled = true { didSet { update() } }
    /// Fired after a gesture ran (used to close the preview).
    var onAction: (@MainActor () -> Void)?

    private let dock: DockObserver
    private var started = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private var pressed: (pid: pid_t, wasFront: Bool, loc: CGPoint)?
    private var swallowRightUp = false
    private var scrollAcc: CGFloat = 0
    private var scrollPID: pid_t?
    private var lastScroll = Date.distantPast
    private var scrollCooldown = Date.distantPast

    init(dock: DockObserver) { self.dock = dock }

    func start() {
        started = true
        update()
    }

    private var wanted: Bool { started && (clickAction != .none || scrollEnabled || quitClickEnabled) }

    private func update() {
        if wanted, tap == nil { install() }
        if !wanted, let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
            self.tap = nil
            self.source = nil
        }
    }

    private func install() {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<DockGestures>.fromOpaque(refcon).takeUnretainedValue()
                let swallow = MainActor.assumeIsolated { me.handle(type: type, event: event) }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon) else {
            Diag.log("dock gestures: couldn't create event tap")
            return
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        source = src
        CGEvent.tapEnable(tap: tap, enable: true)
        Diag.log("dock gestures on (click=\(clickAction.rawValue) scroll=\(scrollEnabled) cmdRightClick=\(quitClickEnabled))")
    }

    /// The app whose icon is under the pointer, if any.
    private func hoveredApp(at loc: CGPoint) -> NSRunningApplication? {
        guard let item = dock.current, item.kind == .app, let app = item.app,
              item.frameAX.insetBy(dx: -2, dy: -2).contains(loc),
              app.processIdentifier != getpid() else { return nil }
        return app
    }

    /// true = swallow the event so the Dock never sees it.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .rightMouseUp:
            if swallowRightUp { swallowRightUp = false; return true }
            return false
        case .leftMouseUp:
            defer { pressed = nil }
            guard let p = pressed, p.wasFront, clickAction != .none else { return false }
            let loc = event.location
            guard hypot(loc.x - p.loc.x, loc.y - p.loc.y) < 6,
                  let app = hoveredApp(at: loc), app.processIdentifier == p.pid else { return false }
            let action = clickAction
            // Let the Dock finish its own click first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                MainActor.assumeIsolated { self?.applyClick(action, app) }
            }
            return false
        default: break
        }

        let loc = event.location
        guard let app = hoveredApp(at: loc) else { return false }
        let mods = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])

        switch type {
        case .leftMouseDown:
            guard clickAction != .none, mods.isEmpty else { pressed = nil; return false }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            pressed = (app.processIdentifier, front && !app.isHidden, loc)
            return false

        case .rightMouseDown:
            guard quitClickEnabled, mods.contains(.maskCommand), !mods.contains(.maskControl) else { return false }
            swallowRightUp = true
            onAction?()
            if mods.contains(.maskAlternate) {
                Diag.log("dock: force quit \(app.localizedName ?? "")")
                app.forceTerminate()
            } else {
                Diag.log("dock: quit \(app.localizedName ?? "")")
                app.terminate()
            }
            return true

        case .scrollWheel:
            guard scrollEnabled else { return false }
            handleScroll(event, app)
            return true

        default:
            return false
        }
    }

    private func handleScroll(_ event: CGEvent, _ app: NSRunningApplication) {
        let now = Date()
        if scrollPID != app.processIdentifier || now.timeIntervalSince(lastScroll) > 0.4 { scrollAcc = 0 }
        scrollPID = app.processIdentifier
        lastScroll = now
        guard now > scrollCooldown else { return }

        var dy = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
        if dy == 0 { dy = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * 10 }
        // Natural scrolling flips the sign; normalize to finger/wheel direction (positive = up).
        let inverted = NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false
        scrollAcc += inverted ? -dy : dy
        guard abs(scrollAcc) >= 14 else { return }

        let up = scrollAcc > 0
        scrollAcc = 0
        scrollCooldown = now.addingTimeInterval(0.5)
        onAction?()
        if up {
            AppActions.activate(app)
        } else {
            app.hide()
        }
    }

    private func applyClick(_ action: DockClickAction, _ app: NSRunningApplication) {
        switch action {
        case .none: return
        case .hide:
            onAction?()
            app.hide()
        case .minimize:
            let visible = WindowEnumerator.windows(for: app).filter { !$0.isMinimized && !$0.isOnOtherSpace }
            guard !visible.isEmpty else { return }   // no open windows: let the Dock bring it back
            onAction?()
            for w in visible { WindowActions.minimize(w) }
        }
    }
}
