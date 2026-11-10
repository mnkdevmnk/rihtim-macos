import AppKit
import IOKit
import SwiftUI
import SystemConfiguration
import UserNotifications

struct DeviceBattery: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case mac, airpods, headphones, mouse, keyboard, trackpad, other }

    let name: String
    let kind: Kind
    let percent: Int?
    let left: Int?
    let right: Int?
    let caseLevel: Int?
    let isCharging: Bool

    var id: String { name }

    var mainPercent: Int? {
        if let percent { return percent }
        if let m = [left, right].compactMap({ $0 }).min() { return m }
        return caseLevel
    }

    var symbol: String {
        switch kind {
        case .mac: return "laptopcomputer"
        case .airpods: return "airpodspro"
        case .headphones: return "headphones"
        case .mouse: return "magicmouse"
        case .keyboard: return "keyboard"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .other: return "battery.75percent"
        }
    }

    var detail: String {
        var parts: [String] = []
        if let left { parts.append(L("Left %@", Fmt.pct(left))) }
        if let right { parts.append(L("Right %@", Fmt.pct(right))) }
        if let caseLevel { parts.append(L("Case %@", Fmt.pct(caseLevel))) }
        return parts.joined(separator: "  ")
    }

    static func kind(name: String, hint: String) -> Kind {
        let n = name.lowercased(), h = hint.lowercased()
        if n.contains("airpods") { return .airpods }
        if h.contains("headphone") || h.contains("headset") || n.contains("beats") { return .headphones }
        if n.contains("trackpad") || h.contains("trackpad") { return .trackpad }
        if n.contains("mouse") || h.contains("mouse") { return .mouse }
        if n.contains("keyboard") || h.contains("keyboard") { return .keyboard }
        return .other
    }
}

enum BatteryReader {
    /// HID devices such as Magic Mouse / Keyboard / Trackpad. Read from IORegistry, no permission needed.
    static func hidDevices() -> [DeviceBattery] {
        var result: [DeviceBattery] = []
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        while true {
            let service = IOIteratorNext(iter)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            func prop(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let pct = prop("BatteryPercent") as? Int else { continue }
            let name = (prop("Product") as? String) ?? L("Device")
            let flags = prop("BatteryStatusFlags") as? Int ?? 0
            result.append(DeviceBattery(name: name, kind: DeviceBattery.kind(name: name, hint: ""),
                                        percent: pct, left: nil, right: nil, caseLevel: nil,
                                        isCharging: flags == 3))
        }
        return result
    }

    /// AirPods and other connected Bluetooth devices via system_profiler.
    /// Takes a second or two, so call it off the main thread.
    static func bluetoothProfiler() -> [DeviceBattery] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]],
              let connected = sections.first?["device_connected"] as? [[String: Any]] else { return [] }

        var result: [DeviceBattery] = []
        for entry in connected {
            for (name, value) in entry {
                guard let props = value as? [String: Any] else { continue }
                func pct(_ key: String) -> Int? {
                    guard let s = props[key] as? String else { return nil }
                    return Int(s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
                }
                let l = pct("device_batteryLevelLeft")
                let r = pct("device_batteryLevelRight")
                let c = pct("device_batteryLevelCase")
                let m = pct("device_batteryLevelMain")
                guard l != nil || r != nil || c != nil || m != nil else { continue }
                let hint = props["device_minorType"] as? String ?? ""
                result.append(DeviceBattery(name: name, kind: DeviceBattery.kind(name: name, hint: hint),
                                            percent: m, left: l, right: r, caseLevel: c, isCharging: false))
            }
        }
        return result
    }

    static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }
}

@MainActor
final class BatteryMonitor: ObservableObject {
    /// Visible devices: hidden ones filtered out, the pinned one first.
    @Published private(set) var devices: [DeviceBattery] = []
    /// Everything we found, for Settings.
    @Published private(set) var allDevices: [DeviceBattery] = []

    var hiddenNames: Set<String> = [] { didSet { publish() } }
    var pinnedName: String? { didSet { publish() } }
    var alertsEnabled = false { didSet { if alertsEnabled && !oldValue { requestNotifications() } } }
    var alertLevel = 20
    private var alerted: Set<String> = []

    private var hid: [DeviceBattery] = []
    private var bluetooth: [DeviceBattery] = []
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var profilerRunning = false
    private let macName = BatteryReader.computerName()

    func start() {
        guard fastTimer == nil else { return }
        refreshFast()
        refreshBluetooth()
        fastTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFast() }
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBluetooth() }
        }
    }

    func refreshNow() {
        refreshFast()
        refreshBluetooth()
    }

    private func refreshFast() {
        hid = BatteryReader.hidDevices()
        merge()
    }

    private func refreshBluetooth() {
        guard !profilerRunning else { return }
        profilerRunning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = BatteryReader.bluetoothProfiler()
            guard let self else { return }
            Task { @MainActor in
                self.bluetooth = list
                self.profilerRunning = false
                self.merge()
            }
        }
    }

    private func merge() {
        var list: [DeviceBattery] = []
        if let p = SystemStats.macPower() {
            list.append(DeviceBattery(name: macName, kind: .mac, percent: p.percent,
                                      left: nil, right: nil, caseLevel: nil, isCharging: p.isCharging))
        }
        for d in bluetooth {
            list.append(hid.first(where: { $0.name == d.name }) ?? d)   // HID value is fresher
        }
        for d in hid where !list.contains(where: { $0.name == d.name }) {
            list.append(d)
        }
        if list != allDevices { allDevices = list }
        publish()
        checkAlerts(list)
    }

    private func publish() {
        var list = allDevices.filter { !hiddenNames.contains($0.name) }
        if let pinnedName, let i = list.firstIndex(where: { $0.name == pinnedName }) {
            list.insert(list.remove(at: i), at: 0)
        }
        if list != devices { devices = list }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func checkAlerts(_ list: [DeviceBattery]) {
        guard alertsEnabled else { return }
        for d in list {
            guard let p = d.mainPercent else { continue }
            if p <= alertLevel && !d.isCharging {
                guard !alerted.contains(d.name) else { continue }
                alerted.insert(d.name)
                let c = UNMutableNotificationContent()
                c.title = L("%@ battery is low", d.name)
                c.body = L("%@ left. Time to plug it in.", Fmt.pct(p))
                c.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "battery-\(d.name)", content: c, trigger: nil))
            } else if p > alertLevel + 5 || d.isCharging {
                alerted.remove(d.name)
            }
        }
    }
}

// MARK: - Views

struct BatteryPill: View {
    let devices: [DeviceBattery]
    let height: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            ForEach(devices.prefix(4)) { d in
                VStack(spacing: 5) {
                    HStack(spacing: 3) {
                        Image(systemName: d.symbol).font(.system(size: 11))
                        Text(d.mainPercent.map { Fmt.pct($0) } ?? "–")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        if d.isCharging {
                            Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundColor(.green)
                        }
                    }
                    LevelBar(value: Double(d.mainPercent ?? 0) / 100).frame(width: 50, height: 4)
                }
                .frame(width: 56)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .modifier(PanelBackground(radius: height * 0.32))
    }
}

struct BatteryPopover: View {
    @ObservedObject var batteries: BatteryMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(batteries.devices) { d in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: d.symbol).font(.system(size: 20)).frame(width: 28)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(d.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Spacer()
                            if d.isCharging {
                                Image(systemName: "bolt.fill").foregroundColor(.green)
                            }
                            Text(d.mainPercent.map { Fmt.pct($0) } ?? "–")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                        }
                        LevelBar(value: Double(d.mainPercent ?? 0) / 100).frame(height: 5)
                        if !d.detail.isEmpty {
                            Text(d.detail).font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
                        }
                    }
                }
            }
            if batteries.devices.isEmpty {
                Text(L("No devices reporting battery levels")).foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(PanelBackground(radius: 18))
    }
}
