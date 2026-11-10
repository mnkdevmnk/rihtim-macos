import AppKit

/// Keeps an auto-hiding Dock on screen while one of our panels (window preview, folder
/// list, widget strip) is under the pointer. Same trick as DockDoor: a listen-only tap on
/// the Dock process watches for its "mouse exited" event and answers with a synthetic
/// mouse-moved at the screen edge, sent only to the Dock. The Dock's settings are never
/// changed and the real cursor never moves.
@MainActor
final class DockReveal {
    static let shared = DockReveal()

    /// Owners currently asking for the Dock to stay up ("preview", "folder", "bar").
    private var holders: Set<String> = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var dockPID: pid_t = 0
    fileprivate var revealPoint: CGPoint = .zero
    private var dockRegion: CGRect = .zero
    fileprivate var list: AXUIElement?
    private var shownMinY: CGFloat = 0
    private var keepAlive: Timer?
    private var exitCount = 0
    private var droppedMoves = 0
    /// Tags our own synthetic events so the tap lets them through.
    static let marker: Int64 = 0x5249_4854

    /// Called when the Dock slides away anyway; our panels close so nothing floats alone.
    var onDockHidden: (@MainActor () -> Void)?

    static let mouseExited = CGEventType(rawValue: UInt32(NSEvent.EventType.mouseExited.rawValue))!

    var isHeld: Bool { !holders.isEmpty }

    func hold(_ owner: String) {
        guard !holders.contains(owner) else { return }
        guard Self.autohideOn else { return }
        holders.insert(owner)
        if tap == nil { install() }
    }

    func release(_ owner: String) {
        guard holders.remove(owner) != nil, holders.isEmpty else { return }
        uninstall()
    }

    static var autohideOn: Bool {
        UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
    }

    /// Mouse position in global CG (top-left) coordinates.
    fileprivate static var mouseCG: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    fileprivate func computeTarget() -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return false }
        let ax = AXUIElementCreateApplication(dock.processIdentifier)
        guard let list = AX.elements(ax, kAXChildrenAttribute)?.first(where: { AX.string($0, kAXRoleAttribute) == kAXListRole }),
              let f = AX.frame(list), f.width > 0 else { return false }
        self.list = list
        shownMinY = f.minY
        let ph = Geometry.primaryHeight
        let screens = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: ph - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
        guard let s = screens.first(where: { $0.insetBy(dx: -2, dy: -2).intersects(f) || ($0.minX...$0.maxX).contains(f.midX) }) else { return false }
        dockPID = dock.processIdentifier

        let distBottom = s.maxY - f.maxY, distLeft = f.minX - s.minX, distRight = s.maxX - f.maxX
        if distBottom <= min(distLeft, distRight) {
            let x = min(max((s.minX + f.minX) / 2, s.minX + 32), f.minX)
            revealPoint = CGPoint(x: x, y: s.maxY - 1)
            dockRegion = CGRect(x: f.minX, y: f.minY, width: f.width, height: max(0, s.maxY - f.minY))
        } else if distLeft < distRight {
            let y = min(max((s.minY + f.minY) / 2, s.minY + 32), f.minY)
            revealPoint = CGPoint(x: s.minX, y: y)
            dockRegion = CGRect(x: s.minX, y: f.minY, width: max(0, f.maxX - s.minX), height: f.height)
        } else {
            let y = min(max((s.minY + f.minY) / 2, s.minY + 32), f.minY)
            revealPoint = CGPoint(x: s.maxX - 1, y: y)
            dockRegion = CGRect(x: f.minX, y: f.minY, width: max(0, s.maxX - f.minX), height: f.height)
        }
        return true
    }

    private func install() {
        guard CGPreflightPostEventAccess(), computeTarget() else {
            Diag.log("dock reveal: not possible (post access=\(CGPreflightPostEventAccess()))")
            return
        }
        // Active tap on the Dock process: while held, the Dock never hears that the real
        // pointer left (exited / moves outside its area are dropped), so it stays up.
        let types: [CGEventType] = [Self.mouseExited, .mouseMoved, .leftMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreateForPid(
            pid: dockPID, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                let drop = MainActor.assumeIsolated { DockReveal.shared.handle(type, event) }
                return drop ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: nil) else {
            Diag.log("dock reveal: couldn't create tap")
            return
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        source = src
        CGEvent.tapEnable(tap: tap, enable: true)
        // The pointer may already have left the Dock on its way to our panel.
        if !dockRegion.contains(Self.mouseCG) { post(.mouseMoved, at: revealPoint) }
        exitCount = 0
        droppedMoves = 0
        Diag.log("dock reveal: hold (pid=\(dockPID) point=\(revealPoint) region=\(dockRegion))")
        keepAlive = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { DockReveal.shared.tick() }
        }
    }

    /// Re-assert the edge position while held, and notice if the Dock hides anyway.
    private func tick() {
        guard tap != nil else { return }
        if !dockRegion.contains(Self.mouseCG) { post(.mouseMoved, at: revealPoint) }
        if let list, let f = AX.frame(list), f.minY > shownMinY + 6 {
            Diag.log("dock reveal: Dock hid anyway (minY \(shownMinY) -> \(f.minY), exits=\(exitCount), dropped=\(droppedMoves)); closing panels")
            holders.removeAll()
            uninstall()
            onDockHidden?()
        }
    }

    private func uninstall() {
        keepAlive?.invalidate(); keepAlive = nil
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        // Let the Dock hide normally now that nothing holds it.
        let m = Self.mouseCG
        if !dockRegion.contains(m) { post(Self.mouseExited, at: m) }
        Diag.log("dock reveal: release (exits seen=\(exitCount), moves dropped=\(droppedMoves))")
    }

    /// true = drop the event before the Dock sees it.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        default: break
        }
        guard tap != nil, event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return false }
        if type == Self.mouseExited {
            exitCount += 1
            post(.mouseMoved, at: revealPoint)
            return true
        }
        // real pointer moves outside the Dock: hide them from the Dock
        if !dockRegion.contains(event.location) {
            droppedMoves += 1
            return true
        }
        return false
    }

    fileprivate func post(_ type: CGEventType, at p: CGPoint) {
        guard dockPID != 0,
              let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) else { return }
        e.type = type
        e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        e.postToPid(dockPID)
    }
}

#if DEBUG
// MARK: - experiment (debug only): which synthetic event keeps / brings the Dock up?
// Trigger: post the distributed notification "dev.minik.rihtim.revealTest".
extension DockReveal {
    func installTestHook() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.minik.rihtim.revealTest"), object: nil, queue: .main) { _ in
            Task { @MainActor in await DockReveal.shared.runTest() }
        }
    }

    private func dockMinY() -> CGFloat {
        guard let list, let f = AX.frame(list) else { return -1 }
        return f.minY
    }

    private func runTest() async {
        guard computeTarget(), let list, let f = AX.frame(list) else { Diag.log("revealTest: no dock"); return }
        let s = NSScreen.screens.first!.frame
        let bottom = s.height - 1
        let midX = f.midX
        let cases: [(String, CGEventType, CGPoint)] = [
            ("moved edge-left", .mouseMoved, CGPoint(x: revealPoint.x, y: bottom)),
            ("moved edge-under-dock", .mouseMoved, CGPoint(x: midX, y: bottom)),
            ("moved inside-dock", .mouseMoved, CGPoint(x: midX, y: bottom - 30)),
            ("entered edge-under-dock", Self.mouseEnteredType, CGPoint(x: midX, y: bottom)),
        ]
        Diag.log("revealTest: start mouse=\(Self.mouseCG) dockMinY=\(f.minY) screenH=\(s.height)")
        for (name, type, p) in cases {
            // let it hide first
            post(Self.mouseExited, at: Self.mouseCG)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let before = dockMinY()
            var samples: [Int] = []
            for _ in 0..<20 {
                post(type, at: p)
                try? await Task.sleep(nanoseconds: 100_000_000)
                samples.append(Int(dockMinY()))
            }
            Diag.log("revealTest: \(name) at \(p): before=\(Int(before)) samples=\(samples)")
        }
        post(Self.mouseExited, at: Self.mouseCG)
        Diag.log("revealTest: done")
    }

    static let mouseEnteredType = CGEventType(rawValue: UInt32(NSEvent.EventType.mouseEntered.rawValue))!
}
#endif
