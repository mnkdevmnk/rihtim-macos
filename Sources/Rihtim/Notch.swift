import AppKit
import Combine
import SwiftUI

/// Black island wrapped around the notch. Closed, it only grows sideways as far as its
/// content needs (album art, Coffee, CPU, Claude…) and shows short banners (charging,
/// device connected, eye break). Hovering opens it with tabs; dragging a file opens the shelf.
/// Screens without a notch (external display, lid closed) get a fake one in the middle of the menu bar.
struct NotchBanner: Equatable {
    let symbol: String
    let text: String
    let color: Color
    /// 0…1; when set, a level bar is drawn next to the text (brightness HUD).
    var progress: Double? = nil
}

/// Cards on the Home tab of the open notch. Each one picked makes the notch wider.
enum HomeWidget: String, CaseIterable, Identifiable {
    case music, system, usage, weather, calendar, batteries, coffee
    var id: String { rawValue }
    var title: String {
        switch self {
        case .music: return L("Music")
        case .system: return L("System (CPU · RAM · network)")
        case .usage: return L("Claude usage")
        case .weather: return L("Weather")
        case .calendar: return L("Next event")
        case .batteries: return L("Device batteries")
        case .coffee: return L("Coffee row (bottom)")
        }
    }
    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .system: return "cpu"
        case .usage: return "sparkle"
        case .weather: return "cloud.sun"
        case .calendar: return "calendar"
        case .batteries: return "battery.75percent"
        case .coffee: return "cup.and.saucer"
        }
    }
    /// Card width (the coffee row spans the full width, so 0).
    var width: CGFloat {
        switch self {
        case .music: return 250
        case .system: return 150
        case .usage: return 220
        case .weather: return 160
        case .calendar: return 190
        case .batteries: return 150
        case .coffee: return 0
        }
    }
}

/// Things that can sit on either side of the closed notch.
enum WingItem: String, CaseIterable, Identifiable {
    case music, coffee, claude, cpu, ram, battery, weather, shelf, time
    var id: String { rawValue }
    var title: String {
        switch self {
        case .music: return L("Album art")
        case .coffee: return L("Coffee")
        case .claude: return L("Claude (usage + waiting sessions)")
        case .cpu: return "CPU"
        case .ram: return "RAM"
        case .battery: return L("Mac battery")
        case .weather: return L("Weather")
        case .shelf: return L("Files on the shelf")
        case .time: return L("Clock")
        }
    }
}

struct NotchConfig: Equatable {
    var left: [WingItem] = [.music, .coffee]
    var right: [WingItem] = [.claude, .cpu]
    var tabs: [NotchTab] = NotchTab.allCases
    var expandedWidth: CGFloat = 660
    var softness: CGFloat = 1          // corner radius multiplier
    var hoverDelay: Double = 0.12
    var home: [HomeWidget] = [.music, .system, .usage, .coffee]
    /// Is the open width derived from the chosen cards?
    var autoSize = true
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var expanded = false
    @Published var tab: NotchTab = .home
    @Published var banner: NotchBanner?
    @Published var notchWidth: CGFloat = 200
    @Published var notchHeight: CGFloat = 32
    @Published var config = NotchConfig()
    /// Measured content widths of the wings.
    @Published var leftContent: CGFloat = 0
    @Published var rightContent: CGFloat = 0
    /// Screen info, for the preview and auto sizing.
    @Published var screenWidth: CGFloat = 1470
    @Published var hasNotch = true

    private var cards: [HomeWidget] { config.home.filter { $0 != .coffee } }

    /// Open width; when automatic, based on the Home tab cards.
    var expandedWidth: CGFloat {
        let maxW = max(screenWidth - 40, 400)
        guard config.autoSize else { return min(config.expandedWidth, maxW) }
        let c = cards
        var w = c.reduce(0) { $0 + $1.width } + CGFloat(max(c.count - 1, 0)) * 14 + 40
        if config.home.contains(.coffee) { w = max(w, 560) }
        // Leave room for the tab row and the shoulder buttons.
        w = max(w, notchWidth + 2 * 130, CGFloat(config.tabs.count) * 34 + 110)
        return min(max(w, 440), maxW)
    }

    /// Height below the notch: tab row + the tallest tab content.
    var bodyHeight: CGFloat {
        let tabBar: CGFloat = config.tabs.count > 1 ? NotchLayout.tabBarHeight + 8 : 0
        var home: CGFloat = cards.isEmpty ? 0 : 112
        if config.home.contains(.coffee) { home += cards.isEmpty ? 30 : 42 }
        let others: CGFloat = config.tabs.contains(where: { $0 != .home }) ? 150 : 0
        let content = max(config.tabs.contains(.home) ? home : 0, others, 60)
        return tabBar + content + 26
    }

    /// Width added to each side of the closed notch (kept symmetric).
    var wing: CGFloat {
        if let banner { return banner.progress != nil ? NotchLayout.bannerWing + 30 : NotchLayout.bannerWing }
        let c = max(leftContent, rightContent)
        return c < 1 ? 0 : c + NotchLayout.wingPadding * 2
    }
    var ear: CGFloat { (expanded ? 14 : 7) * config.softness }
}

enum NotchLayout {
    static let wingPadding: CGFloat = 9
    static let bannerWing: CGFloat = 130
    static let tabBarHeight: CGFloat = 28
    static let windowHeightExtra: CGFloat = 300   // tallest open state + room for the shadow
    static let maxExpandedWidth: CGFloat = 1400
}

/// Island shape: top corners flare concavely into the menu bar, bottom corners are rounded.
struct NotchShape: Shape {
    var ear: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottom) }
        set { ear = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let e = min(ear, r.width / 4)
        let b = max(0, min(bottom, r.height - e, (r.width - 2 * e) / 2))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        // left shoulder: soft S-curve from the outside in
        p.addCurve(to: CGPoint(x: r.minX + e, y: r.minY + e),
                   control1: CGPoint(x: r.minX + e * 0.62, y: r.minY),
                   control2: CGPoint(x: r.minX + e, y: r.minY + e * 0.38))
        p.addLine(to: CGPoint(x: r.minX + e, y: r.maxY - b))
        // bottom-left corner (continuous curve)
        p.addCurve(to: CGPoint(x: r.minX + e + b, y: r.maxY),
                   control1: CGPoint(x: r.minX + e, y: r.maxY - b * 0.45),
                   control2: CGPoint(x: r.minX + e + b * 0.45, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e - b, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.maxX - e, y: r.maxY - b),
                   control1: CGPoint(x: r.maxX - e - b * 0.45, y: r.maxY),
                   control2: CGPoint(x: r.maxX - e, y: r.maxY - b * 0.45))
        p.addLine(to: CGPoint(x: r.maxX - e, y: r.minY + e))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY),
                   control1: CGPoint(x: r.maxX - e, y: r.minY + e * 0.38),
                   control2: CGPoint(x: r.maxX - e * 0.62, y: r.minY))
        p.closeSubpath()
        return p
    }
}

private struct LeftWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct RightWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var music: MusicController
    @ObservedObject var system: SystemMonitor
    @ObservedObject var batteries: BatteryMonitor
    @ObservedObject var caffeine: Caffeine
    @ObservedObject var usage: ClaudeUsage
    @ObservedObject var weather: WeatherMonitor
    @ObservedObject var calendar: CalendarMonitor
    @ObservedObject var shelf: NotchShelf
    @ObservedObject var clipboard: ClipboardHistory
    @ObservedObject var sessions: ClaudeSessions
    @ObservedObject var brightness: BrightnessBoost
    var openSettings: @MainActor () -> Void = {}

    private var bodyWidth: CGFloat {
        model.expanded ? model.expandedWidth : model.notchWidth + model.wing * 2
    }
    private var height: CGFloat {
        model.expanded ? model.notchHeight + model.bodyHeight : model.notchHeight
    }
    private var bottomRadius: CGFloat {
        (model.expanded ? 30 : min(model.notchHeight * 0.42, 13)) * model.config.softness
    }

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(ear: model.ear, bottom: bottomRadius)
                .fill(Color.black)
                .frame(width: bodyWidth + model.ear * 2, height: height)
                .shadow(color: .black.opacity(model.expanded ? 0.5 : 0), radius: 18, y: 8)

            VStack(spacing: 0) {
                topRow.frame(height: model.notchHeight)
                if model.expanded {
                    VStack(spacing: 8) {
                        if model.config.tabs.count > 1 { tabBar }
                        tabContent
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(height: model.bodyHeight - 24)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            }
            .frame(width: bodyWidth, height: height, alignment: .top)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundColor(.white)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: model.expanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.wing)
        .onPreferenceChange(LeftWidthKey.self) { w in Task { @MainActor in if abs(model.leftContent - w) > 0.5 { model.leftContent = w } } }
        .onPreferenceChange(RightWidthKey.self) { w in Task { @MainActor in if abs(model.rightContent - w) > 0.5 { model.rightContent = w } } }
    }

    // MARK: closed notch row

    private var topRow: some View {
        HStack(spacing: 0) {
            Group {
                if model.expanded { expandedLeft } else { collapsedSide(left: true) }
            }
            .frame(width: model.expanded ? (bodyWidth - model.notchWidth) / 2 - 20 : model.wing, alignment: .leading)
            Spacer(minLength: 0)
            Group {
                if model.expanded { expandedRight } else { collapsedSide(left: false) }
            }
            .frame(width: model.expanded ? (bodyWidth - model.notchWidth) / 2 - 20 : model.wing, alignment: .trailing)
        }
        .padding(.horizontal, model.expanded ? 20 : 0)
    }

    @ViewBuilder
    private func collapsedSide(left: Bool) -> some View {
        Group {
            if let b = model.banner {
                if left {
                    Image(systemName: b.symbol).font(.system(size: 13, weight: .semibold)).foregroundColor(b.color)
                } else {
                    HStack(spacing: 6) {
                        if let p = b.progress {
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.18))
                                Capsule().fill(LinearGradient(colors: [b.color.opacity(0.75), b.color], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: 64 * max(0.04, min(1, p)))
                            }
                            .frame(width: 64, height: 5)
                        }
                        Text(b.text).font(.system(size: 12, weight: .semibold).monospacedDigit()).lineLimit(1)
                    }
                }
            } else {
                wingItems(left ? model.config.left : model.config.right)
                    .fixedSize()
                    .background(GeometryReader { g in
                        if left {
                            Color.clear.preference(key: LeftWidthKey.self, value: g.size.width)
                        } else {
                            Color.clear.preference(key: RightWidthKey.self, value: g.size.width)
                        }
                    })
            }
        }
        .padding(.horizontal, NotchLayout.wingPadding)
        .frame(maxWidth: .infinity, alignment: left ? .leading : .trailing)
    }

    private func available(_ i: WingItem) -> Bool {
        switch i {
        case .music: return music.hasTrack
        case .claude: return usage.fiveHour != nil || sessions.waitingCount > 0 || sessions.workingCount > 0
        case .shelf: return !shelf.files.isEmpty
        case .weather: return weather.now != nil
        case .battery: return system.power != nil
        default: return true
        }
    }

    private func wingItems(_ items: [WingItem]) -> some View {
        HStack(spacing: 7) {
            ForEach(items.filter(available)) { item in wingItem(item) }
        }
    }

    @ViewBuilder
    private func wingItem(_ i: WingItem) -> some View {
        switch i {
        case .music:
            Artwork(image: music.artwork, size: model.notchHeight - 12)
        case .coffee:
            CaffeineIcon(active: caffeine.isActive, size: 12)
        case .claude:
            HStack(spacing: 3) {
                ClaudeMark(size: 10)
                if sessions.waitingCount > 0 {
                    Text("\(sessions.waitingCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange))
                        .foregroundColor(.black)
                } else if sessions.workingCount > 0 {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                }
                if let five = usage.fiveHour {
                    Text(Fmt.pct(Int(five.percent.rounded())))
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundColor(UsageMeter.color(five.percent))
                }
            }
        case .cpu:
            miniStat("cpu", "\(Int(system.cpu.rounded()))%", template: "100%")
        case .ram:
            miniStat("memorychip", "\(system.memPercent)%", template: "100%")
        case .battery:
            if let p = system.power {
                miniStat(p.isCharging ? "bolt.fill" : "battery.75percent", "\(p.percent)%", template: "100%")
            }
        case .weather:
            if let n = weather.now {
                HStack(spacing: 3) {
                    Image(systemName: WeatherCode.symbol(n.code, day: n.isDay)).symbolRenderingMode(.multicolor)
                        .font(.system(size: 11))
                    Text("\(Int(n.temp.rounded()))°").font(.system(size: 12, weight: .semibold, design: .rounded))
                }
            }
        case .shelf:
            miniStat("tray.full.fill", "\(shelf.files.count)", template: "99")
        case .time:
            Text(Date.now, style: .time).font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
    }

    /// Reserves the widest possible text so the width doesn't jump as the value changes.
    private func miniStat(_ symbol: String, _ text: String, template: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            ZStack(alignment: .trailing) {
                Text(template).hidden()
                Text(text)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
        }
    }

    // MARK: open header

    /// Left shoulder of the notch: small buttons only, so nothing ends up under the camera.
    private var expandedLeft: some View {
        HStack(spacing: 2) {
            headerButton(caffeine.isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                         on: caffeine.isActive, tint: .orange,
                         help: caffeine.isActive ? L("Coffee on: %@. Click to turn off, right-click for a duration.", caffeine.shortStatus) : L("Coffee: keep the Mac awake. Right-click for a duration.")) {
                caffeine.toggle()
            }
            .contextMenu { CaffeineMenuItems(caffeine: caffeine) }
            headerButton("gearshape.fill", on: false, tint: .white, help: L("Rıhtım settings")) { openSettings() }
            if BrightnessBoost.isSupported {
                headerButton(brightness.isActive ? "sun.max.fill" : "sun.max", on: brightness.isActive, tint: .yellow,
                             help: brightness.isActive ? L("Extra brightness on (%@). Click to turn off.", Fmt.pct(Int((brightness.factor - 1) * 100))) : L("Extra brightness (EDR)")) {
                    brightness.toggle()
                }
            }
        }
    }

    private func headerButton(_ symbol: String, on: Bool, tint: Color, help: String,
                              action: @escaping @MainActor () -> Void) -> some View {
        Button(action: { action() }) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(on ? tint : .white.opacity(0.75))
                .frame(width: 28, height: 22)
                .background(Capsule().fill(on ? tint.opacity(0.22) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Tabs sit centered below the camera housing.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(model.config.tabs) { t in
                Button(action: { model.tab = t }) {
                    HStack(spacing: 4) {
                        Image(systemName: t.symbol).font(.system(size: 10.5, weight: .semibold))
                        if model.tab == t { Text(t.title).font(.system(size: 11, weight: .semibold)) }
                    }
                    .padding(.horizontal, model.tab == t ? 10 : 8)
                    .frame(height: 22)
                    .background(Capsule().fill(model.tab == t ? Color.white.opacity(0.18) : .clear))
                    .foregroundColor(model.tab == t ? .white : .secondary)
                    .overlay(alignment: .topTrailing) {
                        if t == .claude && sessions.waitingCount > 0 {
                            Circle().fill(Color.orange).frame(width: 6, height: 6).offset(x: -2, y: 2)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(t.title)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .frame(height: NotchLayout.tabBarHeight)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.tab)
    }

    private var expandedRight: some View {
        HStack(spacing: 10) {
            if let n = weather.now {
                HStack(spacing: 3) {
                    Image(systemName: WeatherCode.symbol(n.code, day: n.isDay)).symbolRenderingMode(.multicolor)
                    Text("\(Int(n.temp.rounded()))°")
                }
            }
            if let mac = batteries.devices.first(where: { $0.kind == .mac }) {
                HStack(spacing: 3) {
                    Image(systemName: mac.isCharging ? "battery.100.bolt" : "battery.75percent")
                    Text(mac.mainPercent.map { "\($0)%" } ?? "–")
                }
            }
            Text(Date.now, style: .time)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.secondary)
    }

    // MARK: tabs

    @ViewBuilder
    private var tabContent: some View {
        switch model.tab {
        case .home: homeBody
        case .claude: ClaudeSessionsView(sessions: sessions, usage: usage)
        case .shelf: ShelfView(shelf: shelf)
        case .clipboard: ClipboardView(clipboard: clipboard)
        case .notes: NotesView()
        case .calendar: CalendarGridView(calendar: calendar)
        case .mirror: MirrorView().frame(maxWidth: 300).frame(maxWidth: .infinity)
        }
    }

    private var homeBody: some View {
        let cards = model.config.home.filter { $0 != .coffee }
        return VStack(spacing: 12) {
            if !cards.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(cards) { w in
                        homeCard(w)
                            .frame(width: w.width, height: 112, alignment: .topLeading)
                            .clipped()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 112)
            }
            if model.config.home.contains(.coffee) {
                HStack(spacing: 10) {
                    CaffeineChooser(caffeine: caffeine)
                    Spacer(minLength: 0)
                }
            }
            if cards.isEmpty && !model.config.home.contains(.coffee) {
                Text(L("Add cards to the Home tab in Settings › Notch")).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func homeCard(_ w: HomeWidget) -> some View {
        switch w {
        case .music: musicCard
        case .system: systemCard
        case .usage: UsageDetail(usage: usage, showsHeader: true)
        case .weather: weatherCard
        case .calendar: calendarCard
        case .batteries: batteryCard
        case .coffee: EmptyView()
        }
    }

    private var weatherCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let n = weather.now {
                HStack(spacing: 8) {
                    Image(systemName: WeatherCode.symbol(n.code, day: n.isDay)).symbolRenderingMode(.multicolor)
                        .font(.system(size: 26))
                    Text("\(Int(n.temp.rounded()))°").font(.system(size: 28, weight: .bold, design: .rounded))
                }
                Text(WeatherCode.text(n.code)).font(.system(size: 12, weight: .medium))
                Text(L("Feels like %d°", Int(n.feels.rounded())) + " · \(weather.place.name)").font(.system(size: 10)).foregroundColor(.secondary)
                if let d = weather.day, let hi = d.high, let lo = d.low {
                    Text("↑\(Int(hi.rounded()))°  ↓\(Int(lo.rounded()))°").font(.system(size: 10)).foregroundColor(.secondary)
                }
            } else {
                Text(L("Loading weather…")).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
    }

    private var calendarCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.system(size: 11, weight: .semibold)).foregroundColor(.red)
            if let e = calendar.next {
                Text(e.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Text(CalFmt.countdown(e)).font(.system(size: 11, weight: .medium)).foregroundColor(CalFmt.urgency(e))
            } else if calendar.access != .granted {
                Button(L("Allow calendar access")) { calendar.start() }.buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.accentColor)
            } else {
                Text(L("No events today")).font(.system(size: 12)).foregroundColor(.secondary)
            }
            Text(L("%d events today", calendar.todayEvents.count)).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private var batteryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(batteries.devices.prefix(4)) { d in
                HStack(spacing: 6) {
                    Image(systemName: d.symbol).font(.system(size: 11)).frame(width: 16)
                    LevelBar(value: Double(d.mainPercent ?? 0) / 100).frame(width: 50, height: 5)
                    Text(d.mainPercent.map { "\($0)%" } ?? "–").font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    if d.isCharging { Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundColor(.green) }
                }
            }
            if batteries.devices.isEmpty { Text(L("No devices")).font(.system(size: 11)).foregroundColor(.secondary) }
        }
    }

    @ViewBuilder
    private var musicCard: some View {
        if music.hasTrack {
            HStack(spacing: 10) {
                Artwork(image: music.artwork, size: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text(music.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(music.artist).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                    HStack(spacing: 0) {
                        PillButton(symbol: "backward.fill") { music.previous() }
                        PillButton(symbol: music.isPlaying ? "pause.fill" : "play.fill", size: 18) { music.playPause() }
                        PillButton(symbol: "forward.fill") { music.next() }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08))
                    Image(systemName: "music.note").font(.system(size: 24)).foregroundColor(.secondary)
                }
                .frame(width: 72, height: 72)
                Text(L("Nothing playing")).font(.system(size: 12)).foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private var systemCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int(system.cpu.rounded()))").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("% CPU").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            }
            Sparkline(values: system.cpuHistory)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(height: 26)
            Text("RAM \(Fmt.pct(system.memPercent)) · SSD \(Fmt.pct(system.diskPercent))")
                .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            Text("↓ \(Fmt.rate(system.netDown))  ↑ \(Fmt.rate(system.netUp))")
                .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
        }
    }
}

@MainActor
final class NotchController {
    var isEnabled = true { didSet { isEnabled ? show() : hide() } }
    var bannersEnabled = true
    var eyeBreakEnabled = false { didSet { if oldValue != eyeBreakEnabled { scheduleEyeBreak() } } }
    var config: NotchConfig {
        get { model.config }
        set {
            guard newValue != model.config else { return }
            model.config = newValue
            if !newValue.tabs.contains(model.tab) { model.tab = newValue.tabs.first ?? .home }
            layout()
        }
    }

    let model = NotchModel()
    let shelf = NotchShelf()
    let clipboard = ClipboardHistory()
    let sessions = ClaudeSessions()
    var openSettings: @MainActor () -> Void = {}
    private let panel: KeyPanel
    private let system: SystemMonitor
    private let batteries: BatteryMonitor
    private let caffeine: Caffeine
    private var timer: Timer?
    private var bannerTimer: Timer?
    private var eyeTimer: Timer?
    private var screenObserver: Any?
    private var mouseMonitors: [Any] = []
    private var subs: Set<AnyCancellable> = []
    private var enterAt: Date?
    private var leaveAt: Date?
    private var dragChangeCount = 0
    private var draggingFile = false

    init(music: MusicController, system: SystemMonitor, batteries: BatteryMonitor,
         caffeine: Caffeine, usage: ClaudeUsage, weather: WeatherMonitor, calendar: CalendarMonitor,
         brightness: BrightnessBoost) {
        self.system = system
        self.batteries = batteries
        self.caffeine = caffeine
        panel = KeyPanel()
        // Stay above the menu bar.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = NotchView(model: model, music: music, system: system, batteries: batteries,
                             caffeine: caffeine, usage: usage, weather: weather, calendar: calendar,
                             shelf: shelf, clipboard: clipboard, sessions: sessions, brightness: brightness,
                             openSettings: { [weak self] in self?.setExpanded(false); self?.openSettings() })
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        panel.contentView = host

        // ⌘ + brightness key changes get a HUD in the notch, Sapphire style.
        brightness.onLevelChange = { [weak self] f, on in
            let pct = Int((f * 100).rounded())
            self?.flash(NotchBanner(symbol: on ? "sun.max.fill" : "sun.min", text: on ? "\(pct)%" : "Normal",
                                    color: .orange, progress: on ? 1 : 0),
                        seconds: 1.6, force: true)
        }
        brightness.installKeys()
    }

    func start() {
        guard timer == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Catch file drags: when the drag pasteboard changes and holds files, open the shelf.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.globalMouseDown() }
        }) { mouseMonitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.globalDragged() }
        }) { mouseMonitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.draggingFile = false }
        }) { mouseMonitors.append(m) }

        clipboard.start()
        sessions.start()
        observeEvents()
        if isEnabled { show() }
    }

    private func show() {
        guard timer != nil else { return }
        layout()
        panel.orderFrontRegardless()
    }

    private func hide() {
        setExpanded(false)
        panel.orderOut(nil)
    }

    /// The screen with a notch if there is one, otherwise the main screen.
    private var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func layout() {
        guard let screen = targetScreen else { return }
        let f = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notchWidth = max(f.width - left.width - right.width, 120)
            model.notchHeight = screen.safeAreaInsets.top
            model.hasNotch = true
        } else {
            // No notch (older Mac / external display): draw a solid black one, menu bar height.
            model.notchWidth = 180
            model.notchHeight = max(f.maxY - screen.visibleFrame.maxY, 24)
            model.hasNotch = false
        }
        model.screenWidth = f.width
        let h = model.notchHeight + NotchLayout.windowHeightExtra
        let frame = CGRect(x: f.minX, y: f.maxY - h, width: f.width, height: h).integral
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private var hotRect: CGRect {
        let f = panel.frame
        let w = model.notchWidth + max(model.wing, 24) * 2
        return CGRect(x: f.midX - w / 2, y: f.maxY - model.notchHeight, width: w, height: model.notchHeight + 4)
    }

    private var expandedRect: CGRect {
        let f = panel.frame
        let w = model.expandedWidth
        let h = model.notchHeight + model.bodyHeight
        return CGRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h + 4).insetBy(dx: -10, dy: -10)
    }

    private func tick() {
        guard isEnabled, panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let now = Date()

        if !model.expanded {
            // While dragging a file, getting close below the notch is enough.
            let hot = draggingFile ? hotRect.insetBy(dx: -40, dy: -40) : hotRect
            if hot.contains(mouse) {
                if enterAt == nil { enterAt = now }
                if draggingFile || now.timeIntervalSince(enterAt!) > model.config.hoverDelay {
                    if draggingFile, model.config.tabs.contains(.shelf) { model.tab = .shelf }
                    setExpanded(true)
                }
            } else {
                enterAt = nil
            }
        } else {
            if expandedRect.contains(mouse) {
                leaveAt = nil
            } else {
                // Don't close when the pointer drifts while typing a note; a click outside closes it.
                if panel.isKeyWindow && model.tab == .notes { return }
                if leaveAt == nil { leaveAt = now }
                if now.timeIntervalSince(leaveAt!) > 0.3 { setExpanded(false) }
            }
        }
    }

    private func globalMouseDown() {
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        draggingFile = false
        if model.expanded && !expandedRect.contains(NSEvent.mouseLocation) { setExpanded(false) }
    }

    private func globalDragged() {
        guard !draggingFile else { return }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragChangeCount,
              pb.types?.contains(.fileURL) == true else { return }
        draggingFile = true
    }

    private func setExpanded(_ e: Bool) {
        enterAt = nil
        leaveAt = nil
        guard model.expanded != e else { return }
        model.expanded = e
        sessions.setFast(e)
        // While closed, let clicks pass through to the menu bar.
        panel.ignoresMouseEvents = !e
        if !e {
            if model.tab == .mirror { model.tab = model.config.tabs.first ?? .home }
            if panel.isKeyWindow { panel.resignKey() }
        }
    }

    // MARK: banners

    /// Volume / brightness HUD, replacing the macOS one.
    func showHUD(_ kind: HUDKind, level: Double, label: String, muted: Bool) {
        let pct = Int((level * 100).rounded())
        switch kind {
        case .volume:
            let symbol = muted || level <= 0 ? "speaker.slash.fill"
                : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            flash(NotchBanner(symbol: symbol, text: muted ? L("Muted") : "\(pct)%", color: .white,
                              progress: muted ? 0 : level), seconds: 1.4, force: true)
        case .brightness:
            let extra = level > 1.001
            flash(NotchBanner(symbol: extra ? "sun.max.fill" : (level < 0.4 ? "sun.min.fill" : "sun.max"),
                              text: label.isEmpty ? "\(pct)%" : "\(pct)% · \(label)",
                              color: extra ? .orange : .yellow,
                              progress: extra ? 1 : level), seconds: 1.4, force: true)
        case .keyboard:
            flash(NotchBanner(symbol: level <= 0.001 ? "light.min" : "light.max",
                              text: "\(pct)%", color: .white, progress: level), seconds: 1.4, force: true)
        }
    }

    func flash(_ banner: NotchBanner, seconds: TimeInterval = 3, force: Bool = false) {
        guard (bannersEnabled || force), isEnabled else { return }
        model.banner = banner
        bannerTimer?.invalidate()
        bannerTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.banner = nil }
        }
    }

    private func observeEvents() {
        system.$power
            .removeDuplicates()
            .scan((nil, nil)) { (acc: (PowerInfo?, PowerInfo?), new: PowerInfo?) in (acc.1, new) }
            .dropFirst(2)
            .sink { [weak self] pair in
                guard let self, let old = pair.0, let new = pair.1, old.onAC != new.onAC else { return }
                if new.onAC {
                    self.flash(NotchBanner(symbol: "bolt.fill", text: L("Charging") + " · " + Fmt.pct(new.percent), color: .green))
                } else {
                    self.flash(NotchBanner(symbol: "battery.75percent", text: L("On battery") + " · " + Fmt.pct(new.percent), color: .orange))
                }
            }
            .store(in: &subs)

        var known: Set<String>?
        batteries.$devices
            .sink { [weak self] list in
                let names = Set(list.map(\.name))
                defer { known = names }
                guard let self, let prev = known else { return }
                for d in list where !prev.contains(d.name) && d.kind != .mac {
                    self.flash(NotchBanner(symbol: d.symbol, text: "\(d.name) · " + Fmt.pct(d.mainPercent ?? 0), color: .blue))
                }
            }
            .store(in: &subs)

        caffeine.$isActive
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] on in
                self?.flash(NotchBanner(symbol: on ? "cup.and.saucer.fill" : "cup.and.saucer",
                                        text: on ? L("Coffee on") : L("Coffee off"),
                                        color: on ? .orange : .secondary), seconds: 2)
            }
            .store(in: &subs)

        caffeine.$espressoActive
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] on in
                self?.flash(NotchBanner(symbol: "cup.and.heat.waves.fill",
                                        text: on ? L("Espresso on: keeps running with the lid closed") : L("Espresso off"),
                                        color: on ? .orange : .secondary), seconds: 2.5)
            }
            .store(in: &subs)

        // Let the user know when a Claude session finishes its reply or asks for permission.
        var lastStates: [String: ClaudeSession.State] = [:]
        var primed = false
        sessions.$sessions
            .sink { [weak self] list in
                defer {
                    lastStates = Dictionary(list.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
                    primed = true
                }
                guard let self, primed else { return }
                for s in list where s.state.needsAction && lastStates[s.id] == .working {
                    self.flash(NotchBanner(symbol: s.state.symbol,
                                           text: s.state == .needsPermission ? L("Permission: %@", s.project) : L("Your turn: %@", s.project),
                                           color: s.state.color), seconds: 5)
                }
            }
            .store(in: &subs)
    }

    /// 20-20-20 rule: every 20 minutes, look 20 feet (6 m) away for 20 seconds.
    private func scheduleEyeBreak() {
        eyeTimer?.invalidate()
        eyeTimer = nil
        guard eyeBreakEnabled else { return }
        eyeTimer = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flash(NotchBanner(symbol: "eye", text: L("Look away for 20 s"), color: .cyan), seconds: 20)
            }
        }
    }
}
