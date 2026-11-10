import AppKit
import Metal
import MetalKit

/// Extra brightness, the same trick Sapphire and BrightIntosh use:
/// 1. Draw a single EDR (HDR) pixel in a corner of the screen. That puts the display
///    into EDR mode, so the backlight is allowed past the SDR limit.
/// 2. Scale the display's gamma table by `factor` so regular SDR content uses that headroom.
///
/// There is deliberately no full-screen overlay. The scale never exceeds the EDR headroom
/// the display currently offers (whites blow out otherwise). macOS restores gamma itself
/// when we quit or crash. Panic switch: ⌃⌥⌘B or Esc three times.
@MainActor
final class BrightnessBoost: NSObject, ObservableObject, MTKViewDelegate {
    @Published private(set) var isActive = false
    /// 1.0 = normal, 2.0 = twice as bright.
    @Published var factor: Double = 1.4 {
        didSet {
            // Assigning inside didSet re-triggers didSet on @Published even with the same
            // value, so only clamp when it's actually out of range.
            let clamped = min(max(factor, 1.05), Self.maxFactor)
            if clamped != factor { factor = clamped; return }
            UserDefaults.standard.set(factor, forKey: "brightness.factor")
            if isActive { apply() }
        }
    }
    /// Level changed (drives the notch HUD).
    var onLevelChange: (@MainActor (Double, Bool) -> Void)?
    /// Off when MediaKeyController is already handling the media keys.
    var legacyMediaKeys = true

    private var triggers: [NSWindow] = []
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private var timer: Timer?
    private var monitors: [Any] = []
    private var escTimes: [Date] = []

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: ["brightness.factor": 1.4])
        let saved = UserDefaults.standard.double(forKey: "brightness.factor")
        factor = min(max(saved, 1.05), Self.maxFactor)
    }

    static var maxFactor: Double {
        max(1.05, Double(NSScreen.screens.map(\.maximumPotentialExtendedDynamicRangeColorComponentValue).max() ?? 1))
    }
    static var isSupported: Bool { maxFactor > 1.1 && MTLCreateSystemDefaultDevice() != nil }

    /// Start listening for ⌘ + brightness keys and the panic shortcut.
    func installKeys() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.systemDefined, .keyDown], handler: handler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.systemDefined, .keyDown], handler: { e in handler(e); return e }) {
            monitors.append(m)
        }
    }

    private func handle(_ e: NSEvent) {
        if e.type == .keyDown {
            let mods = e.modifierFlags.intersection([.control, .option, .command, .shift])
            if mods == [.control, .option, .command] && e.keyCode == 11 { stop(); return }   // ⌃⌥⌘B
            if e.keyCode == 53 && isActive {                                                    // Esc ×3
                let now = Date()
                escTimes = escTimes.filter { now.timeIntervalSince($0) < 1.5 } + [now]
                if escTimes.count >= 3 { escTimes = []; stop() }
            }
            return
        }
        // Media keys: NX_SYSDEFINED, subtype 8. 2 = brightness up, 3 = brightness down
        guard legacyMediaKeys, e.type == .systemDefined, e.subtype.rawValue == 8 else { return }
        let code = (e.data1 & 0xFFFF0000) >> 16
        let down = ((e.data1 & 0x0000FF00) >> 8) == 0x0A
        guard down, code == 2 || code == 3, e.modifierFlags.contains(.command), Self.isSupported else { return }
        step(up: code == 2)
    }

    /// Regular display brightness (0…1) from the private DisplayServices framework, nil if unavailable.
    static func systemBrightness() -> Float? {
        guard let get = displayServicesGet else { return nil }
        let id = NSScreen.screens.first { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.1 }
            .flatMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID } ?? CGMainDisplayID()
        var v: Float = -1
        guard get(id, &v) == 0, v >= 0 else { return nil }
        return v
    }

    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private static let displayServicesGet: GetBrightness? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: GetBrightness.self)
    }()

    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private static let displayServicesSet: SetBrightness? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let sym = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(sym, to: SetBrightness.self)
    }()

    static var canControlBrightness: Bool { displayServicesGet != nil && displayServicesSet != nil && systemBrightness() != nil }

    @discardableResult
    static func setSystemBrightness(_ v: Float) -> Bool {
        guard let set = displayServicesSet else { return false }
        let id = NSScreen.screens.first { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.1 }
            .flatMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID } ?? CGMainDisplayID()
        return set(id, min(max(v, 0), 1)) == 0
    }

    /// Switch into extra brightness (regular brightness should already be at max).
    func beginExtra(step: Double) {
        guard Self.isSupported else { return }
        factor = 1 + step
        start()
    }

    /// Step while boosted; turns off once it's back at 100%. Returns the new level (1 = normal).
    @discardableResult
    func adjustExtra(by delta: Double) -> Double {
        guard isActive else { return 1 }
        let next = factor + delta
        if next <= 1.001 { stop(); return 1 }
        factor = min(next, Self.maxFactor)
        return factor
    }

    /// Is regular brightness at max? If we can't read it, don't block.
    static var isAtFullBrightness: Bool { (systemBrightness() ?? 1) >= 0.985 }

    /// ⌘ + brightness: once regular brightness is at 100% this goes into extra in 5% steps;
    /// stepping down turns it off at 100%. Below max the key behaves as usual.
    func step(up: Bool) {
        if up {
            if !isActive {
                guard Self.isAtFullBrightness else { return }
                factor = 1.05
                start()
            } else {
                factor = min(Self.maxFactor, factor + 0.05)
            }
        } else {
            guard isActive else { return }
            if factor <= 1.06 { stop(); return }
            factor -= 0.05
        }
        onLevelChange?(factor, isActive)
    }

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard !isActive, Self.isSupported else { return }
        isActive = true
        buildTriggers()
        apply()
        // EDR headroom opens up over a few hundred ms, keep refreshing gamma to follow it.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        onLevelChange?(factor, true)
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        CGDisplayRestoreColorSyncSettings()
        triggers.forEach { $0.orderOut(nil) }
        triggers = []
        onLevelChange?(1, false)
    }

    /// Must be called on quit.
    func shutdown() {
        if isActive { CGDisplayRestoreColorSyncSettings() }
    }

    private func edrScreens() -> [NSScreen] {
        NSScreen.screens.filter { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.1 }
    }

    private func apply() {
        guard isActive else { return }
        // User turned regular brightness down: leave extra mode.
        if let b = Self.systemBrightness(), b < 0.95 { stop(); return }
        for screen in edrScreens() {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            // Cap at the headroom available right now, more than that blows out whites.
            let headroom = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
            let f = Float(min(factor, max(headroom, 1)))
            CGSetDisplayTransferByFormula(id, 0, f, 1, 0, f, 1, 0, f, 1)
        }
    }

    /// A 1×1 pt EDR dot in the bottom-left corner of every EDR display.
    private func buildTriggers() {
        triggers.forEach { $0.orderOut(nil) }
        triggers = []
        guard let device else { return }
        for screen in edrScreens() {
            let rect = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: 1, height: 1)
            let w = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let v = MTKView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), device: device)
            v.colorPixelFormat = .rgba16Float
            v.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            (v.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
            v.isPaused = true
            v.enableSetNeedsDisplay = true
            v.delegate = self
            w.contentView = v
            w.setFrame(rect, display: false)
            w.orderFrontRegardless()
            triggers.append(w)
            v.setNeedsDisplay(v.bounds)
        }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            let m = Self.maxFactor
            view.clearColor = MTLClearColor(red: m, green: m, blue: m, alpha: 1)
            guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let cmd = queue?.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }
    }
}
