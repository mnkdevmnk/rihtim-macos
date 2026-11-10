import AppKit
import SwiftUI

// MARK: - Shared pieces

struct StatCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.system(size: 13, weight: .semibold)) }
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
    }
}

/// Segmented ring: [(fraction, color)] with text in the middle.
struct SegmentRing: View {
    let segments: [(Double, Color)]
    let center: String
    var size: CGFloat = 96
    var line: CGFloat = 9

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: line)
            ForEach(Array(starts.enumerated()), id: \.offset) { i, s in
                Circle().trim(from: s, to: min(1, s + segments[i].0))
                    .stroke(segments[i].1, style: StrokeStyle(lineWidth: line, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            Text(center).font(.system(size: size * 0.22, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(width: size, height: size)
    }

    private var starts: [Double] {
        var acc = 0.0
        return segments.map { s in defer { acc += max(0, s.0) }; return acc }
    }
}

struct StackedBar: View {
    let segments: [(Double, Color)]
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    Rectangle().fill(s.1).frame(width: g.size.width * CGFloat(min(max(s.0, 0), 1)))
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.15))
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }
}

struct LegendItem: View {
    let color: Color
    let title: String
    let value: String
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(title + ":").foregroundColor(.secondary).lineLimit(1)
            Text(value).fontWeight(.semibold).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 11.5))
        .minimumScaleFactor(0.75)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Area chart with a grid; y axis is percent or auto-scaled.
struct HistoryChart: View {
    let series: [([Double], Color)]
    var maxValue: Double? = 100
    var unit: (Double) -> String = { "\(Int($0))%" }
    var start: Date
    var height: CGFloat = 130

    var body: some View {
        let maxV = max(maxValue ?? series.flatMap(\.0).max() ?? 1, 1)
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing) {
                    ForEach([1.0, 0.75, 0.5, 0.25, 0], id: \.self) { f in
                        Text(unit(maxV * f)).font(.system(size: 9)).foregroundColor(.secondary)
                        if f > 0 { Spacer(minLength: 0) }
                    }
                }
                .frame(width: 48, height: height)
                ZStack {
                    VStack(spacing: 0) {
                        ForEach(0..<4) { _ in
                            Divider().opacity(0.4)
                            Spacer(minLength: 0)
                        }
                        Divider().opacity(0.4)
                    }
                    ForEach(Array(series.enumerated()), id: \.offset) { _, s in
                        GeometryReader { g in
                            // right-aligned: newest sample on the right edge
                            let n = MenuStats.historyLength
                            let w = g.size.width * CGFloat(s.0.count) / CGFloat(n)
                            MiniChart(values: s.0, maxValue: maxV, color: s.1)
                                .frame(width: max(w, 1))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
                .frame(height: height)
            }
            HStack {
                Spacer()
                Text(start.formatted(date: .omitted, time: .standard))
                Text("→")
                Text(Date().formatted(date: .omitted, time: .standard))
            }
            .font(.system(size: 9)).foregroundColor(.secondary)
        }
    }
}

struct ProcessTable: View {
    struct Row: Identifiable { let id: pid_t; let name: String; let fraction: Double; let value: String }
    let rows: [Row]
    var onQuit: (@MainActor (pid_t, Bool) -> Void)? = nil   // (pid, force)
    @State private var hovered: pid_t?
    @State private var confirming: pid_t?

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(L("Process")).frame(maxWidth: .infinity, alignment: .leading)
                Text("PID").frame(width: 54, alignment: .trailing)
                Text(L("Usage")).frame(width: 76, alignment: .trailing)
                if onQuit != nil { Spacer().frame(width: 22) }
            }
            .font(.system(size: 10.5, weight: .medium)).foregroundColor(.secondary)
            .padding(.horizontal, 8)
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                row(r, index: i)
            }
        }
    }

    private func row(_ r: Row, index i: Int) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: Self.icon(r.id)).resizable().frame(width: 16, height: 16)
            Text(r.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                .help(r.name)
            Text("\(r.id)").monospacedDigit().foregroundColor(.secondary).frame(width: 54, alignment: .trailing)
            Text(r.value).monospacedDigit().frame(width: 76, alignment: .trailing)
            if let onQuit {
                Button(action: {
                    if confirming == r.id { confirming = nil; onQuit(r.id, true) } else { confirming = r.id }
                }) {
                    Image(systemName: confirming == r.id ? "exclamationmark.octagon.fill" : "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(confirming == r.id ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 22)
                .opacity(hovered == r.id || confirming == r.id ? 1 : 0)
                .help(confirming == r.id ? L("Sure? Click again to force quit %@", r.name) : L("Force Quit"))
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(
            confirming == r.id ? Color.red.opacity(0.15) : (i % 2 == 0 ? Color.primary.opacity(0.05) : .clear)))
        .contentShape(Rectangle())
        .onHover { h in
            if h { hovered = r.id } else if hovered == r.id { hovered = nil; if confirming == r.id { confirming = nil } }
        }
        .contextMenu {
            if let onQuit {
                Button(L("Quit")) { onQuit(r.id, false) }
                Button(L("Force Quit"), role: .destructive) { onQuit(r.id, true) }
            }
        }
    }

    static func icon(_ pid: pid_t) -> NSImage {
        NSRunningApplication(processIdentifier: pid)?.icon ?? NSWorkspace.shared.icon(for: .unixExecutable)
    }
}

// MARK: - Module detail (shared by the popup and the settings page)

struct ModuleDetailView: View {
    let module: MenuModule
    var compact: Bool
    @ObservedObject var stats: MenuStats
    @ObservedObject var system: SystemMonitor
    @ObservedObject var batteries: BatteryMonitor
    @ObservedObject var configs: MenuConfigs
    var zones: [TimeZone] = []
    var openSettings: (@MainActor () -> Void)? = nil

    private var cfg: ModuleConfig { configs[module] }
    private var showHistory: Bool { !compact || cfg.popupHistory }
    private var showDetails: Bool { !compact || cfg.popupDetails }
    private var showProcs: Bool { !compact || cfg.popupProcesses }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if compact {
                HStack {
                    Label(module.title, systemImage: module.symbol).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let openSettings {
                        Button(action: { openSettings() }) { Image(systemName: "gearshape") }.buttonStyle(.plain).help(L("Settings"))
                    }
                }
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch module {
        case .cpu: cpu
        case .gpu: gpu
        case .ram: ram
        case .disk: disk
        case .sensors: sensors
        case .network: network
        case .battery: battery
        case .bluetooth: bluetooth
        case .clock: clock
        }
    }

    private func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    // CPU
    private var cpu: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatCard {
                HStack(spacing: 16) {
                    SegmentRing(segments: [(stats.cpuSystem / 100, .red), (stats.cpuUser / 100, .blue)],
                                center: pct(stats.cpuTotal), size: compact ? 70 : 96)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(CPUInfo.brand).font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Text(CPUInfo.summary).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        StackedBar(segments: [(stats.cpuSystem / 100, .red), (stats.cpuUser / 100, .blue)])
                        HStack {
                            LegendItem(color: .red, title: L("System"), value: pct(stats.cpuSystem))
                            Spacer()
                            LegendItem(color: .blue, title: L("User"), value: pct(stats.cpuUser))
                            Spacer()
                            LegendItem(color: .gray, title: L("Idle"), value: pct(100 - stats.cpuTotal))
                        }
                    }
                }
            }
            if showHistory {
                StatCard(title: L("Usage history")) {
                    HistoryChart(series: [(stats.cpuHistory, .blue)], start: stats.startedAt, height: compact ? 70 : 130)
                }
            }
            if showDetails {
                StatCard(title: L("Load per core")) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], spacing: 8) {
                        ForEach(Array(stats.coreLoads.enumerated()), id: \.offset) { i, l in
                            let info = CPUInfo.label(i)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(compact ? (info.efficiency ? L("E") + "\(i + 1)" : "\(CPUInfo.performanceName.prefix(1))\(i - CPUInfo.efficiencyCount + 1)") : info.title)
                                    Spacer()
                                    Text(pct(l)).monospacedDigit()
                                }
                                .font(.system(size: 11.5))
                                ProgressView(value: min(l / 100, 1)).tint(info.efficiency ? .cyan : .orange)
                            }
                        }
                    }
                }
                if stats.load.count == 3 {
                    StatCard(title: L("Load average")) {
                        ForEach(Array(zip([L("1 minute"), L("5 minutes"), L("15 minutes")], stats.load)), id: \.0) { k, v in
                            HStack { Text(k + ":"); Spacer(); Text(String(format: "%.2f", v)).monospacedDigit().fontWeight(.semibold) }
                                .font(.system(size: 12))
                        }
                    }
                }
            }
            if showProcs { processes(byCPU: true) }
        }
    }

    // GPU
    private var gpu: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatCard {
                HStack(spacing: 16) {
                    SegmentRing(segments: [((stats.gpu ?? 0) / 100, .purple)], center: stats.gpu.map(pct) ?? "–", size: compact ? 70 : 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(stats.gpuName).font(.system(size: 14, weight: .semibold))
                        Text(L("Utilization (IOAccelerator)")).font(.system(size: 11)).foregroundColor(.secondary)
                        if let t = stats.socTemp { LegendItem(color: .orange, title: L("SoC temperature"), value: "\(Int(t.rounded()))°C") }
                    }
                }
            }
            if showHistory {
                StatCard(title: L("Usage history")) {
                    HistoryChart(series: [(stats.gpuHistory, .purple)], start: stats.startedAt, height: compact ? 70 : 130)
                }
            }
        }
    }

    // RAM
    private var ram: some View {
        let r = stats.ram
        let t = Double(max(r.total, 1))
        let segs: [(Double, Color)] = [(Double(r.app) / t, .blue), (Double(r.wired) / t, .orange), (Double(r.compressed) / t, .pink)]
        return VStack(alignment: .leading, spacing: 14) {
            StatCard {
                HStack(spacing: 16) {
                    SegmentRing(segments: segs, center: pct(stats.ramPercent), size: compact ? 70 : 96)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("Used: %@", Fmt.bytes(r.used))).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(L("Total: %@", Fmt.bytes(r.total))).font(.system(size: 13, weight: .medium))
                        }
                        StackedBar(segments: segs)
                        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .trailing)], spacing: 4) {
                            LegendItem(color: .blue, title: L("App"), value: Fmt.bytes(r.app))
                            LegendItem(color: .orange, title: L("Wired"), value: Fmt.bytes(r.wired))
                            LegendItem(color: .pink, title: L("Compressed"), value: Fmt.bytes(r.compressed))
                            LegendItem(color: .gray, title: L("Free"), value: Fmt.bytes(r.free))
                        }
                    }
                }
            }
            if showHistory {
                StatCard(title: L("Usage history")) {
                    HistoryChart(series: [(stats.ramHistory, .blue)], start: stats.startedAt, height: compact ? 70 : 130)
                }
            }
            if showDetails {
                HStack(alignment: .top, spacing: 14) {
                    StatCard(title: L("Memory pressure")) {
                        VStack(spacing: 4) {
                            TachometerShape(fraction: stats.pressure >= 4 ? 0.9 : (stats.pressure >= 2 ? 0.55 : 0.2), lineWidth: 7)
                                .frame(width: 110, height: 56)
                            Text(stats.pressure >= 4 ? L("Critical") : (stats.pressure >= 2 ? L("Warning") : L("Normal")))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    StatCard(title: "Swap") {
                        SegmentRing(segments: [(min(Double(stats.swap) / t, 1), .gray)],
                                    center: stats.swap == 0 ? "0 KB" : Fmt.bytes(stats.swap), size: 72, line: 7)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            if showProcs { processes(byCPU: false) }
        }
    }

    // Disk
    private var disk: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatCard {
                HStack(spacing: 16) {
                    SegmentRing(segments: [((stats.diskPercent ?? 0) / 100, .teal)], center: stats.diskPercent.map(pct) ?? "–", size: compact ? 70 : 96)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Macintosh HD").font(.system(size: 14, weight: .semibold))
                        if let s = stats.space {
                            LegendItem(color: .teal, title: L("Used"), value: ByteCountFormatter.string(fromByteCount: s.total - s.free, countStyle: .file))
                            LegendItem(color: .gray, title: L("Free"), value: ByteCountFormatter.string(fromByteCount: s.free, countStyle: .file))
                        }
                        HStack(spacing: 16) {
                            LegendItem(color: .blue, title: L("Read"), value: Fmt.rate(stats.diskRead))
                            LegendItem(color: .red, title: L("Write"), value: Fmt.rate(stats.diskWrite))
                        }
                    }
                }
            }
            if showHistory {
                StatCard(title: L("Read / write")) {
                    HistoryChart(series: [(stats.readHistory, .blue), (stats.writeHistory, .red)], maxValue: nil,
                                 unit: { MenuFmt.speed($0) }, start: stats.startedAt, height: compact ? 70 : 130)
                }
            }
        }
    }

    // Sensors
    private var sensors: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatCard {
                HStack(spacing: 24) {
                    tempBig(L("SoC (hottest)"), stats.socTemp)
                    tempBig(L("Battery"), stats.batteryTemp)
                    tempBig("SSD", stats.ssdTemp)
                }
            }
            if showHistory {
                StatCard(title: L("SoC temperature")) {
                    HistoryChart(series: [(stats.socHistory, .orange)], maxValue: 100, unit: { "\(Int($0))°" },
                                 start: stats.startedAt, height: compact ? 70 : 120)
                }
            }
            if showDetails {
                let groups = Dictionary(grouping: stats.sensors, by: \.group).sorted { $0.key < $1.key }
                ForEach(groups, id: \.key) { g, list in
                    StatCard(title: g) {
                        if compact {
                            HStack {
                                Text(L("%d sensors", list.count)).foregroundColor(.secondary)
                                Spacer()
                                Text(L("avg %d° · max %d°", Int((list.map(\.value).reduce(0, +) / Double(list.count)).rounded()), Int((list.map(\.value).max() ?? 0).rounded())))
                                    .monospacedDigit()
                            }
                            .font(.system(size: 12))
                        } else {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], spacing: 6) {
                                ForEach(list) { s in
                                    HStack {
                                        Text(s.name)
                                        Spacer()
                                        Text(String(format: "%.1f °C", s.value)).monospacedDigit()
                                            .foregroundColor(UsageColor.color(min(1, max(0, (s.value - 30) / 70))))
                                    }
                                    .font(.system(size: 12))
                                }
                            }
                        }
                    }
                }
                if !compact {
                    Text(L("This Mac has no fan, so there's no fan sensor. Power (watt) readings need the SMC and aren't shown."))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func tempBig(_ title: String, _ v: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v.map { "\(Int($0.rounded()))°" } ?? "–").font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(v.map { UsageColor.color(min(1, max(0, ($0 - 30) / 70))) } ?? .secondary)
            Text(title).font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    // Network
    private var network: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatCard {
                HStack(spacing: 28) {
                    VStack(alignment: .leading) {
                        Text(Fmt.rate(system.netDown)).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                        Label(L("Download"), systemImage: "arrow.down").font(.system(size: 11)).foregroundColor(.blue)
                    }
                    VStack(alignment: .leading) {
                        Text(Fmt.rate(system.netUp)).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                        Label(L("Upload"), systemImage: "arrow.up").font(.system(size: 11)).foregroundColor(.red)
                    }
                }
            }
            if showHistory {
                StatCard(title: L("History")) {
                    HistoryChart(series: [(stats.downHistory, .blue), (stats.upHistory, .red)], maxValue: nil,
                                 unit: { MenuFmt.speed($0) }, start: stats.startedAt, height: compact ? 70 : 130)
                }
            }
            if showDetails {
                StatCard(title: L("Details")) {
                    row(L("This session ↓"), Fmt.bytes(stats.totalDown))
                    row(L("This session ↑"), Fmt.bytes(stats.totalUp))
                    if let ip = stats.ip { row(L("Local IP (%@)", ip.iface), ip.ip) }
                }
            }
        }
    }

    // Battery
    private var battery: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatCard {
                HStack(spacing: 16) {
                    let p = Double(system.power?.percent ?? 0)
                    SegmentRing(segments: [(p / 100, UsageColor.color(p / 100, inverse: true))],
                                center: system.power.map { Fmt.pct($0.percent) } ?? "–", size: compact ? 70 : 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(system.power?.isCharging == true ? L("Charging") : (system.power?.onAC == true ? L("On power adapter") : L("On battery")))
                            .font(.system(size: 14, weight: .semibold))
                        if let m = stats.battery?.minutesRemaining {
                            Text(system.power?.isCharging == true ? L("Full in %dh %dm", m / 60, m % 60) : L("%dh %dm left", m / 60, m % 60))
                                .font(.system(size: 12)).foregroundColor(.secondary)
                        }
                    }
                }
            }
            if showDetails, let b = stats.battery {
                StatCard(title: L("Details")) {
                    if let h = b.healthPercent { row(L("Health"), Fmt.pct(h)) }
                    if let c = b.cycles { row(L("Cycle count"), "\(c)") }
                    if let t = b.temperature { row(L("Temperature"), String(format: "%.1f °C", t)) }
                    if let w = b.watts, abs(w) > 0.1 { row(w > 0 ? L("Charging power") : L("Power draw"), String(format: "%.1f W", abs(w))) }
                    if let a = b.adapterWatts { row(L("Adapter"), "\(a) W") }
                    if let d = b.designCapacity, let m = b.maxCapacity { row(L("Capacity"), "\(m) / \(d) mAh") }
                }
            }
        }
    }

    // Bluetooth
    private var bluetooth: some View {
        StatCard(title: L("Connected devices")) {
            if stats.bluetoothDevices.isEmpty { Text(L("No devices reporting battery levels")).foregroundColor(.secondary) }
            ForEach(stats.bluetoothDevices) { d in
                HStack(spacing: 8) {
                    Image(systemName: d.symbol).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.name).font(.system(size: 12.5, weight: .medium))
                        if !d.detail.isEmpty { Text(d.detail).font(.system(size: 10.5)).foregroundColor(.secondary) }
                    }
                    Spacer()
                    LevelBar(value: Double(d.mainPercent ?? 0) / 100).frame(width: 70, height: 6)
                    Text(d.mainPercent.map { Fmt.pct($0) } ?? "–").monospacedDigit().frame(width: 40, alignment: .trailing)
                    if d.isCharging { Image(systemName: "bolt.fill").foregroundColor(.green).font(.system(size: 10)) }
                }
            }
        }
    }

    // Clock
    private var clock: some View {
        StatCard(title: L("World clocks")) {
            ForEach(zones, id: \.identifier) { z in
                HStack {
                    Text(z.identifier.replacingOccurrences(of: "_", with: " "))
                    Spacer()
                    Text(Self.full(z)).monospacedDigit().font(.system(size: 13, weight: .semibold))
                }
                .font(.system(size: 12))
            }
            if zones.isEmpty { Text(L("No time zones added")).foregroundColor(.secondary) }
        }
    }

    private static func full(_ z: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = z
        f.locale = L10n.locale
        f.setLocalizedDateFormatFromTemplate("EEE d MMM jj:mm")
        return f.string(from: Date())
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundColor(.secondary); Spacer(); Text(v).monospacedDigit() }.font(.system(size: 12))
    }

    @ViewBuilder
    private func processes(byCPU: Bool) -> some View {
        let n = compact ? min(cfg.topCount, 5) : cfg.topCount
        let list = system.processes.sorted { byCPU ? $0.cpu > $1.cpu : $0.memory > $1.memory }.prefix(n)
        StatCard(title: L("Top processes")) {
            if list.isEmpty {
                Text(L("Collecting…")).foregroundColor(.secondary).font(.system(size: 12))
            } else {
                let total = Double(max(stats.ram.total, 1))
                ProcessTable(rows: list.map { p in
                    ProcessTable.Row(id: p.id, name: p.name,
                                     fraction: byCPU ? p.cpu / 100 : Double(p.memory) / total,
                                     value: byCPU ? String(format: "%.1f%%", p.cpu) : Fmt.bytes(p.memory))
                }, onQuit: { pid, force in system.quit(pid, force: force) })
            }
        }
    }
}

// MARK: - Dashboard

struct StatsDashboard: View {
    @ObservedObject var stats: MenuStats
    @ObservedObject var system: SystemMonitor
    let select: (MenuModule) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                ForEach([MenuModule.cpu, .gpu, .ram, .disk, .sensors, .battery]) { m in
                    Button(action: { select(m) }) { card(m) }.buttonStyle(.plain)
                }
            }
            .padding(20)
            HStack(spacing: 14) {
                Button(action: { select(.network) }) {
                    StatCard(title: L("Network")) {
                        HStack {
                            Label(Fmt.rate(system.netDown), systemImage: "arrow.down").foregroundColor(.blue)
                            Spacer()
                            Label(Fmt.rate(system.netUp), systemImage: "arrow.up").foregroundColor(.red)
                        }
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        MiniChart(values: stats.downHistory, maxValue: nil, color: .blue).frame(height: 40)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            Text(L("Click a card to open that module's page. Use the switch on the module page to add it to the menu bar."))
                .font(.caption).foregroundColor(.secondary).padding(20)
        }
    }

    private func card(_ m: MenuModule) -> some View {
        let v = stats.value(m)
        let f = stats.fraction(m)
        let text: String = {
            guard let v else { return "–" }
            return m == .sensors ? "\(Int(v.rounded()))°" : "\(Int(v.rounded()))%"
        }()
        return VStack(spacing: 10) {
            SegmentRing(segments: [(f, m == .battery ? UsageColor.color(f, inverse: true) : m.accent)], center: text, size: 86, line: 8)
            Label(m.title, systemImage: m.symbol).font(.system(size: 13, weight: .semibold))
            Text(subtitle(m)).font(.system(size: 10.5)).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
        .contentShape(Rectangle())
    }

    private func subtitle(_ m: MenuModule) -> String {
        switch m {
        case .cpu: return CPUInfo.brand
        case .gpu: return stats.gpuName
        case .ram: return "\(Fmt.bytes(stats.ram.used)) / \(Fmt.bytes(stats.ram.total))"
        case .disk: return stats.space.map { L("%@ free", ByteCountFormatter.string(fromByteCount: $0.free, countStyle: .file)) } ?? ""
        case .sensors: return L("SoC hottest")
        case .battery: return system.power?.isCharging == true ? L("Charging") : L("Battery")
        default: return ""
        }
    }
}

// MARK: - Module page (live data ⇄ settings)

struct ModuleSettingsPage: View {
    let module: MenuModule
    @ObservedObject var stats: MenuStats
    @ObservedObject var system: SystemMonitor
    @ObservedObject var batteries: BatteryMonitor
    @ObservedObject var configs = MenuConfigs.shared
    @AppStorage private var enabled: Bool
    @AppStorage(Prefs.menuZones) private var zonesRaw = ""
    @State private var showSettings = false
    @State private var tab = 0

    init(module: MenuModule, stats: MenuStats, system: SystemMonitor, batteries: BatteryMonitor) {
        self.module = module
        self.stats = stats
        self.system = system
        self.batteries = batteries
        _enabled = AppStorage(wrappedValue: module.defaultOn, module.enabledKey)
    }

    private var cfg: Binding<ModuleConfig> { configs.binding(module) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(module.title, systemImage: module.symbol).font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: { withAnimation { showSettings.toggle() } }) {
                    Image(systemName: showSettings ? "chart.xyaxis.line" : "slider.horizontal.3").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .help(showSettings ? L("Show live data") : L("Settings"))
                Toggle("", isOn: $enabled).toggleStyle(.switch).labelsHidden().help(L("Show in menu bar"))
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            ScrollView {
                Group {
                    if showSettings { settings } else {
                        ModuleDetailView(module: module, compact: false, stats: stats, system: system, batteries: batteries,
                                         configs: configs, zones: Prefs.zones())
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .onAppear { if module.hasProcesses { system.wantsProcesses = true } }
        .onDisappear { if module.hasProcesses { system.wantsProcesses = false } }
    }

    // MARK: settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            widgetStrip
            Picker("", selection: $tab) {
                Text(L("Module")).tag(0)
                Text(L("Widgets")).tag(1)
                Text(L("Popup")).tag(2)
                Text(L("Notifications")).tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case 0: moduleTab
            case 1: widgetsTab
            case 2: popupTab
            default: alertTab
            }
        }
    }

    /// Every supported widget, live. Click to add it to / remove it from the menu bar.
    private var widgetStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(module.widgets) { k in
                    let on = cfg.wrappedValue.widgets.contains(k)
                    Button(action: {
                        var c = cfg.wrappedValue
                        if on { c.widgets.removeAll { $0 == k } } else { c.widgets.append(k) }
                        cfg.wrappedValue = c
                    }) {
                        MenuWidgetView(module: module, kind: k, cfg: cfg.wrappedValue, stats: stats, system: system,
                                       batteries: batteries, zones: Prefs.zones())
                            .padding(.horizontal, 4).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Color.accentColor : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .help(k.title + (on ? " " + L("(in menu bar)") : ""))
                }
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
    }

    private var moduleTab: some View {
        StatCard {
            settingRow(L("Update interval")) {
                Picker("", selection: cfg.interval) {
                    ForEach([1.0, 2, 3, 5, 10], id: \.self) { Text(L("%d s", Int($0))).tag($0) }
                }
                .labelsHidden().frame(width: 100)
            }
            if module.hasProcesses {
                Divider()
                settingRow(L("Number of top processes")) {
                    Stepper("\(cfg.wrappedValue.topCount)", value: cfg.topCount, in: 3...15)
                }
            }
            if module == .clock {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Time zones (comma separated)"))
                    TextField("Europe/Istanbul, America/New_York", text: $zonesRaw).textFieldStyle(.roundedBorder)
                    Text(L("The first two show in the menu bar.")).font(.caption).foregroundColor(.secondary)
                }
            }
            Text(L("Sampling runs at the shortest interval among the enabled modules.")).font(.caption).foregroundColor(.secondary)
        }
    }

    private var widgetsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatCard {
                settingRow(L("Combine widgets")) { Toggle("", isOn: cfg.combine).toggleStyle(.switch).labelsHidden() }
                Text(L("When on, the selected widgets sit side by side in a single menu bar item.")).font(.caption).foregroundColor(.secondary)
            }
            ForEach(Array(cfg.wrappedValue.widgets.enumerated()), id: \.element) { i, k in
                VStack(spacing: 6) {
                    MenuWidgetView(module: module, kind: k, cfg: cfg.wrappedValue, stats: stats, system: system,
                                   batteries: batteries, zones: Prefs.zones())
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                    HStack {
                        Text(k.title).font(.system(size: 13, weight: .semibold))
                        Button(action: { move(i, -1) }) { Image(systemName: "chevron.left") }.buttonStyle(.borderless).disabled(i == 0)
                        Button(action: { move(i, 1) }) { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                            .disabled(i == cfg.wrappedValue.widgets.count - 1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            StatCard {
                settingRow(L("Label")) { Toggle("", isOn: cfg.label).toggleStyle(.switch).labelsHidden() }
                if module == .battery {
                    Divider()
                    settingRow(L("Percentage inside the battery icon")) {
                        Toggle("", isOn: cfg.percentInside).toggleStyle(.switch).labelsHidden()
                    }
                }
                Divider()
                settingRow(L("Color")) {
                    Picker("", selection: cfg.colorMode) {
                        ForEach(ColorMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 170)
                }
            }
        }
    }

    private func move(_ i: Int, _ d: Int) {
        var c = cfg.wrappedValue
        let j = i + d
        guard c.widgets.indices.contains(j) else { return }
        c.widgets.swapAt(i, j)
        cfg.wrappedValue = c
    }

    private var popupTab: some View {
        StatCard {
            settingRow(L("History chart")) { Toggle("", isOn: cfg.popupHistory).toggleStyle(.switch).labelsHidden() }
            Divider()
            settingRow(module == .cpu ? L("Cores and load average") : L("Details")) {
                Toggle("", isOn: cfg.popupDetails).toggleStyle(.switch).labelsHidden()
            }
            if module.hasProcesses {
                Divider()
                settingRow(L("Top processes")) { Toggle("", isOn: cfg.popupProcesses).toggleStyle(.switch).labelsHidden() }
            }
            Text(L("What shows up in the popup when you click the menu bar item.")).font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var alertTab: some View {
        if stats.value(module) == nil && module != .disk {
            StatCard { Text(L("No notifications for this module.")).foregroundColor(.secondary) }
        } else {
            let unit = module == .sensors ? "°C" : "%"
            StatCard {
                settingRow(module.alertBelow ? L("Notify when it drops below") : L("Notify when it goes above")) {
                    Toggle("", isOn: cfg.alertEnabled).toggleStyle(.switch).labelsHidden()
                }
                Divider()
                Slider(value: cfg.alertThreshold, in: module == .sensors ? 50...110 : 5...100, step: 1) {
                    Text(L("Threshold: %@", "\(Int(cfg.wrappedValue.alertThreshold))\(unit)"))
                }
                .disabled(!cfg.wrappedValue.alertEnabled)
                if let v = stats.value(module) {
                    Text(L("Now: %@", "\(Int(v.rounded()))\(unit)")).font(.caption).foregroundColor(.secondary)
                }
                Text(L("You get one notification; it re-arms once the value moves 5 units away from the threshold. The module has to be on in the menu bar."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func settingRow<C: View>(_ title: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            control()
        }
    }
}
