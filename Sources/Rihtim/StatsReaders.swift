import AppKit
import Darwin
import IOKit

// MARK: - Readers

enum ExtraStats {
    private static func props(_ service: io_object_t) -> [String: Any]? {
        var p: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &p, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return p?.takeRetainedValue() as? [String: Any]
    }

    private static func forEach(_ cls: String, _ body: ([String: Any]) -> Void) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while true {
            let s = IOIteratorNext(it)
            guard s != 0 else { break }
            if let d = props(s) { body(d) }
            IOObjectRelease(s)
        }
    }

    static func gpuUtilization() -> Double? {
        var best: Double?
        forEach("IOAccelerator") { d in
            guard let perf = d["PerformanceStatistics"] as? [String: Any] else { return }
            let v = (perf["Device Utilization %"] as? NSNumber) ?? (perf["GPU Activity(%)"] as? NSNumber)
            if let v { best = max(best ?? 0, v.doubleValue) }
        }
        return best
    }

    static func gpuName() -> String? {
        var name: String?
        forEach("IOAccelerator") { d in if name == nil { name = d["model"] as? String } }
        return name
    }

    /// Total bytes read / written across all disks.
    static func diskIO() -> (read: UInt64, write: UInt64) {
        var r: UInt64 = 0, w: UInt64 = 0
        forEach("IOBlockStorageDriver") { d in
            guard let st = d["Statistics"] as? [String: Any] else { return }
            r += (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            w += (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (r, w)
    }

    struct DiskSpace: Sendable { let total: Int64; let free: Int64 }
    static func diskSpace() -> DiskSpace? {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskSpace(total: Int64(total), free: free)
    }

    struct BatteryDetail: Equatable, Sendable {
        var cycles: Int?
        var healthPercent: Int?
        var temperature: Double?
        var minutesRemaining: Int?
        var watts: Double?            // + charging, - discharging
        var adapterWatts: Int?
        var designCapacity: Int?
        var maxCapacity: Int?
    }

    static func battery() -> BatteryDetail? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard s != 0 else { return nil }
        defer { IOObjectRelease(s) }
        guard let d = props(s) else { return nil }
        func int(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        var b = BatteryDetail()
        b.cycles = int("CycleCount")
        b.designCapacity = int("DesignCapacity")
        b.maxCapacity = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity")
        if let m = b.maxCapacity, let des = b.designCapacity, des > 0 { b.healthPercent = min(100, m * 100 / des) }
        if let t = int("Temperature") { b.temperature = Double(t) / 100 }
        if let t = int("TimeRemaining"), t > 0, t < 6000 { b.minutesRemaining = t }
        if let a = int("InstantAmperage") ?? int("Amperage"), let v = int("Voltage") {
            let amps = Double(Int16(truncatingIfNeeded: a))           // may come back as signed 16-bit
            b.watts = amps * Double(v) / 1_000_000
        }
        if let ad = d["AdapterDetails"] as? [String: Any] { b.adapterWatts = (ad["Watts"] as? NSNumber)?.intValue }
        return b
    }

    static func memoryPressure() -> Int {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &size, nil, 0)
        return Int(v)      // 1 normal, 2 warning, 4 critical
    }

    static func swapUsed() -> UInt64 {
        var x = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &x, &size, nil, 0) == 0 else { return 0 }
        return x.xsu_used
    }

    static func localIP() -> (iface: String, ip: String)? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            let ifa = p.pointee
            let name = String(cString: ifa.ifa_name)
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, (ifa.ifa_flags & UInt32(IFF_UP)) != 0,
               name.hasPrefix("en") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return (name, String(cString: host))
                }
            }
            cursor = ifa.ifa_next
        }
        return nil
    }

    static func loadAverage() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? l : []
    }
}


// MARK: - CPU cores

struct CoreTicks: Sendable { var user: UInt64; var system: UInt64; var idle: UInt64; var nice: UInt64
    var total: UInt64 { user + system + idle + nice } }

enum CPUInfo {
    private static func sysStr(_ n: String) -> String {
        var s = 0
        sysctlbyname(n, nil, &s, nil, 0)
        var b = [CChar](repeating: 0, count: max(s, 1))
        sysctlbyname(n, &b, &s, nil, 0)
        return String(cString: b)
    }
    private static func sysInt(_ n: String) -> Int {
        var v: Int32 = 0
        var s = MemoryLayout<Int32>.size
        return sysctlbyname(n, &v, &s, nil, 0) == 0 ? Int(v) : 0
    }

    static let brand: String = { let b = sysStr("machdep.cpu.brand_string"); return b.isEmpty ? "Mac" : b }()

    /// (name, count). On Apple Silicon level 0 is the fast cluster (Performance/Super), 1 is efficiency.
    static let levels: [(name: String, count: Int)] = {
        let n = sysInt("hw.nperflevels")
        return (0..<max(n, 0)).map { (sysStr("hw.perflevel\($0).name"), sysInt("hw.perflevel\($0).logicalcpu")) }
    }()

    static var efficiencyCount: Int { levels.first { $0.name.lowercased().contains("eff") }?.count ?? 0 }
    static var performanceName: String {
        let n = levels.first { !$0.name.lowercased().contains("eff") }?.name ?? "Performance"
        return n.lowercased().contains("super") ? L("Super") : L("Performance")
    }
    static var summary: String {
        levels.map { "\($0.count) " + ($0.name.lowercased().contains("eff") ? L("efficiency") : performanceName.lowercased(with: L10n.locale)) }
            .joined(separator: " · ")
    }

    /// Core order: on Apple Silicon the efficiency cores come first.
    static func label(_ i: Int) -> (title: String, efficiency: Bool) {
        let e = efficiencyCount
        if i < e { return (L("Efficiency core %d", i + 1), true) }
        return (L("%@ core %d", performanceName, i - e + 1), false)
    }

    static func coreTicks() -> [CoreTicks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var n: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &n) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(n) * vm_size_t(MemoryLayout<integer_t>.size)) }
        let m = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { c in
            CoreTicks(user: UInt64(UInt32(bitPattern: info[c * m + Int(CPU_STATE_USER)])),
                      system: UInt64(UInt32(bitPattern: info[c * m + Int(CPU_STATE_SYSTEM)])),
                      idle: UInt64(UInt32(bitPattern: info[c * m + Int(CPU_STATE_IDLE)])),
                      nice: UInt64(UInt32(bitPattern: info[c * m + Int(CPU_STATE_NICE)])))
        }
    }
}

// MARK: - RAM breakdown

struct RAMBreakdown: Equatable, Sendable {
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var total: UInt64 = 1
    var used: UInt64 { min(app + wired + compressed, total) }
    var free: UInt64 { total > used ? total - used : 0 }

    static func read() -> RAMBreakdown {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        var b = RAMBreakdown(total: ProcessInfo.processInfo.physicalMemory)
        guard r == KERN_SUCCESS else { return b }
        let page = UInt64(vm_kernel_page_size)
        let inner = UInt64(stats.internal_page_count), purgeable = UInt64(stats.purgeable_count)
        b.app = (inner > purgeable ? inner - purgeable : 0) * page
        b.wired = UInt64(stats.wire_count) * page
        b.compressed = UInt64(stats.compressor_page_count) * page
        return b
    }
}

// MARK: - Temperature sensors (Apple Silicon, via HID, no entitlement needed)

struct TempSensor: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let group: String
    let value: Double
}

@_silgen_name("IOHIDEventSystemClientCreate") private func hidClientCreate(_ a: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching") private func hidClientSetMatching(_ c: AnyObject, _ m: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") private func hidClientCopyServices(_ c: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty") private func hidServiceCopyProperty(_ s: AnyObject, _ k: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent") private func hidServiceCopyEvent(_ s: AnyObject, _ t: Int64, _ a: Int32, _ b: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue") private func hidEventGetFloat(_ e: AnyObject, _ f: Int32) -> Double

enum HIDTemps {
    nonisolated(unsafe) private static var client: AnyObject? = {
        guard let c = hidClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        _ = hidClientSetMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        return c
    }()

    static func read() -> [TempSensor] {
        guard let client, let services = hidClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [] }
        var out: [TempSensor] = []
        var seen: [String: Int] = [:]
        for s in services {
            let raw = (hidServiceCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String) ?? L("Sensor")
            guard let e = hidServiceCopyEvent(s, 15, 0, 0)?.takeRetainedValue() else { continue }
            let v = hidEventGetFloat(e, 15 << 16)
            let low = raw.lowercased()
            guard v > -5, v < 130, !low.contains("tcal") else { continue }
            let (group, name) = friendly(raw)
            let n = (seen[name] ?? 0) + 1
            seen[name] = n
            let title = n > 1 ? "\(name) (\(n))" : name
            out.append(TempSensor(id: title, name: title, group: group, value: v))
        }
        return out.sorted { $0.group != $1.group ? $0.group < $1.group : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func friendly(_ raw: String) -> (String, String) {
        let low = raw.lowercased()
        let num = raw.split(separator: " ").last.map { String($0).filter(\.isNumber) } ?? ""
        let second = low.hasPrefix("pmu2")
        if low.contains("tdie") { return (L("SoC (CPU · GPU)"), L("Die %@", "\(second ? "B" : "A")\(num)")) }
        if low.contains("tdev") { return (L("Power management"), L("Device %@", "\(second ? "B" : "A")\(num)")) }
        if low.contains("nand") { return ("SSD", "NAND") }
        if low.contains("battery") || low.contains("gas gauge") { return (L("Battery"), L("Battery cell")) }
        return (L("Other"), raw)
    }
}
