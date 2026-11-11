import Foundation
import ObjectiveC

/// Keyboard backlight through CoreBrightness's private `KeyboardBrightnessClient`
/// (what Control Center uses). There's no public API for this on Apple Silicon.
/// Every call goes through the class's IMP so a missing selector just means "not available".
@MainActor
enum KeyboardBacklight {
    private static let client: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    private static func imp(_ name: String) -> (NSObject, Selector, IMP)? {
        guard let c = client else { return nil }
        let sel = NSSelectorFromString(name)
        guard c.responds(to: sel), let m = class_getMethodImplementation(type(of: c), sel) else { return nil }
        return (c, sel, m)
    }

    /// The built-in keyboard first, otherwise whatever backlit keyboard is there.
    private static var keyboardID: UInt64? {
        guard let c = client, c.responds(to: NSSelectorFromString("copyKeyboardBacklightIDs")),
              let ids = c.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber],
              !ids.isEmpty else { return nil }
        let all = ids.map(\.uint64Value)
        if let (o, s, m) = imp("isKeyboardBuiltIn:") {
            typealias F = @convention(c) (AnyObject, Selector, UInt64) -> Bool
            let f = unsafeBitCast(m, to: F.self)
            if let builtIn = all.first(where: { f(o, s, $0) }) { return builtIn }
        }
        return all.first
    }

    static var isAvailable: Bool { keyboardID != nil && imp("setBrightness:forKeyboard:") != nil }

    static func level() -> Float? {
        guard let id = keyboardID, let (o, s, m) = imp("brightnessForKeyboard:") else { return nil }
        typealias F = @convention(c) (AnyObject, Selector, UInt64) -> Float
        return unsafeBitCast(m, to: F.self)(o, s, id)
    }

    @discardableResult
    static func setLevel(_ value: Float) -> Bool {
        guard let id = keyboardID else { return false }
        let v = min(max(value, 0), 1)
        // Pressing the key means "manual": auto-brightness would undo it a moment later.
        if let (o, s, m) = imp("enableAutoBrightness:forKeyboard:") {
            typealias F = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool
            _ = unsafeBitCast(m, to: F.self)(o, s, false, id)
        }
        // fadeSpeed in ms, commit = remember it like the system slider does.
        if let (o, s, m) = imp("setBrightness:fadeSpeed:commit:forKeyboard:") {
            typealias F = @convention(c) (AnyObject, Selector, Float, Int32, Bool, UInt64) -> Bool
            if unsafeBitCast(m, to: F.self)(o, s, v, 120, true, id) { return true }
        }
        guard let (o, s, m) = imp("setBrightness:forKeyboard:") else { return false }
        typealias F = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        return unsafeBitCast(m, to: F.self)(o, s, v, id)
    }
}
