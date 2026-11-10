import AppKit
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

    init() {
        UserDefaults.standard.register(defaults: ["caffeineDisplay": true])
        keepDisplayOn = UserDefaults.standard.bool(forKey: "caffeineDisplay")
    }

    func activate(minutes: Int?) {
        selectedMinutes = minutes
        assert()
        isActive = hasAssertion
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
        guard let endsAt else { return L("Indefinitely") }
        return Fmt.until(endsAt)
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
