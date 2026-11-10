import AppKit
import Darwin
import IOKit.ps
import SwiftUI

struct PowerInfo: Sendable, Equatable {
    var percent: Int
    var isCharging: Bool
    var onAC: Bool
}

struct ProcessRow: Identifiable {
    let id: pid_t
    let name: String
    let cpu: Double
    let memory: UInt64
}

enum SystemStats {
    struct Ticks { var busy: UInt64; var total: UInt64 }

    static func cpuTicks() -> Ticks? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let sys = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + sys + nice
            total += user + sys + nice + idle
        }
        return Ticks(busy: busy, total: total)
    }

    /// Same math as "Memory Used" in Activity Monitor: app + wired + compressed.
    static func memory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(getpagesize())
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = internalPages > purgeable ? internalPages - purgeable : 0
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }

    static func diskPercent() -> Int? {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, total > 0,
              let avail = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int((Double(Int64(total) - avail) / Double(total) * 100).rounded())
    }

    /// Total bytes in/out per interface. The counters are 32-bit; wraparound is handled with &- on the delta.
    static func interfaceCounters() -> [String: (rx: UInt32, tx: UInt32)] {
        var result: [String: (rx: UInt32, tx: UInt32)] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [:] }
        defer { freeifaddrs(ifap) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let data = ifa.ifa_data, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                result[String(cString: ifa.ifa_name)] = (d.ifi_ibytes, d.ifi_obytes)
            }
            cursor = ifa.ifa_next
        }
        return result
    }

    static func macPower() -> PowerInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCap = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let state = desc[kIOPSPowerSourceStateKey] as? String
            return PowerInfo(percent: maxCap > 0 ? cur * 100 / maxCap : cur,
                             isCharging: charging,
                             onAC: state == kIOPSACPowerValue)
        }
        return nil
    }

    struct ProcSample: Sendable { let pid: pid_t; let name: String; let cpuNanos: UInt64; let resident: UInt64 }

    /// Every process we're allowed to read (other users' and root processes are skipped).
    static func processes(names: [pid_t: String]) -> [ProcSample] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }

        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let numer = UInt64(max(tb.numer, 1))
        let denom = UInt64(max(tb.denom, 1))

        var out: [ProcSample] = []
        out.reserveCapacity(Int(n))
        let infoSize = Int32(MemoryLayout<proc_taskinfo>.size)
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var info = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, infoSize) == infoSize else { continue }
            let ticks = info.pti_total_user &+ info.pti_total_system
            let ns = ticks / denom * numer
            var name = names[pid]
            if name == nil {
                var buf = [CChar](repeating: 0, count: 256)
                proc_name(pid, &buf, UInt32(buf.count))
                name = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            }
            out.append(ProcSample(pid: pid, name: (name?.isEmpty == false ? name! : "\(pid)"),
                                  cpuNanos: ns, resident: info.pti_resident_size))
        }
        return out
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var cpu: Double = 0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memUsed: UInt64 = 0
    @Published private(set) var memTotal: UInt64 = 1
    @Published private(set) var diskPercent = 0
    @Published private(set) var netDown: Double = 0
    @Published private(set) var netUp: Double = 0
    @Published private(set) var power: PowerInfo?
    @Published private(set) var processes: [ProcessRow] = []

    var memPercent: Int { Int((Double(memUsed) / Double(max(memTotal, 1)) * 100).rounded()) }

    /// The process list is expensive, so it's only collected while the popover is open.
    var wantsProcesses = false {
        didSet {
            guard wantsProcesses, !oldValue else { return }
            lastProc = [:]
            sampleProcesses()
            Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { if self?.wantsProcesses == true { self?.sampleProcesses() } }
            }
        }
    }

    private var lastTicks: SystemStats.Ticks?
    private var lastNet: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var lastNetTime = Date()
    private var lastProc: [pid_t: UInt64] = [:]
    private var lastProcTime = Date()
    private var timer: Timer?
    private var tickCount = 0

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        tickCount += 1

        if let t = SystemStats.cpuTicks() {
            if let last = lastTicks, t.total > last.total, t.busy >= last.busy {
                let v = Double(t.busy - last.busy) / Double(t.total - last.total) * 100
                cpu = max(0, min(100, v))
                cpuHistory.append(cpu)
                if cpuHistory.count > 30 { cpuHistory.removeFirst(cpuHistory.count - 30) }
            }
            lastTicks = t
        }

        let m = SystemStats.memory()
        memUsed = m.used
        memTotal = m.total

        if tickCount % 10 == 1, let d = SystemStats.diskPercent() { diskPercent = d }

        let now = Date()
        let counters = SystemStats.interfaceCounters()
        let dt = now.timeIntervalSince(lastNetTime)
        if !lastNet.isEmpty, dt > 0 {
            var rx: UInt64 = 0
            var tx: UInt64 = 0
            for (name, c) in counters {
                guard let l = lastNet[name] else { continue }
                rx += UInt64(c.rx &- l.rx)
                tx += UInt64(c.tx &- l.tx)
            }
            netDown = Double(rx) / dt
            netUp = Double(tx) / dt
        }
        lastNet = counters
        lastNetTime = now

        let p = SystemStats.macPower()
        if p != power { power = p }

        if wantsProcesses { sampleProcesses() }
    }

    private var sampling = false

    /// Scanning every pid is expensive: done in the background, results land on the main thread.
    private func sampleProcesses() {
        guard !sampling else { return }
        sampling = true
        var names: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let n = app.localizedName { names[app.processIdentifier] = n }
        }
        let captured = names
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let samples = SystemStats.processes(names: captured)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.sampling = false
                    self?.applyProcesses(samples)
                }
            }
        }
    }

    private func applyProcesses(_ samples: [SystemStats.ProcSample]) {
        let now = Date()
        let dtNs = now.timeIntervalSince(lastProcTime) * 1e9
        let hadPrevious = !lastProc.isEmpty

        var rows: [ProcessRow] = []
        rows.reserveCapacity(samples.count)
        var next: [pid_t: UInt64] = [:]
        for s in samples {
            next[s.pid] = s.cpuNanos
            var pct = 0.0
            if hadPrevious, dtNs > 0, let prev = lastProc[s.pid], s.cpuNanos >= prev {
                pct = Double(s.cpuNanos - prev) / dtNs * 100
            }
            rows.append(ProcessRow(id: s.pid, name: s.name, cpu: pct, memory: s.resident))
        }
        lastProc = next
        lastProcTime = now
        processes = rows
    }

    /// force: SIGKILL, like "Force Quit" in Activity Monitor. Apps go through AppKit first.
    func quit(_ pid: pid_t, force: Bool) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            _ = force ? app.forceTerminate() : app.terminate()
        } else {
            _ = Darwin.kill(pid, force ? SIGKILL : SIGTERM)
        }
        processes.removeAll { $0.id == pid }
    }

    func terminate(_ pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()
        } else {
            _ = Darwin.kill(pid, SIGTERM)
        }
        processes.removeAll { $0.id == pid }
    }
}

// MARK: - Views

struct SystemPill: View {
    @ObservedObject var system: SystemMonitor
    let height: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.green.opacity(0.18))
                Image(systemName: "cpu").font(.system(size: 15, weight: .semibold)).foregroundColor(.green)
            }
            .frame(width: height - 22, height: height - 22)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(system.cpu.rounded()))").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("%").font(.system(size: 11, weight: .semibold))
                }
                Text("RAM \(Fmt.pct(system.memPercent)) · SSD \(Fmt.pct(system.diskPercent))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Sparkline(values: system.cpuHistory)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 64, height: height * 0.42)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .modifier(PanelBackground(radius: height * 0.32))
    }
}

struct TabChip: View {
    let title: String
    let symbol: String
    let active: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: { action() }) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(active ? 0.16 : 0)))
            .foregroundColor(active ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }
}

struct ProcessRowView: View {
    let row: ProcessRow
    let showMemory: Bool
    let onKill: @MainActor () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer()
            Text(showMemory ? Fmt.bytes(row.memory) : String(format: "%.1f%%", row.cpu))
                .font(.system(size: 12, design: .monospaced))
            Button(action: { onKill() }) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(.pink)
            }
            .buttonStyle(.plain)
            .help(L("End process"))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hovering ? 0.1 : 0)))
        .onHover { hovering = $0 }
    }
}

struct ProcessPopover: View {
    @ObservedObject var system: SystemMonitor
    let onClose: @MainActor () -> Void
    @State private var query = ""
    @State private var sortByMemory = false

    private var rows: [ProcessRow] {
        let base = query.isEmpty ? system.processes : system.processes.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let sorted = sortByMemory ? base.sorted { $0.memory > $1.memory } : base.sorted { $0.cpu > $1.cpu }
        return Array(sorted.prefix(40))
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField(L("Search processes"), text: $query).textFieldStyle(.plain).font(.system(size: 14))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))

            HStack(spacing: 6) {
                TabChip(title: "CPU", symbol: "cpu", active: !sortByMemory) { sortByMemory = false }
                TabChip(title: L("Memory"), symbol: "memorychip", active: sortByMemory) { sortByMemory = true }
                Spacer()
                Text("↓\(Fmt.rate(system.netDown))  ↑\(Fmt.rate(system.netUp))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Button(action: { onClose() }) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
            }

            HStack {
                Text("RAM \(Fmt.bytes(system.memUsed)) / \(Fmt.bytes(system.memTotal))")
                Spacer()
                if let p = system.power {
                    Image(systemName: p.isCharging ? "battery.100percent.bolt" : "battery.75percent")
                    Text(Fmt.pct(p.percent))
                }
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { r in
                        ProcessRowView(row: r, showMemory: sortByMemory) { system.terminate(r.id) }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PanelBackground(radius: 18))
        .onExitCommand { onClose() }
    }
}
