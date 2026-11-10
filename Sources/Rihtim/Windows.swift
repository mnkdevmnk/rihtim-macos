import AppKit
import ApplicationServices
import ScreenCaptureKit

struct WindowInfo: Identifiable {
    let id = UUID()
    let windowID: CGWindowID
    let element: AXUIElement
    let pid: pid_t
    let title: String
    let appName: String
    let appIcon: NSImage?
    let isMinimized: Bool
    var isOnOtherSpace = false
}

/// Windows on other Spaces don't show up in `kAXWindowsAttribute`.
/// AltTab's approach: find the missing window IDs in CGWindowList, then build the app's
/// AX elements one by one from a "remote token" until one matches the ID.
@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

enum WindowEnumerator {
    /// Can be turned off in Settings.
    nonisolated(unsafe) static var includeOtherSpaces = true
    /// pid -> (windowID -> AX element) cache, since the brute force is expensive.
    nonisolated(unsafe) private static var remoteCache: [pid_t: [CGWindowID: AXUIElement]] = [:]

    static func windows(for app: NSRunningApplication) -> [WindowInfo] {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        let list = AX.elements(axApp, kAXWindowsAttribute) ?? []
        let appName = app.localizedName ?? ""
        let icon = app.icon

        func info(_ w: AXUIElement, otherSpace: Bool) -> WindowInfo? {
            let subrole = AX.string(w, kAXSubroleAttribute)
            guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { return nil }
            if let s = AX.size(w, kAXSizeAttribute), s.width < 60 || s.height < 40 { return nil }
            let title = AX.string(w, kAXTitleAttribute) ?? ""
            return WindowInfo(windowID: AX.windowID(w), element: w, pid: pid,
                              title: title.isEmpty ? appName : title,
                              appName: appName, appIcon: icon,
                              isMinimized: AX.bool(w, kAXMinimizedAttribute) ?? false,
                              isOnOtherSpace: otherSpace)
        }

        var result = list.compactMap { info($0, otherSpace: false) }
        guard includeOtherSpaces, !app.isHidden else { return result }

        let known = Set(result.map(\.windowID))
        let missing = Set(cgWindowIDs(pid: pid)).subtracting(known)
        guard !missing.isEmpty else { return result }
        for (id, el) in remoteElements(pid: pid, wanted: missing) {
            if var w = info(el, otherSpace: true), w.windowID == id, !w.isMinimized {
                w.isOnOtherSpace = true
                result.append(w)
            }
        }
        return result
    }

    /// The app's normal (layer 0) window IDs across all Spaces.
    private static func cgWindowIDs(pid: pid_t) -> [CGWindowID] {
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return info.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  (b["Width"] as? Double ?? 0) >= 60, (b["Height"] as? Double ?? 0) >= 40,
                  let num = w[kCGWindowNumber as String] as? Int else { return nil }
            return CGWindowID(num)
        }
    }

    private static func remoteElements(pid: pid_t, wanted: Set<CGWindowID>) -> [CGWindowID: AXUIElement] {
        var cache = remoteCache[pid] ?? [:]
        var found = cache.filter { wanted.contains($0.key) }
        guard found.count < wanted.count else { return found }

        var token = Data(count: 20)
        token.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: pid, toByteOffset: 0, as: pid_t.self)
            raw.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: Int32(0x636f_636f), toByteOffset: 8, as: Int32.self)   // "coco"
        }
        let deadline = Date().addingTimeInterval(0.12)
        for elementID: UInt64 in 0..<1000 {
            if Date() > deadline { break }
            token.withUnsafeMutableBytes { $0.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self) }
            guard let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(el, 0.05)
            // Other elements can report the same window ID (Safari has one right after its
            // window); keep only the AXWindow, or it overwrites the real one and gets dropped.
            let id = AX.windowID(el)
            guard id != 0, AX.string(el, kAXRoleAttribute) == kAXWindowRole as String else { continue }
            cache[id] = el
            if wanted.contains(id) {
                found[id] = el
                if found.count == wanted.count { break }
            }
        }
        remoteCache[pid] = cache
        return found
    }

    /// One app's windows, front to back; other-Space and minimized ones last.
    static func sortedWindows(for app: NSRunningApplication) -> [WindowInfo] {
        sort(windows(for: app))
    }

    /// Windows of all regular apps, front to back.
    static func allWindows() -> [WindowInfo] {
        let me = getpid()
        var result: [WindowInfo] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != me && !app.isTerminated {
            result += windows(for: app)
        }
        return sort(result)
    }

    private static func sort(_ list: [WindowInfo]) -> [WindowInfo] {
        let order = zOrder()
        func key(_ w: WindowInfo, _ i: Int) -> (Int, Int, Int) {
            (w.isMinimized ? 2 : (w.isOnOtherSpace ? 1 : 0), order[w.windowID] ?? Int.max, i)
        }
        return list.enumerated().sorted { key($0.element, $0.offset) < key($1.element, $1.offset) }.map(\.element)
    }

    static func zOrder() -> [CGWindowID: Int] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var map: [CGWindowID: Int] = [:]
        for (i, w) in info.enumerated() {
            guard let num = w[kCGWindowNumber as String] as? Int,
                  (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
            map[CGWindowID(num)] = i
        }
        return map
    }
}

/// SkyLight calls (same as AltTab) to bring a window forward, even on another Space.
/// Looked up with dlsym; without them we fall back to plain AX focusing.
private enum SkyLightFocus {
    typealias GetPSN = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
    typealias PostEvent = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32

    static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static let getPSN: GetPSN? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID").map { unsafeBitCast($0, to: GetPSN.self) }
    static let setFront: SetFront? = sky.flatMap { dlsym($0, "_SLPSSetFrontProcessWithOptions") }.map { unsafeBitCast($0, to: SetFront.self) }
    static let post: PostEvent? = sky.flatMap { dlsym($0, "SLPSPostEventRecordTo") }.map { unsafeBitCast($0, to: PostEvent.self) }

    @discardableResult
    static func focus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard windowID != 0, let getPSN, let setFront, let post else { return false }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else { return false }
        guard setFront(&psn, windowID, 0x200) == 0 else { return false }   // kCPSUserGenerated
        var wid = windowID
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: &wid) { src in for i in 0..<4 { bytes[0x3c + i] = src[i] } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = post(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = post(&psn, &bytes)
        return true
    }
}

enum WindowActions {
    static func focus(_ w: WindowInfo) {
        if w.isMinimized { AX.set(w.element, kAXMinimizedAttribute, kCFBooleanFalse) }
        if SkyLightFocus.focus(pid: w.pid, windowID: w.windowID) {
            AX.perform(w.element, kAXRaiseAction)
            return
        }
        let axApp = AXUIElementCreateApplication(w.pid)
        AX.set(axApp, kAXFrontmostAttribute, kCFBooleanTrue)
        AX.perform(w.element, kAXRaiseAction)
        AX.set(w.element, kAXMainAttribute, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: w.pid)?.activate(options: [])
    }

    static func close(_ w: WindowInfo) {
        if let button = AX.element(w.element, kAXCloseButtonAttribute) {
            AX.perform(button, kAXPressAction)
        }
    }

    static func minimize(_ w: WindowInfo) {
        AX.set(w.element, kAXMinimizedAttribute, kCFBooleanTrue)
    }
}

@MainActor
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private var content: SCShareableContent?
    private var contentStamp = Date.distantPast
    private var cache: [CGWindowID: (image: NSImage, stamp: Date)] = [:]

    func thumbnail(windowID: CGWindowID, maxSize: CGSize) async -> NSImage? {
        guard windowID != 0, Permissions.hasScreenRecording else { return nil }
        if let hit = cache[windowID], Date().timeIntervalSince(hit.stamp) < 0.75 { return hit.image }

        if content == nil || Date().timeIntervalSince(contentStamp) > 1.5 {
            content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            contentStamp = Date()
        }
        guard let scWindow = content?.windows.first(where: { $0.windowID == windowID }) else {
            return cache[windowID]?.image
        }

        let f = scWindow.frame
        guard f.width > 1, f.height > 1 else { return cache[windowID]?.image }
        let ratio = min(maxSize.width / f.width, maxSize.height / f.height, 1)
        let scale = NSScreen.main?.backingScaleFactor ?? 2

        let config = SCStreamConfiguration()
        config.width = max(2, Int(f.width * ratio * scale))
        config.height = max(2, Int(f.height * ratio * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
            // minimized windows can't be captured, reuse the last image we got
            return cache[windowID]?.image
        }
        let image = NSImage(cgImage: cg, size: NSSize(width: f.width * ratio, height: f.height * ratio))
        cache[windowID] = (image, Date())
        return image
    }
}
