import AppKit
import CoreAudio

/// Grabs the volume and brightness keys before the system does (CGEventTap), applies them
/// itself and draws the HUD in the notch, so the macOS overlay never shows up.
/// ⌥ + brightness keys drive the keyboard backlight instead. Step per press comes from
/// Settings (`Prefs.stepVolume` / `stepBrightness` / `stepKeyboard`, in percent); ⇧ makes it a quarter.
/// Anything we can't handle (say an HDMI output without volume control) is passed through.
enum HUDKind { case volume, brightness, keyboard }

enum SystemAudio {
    private static func addr(_ sel: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
    }

    static func defaultOutput() -> AudioDeviceID? {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    /// Is volume on the main element, or on the left/right channels?
    private static func volumeElements(_ dev: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var main = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(dev, &main), AudioObjectIsPropertySettable(dev, &main, &settable) == noErr, settable.boolValue {
            return [kAudioObjectPropertyElementMain]
        }
        return [1, 2].filter { ch in
            var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, ch)
            var s: DarwinBoolean = false
            return AudioObjectHasProperty(dev, &a) && AudioObjectIsPropertySettable(dev, &a, &s) == noErr && s.boolValue
        }
    }

    /// The "virtual main volume" ('vmvc') the macOS volume HUD uses. On some devices
    /// (MacBook speakers, for one) the channel volumes stay pinned at 100% and the real level lives here.
    private static let virtualMain = AudioObjectPropertySelector(0x766d_7663)

    private static func hasVirtualMain(_ dev: AudioDeviceID) -> Bool {
        var a = addr(virtualMain, kAudioDevicePropertyScopeOutput)
        var s: DarwinBoolean = false
        return AudioObjectHasProperty(dev, &a) && AudioObjectIsPropertySettable(dev, &a, &s) == noErr && s.boolValue
    }

    static func volume(_ dev: AudioDeviceID) -> Float? {
        if hasVirtualMain(dev) {
            var a = addr(virtualMain, kAudioDevicePropertyScopeOutput)
            var v = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr { return v }
        }
        let els = volumeElements(dev)
        guard !els.isEmpty else { return nil }
        let vals: [Float] = els.compactMap { el in
            var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el)
            var v = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
        }
        return vals.isEmpty ? nil : vals.reduce(0, +) / Float(vals.count)
    }

    @discardableResult
    static func setVolume(_ dev: AudioDeviceID, _ value: Float) -> Bool {
        var v = Float32(min(max(value, 0), 1))
        if hasVirtualMain(dev) {
            var a = addr(virtualMain, kAudioDevicePropertyScopeOutput)
            if AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr { return true }
        }
        var ok = false
        for el in volumeElements(dev) {
            var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el)
            ok = AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr || ok
        }
        return ok
    }

    static func isMuted(_ dev: AudioDeviceID) -> Bool {
        var a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var v = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(dev, &a), AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr else { return false }
        return v != 0
    }

    @discardableResult
    static func setMuted(_ dev: AudioDeviceID, _ on: Bool) -> Bool {
        var a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var v = UInt32(on ? 1 : 0)
        guard AudioObjectHasProperty(dev, &a) else { return false }
        return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }

    static func name(_ dev: AudioDeviceID) -> String {
        var a = addr(kAudioObjectPropertyName)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let r = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(dev, &a, 0, nil, &size, $0) }
        guard r == noErr, let ref else { return L("Sound") }
        return ref.takeRetainedValue() as String
    }
}

@MainActor
final class MediaKeyController {
    var isEnabled = false { didSet { if oldValue != isEnabled { updateTap() } } }
    /// Draw the HUD: kind, level (above 1 means extra brightness), label, muted.
    var onHUD: (@MainActor (HUDKind, Double, String, Bool) -> Void)?

    private let brightness: BrightnessBoost
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var layer = ""

    init(brightness: BrightnessBoost) { self.brightness = brightness }

    private func updateTap() {
        if isEnabled, tap == nil {
            let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED (media keys)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            // macOS handles the key-down of the volume keys before the session layer,
            // so tap at the HID layer first and fall back to the session layer.
            var made = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: mediaKeyCallback, userInfo: refcon)
            layer = "hid"
            if made == nil {
                made = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: mediaKeyCallback, userInfo: refcon)
                layer = "session"
            }
            guard let t = made else {
                Diag.log("couldn't install media key tap (Accessibility permission?)")
                return
            }
            tap = t
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
        } else if !isEnabled, let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            tap = nil
            source = nil
        }
        brightness.legacyMediaKeys = (tap == nil)
        Diag.log("media: wanted=\(isEnabled) tap=\(tap != nil) layer=\(layer)")
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// true = event swallowed, the system never sees it.
    fileprivate func handle(code: Int, down: Bool, flags: NSEvent.ModifierFlags) -> Bool {
        switch code {
        case 0, 1, 7:   // volume up, volume down, mute
            guard let dev = SystemAudio.defaultOutput(), SystemAudio.volume(dev) != nil || code == 7 else { return false }
            let fine = flags.contains(.option) && flags.contains(.shift)
            if down { volumeKey(dev: dev, code: code, step: Self.step(Prefs.stepVolume, fine: fine)) }
            return true
        case 2, 3:      // brightness up, brightness down
            let fine = flags.contains(.shift)
            if flags.contains(.option), KeyboardBacklight.isAvailable {
                if down { keyboardKey(up: code == 2, step: Self.step(Prefs.stepKeyboard, fine: fine)) }
                return true
            }
            guard BrightnessBoost.canControlBrightness else { return false }
            if down { brightnessKey(up: code == 2, command: flags.contains(.command),
                                    step: Self.step(Prefs.stepBrightness, fine: fine)) }
            return true
        default:
            return false
        }
    }

    /// Percent from Settings → fraction; fine = a quarter of it.
    private static func step(_ key: String, fine: Bool) -> Float {
        let pct = UserDefaults.standard.double(forKey: key)
        let s = Float(min(max(pct > 0 ? pct : 6.25, 0.5), 50) / 100)
        return fine ? s / 4 : s
    }

    /// Snap to the step grid, then move one step (so 6.25% steps land on 0, 6.25, 12.5 … 100).
    private static func stepped(_ v: Float, _ step: Float, up: Bool) -> Float {
        let base = (v / step).rounded() * step
        return min(1, max(0, base + (up ? step : -step)))
    }

    private func volumeKey(dev: AudioDeviceID, code: Int, step: Float) {
        var muted = SystemAudio.isMuted(dev)
        var v = SystemAudio.volume(dev) ?? 0
        switch code {
        case 7:
            muted.toggle()
            SystemAudio.setMuted(dev, muted)
        case 0:
            if muted { muted = false; SystemAudio.setMuted(dev, false) }
            v = Self.stepped(v, step, up: true)
            SystemAudio.setVolume(dev, v)
        default:
            v = Self.stepped(v, step, up: false)
            SystemAudio.setVolume(dev, v)
            if v == 0 { muted = true; SystemAudio.setMuted(dev, true) }
        }
        onHUD?(.volume, Double(muted ? 0 : v), SystemAudio.name(dev), muted)
    }

    private func keyboardKey(up: Bool, step: Float) {
        let cur = KeyboardBacklight.level() ?? 0
        KeyboardBacklight.setLevel(Self.stepped(cur, step, up: up))
        onHUD?(.keyboard, Double(KeyboardBacklight.level() ?? cur), "", false)
    }

    private func brightnessKey(up: Bool, command: Bool, step: Float) {
        let cur = BrightnessBoost.systemBrightness() ?? 1
        var hint = ""
        if up {
            if brightness.isActive {
                brightness.adjustExtra(by: Double(step))
            } else if cur >= 0.985 {
                if command, BrightnessBoost.isSupported {
                    brightness.beginExtra(step: Double(step))
                } else if BrightnessBoost.isSupported {
                    hint = L("⌘ for extra")
                }
            } else {
                BrightnessBoost.setSystemBrightness(Self.stepped(cur, step, up: true))
            }
        } else {
            if brightness.isActive {
                brightness.adjustExtra(by: -Double(step))   // turns itself off at 100%
            } else {
                BrightnessBoost.setSystemBrightness(Self.stepped(cur, step, up: false))
            }
        }
        let level = brightness.isActive ? brightness.factor : Double(BrightnessBoost.systemBrightness() ?? cur)
        onHUD?(.brightness, level, hint, false)
    }
}

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<MediaKeyController>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { me.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let code = (ns.data1 & 0xFFFF_0000) >> 16
    let state = (ns.data1 & 0x0000_FF00) >> 8
    guard [0, 1, 2, 3, 7].contains(code), state == 0x0A || state == 0x0B else { return Unmanaged.passUnretained(event) }
    let flags = ns.modifierFlags
    let swallowed = MainActor.assumeIsolated { me.handle(code: code, down: state == 0x0A, flags: flags) }
    Diag.log("media key: code=\(code) state=\(String(state, radix: 16)) swallowed=\(swallowed)")
    return swallowed ? nil : Unmanaged.passUnretained(event)
}
