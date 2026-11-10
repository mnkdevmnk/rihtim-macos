import AppKit
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Actions

/// Window snapping actions, named the way Rectangle names them.
enum SnapAction: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case maximize, almostMaximize, center, larger, smaller, restore
    case nextDisplay, previousDisplay
    case nextSpace, previousSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: return L("Left half")
        case .rightHalf: return L("Right half")
        case .topHalf: return L("Top half")
        case .bottomHalf: return L("Bottom half")
        case .topLeft: return L("Top left quarter")
        case .topRight: return L("Top right quarter")
        case .bottomLeft: return L("Bottom left quarter")
        case .bottomRight: return L("Bottom right quarter")
        case .firstThird: return L("First third")
        case .centerThird: return L("Center third")
        case .lastThird: return L("Last third")
        case .firstTwoThirds: return L("First two thirds")
        case .lastTwoThirds: return L("Last two thirds")
        case .maximize: return L("Maximize")
        case .almostMaximize: return L("Almost maximize")
        case .center: return L("Center")
        case .larger: return L("Make larger")
        case .smaller: return L("Make smaller")
        case .restore: return L("Restore previous size")
        case .nextDisplay: return L("Next display")
        case .previousDisplay: return L("Previous display")
        case .nextSpace: return L("Move to next desktop")
        case .previousSpace: return L("Move to previous desktop")
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .topLeft: return "rectangle.inset.topleft.filled"
        case .topRight: return "rectangle.inset.topright.filled"
        case .bottomLeft: return "rectangle.inset.bottomleft.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        case .firstThird, .centerThird, .lastThird: return "rectangle.split.3x1"
        case .firstTwoThirds, .lastTwoThirds: return "rectangle.split.2x1"
        case .maximize: return "rectangle.fill"
        case .almostMaximize: return "rectangle.inset.filled"
        case .center: return "rectangle.center.inset.filled"
        case .larger: return "plus.rectangle"
        case .smaller: return "minus.rectangle"
        case .restore: return "arrow.uturn.backward"
        case .nextDisplay: return "rectangle.righthalf.inset.filled.arrow.right"
        case .previousDisplay: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .nextSpace: return "arrow.right.square"
        case .previousSpace: return "arrow.left.square"
        }
    }

    var group: Int {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: return 0
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return 1
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds: return 2
        case .maximize, .almostMaximize, .center, .larger, .smaller, .restore: return 3
        case .nextDisplay, .previousDisplay, .nextSpace, .previousSpace: return 4
        }
    }

    var defaultShortcut: Shortcut? {
        let co = Shortcut.ctrl | Shortcut.opt
        switch self {
        case .leftHalf: return Shortcut(code: kVK_LeftArrow, mods: co)
        case .rightHalf: return Shortcut(code: kVK_RightArrow, mods: co)
        case .topHalf: return Shortcut(code: kVK_UpArrow, mods: co)
        case .bottomHalf: return Shortcut(code: kVK_DownArrow, mods: co)
        case .topLeft: return Shortcut(code: kVK_ANSI_U, mods: co)
        case .topRight: return Shortcut(code: kVK_ANSI_I, mods: co)
        case .bottomLeft: return Shortcut(code: kVK_ANSI_J, mods: co)
        case .bottomRight: return Shortcut(code: kVK_ANSI_K, mods: co)
        case .firstThird: return Shortcut(code: kVK_ANSI_D, mods: co)
        case .centerThird: return Shortcut(code: kVK_ANSI_F, mods: co)
        case .lastThird: return Shortcut(code: kVK_ANSI_G, mods: co)
        case .firstTwoThirds: return Shortcut(code: kVK_ANSI_E, mods: co)
        case .lastTwoThirds: return Shortcut(code: kVK_ANSI_T, mods: co)
        case .maximize: return Shortcut(code: kVK_Return, mods: co)
        case .almostMaximize: return Shortcut(code: kVK_Return, mods: co | Shortcut.shift)
        case .center: return Shortcut(code: kVK_ANSI_C, mods: co)
        case .larger: return Shortcut(code: kVK_ANSI_Equal, mods: co)
        case .smaller: return Shortcut(code: kVK_ANSI_Minus, mods: co)
        case .restore: return Shortcut(code: kVK_Delete, mods: co)
        case .nextDisplay: return Shortcut(code: kVK_RightArrow, mods: co | Shortcut.cmd)
        case .previousDisplay: return Shortcut(code: kVK_LeftArrow, mods: co | Shortcut.cmd)
        case .nextSpace: return Shortcut(code: kVK_RightArrow, mods: co | Shortcut.shift)
        case .previousSpace: return Shortcut(code: kVK_LeftArrow, mods: co | Shortcut.shift)
        }
    }

    var prefKey: String { "snap.key." + rawValue }

    /// Saved shortcut; nil if the user cleared it.
    var shortcut: Shortcut? {
        guard let s = UserDefaults.standard.string(forKey: prefKey) else { return defaultShortcut }
        return Shortcut(string: s)
    }
}

/// Carbon hotkey: virtual key code + Carbon modifier mask.
struct Shortcut: Equatable {
    static let cmd = UInt32(cmdKey), shift = UInt32(shiftKey), opt = UInt32(optionKey), ctrl = UInt32(controlKey)

    var code: UInt32
    var mods: UInt32
    var label: String?

    init(code: Int, mods: UInt32, label: String? = nil) {
        self.code = UInt32(code); self.mods = mods; self.label = label
    }

    init?(string: String) {
        let p = string.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        guard p.count >= 2, let c = UInt32(p[0]), let m = UInt32(p[1]) else { return nil }
        code = c; mods = m
        label = p.count == 3 && !p[2].isEmpty ? String(p[2]) : nil
    }

    var string: String { "\(code),\(mods),\(label ?? "")" }

    static func from(event: NSEvent) -> Shortcut? {
        let f = event.modifierFlags
        var m: UInt32 = 0
        if f.contains(.command) { m |= cmd }
        if f.contains(.shift) { m |= shift }
        if f.contains(.option) { m |= opt }
        if f.contains(.control) { m |= ctrl }
        guard m != 0, m != shift else { return nil }   // a shortcut needs a real modifier
        let ch = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return Shortcut(code: Int(event.keyCode), mods: m, label: ch.isEmpty ? nil : ch)
    }

    private static let names: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Return: "↩", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Space: "Space", kVK_Tab: "⇥",
        kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
    ]

    var display: String {
        var s = ""
        if mods & Shortcut.ctrl != 0 { s += "⌃" }
        if mods & Shortcut.opt != 0 { s += "⌥" }
        if mods & Shortcut.shift != 0 { s += "⇧" }
        if mods & Shortcut.cmd != 0 { s += "⌘" }
        return s + (Shortcut.names[Int(code)] ?? label ?? "#\(code)")
    }
}

// MARK: - Geometry

/// All math is in AX coordinates (origin at the primary screen's top-left, y grows down).
@MainActor
enum SnapGeometry {
    /// Usable screen area (minus menu bar and Dock), in AX coordinates.
    static func visibleAX(_ screen: NSScreen) -> CGRect {
        let v = screen.visibleFrame
        return CGRect(x: v.minX, y: Geometry.primaryHeight - v.maxY, width: v.width, height: v.height)
    }

    static func fullAX(_ screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: f.minX, y: Geometry.primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    /// The screen the window overlaps most.
    static func screen(forAX r: CGRect) -> NSScreen {
        let c = Geometry.cocoa(fromAX: r)
        var best: NSScreen?
        var bestArea: CGFloat = -1
        for s in NSScreen.screens {
            let i = s.frame.intersection(c)
            let a = i.isNull ? 0 : i.width * i.height
            if a > bestArea { bestArea = a; best = s }
        }
        return best ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Fraction (x, y, w, h; y from the top) -> real rect on screen, with the gap applied.
    static func rect(_ frac: CGRect, in vf: CGRect, gap g: CGFloat) -> CGRect {
        var r = CGRect(x: vf.minX + frac.minX * vf.width, y: vf.minY + frac.minY * vf.height,
                       width: frac.width * vf.width, height: frac.height * vf.height)
        guard g > 0 else { return r.integral }
        let eps: CGFloat = 1
        let l = abs(r.minX - vf.minX) < eps ? g : g / 2
        let rr = abs(r.maxX - vf.maxX) < eps ? g : g / 2
        let t = abs(r.minY - vf.minY) < eps ? g : g / 2
        let b = abs(r.maxY - vf.maxY) < eps ? g : g / 2
        r = CGRect(x: r.minX + l, y: r.minY + t, width: r.width - l - rr, height: r.height - t - b)
        return r.integral
    }

    /// Ratios cycled through when a half is pressed again.
    static let cycle: [CGFloat] = [1.0 / 2, 2.0 / 3, 1.0 / 3]

    /// Target fraction for an action. `step` = how many times in a row the key was pressed.
    static func fraction(_ a: SnapAction, step: Int, cycles: Bool, portrait: Bool) -> CGRect? {
        let f = cycles ? cycle[step % cycle.count] : 0.5
        switch a {
        case .leftHalf: return CGRect(x: 0, y: 0, width: f, height: 1)
        case .rightHalf: return CGRect(x: 1 - f, y: 0, width: f, height: 1)
        case .topHalf: return CGRect(x: 0, y: 0, width: 1, height: f)
        case .bottomHalf: return CGRect(x: 0, y: 1 - f, width: 1, height: f)
        case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds:
            let (start, len): (CGFloat, CGFloat) = {
                switch a {
                case .firstThird: return (0, 1.0 / 3)
                case .centerThird: return (1.0 / 3, 1.0 / 3)
                case .lastThird: return (2.0 / 3, 1.0 / 3)
                case .firstTwoThirds: return (0, 2.0 / 3)
                default: return (1.0 / 3, 2.0 / 3)
                }
            }()
            // On a portrait screen thirds go top to bottom.
            return portrait ? CGRect(x: 0, y: start, width: 1, height: len)
                            : CGRect(x: start, y: 0, width: len, height: 1)
        case .maximize: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .almostMaximize: return CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        default: return nil
        }
    }

    static func close(_ a: CGRect, _ b: CGRect, tol: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol &&
        abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }
}

// MARK: - Window access

@MainActor
enum SnapWindow {
    static func focused() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        return AX.element(el, kAXFocusedWindowAttribute) ?? AX.element(el, kAXMainWindowAttribute)
    }

    /// Window under the pointer (AX coordinates).
    static func at(_ p: CGPoint) -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success, var cur = el else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(cur, &pid)
        if pid == getpid() { return nil }
        for _ in 0..<12 {
            if AX.string(cur, kAXRoleAttribute) == kAXWindowRole as String { return cur }
            if let w = AX.element(cur, kAXWindowAttribute) { return w }
            guard let parent = AX.element(cur, kAXParentAttribute) else { return nil }
            cur = parent
        }
        return nil
    }

    static func isResizable(_ w: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(w, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    static func isFullScreen(_ w: AXUIElement) -> Bool { AX.bool(w, "AXFullScreen") ?? false }

    /// Applies position and size. Size, position, size again, because moving across
    /// screens can clamp the size (Rectangle does the same).
    static func setFrame(_ w: AXUIElement, _ r: CGRect) {
        var pid: pid_t = 0
        AXUIElementGetPid(w, &pid)
        let app = AXUIElementCreateApplication(pid)
        // With AXEnhancedUserInterface on (VoiceOver etc.) apps animate the resize and get it wrong.
        let enhanced = AX.bool(app, "AXEnhancedUserInterface") ?? false
        if enhanced { AX.set(app, "AXEnhancedUserInterface", kCFBooleanFalse) }
        setSize(w, r.size)
        setPos(w, r.origin)
        setSize(w, r.size)
        if enhanced { AX.set(app, "AXEnhancedUserInterface", kCFBooleanTrue) }
    }

    static func setPos(_ w: AXUIElement, _ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) { AX.set(w, kAXPositionAttribute, v) }
    }

    static func setSize(_ w: AXUIElement, _ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) { AX.set(w, kAXSizeAttribute, v) }
    }
}

// MARK: - Controller

@MainActor
final class WindowSnapper {
    static weak var shared: WindowSnapper?

    var hotkeysEnabled = false { didSet { if hotkeysEnabled != oldValue { reloadHotKeys() } } }
    var dragEnabled = false { didSet { if dragEnabled != oldValue { updateTap() } } }
    var gap: CGFloat = 0
    var cycles = true
    var restoreOnDrag = true
    var dragTopMaximizes = true
    var showsFlash = true
    /// Only snap on edge drag while ⌘ is held.
    var snapNeedsCommand = true
    /// Without ⌘, resting on the left/right edge moves to the neighboring desktop.
    var spaceDragEnabled = true
    var spaceDelay: TimeInterval = 0.45

    private var started = false
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var actionsByID: [UInt32: SnapAction] = [:]
    private var suspended = false

    /// Frame before snapping and the frame we applied, per window ID.
    private struct Saved { var original: CGRect; var applied: CGRect }
    private var saved: [CGWindowID: Saved] = [:]
    private var last: (action: SnapAction, wid: CGWindowID, step: Int, frame: CGRect)?

    // drag-to-snap state
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private enum DragState { case idle, pending, moving, ignored }
    private var dragState: DragState = .idle
    private var dragWindow: AXUIElement?
    private var dragWID: CGWindowID = 0
    private var dragStart: CGPoint = .zero
    private var dragStartFrame: CGRect = .zero
    private var dragChecks = 0
    private var dragZone: SnapAction?
    private var dragScreen: NSScreen?
    private let overlay = SnapOverlay()
    private let edgeHint = SnapOverlay(edge: true)
    private var lastLoc: CGPoint = .zero
    private var commandDown = false
    private var spaceTimer: Timer?
    private var spaceEdge: Int = 0          // -1 left, 1 right
    private var synthesizing = false        // mouse events we're posting ourselves

    init() { WindowSnapper.shared = self }

    func start() {
        started = true
        reloadHotKeys()
        updateTap()
    }

    // MARK: hotkeys

    /// Temporarily off so the shortcut recorder in Settings can catch the keys.
    func suspend(_ on: Bool) {
        suspended = on
        reloadHotKeys()
    }

    func reloadHotKeys() {
        for r in hotKeyRefs { UnregisterEventHotKey(r) }
        hotKeyRefs.removeAll()
        actionsByID.removeAll()
        guard started, hotkeysEnabled, !suspended else { return }
        installHandler()
        var id: UInt32 = 1
        for a in SnapAction.allCases {
            guard let s = a.shortcut else { continue }
            var ref: EventHotKeyRef?
            let hk = EventHotKeyID(signature: OSType(0x5248_534E), id: id)  // 'RHSN'
            let st = RegisterEventHotKey(s.code, s.mods, hk, GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref {
                hotKeyRefs.append(ref)
                actionsByID[id] = a
            } else {
                Diag.log("snap: couldn't register hotkey \(a.rawValue) \(s.display) (\(st))")
            }
            id += 1
        }
        Diag.log("snap: \(hotKeyRefs.count) hotkeys registered")
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<WindowSnapper>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.hotKey(hk.id) }
            return noErr
        }, 1, &spec, refcon, &handlerRef)
    }

    private func hotKey(_ id: UInt32) {
        guard let a = actionsByID[id] else { return }
        guard let w = SnapWindow.focused() else { NSSound.beep(); return }
        if a == .nextSpace || a == .previousSpace { throwToSpace(w, right: a == .nextSpace); return }
        perform(a, on: w)
    }

    // MARK: applying

    func perform(_ a: SnapAction, on w: AXUIElement) {
        guard let cur = AX.frame(w) else { return }
        if SnapWindow.isFullScreen(w) { NSSound.beep(); return }
        let wid = AX.windowID(w)
        let screen = SnapGeometry.screen(forAX: cur)
        let vf = SnapGeometry.visibleAX(screen)

        var step = 0
        if let l = last, l.action == a, l.wid == wid, SnapGeometry.close(l.frame, cur, tol: 8) { step = l.step + 1 }

        var target: CGRect?
        switch a {
        case .restore:
            guard let s = saved[wid] else { NSSound.beep(); return }
            SnapWindow.setFrame(w, s.original)
            saved[wid] = nil
            last = nil
            return
        case .center:
            let size = CGSize(width: min(cur.width, vf.width), height: min(cur.height, vf.height))
            target = CGRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2,
                            width: size.width, height: size.height).integral
        case .larger, .smaller:
            let d: CGFloat = a == .larger ? 30 : -30
            var r = cur.insetBy(dx: -d, dy: -d)
            if a == .smaller, r.width < 200 || r.height < 150 { r = cur }
            r = r.intersection(vf)
            target = r.isNull ? cur : r.integral
        case .nextSpace, .previousSpace:
            throwToSpace(w, right: a == .nextSpace)
            return
        case .nextDisplay, .previousDisplay:
            let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
            guard screens.count > 1, let i = screens.firstIndex(of: screen) else { NSSound.beep(); return }
            let next = screens[(i + (a == .nextDisplay ? 1 : screens.count - 1)) % screens.count]
            let nvf = SnapGeometry.visibleAX(next)
            let rel = CGRect(x: (cur.minX - vf.minX) / vf.width, y: (cur.minY - vf.minY) / vf.height,
                             width: cur.width / vf.width, height: cur.height / vf.height)
            var r = CGRect(x: nvf.minX + rel.minX * nvf.width, y: nvf.minY + rel.minY * nvf.height,
                           width: min(rel.width, 1) * nvf.width, height: min(rel.height, 1) * nvf.height)
            r.origin.x = min(max(r.minX, nvf.minX), nvf.maxX - r.width)
            r.origin.y = min(max(r.minY, nvf.minY), nvf.maxY - r.height)
            target = r.integral
        default:
            guard let frac = SnapGeometry.fraction(a, step: step, cycles: cycles, portrait: vf.height > vf.width)
            else { return }
            target = SnapGeometry.rect(frac, in: vf, gap: gap)
        }
        guard var r = target else { return }
        if !SnapWindow.isResizable(w) {
            // Window that can't be resized: center it in the target.
            r = CGRect(x: r.midX - cur.width / 2, y: r.midY - cur.height / 2, width: cur.width, height: cur.height)
        }

        if saved[wid] == nil { saved[wid] = Saved(original: cur, applied: r) }
        else { saved[wid]?.applied = r }
        SnapWindow.setFrame(w, r)
        // The app may have clamped the size, so store what actually happened.
        let applied = AX.frame(w) ?? r
        saved[wid]?.applied = applied
        last = (a, wid, step, applied)
        if showsFlash, !overlay.isVisible { overlay.flash(Geometry.cocoa(fromAX: applied)) }
    }

    // MARK: drag to snap

    private func updateTap() {
        let want = started && dragEnabled
        if want, tap == nil { installTap() }
        if !want, let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            CFMachPortInvalidate(tap)
            self.tap = nil
            tapSource = nil
            endDrag()
        }
    }

    private func installTap() {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<WindowSnapper>.fromOpaque(refcon).takeUnretainedValue()
                let loc = event.location, cmd = event.flags.contains(.maskCommand)
                MainActor.assumeIsolated { me.mouse(type, loc, cmd) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon) else {
            Diag.log("snap: couldn't create drag tap")
            return
        }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        tapSource = src
        CGEvent.tapEnable(tap: t, enable: true)
        Diag.log("snap: drag to snap on")
    }

    /// `loc` is in CG global coordinates, which match AX (top-left origin).
    private func mouse(_ type: CGEventType, _ loc: CGPoint, _ cmd: Bool) {
        if synthesizing { return }
        if type != .flagsChanged { lastLoc = loc }
        commandDown = cmd
        switch type {
        case .flagsChanged:
            if dragState == .moving { dragZone = nil; dragScreen = nil; updateZone(lastLoc, force: true) }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            endDrag()
            dragState = .pending
            dragStart = loc
            dragChecks = 0
        case .leftMouseDragged:
            dragged(loc)
        case .leftMouseUp:
            if dragState == .moving, let zone = dragZone, let w = dragWindow {
                // Let the app finish its own drag, then place the window.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    MainActor.assumeIsolated { self?.perform(zone, on: w) }
                }
            }
            endDrag()
        default: break
        }
    }

    private func dragged(_ loc: CGPoint) {
        switch dragState {
        case .idle, .ignored: return
        case .pending:
            if dragWindow == nil {
                guard let w = SnapWindow.at(dragStart), let f = AX.frame(w) else { dragState = .ignored; return }
                // Only drags that grab the title bar (moving the window), not content drags.
                dragWindow = w
                dragWID = AX.windowID(w)
                dragStartFrame = f
            }
            guard let w = dragWindow, let f = AX.frame(w) else { dragState = .ignored; return }
            dragChecks += 1
            if abs(f.width - dragStartFrame.width) > 1 || abs(f.height - dragStartFrame.height) > 1 {
                dragState = .ignored   // resizing
                return
            }
            if abs(f.minX - dragStartFrame.minX) > 1 || abs(f.minY - dragStartFrame.minY) > 1 {
                dragState = .moving
                beganMoving(w, loc)
            } else if hypot(loc.x - dragStart.x, loc.y - dragStart.y) > 40 || dragChecks > 40 {
                dragState = .ignored   // text selection and such
            }
        case .moving:
            updateZone(loc, force: false)
        }
    }

    private func beganMoving(_ w: AXUIElement, _ loc: CGPoint) {
        // Dragging a snapped window restores its old size.
        guard restoreOnDrag, let s = saved[dragWID], let f = AX.frame(w),
              abs(f.width - s.applied.width) < 6, abs(f.height - s.applied.height) < 6 else { return }
        saved[dragWID] = nil
        last = nil
        // Keep the pointer at the same relative spot in the title bar.
        let ratio = (loc.x - f.minX) / max(f.width, 1)
        let size = s.original.size
        SnapWindow.setSize(w, size)
        SnapWindow.setPos(w, CGPoint(x: loc.x - ratio * size.width, y: f.minY))
        dragStartFrame = AX.frame(w) ?? dragStartFrame
    }

    private func updateZone(_ loc: CGPoint, force: Bool) {
        let cocoaPt = CGPoint(x: loc.x, y: Geometry.primaryHeight - loc.y)
        let screen = Geometry.screen(containing: cocoaPt)
        let full = SnapGeometry.fullAX(screen)
        let vf = SnapGeometry.visibleAX(screen)
        let edge: CGFloat = 6
        let corner: CGFloat = 90

        let left = loc.x <= full.minX + edge
        let right = loc.x >= full.maxX - edge
        let top = loc.y <= full.minY + edge
        let bottom = loc.y >= full.maxY - edge
        let nearTop = loc.y <= full.minY + corner
        let nearBottom = loc.y >= full.maxY - corner
        let nearLeft = loc.x <= full.minX + corner
        let nearRight = loc.x >= full.maxX - corner

        // Without ⌘: no snapping, resting on the left/right edge switches desktops.
        let snapping = !snapNeedsCommand || commandDown
        let edgeSide = spaceDragEnabled && !snapping ? (left ? -1 : right ? 1 : 0) : 0
        updateSpaceDwell(edgeSide, full: full)

        var zone: SnapAction?
        if !snapping {
            zone = nil
        } else if left { zone = nearTop ? .topLeft : nearBottom ? .bottomLeft : .leftHalf }
        else if right { zone = nearTop ? .topRight : nearBottom ? .bottomRight : .rightHalf }
        else if top {
            zone = nearLeft ? .topLeft : nearRight ? .topRight : (dragTopMaximizes ? .maximize : .topHalf)
        } else if bottom {
            let third = (loc.x - full.minX) / full.width
            zone = nearLeft ? .bottomLeft : nearRight ? .bottomRight
                 : third < 1.0 / 3 ? .firstThird : third < 2.0 / 3 ? .centerThird : .lastThird
        }

        guard force || zone != dragZone || screen != dragScreen else { return }
        dragZone = zone
        dragScreen = screen
        if let zone, let frac = SnapGeometry.fraction(zone, step: 0, cycles: false, portrait: vf.height > vf.width) {
            overlay.show(Geometry.cocoa(fromAX: SnapGeometry.rect(frac, in: vf, gap: gap)))
        } else {
            overlay.hide()
        }
    }

    // MARK: switching desktops

    private func updateSpaceDwell(_ side: Int, full: CGRect) {
        guard side != spaceEdge else { return }
        spaceEdge = side
        spaceTimer?.invalidate()
        spaceTimer = nil
        guard side != 0 else { edgeHint.hide(); return }
        let w: CGFloat = 10
        let strip = CGRect(x: side < 0 ? full.minX : full.maxX - w, y: full.minY, width: w, height: full.height)
        edgeHint.show(Geometry.cocoa(fromAX: strip))
        armSpaceTimer(spaceDelay)
    }

    private func armSpaceTimer(_ delay: TimeInterval) {
        spaceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.dragState == .moving, self.spaceEdge != 0 else { return }
                SymbolicHotKeys.post(self.spaceEdge < 0 ? SymbolicHotKeys.spaceLeft : SymbolicHotKeys.spaceRight)
                Diag.log("snap: drag moved desktop \(self.spaceEdge < 0 ? "left" : "right")")
                // Still on the edge: keep going to the next one.
                self.armSpaceTimer(max(self.spaceDelay, 0.3) + 0.55)
            }
        }
    }

    /// Keyboard version: fake-grab the title bar and switch desktops, macOS carries the window along.
    func throwToSpace(_ w: AXUIElement, right: Bool) {
        guard let f = AX.frame(w), !SnapWindow.isFullScreen(w) else { NSSound.beep(); return }
        var grab = CGPoint(x: f.minX + 90, y: f.minY + 12)
        if let zoom = AX.element(w, kAXZoomButtonAttribute), let zf = AX.frame(zoom) {
            grab = CGPoint(x: zf.maxX + 24, y: zf.midY)
        }
        let back = CGEvent(source: nil)?.location ?? grab
        let src = CGEventSource(stateID: .hidSystemState)
        func mouse(_ t: CGEventType, _ p: CGPoint) {
            CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        synthesizing = true
        mouse(.leftMouseDown, grab)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            mouse(.leftMouseDragged, CGPoint(x: grab.x + 1, y: grab.y))
            SymbolicHotKeys.post(right ? SymbolicHotKeys.spaceRight : SymbolicHotKeys.spaceLeft)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                mouse(.leftMouseUp, CGPoint(x: grab.x + 1, y: grab.y))
                CGWarpMouseCursorPosition(back)
                MainActor.assumeIsolated { self?.synthesizing = false }
            }
        }
        Diag.log("snap: window moved desktop \(right ? "right" : "left") (hotkey)")
    }

    private func endDrag() {
        spaceTimer?.invalidate()
        spaceTimer = nil
        spaceEdge = 0
        edgeHint.hide()
        dragState = .idle
        dragWindow = nil
        dragWID = 0
        dragZone = nil
        dragScreen = nil
        overlay.hide()
    }
}

// MARK: - Preview overlay

/// Translucent rectangle showing the drop target while dragging.
@MainActor
final class SnapOverlay {
    private var panel: NSPanel?
    private(set) var isVisible = false
    private let edge: Bool

    init(edge: Bool = false) { self.edge = edge }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = edge ? 5 : 14
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 1.5
        v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(edge ? 0.7 : 0.18).cgColor
        tint.autoresizingMask = [.width, .height]
        v.addSubview(tint)
        p.contentView = v
        return p
    }

    func show(_ frame: CGRect) {
        let p = panel ?? make()
        panel = p
        if !isVisible {
            p.setFrame(frame.insetBy(dx: frame.width * 0.04, dy: frame.height * 0.04), display: false)
            p.alphaValue = 0
            p.orderFrontRegardless()
            isVisible = true
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(frame, display: true)
            p.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isVisible, let p = panel else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if self?.isVisible == false { p.orderOut(nil) } }
        })
    }

    /// Short flash after a hotkey.
    func flash(_ frame: CGRect) {
        show(frame)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
    }
}
