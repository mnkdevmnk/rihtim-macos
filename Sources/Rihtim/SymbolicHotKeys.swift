import Foundation
import CoreGraphics

/// Temporarily disables the system ⌘⇥ (a WindowServer "symbolic hotkey").
/// Same SkyLight call AltTab uses, looked up with dlsym at runtime; if it's not
/// there we do nothing. The setting is per login session, so worst case a
/// log out / log in brings ⌘⇥ back.
enum SymbolicHotKeys {
    private typealias SetEnabledFn = @convention(c) (UInt32, Bool) -> Int32

    private static let setEnabled: SetEnabledFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let sym = dlsym(handle, "CGSSetSymbolicHotKeyEnabled") else { return nil }
        return unsafeBitCast(sym, to: SetEnabledFn.self)
    }()

    private static let commandTab: UInt32 = 1
    private static let commandShiftTab: UInt32 = 2

    static var isAvailable: Bool { setEnabled != nil }

    static func setCommandTabEnabled(_ enabled: Bool) {
        guard let f = setEnabled else { return }
        _ = f(commandTab, enabled)
        _ = f(commandShiftTab, enabled)
    }

    // MARK: switching Spaces

    private typealias GetValueFn = @convention(c) (UInt32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias IsEnabledFn = @convention(c) (UInt32) -> Bool

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let getValue: GetValueFn? = {
        guard let h = skyLight, let sym = dlsym(h, "CGSGetSymbolicHotKeyValue") else { return nil }
        return unsafeBitCast(sym, to: GetValueFn.self)
    }()
    private static let isEnabledFn: IsEnabledFn? = {
        guard let h = skyLight, let sym = dlsym(h, "CGSIsSymbolicHotKeyEnabled") else { return nil }
        return unsafeBitCast(sym, to: IsEnabledFn.self)
    }()

    /// 79 = "Move left a space", 81 = "Move right a space" (Keyboard › Shortcuts › Mission Control).
    static let spaceLeft: UInt32 = 79
    static let spaceRight: UInt32 = 81

    /// Presses whatever key the system has bound to that hotkey. A window being dragged
    /// moves along with it. If the hotkey is disabled it's switched on briefly.
    static func post(_ hotKey: UInt32) {
        var ch: UInt16 = 0, code: UInt16 = 0
        var mods: UInt32 = 0
        var flags = CGEventFlags([.maskControl, .maskSecondaryFn])
        code = hotKey == spaceLeft ? 123 : 124
        if let g = getValue, g(hotKey, &ch, &code, &mods) == 0, code != 0xFFFF {
            flags = CGEventFlags(rawValue: UInt64(mods))
        }
        let wasEnabled = isEnabledFn?(hotKey) ?? true
        if !wasEnabled { _ = setEnabled?(hotKey, true) }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
        if !wasEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { _ = setEnabled?(hotKey, false) }
        }
    }
}
