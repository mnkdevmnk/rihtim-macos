import AppKit
import EventKit
import SwiftUI

struct CalEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: NSColor
    let calendarTitle: String
    let link: URL?
}

struct CalInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let source: String
    let color: NSColor
    let isNoise: Bool      // birthdays / public holidays
}

/// Apple Calendar via EventKit. No Google sign-in needed: any account added to
/// Calendar.app (iCloud, Google, Exchange) shows up here.
@MainActor
final class CalendarMonitor: ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var events: [CalEvent] = []
    @Published private(set) var calendars: [CalInfo] = []

    /// Empty means every calendar except birthdays and holidays.
    var selectedIDs: Set<String> = [] { didSet { if oldValue != selectedIDs { reload() } } }
    var openLinks = false

    private let store = EKEventStore()
    private var timer: Timer?
    private var changeToken: NSObjectProtocol?
    private var openedLinks: Set<String> = []

    var next: CalEvent? {
        let now = Date()
        return events.first { !$0.isAllDay && $0.end > now }
    }

    var todayEvents: [CalEvent] {
        let cal = Calendar.current
        return events.filter { cal.isDateInToday($0.start) || ($0.start < Date() && $0.end > Date()) }
    }

    func start() {
        guard timer == nil else { return }
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess {
            access = .granted
            begin()
        } else if status == .notDetermined {
            store.requestFullAccessToEvents { [weak self] ok, _ in
                Task { @MainActor in
                    self?.access = ok ? .granted : .denied
                    if ok { self?.begin() }
                }
            }
        } else {
            access = .denied
        }
    }

    private func begin() {
        guard timer == nil else { return }
        changeToken = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private var tickCount = 0
    private func tick() {
        tickCount += 1
        if tickCount % 8 == 0 { reload() }       // reload every ~2 minutes
        objectWillChange.send()                  // keeps the countdown moving
        guard openLinks, let e = next, let link = e.link, !openedLinks.contains(e.id) else { return }
        let dt = e.start.timeIntervalSinceNow
        if dt <= 0 && dt > -120 {
            openedLinks.insert(e.id)
            NSWorkspace.shared.open(link)
        }
    }

    func reload() {
        guard access == .granted else { return }
        let all = store.calendars(for: .event)
        calendars = all.map { c in
            CalInfo(id: c.calendarIdentifier, title: c.title, source: c.source?.title ?? "",
                    color: c.color ?? .systemBlue, isNoise: Self.isNoise(c))
        }.sorted { ($0.source, $0.title) < ($1.source, $1.title) }

        let chosen = all.filter { selectedIDs.isEmpty ? !Self.isNoise($0) : selectedIDs.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { events = []; return }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Date().addingTimeInterval(36 * 3600)
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: chosen)
        let list = store.events(matching: pred)
            .sorted { $0.startDate < $1.startDate }
            .map { e in
                CalEvent(id: (e.eventIdentifier ?? UUID().uuidString) + "\(e.startDate.timeIntervalSince1970)",
                         title: e.title ?? L("Event"), start: e.startDate, end: e.endDate,
                         isAllDay: e.isAllDay, color: e.calendar.color ?? .systemBlue,
                         calendarTitle: e.calendar.title, link: Self.meetingLink(e))
            }
        if list != events { events = list }
    }

    private static func isNoise(_ c: EKCalendar) -> Bool {
        if c.type == .birthday { return true }
        let t = c.title.lowercased()
        return c.type == .subscription && (t.contains("holiday") || t.contains("tatil") || t.contains("feiertag"))
    }

    private static let linkRegex = try? NSRegularExpression(
        pattern: #"https?://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com|discord\.gg|facetime\.apple\.com)[^\s<>"]*"#,
        options: [.caseInsensitive])

    private static func meetingLink(_ e: EKEvent) -> URL? {
        for text in [e.url?.absoluteString, e.location, e.notes].compactMap({ $0 }) {
            let r = NSRange(text.startIndex..., in: text)
            if let m = linkRegex?.firstMatch(in: text, range: r), let range = Range(m.range, in: text) {
                return URL(string: String(text[range]))
            }
        }
        return e.url
    }
}

// MARK: - Views

enum CalFmt {
    static func countdown(_ e: CalEvent) -> String {
        let now = Date()
        if e.start <= now { return L("now · %@ left", Fmt.until(e.end)) }
        let s = e.start.timeIntervalSinceNow
        if s < 3600 { return L("in %d min", max(Int(s / 60), 1)) }
        if Calendar.current.isDateInToday(e.start) { return Fmt.clock(e.start) }
        return L("tomorrow %@", Fmt.clock(e.start))
    }

    static func urgency(_ e: CalEvent) -> Color {
        let s = e.start.timeIntervalSinceNow
        if s <= 0 { return .green }
        if s < 120 { return .red }
        if s < 600 { return .orange }
        return .secondary
    }
}

struct CalendarPill: View {
    @ObservedObject var calendar: CalendarMonitor
    let height: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 0) {
                Text(Date().formatted(.dateTime.weekday(.abbreviated).locale(L10n.locale)).uppercased(with: L10n.locale))
                    .font(.system(size: 8, weight: .bold)).foregroundColor(.red)
                Text(Date().formatted(.dateTime.day()))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
            }
            .frame(width: height - 22, height: height - 22)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.1)))

            VStack(alignment: .leading, spacing: 1) {
                if let e = calendar.next {
                    Text(e.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(CalFmt.countdown(e)).font(.system(size: 10, weight: .medium))
                        .foregroundColor(CalFmt.urgency(e)).lineLimit(1)
                } else {
                    Text(calendar.access == .denied ? L("No calendar access") : L("No events"))
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(L("Nothing today")).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .modifier(PanelBackground(radius: height * 0.32))
    }
}

struct CalendarPopover: View {
    @ObservedObject var calendar: CalendarMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide).locale(L10n.locale)))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(L("Open Calendar")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.accentColor)
            }
            if calendar.access == .denied {
                Text(L("Calendar access is off. Allow Rıhtım in System Settings › Privacy › Calendars."))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else if calendar.todayEvents.isEmpty {
                Text(L("No events today")).font(.system(size: 12)).foregroundColor(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(calendar.todayEvents) { e in
                        HStack(alignment: .top, spacing: 8) {
                            Capsule().fill(Color(nsColor: e.color)).frame(width: 4, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text(e.isAllDay ? L("All day") : "\(Fmt.clock(e.start)) – \(Fmt.clock(e.end))")
                                    .font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            .opacity(e.end < Date() ? 0.45 : 1)
                            Spacer()
                            if let link = e.link {
                                Button(action: { NSWorkspace.shared.open(link) }) {
                                    Image(systemName: "video.fill").font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .help(L("Join meeting"))
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(PanelBackground())
    }
}
