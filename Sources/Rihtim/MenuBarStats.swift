import AppKit
import Combine
import SwiftUI
import UserNotifications

// MARK: - Modules

enum MenuModule: String, CaseIterable, Identifiable, Codable {
    case cpu, gpu, ram, disk, sensors, network, battery, bluetooth, clock
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ram: return "RAM"
        case .disk: return "Disk"
        case .sensors: return L("Sensors")
        case .network: return L("Network")
        case .battery: return L("Battery")
        case .bluetooth: return "Bluetooth"
        case .clock: return L("Clock")
        }
    }
    /// Short name for the menu bar label.
    var short: String {
        switch self {
        case .sensors: return "SEN"
        case .network: return "NET"
        case .battery: return "BAT"
        case .bluetooth: return "BT"
        case .clock: return L("CLK")
        default: return title.uppercased(with: L10n.locale)
        }
    }
    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "display"
        case .ram: return "memorychip"
        case .disk: return "internaldrive"
        case .sensors: return "thermometer.medium"
        case .network: return "network"
        case .battery: return "battery.75percent"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .clock: return "clock"
        }
    }
    var accent: Color {
        switch self {
        case .cpu: return .green
        case .gpu: return .purple
        case .ram: return .blue
        case .disk: return .teal
        case .sensors: return .orange
        case .network: return .cyan
        case .battery: return .green
        case .bluetooth: return .indigo
        case .clock: return .primary
        }
    }

    var enabledKey: String { "menu." + rawValue }
    var defaultOn: Bool { [.cpu, .ram, .network].contains(self) }

    /// Menu bar widgets this module supports.
    var widgets: [WidgetKind] {
        switch self {
        case .cpu: return [.mini, .lineChart, .barChart, .pie, .tachometer, .text, .dot]
        case .gpu: return [.mini, .lineChart, .pie, .tachometer, .text, .dot]
        case .ram: return [.mini, .lineChart, .pie, .tachometer, .memory, .text, .dot]
        case .disk: return [.mini, .pie, .memory, .speed, .text, .dot]
        case .sensors: return [.mini, .text, .lineChart, .dot]
        case .network: return [.speed, .lineChart, .text, .dot]
        case .battery: return [.battery, .mini, .text, .pie]
        case .bluetooth: return [.text, .mini]
        case .clock: return [.text]
        }
    }
    var defaultWidgets: [WidgetKind] {
        switch self {
        case .cpu: return [.mini, .lineChart]
        case .network: return [.speed]
        case .battery: return [.battery]
        case .sensors, .bluetooth, .clock: return [.text]
        default: return [.mini]
        }
    }
    /// Does the alert fire when the value drops below the threshold (battery, free disk) or rises above it?
    var alertBelow: Bool { self == .battery || self == .bluetooth }
    var hasProcesses: Bool { self == .cpu || self == .ram }
}

enum WidgetKind: String, CaseIterable, Identifiable, Codable {
    case mini, lineChart, barChart, pie, tachometer, text, speed, memory, battery, dot
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mini: return "Mini"
        case .lineChart: return L("Line chart")
        case .barChart: return L("Bar chart")
        case .pie: return L("Pie")
        case .tachometer: return L("Tachometer")
        case .text: return L("Text")
        case .speed: return L("Speed (↑↓)")
        case .memory: return L("Memory (used/free)")
        case .battery: return L("Battery")
        case .dot: return L("Status dot")
        }
    }
}

enum ColorMode: String, CaseIterable, Identifiable, Codable {
    case usage, accent, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .usage: return L("By usage")
        case .accent: return L("Module color")
        case .mono: return L("Monochrome")
        }
    }
}

struct ModuleConfig: Codable, Equatable {
    var widgets: [WidgetKind]
    var combine = true
    var label = true
    var colorMode: ColorMode = .usage
    var interval: Double = 2
    var topCount = 8
    // popup sections
    var popupHistory = true
    var popupDetails = true
    var popupProcesses = true
    // alert
    var alertEnabled = false
    var alertThreshold: Double = 90
    /// Battery widget: draw the percentage inside the icon, like Stats does.
    var percentInside = true

    init(module: MenuModule) {
        widgets = module.defaultWidgets
        if module.alertBelow { alertThreshold = 20 }
        if module == .sensors { alertThreshold = 85 }
        if module == .disk { alertThreshold = 90 }
    }

    /// Fields that affect the menu bar look; the item is rebuilt when they change.
    var renderKey: String { "\(widgets.map(\.rawValue))\(combine)\(label)\(colorMode.rawValue)\(percentInside)" }

    // Missing keys fall back to defaults, so adding a field doesn't wipe saved configs.
    private enum CodingKeys: String, CodingKey {
        case widgets, combine, label, colorMode, interval, topCount, popupHistory, popupDetails, popupProcesses
        case alertEnabled, alertThreshold, percentInside
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        widgets = (try? c.decode([WidgetKind].self, forKey: .widgets)) ?? [.mini]
        combine = (try? c.decode(Bool.self, forKey: .combine)) ?? true
        label = (try? c.decode(Bool.self, forKey: .label)) ?? true
        colorMode = (try? c.decode(ColorMode.self, forKey: .colorMode)) ?? .usage
        interval = (try? c.decode(Double.self, forKey: .interval)) ?? 2
        topCount = (try? c.decode(Int.self, forKey: .topCount)) ?? 8
        popupHistory = (try? c.decode(Bool.self, forKey: .popupHistory)) ?? true
        popupDetails = (try? c.decode(Bool.self, forKey: .popupDetails)) ?? true
        popupProcesses = (try? c.decode(Bool.self, forKey: .popupProcesses)) ?? true
        alertEnabled = (try? c.decode(Bool.self, forKey: .alertEnabled)) ?? false
        alertThreshold = (try? c.decode(Double.self, forKey: .alertThreshold)) ?? 90
        percentInside = (try? c.decode(Bool.self, forKey: .percentInside)) ?? true
    }
}

/// Per-module settings, stored as JSON under "mb.cfg.<module>" in UserDefaults.
@MainActor
final class MenuConfigs: ObservableObject {
    static let shared = MenuConfigs()
    @Published private(set) var all: [MenuModule: ModuleConfig] = [:]

    private init() {
        for m in MenuModule.allCases {
            if let d = UserDefaults.standard.data(forKey: key(m)), let c = try? JSONDecoder().decode(ModuleConfig.self, from: d) {
                var c = c
                c.widgets = c.widgets.filter { m.widgets.contains($0) }
                if c.widgets.isEmpty { c.widgets = m.defaultWidgets }
                all[m] = c
            } else {
                all[m] = ModuleConfig(module: m)
            }
        }
    }

    private func key(_ m: MenuModule) -> String { "mb.cfg." + m.rawValue }

    subscript(m: MenuModule) -> ModuleConfig {
        get { all[m] ?? ModuleConfig(module: m) }
        set {
            var v = newValue
            if v.widgets.isEmpty { v.widgets = [m.widgets[0]] }
            all[m] = v
            if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: key(m)) }
            if v.alertEnabled { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        }
    }

    func binding(_ m: MenuModule) -> Binding<ModuleConfig> {
        Binding(get: { self[m] }, set: { self[m] = $0 })
    }
}

// MARK: - Data

@MainActor
final class MenuStats: ObservableObject {
    static let historyLength = 120

    @Published private(set) var cpuUser: Double = 0
    @Published private(set) var cpuSystem: Double = 0
    @Published private(set) var coreLoads: [Double] = []
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var gpu: Double?
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var ram = RAMBreakdown()
    @Published private(set) var ramHistory: [Double] = []
    @Published private(set) var pressure = 1
    @Published private(set) var swap: UInt64 = 0
    @Published private(set) var diskRead: Double = 0
    @Published private(set) var diskWrite: Double = 0
    @Published private(set) var readHistory: [Double] = []
    @Published private(set) var writeHistory: [Double] = []
    @Published private(set) var space: ExtraStats.DiskSpace?
    @Published private(set) var downHistory: [Double] = []
    @Published private(set) var upHistory: [Double] = []
    @Published private(set) var totalDown: UInt64 = 0
    @Published private(set) var totalUp: UInt64 = 0
    @Published private(set) var ip: (iface: String, ip: String)?
    @Published private(set) var battery: ExtraStats.BatteryDetail?
    @Published private(set) var sensors: [TempSensor] = []
    @Published private(set) var socTemp: Double?
    @Published private(set) var socHistory: [Double] = []
    @Published private(set) var load: [Double] = []
    @Published private(set) var startedAt = Date()

    let gpuName = ExtraStats.gpuName() ?? "GPU"
    let system: SystemMonitor
    let batteries: BatteryMonitor
    var interval: TimeInterval = 2 { didSet { if abs(oldValue - interval) > 0.01, timer != nil { restart() } } }

    private var timer: Timer?
    private var lastCores: [CoreTicks] = []
    private var lastIO: (read: UInt64, write: UInt64)?
    private var lastIOTime = Date()
    private var ticks = 0
    private var alerted: Set<MenuModule> = []

    init(system: SystemMonitor, batteries: BatteryMonitor) {
        self.system = system
        self.batteries = batteries
    }

    var cpuTotal: Double { min(100, cpuUser + cpuSystem) }
    var ramPercent: Double { Double(ram.used) / Double(max(ram.total, 1)) * 100 }
    var diskPercent: Double? { space.map { Double($0.total - $0.free) / Double(max($0.total, 1)) * 100 } }
    var batteryTemp: Double? { avg(sensors.filter { $0.group == L("Battery") }) }
    var ssdTemp: Double? { sensors.first { $0.group == "SSD" }?.value }
    private func avg(_ l: [TempSensor]) -> Double? { l.isEmpty ? nil : l.map(\.value).reduce(0, +) / Double(l.count) }

    func start() {
        guard timer == nil else { return }
        startedAt = Date()
        tick()
        restart()
    }

    private func restart() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func push(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > historyLength { a.removeFirst(a.count - historyLength) }
    }

    /// IOKit / HID reads (GPU, disk, sensors, battery) can take tens of ms, so they run in the background.
    private struct Snapshot: Sendable {
        var cores: [CoreTicks]
        var gpu: Double?
        var ram: RAMBreakdown
        var pressure: Int
        var io: (read: UInt64, write: UInt64)
        var sensors: [TempSensor]?
        var swap: UInt64?
        var space: ExtraStats.DiskSpace?
        var battery: ExtraStats.BatteryDetail?
        var load: [Double]?
        var ip: (iface: String, ip: String)??
    }

    private static let queue = DispatchQueue(label: "dev.minik.rihtim.stats", qos: .utility)
    private var busy = false

    private func tick() {
        guard !busy else { return }
        busy = true
        ticks += 1
        let n = ticks
        Self.queue.async { [weak self] in
            let slow = n % 5 == 1
            let snap = Snapshot(
                cores: CPUInfo.coreTicks(),
                gpu: ExtraStats.gpuUtilization(),
                ram: RAMBreakdown.read(),
                pressure: ExtraStats.memoryPressure(),
                io: ExtraStats.diskIO(),
                sensors: n % 2 == 1 ? HIDTemps.read() : nil,
                swap: slow ? ExtraStats.swapUsed() : nil,
                space: slow ? ExtraStats.diskSpace() : nil,
                battery: slow ? ExtraStats.battery() : nil,
                load: slow ? ExtraStats.loadAverage() : nil,
                ip: slow ? .some(ExtraStats.localIP()) : nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.busy = false
                    self?.apply(snap)
                }
            }
        }
    }

    private func apply(_ snap: Snapshot) {
        // CPU: per core, user / system
        let cores = snap.cores
        if cores.count == lastCores.count, !cores.isEmpty {
            var u: UInt64 = 0, s: UInt64 = 0, tot: UInt64 = 0
            var loads: [Double] = []
            for (n, o) in zip(cores, lastCores) {
                let du = n.user &- o.user, ds = n.system &- o.system, dn = n.nice &- o.nice
                let dt = n.total &- o.total
                u += du + dn; s += ds; tot += dt
                loads.append(dt > 0 ? Double(du + ds + dn) / Double(dt) * 100 : 0)
            }
            if tot > 0 {
                cpuUser = Double(u) / Double(tot) * 100
                cpuSystem = Double(s) / Double(tot) * 100
            }
            coreLoads = loads
            Self.push(&cpuHistory, cpuTotal)
        }
        lastCores = cores

        if let g = snap.gpu { gpu = g; Self.push(&gpuHistory, g) }

        ram = snap.ram
        Self.push(&ramHistory, ramPercent)
        if pressure != snap.pressure { pressure = snap.pressure }

        let now = Date()
        if let last = lastIO {
            let dt = max(now.timeIntervalSince(lastIOTime), 0.1)
            diskRead = Double(snap.io.read &- last.read) / dt
            diskWrite = Double(snap.io.write &- last.write) / dt
            Self.push(&readHistory, diskRead)
            Self.push(&writeHistory, diskWrite)
        }
        lastIO = snap.io
        lastIOTime = now

        Self.push(&downHistory, system.netDown)
        Self.push(&upHistory, system.netUp)
        totalDown += UInt64(max(0, system.netDown * interval))
        totalUp += UInt64(max(0, system.netUp * interval))

        if let list = snap.sensors {
            if list != sensors { sensors = list }
            socTemp = list.filter { $0.group.hasPrefix("SoC") }.map(\.value).max()
            if let t = socTemp { Self.push(&socHistory, t) }
        }
        if let v = snap.swap { swap = v }
        if let v = snap.space { space = v }
        if let v = snap.battery, v != battery { battery = v }
        if let v = snap.load { load = v }
        if let v = snap.ip, v?.ip != ip?.ip { ip = v }
        if snap.swap != nil { checkAlerts() }
    }

    // MARK: values (for widgets and colors)

    /// 0…1 fill, for colors and charts.
    func fraction(_ m: MenuModule) -> Double {
        switch m {
        case .cpu: return cpuTotal / 100
        case .gpu: return (gpu ?? 0) / 100
        case .ram: return ramPercent / 100
        case .disk: return (diskPercent ?? 0) / 100
        case .sensors: return min(1, max(0, ((socTemp ?? 30) - 30) / 70))
        case .network: return min(1, system.netDown / (10 * 1024 * 1024))
        case .battery: return Double(system.power?.percent ?? 0) / 100
        case .bluetooth: return Double(bluetoothDevices.compactMap(\.mainPercent).min() ?? 0) / 100
        case .clock: return 0
        }
    }

    var bluetoothDevices: [DeviceBattery] { batteries.devices.filter { $0.kind != .mac } }

    /// Main value for alerts and the settings page (percent or °C).
    func value(_ m: MenuModule) -> Double? {
        switch m {
        case .cpu: return cpuTotal
        case .gpu: return gpu
        case .ram: return ramPercent
        case .disk: return diskPercent
        case .sensors: return socTemp
        case .battery: return system.power.map { Double($0.percent) }
        case .bluetooth: return bluetoothDevices.compactMap(\.mainPercent).min().map(Double.init)
        case .network, .clock: return nil
        }
    }

    func history(_ m: MenuModule) -> [Double] {
        switch m {
        case .cpu: return cpuHistory
        case .gpu: return gpuHistory
        case .ram: return ramHistory
        case .disk: return readHistory.indices.map { readHistory[$0] + (writeHistory.indices.contains($0) ? writeHistory[$0] : 0) }
        case .sensors: return socHistory
        case .network: return downHistory
        default: return []
        }
    }

    private func checkAlerts() {
        let cfgs = MenuConfigs.shared
        for m in MenuModule.allCases {
            let c = cfgs[m]
            guard c.alertEnabled, UserDefaults.standard.bool(forKey: m.enabledKey), let v = value(m) else { alerted.remove(m); continue }
            let over = m.alertBelow ? v <= c.alertThreshold : v >= c.alertThreshold
            if over && !alerted.contains(m) {
                alerted.insert(m)
                let n = UNMutableNotificationContent()
                let unit = m == .sensors ? "°C" : "%"
                n.title = m.alertBelow ? L("%@ is low", m.title) : L("%@ is high", m.title)
                n.body = L("%@: %@ (threshold %@)", m.title, "\(Int(v.rounded()))\(unit)", "\(Int(c.alertThreshold))\(unit)")
                n.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "mb-\(m.rawValue)", content: n, trigger: nil))
            } else if !over {
                let back = m.alertBelow ? v > c.alertThreshold + 5 : v < c.alertThreshold - 5
                if back { alerted.remove(m) }
            }
        }
    }
}

// MARK: - Menu bar widgets

/// Hosting view that lets clicks fall through to the NSStatusBarButton underneath.
final class PassthroughHostingView<V: View>: NSHostingView<V> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct MiniChart: View {
    let values: [Double]
    var maxValue: Double? = 100
    var color: Color = .primary
    var fill = true

    var body: some View {
        GeometryReader { g in
            let maxV = max(maxValue ?? (values.max() ?? 1), 1)
            let step = values.count > 1 ? g.size.width / CGFloat(values.count - 1) : 0
            let pt: (Int, Double) -> CGPoint = { i, v in
                CGPoint(x: CGFloat(i) * step, y: g.size.height - CGFloat(min(max(v, 0), maxV) / maxV) * g.size.height)
            }
            ZStack {
                if fill {
                    Path { p in
                        guard values.count > 1 else { return }
                        p.move(to: CGPoint(x: 0, y: g.size.height))
                        for (i, v) in values.enumerated() { p.addLine(to: pt(i, v)) }
                        p.addLine(to: CGPoint(x: CGFloat(values.count - 1) * step, y: g.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.55), color.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                }
                Path { p in
                    guard values.count > 1 else { return }
                    for (i, v) in values.enumerated() { i == 0 ? p.move(to: pt(i, v)) : p.addLine(to: pt(i, v)) }
                }
                .stroke(color, lineWidth: 1)
            }
        }
    }
}

enum UsageColor {
    static func color(_ f: Double, inverse: Bool = false) -> Color {
        let v = inverse ? 1 - f : f
        switch v {
        case ..<0.5: return .green
        case ..<0.75: return .yellow
        case ..<0.9: return .orange
        default: return .red
        }
    }
}

/// Half-circle gauge (green → yellow → red) with a needle.
struct TachometerShape: View {
    let fraction: Double
    var lineWidth: CGFloat = 2.5

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let r = min(w / 2, h) - lineWidth / 2
            let c = CGPoint(x: w / 2, y: h - lineWidth / 2)
            ZStack {
                ForEach(0..<3) { i in
                    Path { p in
                        p.addArc(center: c, radius: r, startAngle: .degrees(180 + Double(i) * 60 + 2),
                                 endAngle: .degrees(180 + Double(i + 1) * 60 - 2), clockwise: false)
                    }
                    .stroke([Color.green, .yellow, .red][i], style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }
                Path { p in
                    let a = Angle.degrees(180 + 180 * min(max(fraction, 0), 1)).radians
                    p.move(to: c)
                    p.addLine(to: CGPoint(x: c.x + cos(a) * r * 0.85, y: c.y + sin(a) * r * 0.85))
                }
                .stroke(Color.primary, style: StrokeStyle(lineWidth: max(1, lineWidth * 0.55), lineCap: .round))
            }
        }
    }
}

struct BatteryGlyph: View {
    let fraction: Double
    let charging: Bool
    var tint: Color = .primary
    /// Percentage inside the icon (Stats style); nil draws just the fill.
    var inside: Int? = nil

    var body: some View {
        if let inside { insideBody(inside) } else { plainBody }
    }

    private func insideBody(_ pct: Int) -> some View {
        HStack(spacing: 1) {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous).stroke(Color.primary.opacity(0.5), lineWidth: 1)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tint)
                        .frame(width: max(2, (g.size.width) * CGFloat(min(max(fraction, 0), 1))))
                }
                .padding(1.5)
                HStack(spacing: 0.5) {
                    if charging { Image(systemName: "bolt.fill").font(.system(size: 6.5, weight: .heavy)) }
                    Text("\(pct)").font(.system(size: 9, weight: .bold, design: .rounded).monospacedDigit())
                }
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.55), radius: 0.6)
            }
            .frame(width: 27, height: 13)
            RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.5)).frame(width: 1.5, height: 4.5)
        }
    }

    private var plainBody: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.55), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.5).fill(tint)
                    .frame(width: max(1.5, 17 * min(max(fraction, 0), 1)))
                    .padding(1.5)
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 7, weight: .bold)).foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 22, height: 11)
            RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.55)).frame(width: 1.5, height: 4)
        }
    }
}

struct MenuWidgetView: View {
    let module: MenuModule
    let kind: WidgetKind
    let cfg: ModuleConfig
    @ObservedObject var stats: MenuStats
    @ObservedObject var system: SystemMonitor
    @ObservedObject var batteries: BatteryMonitor
    var zones: [TimeZone] = []

    private var frac: Double { stats.fraction(module) }
    private var tint: Color {
        switch cfg.colorMode {
        case .usage: return module == .clock ? .primary : UsageColor.color(frac, inverse: module.alertBelow)
        case .accent: return module.accent
        case .mono: return .primary
        }
    }

    var body: some View {
        content
            .padding(.horizontal, 3)
            .fixedSize()
            .frame(height: 22)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .mini:
            VStack(alignment: .leading, spacing: -2) {
                if cfg.label { Text(module.short).font(.system(size: 7, weight: .bold)) }
                fixed(valueText, template).font(.system(size: cfg.label ? 11 : 12.5, weight: .semibold).monospacedDigit())
                    .foregroundColor(cfg.colorMode == .mono ? .primary : tint)
            }
        case .text:
            if module == .clock {
                HStack(spacing: 8) {
                    ForEach(zones.prefix(2), id: \.identifier) { z in
                        Text(MenuFmt.zoneTime(z)).font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    }
                }
            } else if module == .bluetooth {
                HStack(spacing: 6) {
                    ForEach(stats.bluetoothDevices.prefix(3)) { d in
                        HStack(spacing: 2) {
                            Image(systemName: d.symbol).font(.system(size: 10))
                            Text(d.mainPercent.map { "\($0)%" } ?? "–").font(.system(size: 11, weight: .medium).monospacedDigit())
                        }
                    }
                    if stats.bluetoothDevices.isEmpty { Image(systemName: module.symbol).font(.system(size: 11)) }
                }
            } else if module == .sensors {
                VStack(alignment: .trailing, spacing: -2) {
                    fixed(stats.socTemp.map { "\(Int($0.rounded()))°" } ?? "–", "100°")
                    fixed(stats.batteryTemp.map { "\(Int($0.rounded()))°" } ?? "–", "100°")
                }
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
            } else {
                HStack(spacing: 3) {
                    if cfg.label { Text(module.short).font(.system(size: 9, weight: .bold)).foregroundColor(.secondary) }
                    fixed(valueText, template).font(.system(size: 12, weight: .medium).monospacedDigit())
                }
            }
        case .lineChart:
            HStack(spacing: 2) {
                if cfg.label { verticalLabel }
                MiniChart(values: Array(stats.history(module).suffix(40)),
                          maxValue: module == .network || module == .disk ? nil : 100,
                          color: cfg.colorMode == .mono ? .primary : (cfg.colorMode == .accent ? module.accent : tint))
                    .frame(width: 34, height: 16)
                    .background(RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08)))
            }
        case .barChart:
            HStack(spacing: 2) {
                if cfg.label { verticalLabel }
                HStack(alignment: .bottom, spacing: 1) {
                    let loads = module == .cpu ? stats.coreLoads : [frac * 100]
                    ForEach(Array(loads.enumerated()), id: \.offset) { i, l in
                        let eff = module == .cpu && CPUInfo.label(i).efficiency
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(cfg.colorMode == .usage ? (eff ? Color.cyan : Color.orange) : tint)
                            .frame(width: 2.5, height: max(1, 16 * CGFloat(l / 100)))
                    }
                }
                .frame(height: 16, alignment: .bottom)
            }
        case .pie:
            HStack(spacing: 3) {
                if cfg.label { verticalLabel }
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.22), lineWidth: 3)
                    Circle().trim(from: 0, to: frac).stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 14, height: 14)
            }
        case .tachometer:
            HStack(spacing: 3) {
                if cfg.label { verticalLabel }
                TachometerShape(fraction: frac).frame(width: 22, height: 12)
            }
        case .speed:
            let up = module == .disk ? stats.diskWrite : system.netUp
            let down = module == .disk ? stats.diskRead : system.netDown
            VStack(alignment: .trailing, spacing: -1) {
                let w = L("W"), r = L("R")
                fixed((module == .disk ? w + " " : "↑ ") + MenuFmt.speed(up), (module == .disk ? w : "↑") + " 99.9 MB/s")
                fixed((module == .disk ? r + " " : "↓ ") + MenuFmt.speed(down), (module == .disk ? r : "↓") + " 99.9 MB/s")
            }
            .font(.system(size: 8.5, weight: .medium).monospacedDigit())
        case .memory:
            let (used, free): (Int64, Int64) = module == .disk
                ? ((stats.space.map { $0.total - $0.free }) ?? 0, stats.space?.free ?? 0)
                : (Int64(stats.ram.used), Int64(stats.ram.free))
            VStack(alignment: .trailing, spacing: -1) {
                let u = L("U:"), f = L("F:")
                fixed(u + " " + MenuFmt.gb(used), u + " 999.9 GB")
                fixed(f + " " + MenuFmt.gb(free), f + " 999.9 GB")
            }
            .font(.system(size: 8.5, weight: .medium).monospacedDigit())
        case .battery:
            HStack(spacing: 3) {
                BatteryGlyph(fraction: frac, charging: system.power?.isCharging == true,
                             tint: cfg.colorMode == .mono ? .primary : tint,
                             inside: module == .battery && cfg.percentInside ? system.power?.percent : nil)
                if cfg.label && !(module == .battery && cfg.percentInside) {
                    fixed(valueText, "100%").font(.system(size: 11.5, weight: .medium).monospacedDigit())
                }
            }
        case .dot:
            Circle().fill(tint).frame(width: 8, height: 8)
        }
    }

    private var verticalLabel: some View {
        VStack(spacing: -2.5) {
            ForEach(Array(module.short.prefix(4).enumerated()), id: \.offset) { _, ch in
                Text(String(ch)).font(.system(size: 6, weight: .bold))
            }
        }
        .frame(width: 6)
    }

    private func fixed(_ text: String, _ template: String) -> some View {
        ZStack(alignment: .trailing) {
            Text(template).hidden()
            Text(text)
        }
    }

    private var template: String {
        switch module {
        case .sensors: return "100°"
        case .network: return "99.9 MB/s"
        default: return "100%"
        }
    }

    private var valueText: String {
        switch module {
        case .cpu: return "\(Int(stats.cpuTotal.rounded()))%"
        case .gpu: return stats.gpu.map { "\(Int($0.rounded()))%" } ?? "–"
        case .ram: return "\(Int(stats.ramPercent.rounded()))%"
        case .disk: return stats.diskPercent.map { "\(Int($0.rounded()))%" } ?? "–"
        case .sensors: return stats.socTemp.map { "\(Int($0.rounded()))°" } ?? "–"
        case .network: return MenuFmt.speed(system.netDown)
        case .battery: return system.power.map { "\($0.percent)%" } ?? "–"
        case .bluetooth: return stats.bluetoothDevices.compactMap(\.mainPercent).min().map { "\($0)%" } ?? "–"
        case .clock: return ""
        }
    }
}

enum MenuFmt {
    static func speed(_ v: Double) -> String {
        if v < 1024 { return "0 KB/s" }
        if v < 1024 * 1024 { return "\(Int(v / 1024)) KB/s" }
        return String(format: "%.1f MB/s", v / 1024 / 1024)
    }
    static func gb(_ b: Int64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }
    static func zoneTime(_ z: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = z
        f.dateFormat = "HH:mm"
        let city = z.identifier.split(separator: "/").last.map { String($0).replacingOccurrences(of: "_", with: " ") } ?? z.identifier
        return "\(city.prefix(3).uppercased()) \(f.string(from: Date()))"
    }
}

/// One menu bar item. When combined, all of the module's widgets sit side by side.
struct MenuItemView: View {
    let module: MenuModule
    let kinds: [WidgetKind]
    let cfg: ModuleConfig
    @ObservedObject var stats: MenuStats
    @ObservedObject var system: SystemMonitor
    @ObservedObject var batteries: BatteryMonitor
    var zones: [TimeZone] = []

    var body: some View {
        HStack(spacing: 2) {
            ForEach(kinds) { k in
                MenuWidgetView(module: module, kind: k, cfg: cfg, stats: stats, system: system, batteries: batteries, zones: zones)
            }
        }
        .padding(.horizontal, 2)
        .fixedSize()
        .frame(height: 22)
    }
}

// MARK: - Controller

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    let stats: MenuStats
    private let system: SystemMonitor
    private let batteries: BatteryMonitor
    private var items: [String: NSStatusItem] = [:]
    private var hosts: [String: NSView] = [:]
    private var signature = ""
    private var popover: NSPopover?
    private var sizeTimer: Timer?
    var zones: [TimeZone] = []
    var openSettings: (@MainActor (MenuModule) -> Void)?

    init(system: SystemMonitor, batteries: BatteryMonitor) {
        self.system = system
        self.batteries = batteries
        stats = MenuStats(system: system, batteries: batteries)
    }

    func apply(enabled: [MenuModule]) {
        let cfgs = MenuConfigs.shared
        stats.interval = max(1, enabled.map { cfgs[$0].interval }.min() ?? 2)
        stats.start()
        let sig = enabled.map { "\($0.rawValue):\(cfgs[$0].renderKey)" }.joined(separator: "|") + zones.map(\.identifier).joined()
        guard sig != signature else { return }
        signature = sig
        rebuild(enabled)
    }

    private func rebuild(_ enabled: [MenuModule]) {
        for (_, item) in items { NSStatusBar.system.removeStatusItem(item) }
        items = [:]
        hosts = [:]
        let cfgs = MenuConfigs.shared
        // New status items get inserted on the left, so build in reverse to keep left-to-right order.
        var entries: [(key: String, module: MenuModule, kinds: [WidgetKind])] = []
        for m in enabled {
            let c = cfgs[m]
            if c.combine { entries.append((m.rawValue, m, c.widgets)) }
            else { for k in c.widgets { entries.append(("\(m.rawValue).\(k.rawValue)", m, [k])) } }
        }
        for e in entries.reversed() {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "rihtim." + e.key
            guard let button = item.button else { continue }
            let view = MenuItemView(module: e.module, kinds: e.kinds, cfg: cfgs[e.module], stats: stats,
                                    system: system, batteries: batteries, zones: zones)
            let host = PassthroughHostingView(rootView: view)
            host.translatesAutoresizingMaskIntoConstraints = true
            button.addSubview(host)
            button.target = self
            button.action = #selector(clicked(_:))
            button.identifier = NSUserInterfaceItemIdentifier(e.module.rawValue)
            items[e.key] = item
            hosts[e.key] = host
        }
        resize()
        if sizeTimer == nil {
            sizeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.resize() }
            }
        }
    }

    private func resize() {
        for (k, host) in hosts {
            guard let item = items[k] else { continue }
            let size = host.fittingSize
            let w = ceil(size.width)
            if abs(item.length - w) > 0.5 { item.length = w }
            let h = item.button?.bounds.height ?? 22
            host.frame = NSRect(x: 0, y: (h - size.height) / 2, width: w, height: size.height)
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let m = MenuModule(rawValue: raw) else { return }
        if let popover, popover.isShown { popover.performClose(nil); return }
        if m.hasProcesses { system.wantsProcesses = true }
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        let view = ScrollView {
            ModuleDetailView(module: m, compact: true, stats: stats, system: system, batteries: batteries,
                             configs: MenuConfigs.shared, zones: zones,
                             openSettings: { [weak self] in self?.popover?.performClose(nil); self?.openSettings?(m) })
                .padding(14)
        }
        .frame(width: 380, height: Self.popupHeight(m))
        let host = NSHostingController(rootView: view)
        p.contentViewController = host
        p.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover = p
    }

    static func popupHeight(_ m: MenuModule) -> CGFloat {
        let c = MenuConfigs.shared[m]
        switch m {
        case .cpu, .ram: return c.popupProcesses || c.popupDetails ? 620 : 330
        case .sensors, .network, .disk, .battery, .gpu: return c.popupHistory || c.popupDetails ? 440 : 220
        default: return 300
        }
    }

    func popoverDidClose(_ notification: Notification) {
        system.wantsProcesses = false
        popover = nil
    }
}
