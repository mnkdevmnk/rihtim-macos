import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import SwiftUI

/// Keep-awake in the spirit of `caffeinate`, via an IOPMAssertion. The system drops
/// the assertion on its own when the app exits, even on a crash.
@MainActor
final class Caffeine: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var endsAt: Date?
    /// Keep the display awake too (`caffeinate -d`); otherwise only system sleep is blocked.
    @Published var keepDisplayOn = true {
        didSet {
            UserDefaults.standard.set(keepDisplayOn, forKey: "caffeineDisplay")
            if isActive { assert() }
        }
    }

    static var durations: [(String, Int?)] {
        [(L("Indefinitely"), nil), (L("30 min"), 30), (L("1 h"), 60), (L("2 h"), 120), (L("4 h"), 240)]
    }

    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false
    private var timer: Timer?

    /// Espresso: Coffee that keeps going with the lid closed / display off (see `LidSleep`).
    @Published var espresso = false {
        didSet {
            guard espresso != oldValue else { return }
            UserDefaults.standard.set(espresso, forKey: "caffeineMilk")
            if espresso { espressoError = nil }
            if espresso && !isActive { activate(minutes: nil) } else { applyEspresso() }
        }
    }
    /// Lid sleep is really disabled right now.
    @Published private(set) var espressoActive = false
    @Published private(set) var espressoError: String?
    /// Espresso turns itself off on battery at or below this level.
    @Published var espressoMinBattery = 15 {
        didSet { UserDefaults.standard.set(espressoMinBattery, forKey: "caffeineMilkMinBattery") }
    }
    private var batteryTimer: Timer?

    init() {
        let d = UserDefaults.standard
        // Espresso was called Milk at first; the stored keys keep that name.
        d.register(defaults: ["caffeineDisplay": true, "caffeineMilkMinBattery": 15])
        keepDisplayOn = d.bool(forKey: "caffeineDisplay")
        espressoMinBattery = d.integer(forKey: "caffeineMilkMinBattery")
        // Set before `espresso`'s didSet can matter: Coffee starts off, so nothing is applied.
        espresso = d.bool(forKey: "caffeineMilk")
        LidSleep.cleanUpAfterCrash()
    }

    /// Called on quit: never leave lid sleep disabled behind.
    func shutdown() {
        if espressoActive { _ = LidSleep.set(disabled: false) }
        espressoActive = false
    }

    func activate(minutes: Int?) {
        selectedMinutes = minutes
        assert()
        isActive = hasAssertion
        applyEspresso()
        endsAt = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        timer?.invalidate()
        timer = nil
        if let endsAt {
            let t = Timer(fire: endsAt, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.deactivate() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
        release()
        isActive = false
        endsAt = nil
        applyEspresso()
    }

    func toggle() { isActive ? deactivate() : activate(minutes: nil) }

    /// Is this the active duration? Used for checkmarks in the menu and the notch.
    func isMode(_ minutes: Int?) -> Bool {
        guard isActive else { return false }
        return minutes == nil ? endsAt == nil : endsAt != nil && selectedMinutes == minutes
    }
    private(set) var selectedMinutes: Int?

    func select(_ minutes: Int?) {
        if isMode(minutes) { deactivate(); return }
        activate(minutes: minutes)
    }

    var shortStatus: String {
        guard isActive else { return L("Off") }
        let base = endsAt.map { Fmt.until($0) } ?? L("Indefinitely")
        return espressoActive ? L("%@ + Espresso", base) : base
    }

    // MARK: Espresso

    private func applyEspresso() {
        let want = isActive && espresso
        if want && !espressoActive {
            if let battery = Self.batteryLevel(), battery <= espressoMinBattery {
                espressoError = L("Battery is at %@, Espresso needs more than %@.", Fmt.pct(battery), Fmt.pct(espressoMinBattery))
                espresso = false
                return
            }
            if !LidSleep.isAllowed && !LidSleep.install() {
                espressoError = L("Espresso needs your password once to allow `pmset disablesleep`.")
                espresso = false
                return
            }
            guard LidSleep.set(disabled: true) else {
                espressoError = L("Couldn't disable lid sleep (pmset failed).")
                espresso = false
                return
            }
            espressoActive = true
            espressoError = nil
            startBatteryWatch()
            Diag.log("espresso: lid sleep disabled")
        } else if !want && espressoActive {
            _ = LidSleep.set(disabled: false)
            espressoActive = false
            batteryTimer?.invalidate()
            batteryTimer = nil
            Diag.log("espresso: lid sleep restored")
        }
    }

    private func startBatteryWatch() {
        batteryTimer?.invalidate()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.espressoActive, let level = Self.batteryLevel(), level <= self.espressoMinBattery else { return }
                self.espressoError = L("Espresso turned off: battery at %@.", Fmt.pct(level))
                self.espresso = false
            }
        }
        RunLoop.main.add(t, forMode: .common)
        batteryTimer = t
    }

    /// Internal battery percentage while running on battery; nil on AC or without a battery.
    static func batteryLevel() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return cur * 100 / max
        }
        return nil
    }

    private func assert() {
        release()
        let type = keepDisplayOn ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep"
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(type as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "Rihtim Coffee: keeping the Mac awake" as CFString,
                                            &id)
        if r == kIOReturnSuccess {
            assertionID = id
            hasAssertion = true
        } else {
            NSLog("Rihtim: couldn't create sleep assertion (\(r))")
        }
    }

    private func release() {
        guard hasAssertion else { return }
        IOPMAssertionRelease(assertionID)
        hasAssertion = false
    }
}

// MARK: - Lid sleep

/// macOS always sleeps on lid close (without an external display), and assertions can't
/// stop that. Only `pmset -a disablesleep 1` can, and it needs root. A one-time admin
/// prompt installs a sudoers rule that allows exactly these two commands without a password.
enum LidSleep {
    static let sudoersPath = "/etc/sudoers.d/rihtim-milk"
    private static let appliedKey = "caffeineMilkApplied"

    /// Is `sudo -n pmset -a disablesleep 1` allowed without a password?
    static var isAllowed: Bool {
        run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]).status == 0
    }

    /// Current `SleepDisabled` value from `pmset -g`.
    static var isDisabled: Bool {
        let out = run("/usr/bin/pmset", ["-g"]).output
        return out.split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return parts.first == "SleepDisabled" && parts.last == "1"
        }
    }

    @discardableResult
    static func set(disabled: Bool) -> Bool {
        let ok = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]).status == 0
        if ok { UserDefaults.standard.set(disabled, forKey: appliedKey) }
        return ok
    }

    /// If Rıhtım crashed while Espresso was on, lid sleep is still disabled: restore it.
    static func cleanUpAfterCrash() {
        guard UserDefaults.standard.bool(forKey: appliedKey) else { return }
        if isDisabled { set(disabled: false) } else { UserDefaults.standard.set(false, forKey: appliedKey) }
        Diag.log("espresso: restored lid sleep left over from the last run")
    }

    /// Asks for the admin password once and installs the sudoers rule (checked with visudo).
    static func install() -> Bool {
        let user = NSUserName()
        guard !user.isEmpty, user.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return false }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let sh = "t=$(/usr/bin/mktemp) && printf '%s\\n' '\(rule)' > \"$t\" && /usr/sbin/visudo -cf \"$t\" && "
            + "/usr/bin/install -m 0440 -o root -g wheel \"$t\" \(sudoersPath); r=$?; /bin/rm -f \"$t\"; exit $r"
        let script = "do shell script \"\(sh.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" "
            + "with prompt \"\(L("Rıhtım wants to allow Espresso to keep the Mac awake with the lid closed."))\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err { Diag.log("espresso: install failed \(err)") }
        return err == nil && isAllowed
    }

    private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Views

struct CaffeineIcon: View {
    let active: Bool
    var size: CGFloat = 15
    var body: some View {
        Image(systemName: active ? "cup.and.saucer.fill" : "cup.and.saucer")
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(active ? .orange : .secondary)
    }
}

/// Pill in the Dock strip: click toggles indefinitely, right-click picks a duration.
struct CaffeinePill: View {
    @ObservedObject var caffeine: Caffeine
    let height: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { _ in
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.orange.opacity(caffeine.isActive ? 0.25 : 0.08))
                    CaffeineIcon(active: caffeine.isActive)
                }
                .frame(width: height - 22, height: height - 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Coffee")).font(.system(size: 12, weight: .semibold))
                    Text(caffeine.shortStatus).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .modifier(PanelBackground(radius: height * 0.32))
        .contextMenu { CaffeineMenuItems(caffeine: caffeine) }
    }
}

struct CaffeineMenuItems: View {
    @ObservedObject var caffeine: Caffeine
    var body: some View {
        ForEach(Caffeine.durations, id: \.0) { title, minutes in
            Button((caffeine.isMode(minutes) ? "✓ " : "") + title) { caffeine.select(minutes) }
        }
        Divider()
        Button((caffeine.keepDisplayOn ? "✓ " : "") + L("Keep the display on too")) { caffeine.keepDisplayOn.toggle() }
        Button((caffeine.espresso ? "✓ " : "") + L("Espresso: keep running with the lid closed")) { caffeine.espresso.toggle() }
        if caffeine.isActive { Button(L("Turn off")) { caffeine.deactivate() } }
    }
}

/// Duration picker used in the notch and the popover.
struct CaffeineChooser: View {
    @ObservedObject var caffeine: Caffeine

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { caffeine.toggle() }) {
                HStack(spacing: 5) {
                    CaffeineIcon(active: caffeine.isActive, size: 13)
                    Text(caffeine.isActive ? L("Coffee: %@", caffeine.shortStatus) : L("Coffee off"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(caffeine.isActive ? .orange : .secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .frame(width: 132, alignment: .leading)

            ForEach(Caffeine.durations, id: \.0) { title, minutes in
                Chip(title: minutes == nil ? "∞" : title, on: caffeine.isMode(minutes)) {
                    caffeine.select(minutes)
                }
            }
            Chip(title: L("Display"), symbol: "display", on: caffeine.keepDisplayOn) { caffeine.keepDisplayOn.toggle() }
            Chip(title: L("Espresso"), symbol: "cup.and.heat.waves.fill", on: caffeine.espresso) { caffeine.espresso.toggle() }
                .help(L("Espresso: keep running with the lid closed"))
        }
    }
}

struct Chip: View {
    let title: String
    var symbol: String?
    let on: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: { action() }) {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(on ? Color.orange.opacity(0.85) : Color.white.opacity(0.1)))
            .foregroundColor(on ? .black : .white)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
