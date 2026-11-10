import AppKit
import SwiftUI

enum PopoverKind: String, CaseIterable, Identifiable {
    case music, calendar, weather, system, usage, caffeine, battery
    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: return L("Music")
        case .calendar: return L("Calendar")
        case .weather: return L("Weather")
        case .system: return L("System (CPU · RAM · SSD)")
        case .usage: return L("Claude usage")
        case .caffeine: return L("Coffee (keep awake)")
        case .battery: return L("Device batteries")
        }
    }

    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .calendar: return "calendar"
        case .weather: return "cloud.sun"
        case .system: return "cpu"
        case .usage: return "sparkle"
        case .caffeine: return "cup.and.saucer"
        case .battery: return "battery.75percent"
        }
    }

    var enabledKey: String { "bar." + rawValue }
    var sideKey: String { "bar.side." + rawValue }
    var defaultSide: BarSide { [.battery, .music, .calendar].contains(self) ? .left : .right }

    /// When space runs out: lower number = shrunk / hidden last.
    var priority: Int {
        switch self {
        case .battery: return 0
        case .system: return 1
        case .music: return 2
        case .calendar: return 3
        case .usage: return 4
        case .weather: return 5
        case .caffeine: return 6
        }
    }
}

enum BarSide: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var title: String { self == .left ? L("Left of the Dock") : L("Right of the Dock") }
}

enum BarHeightMode: String, CaseIterable, Identifiable {
    case dock, manual
    var id: String { rawValue }
}

/// Strip appearance (Settings › Dock › Widget strip).
struct BarStyle: Equatable {
    var heightMode: BarHeightMode = .dock
    /// Fine-tune in "match the Dock" mode (pt).
    var heightAdjust: CGFloat = 0
    var manualHeight: CGFloat = 60
    var offsetY: CGFloat = 0
    var gap: CGFloat = 8
    /// Corner radius as a fraction of height.
    var radius: CGFloat = 0.42
    var glass: GlassKind = .regular
    var tint: CGFloat = 0
    var separators = true
}

@MainActor
final class BarSettings: ObservableObject {
    @Published var style = BarStyle()
    @Published var enabled: Set<PopoverKind> = Set(PopoverKind.allCases)
    @Published var sides: [PopoverKind: BarSide] = [:]
    @Published var height: CGFloat = 56
    @Published var compactAlways = false

    func side(_ k: PopoverKind) -> BarSide { sides[k] ?? k.defaultSide }
}

struct BarSlot: Identifiable, Equatable {
    var id: PopoverKind { kind }
    let kind: PopoverKind
    var compact: Bool
    var width: CGFloat
}

enum BarLayout {
    static let inset: CGFloat = 6         // inner padding of the glass container
    static let sepPad: CGFloat = 4        // space on each side of a separator
    static var separator: CGFloat { 1 + sepPad * 2 }
    /// On Tahoe the visible Dock glass is as tall as the AX list frame but sits ~5 pt lower
    /// (measured with tilesize 50: AX 876–946, glass 881–951, screen bottom 956).
    static var axShift: CGFloat {
        if #available(macOS 26.0, *) { return 5 }
        return 0
    }
}

/// The pills on one side.
struct BarView: View {
    let side: BarSide
    @ObservedObject var settings: BarSettings
    @ObservedObject var music: MusicController
    @ObservedObject var system: SystemMonitor
    @ObservedObject var batteries: BatteryMonitor
    @ObservedObject var caffeine: Caffeine
    @ObservedObject var usage: ClaudeUsage
    @ObservedObject var calendar: CalendarMonitor
    @ObservedObject var weather: WeatherMonitor
    let kinds: [BarSlot]
    let onOpen: @MainActor (PopoverKind) -> Void

    var body: some View {
        // Reads as an extension of the Dock: one glass container with widgets lined up like icons.
        HStack(spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.element.id) { i, slot in
                if i > 0 {
                    Capsule().fill(Color.primary.opacity(settings.style.separators ? 0.18 : 0))
                        .frame(width: 1, height: settings.height * 0.5)
                        .padding(.horizontal, BarLayout.sepPad)
                }
                Group {
                    if slot.compact { compact(slot.kind) } else { pill(slot.kind) }
                }
                .frame(width: slot.width)
                .contentShape(Rectangle())
                .onTapGesture { slot.kind == .caffeine ? caffeine.toggle() : onOpen(slot.kind) }
            }
        }
        .padding(.horizontal, BarLayout.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlassBackground(cornerRadius: settings.height * settings.style.radius,
                                    kind: settings.style.glass, tint: settings.style.tint)
            .id(settings.style.glass))
        .environment(\.flatPill, true)
    }

    /// Narrow layout: icon plus a single value.
    @ViewBuilder
    private func compact(_ k: PopoverKind) -> some View {
        let h = settings.height
        Group {
            switch k {
            case .music:
                Artwork(image: music.artwork, size: h - 18)
            case .calendar:
                VStack(spacing: 0) {
                    Text(Date().formatted(.dateTime.day())).font(.system(size: 15, weight: .semibold, design: .rounded))
                    if let e = calendar.next, e.start.timeIntervalSinceNow < 3600 {
                        Text(e.start <= Date() ? L("now") : L("%dm", max(Int(e.start.timeIntervalSinceNow / 60), 1)))
                            .font(.system(size: 9, weight: .semibold)).foregroundColor(CalFmt.urgency(e))
                    } else {
                        Text(Date().formatted(.dateTime.weekday(.abbreviated).locale(L10n.locale))).font(.system(size: 9)).foregroundColor(.red)
                    }
                }
            case .weather:
                VStack(spacing: 1) {
                    Image(systemName: weather.now.map { WeatherCode.symbol($0.code, day: $0.isDay) } ?? "cloud")
                        .symbolRenderingMode(.multicolor).font(.system(size: 14))
                    Text(weather.now.map { "\(Int($0.temp.rounded()))°" } ?? "–").font(.system(size: 12, weight: .semibold, design: .rounded))
                }
            case .system:
                VStack(spacing: 1) {
                    Text(Fmt.pct(Int(system.cpu.rounded()))).font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("RAM \(system.memPercent)").font(.system(size: 9)).foregroundColor(.secondary)
                }
            case .usage:
                VStack(spacing: 1) {
                    ClaudeMark(size: 11)
                    Text(usage.fiveHour.map { Fmt.pct(Int($0.percent.rounded())) } ?? "–")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(usage.fiveHour.map { UsageMeter.color($0.percent) } ?? .secondary)
                }
            case .caffeine:
                CaffeineIcon(active: caffeine.isActive, size: 16)
            case .battery:
                HStack(spacing: 8) {
                    ForEach(batteries.devices.prefix(3)) { d in
                        VStack(spacing: 3) {
                            HStack(spacing: 2) {
                                Image(systemName: d.symbol).font(.system(size: 10))
                                if d.isCharging { Image(systemName: "bolt.fill").font(.system(size: 7)).foregroundColor(.green) }
                            }
                            Text(d.mainPercent.map { "\($0)" } ?? "–").font(.system(size: 11, weight: .semibold, design: .rounded))
                            LevelBar(value: Double(d.mainPercent ?? 0) / 100).frame(width: 28, height: 3)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .modifier(PanelBackground(radius: h * 0.32))
    }

    @ViewBuilder
    private func pill(_ k: PopoverKind) -> some View {
        let h = settings.height
        switch k {
        case .music: MusicPill(music: music, height: h)
        case .calendar: CalendarPill(calendar: calendar, height: h)
        case .weather: WeatherPill(weather: weather, height: h)
        case .system: SystemPill(system: system, height: h)
        case .usage: UsagePill(usage: usage, height: h)
        case .caffeine: CaffeinePill(caffeine: caffeine, height: h)
        case .battery: BatteryPill(devices: batteries.devices, height: h)
        }
    }
}

/// Widget strips stuck to either side of the real Dock. The Dock isn't touched: we read
/// its position through AX and place our own panels next to it.
@MainActor
final class WidgetBarController {
    var isEnabled = true { didSet { update() } }

    let settings: BarSettings
    private var panels: [BarSide: FloatingPanel] = [:]
    private var lastSlots: [BarSide: [BarSlot]] = [:]
    /// Slides in sync with an auto-hiding Dock. 1 = fully visible, 0 = below the screen.
    private var reveal: CGFloat = 1
    private var axTracks = false
    private var lastAXMinY: CGFloat?
    private var dockMoving = Date.distantPast
    private var edgeSince: Date?
    private var lastTick = Date()
    private var rate: TimeInterval = 0.4
    var revealDelay: TimeInterval = 0.5
    var revealDuration: TimeInterval = 0.35
    private var lastLoggedDock: CGRect = .zero
    private var measuredDockHeight: CGFloat = 0
    private var hostedKinds: [BarSide: [String]] = [:]
    private let popover: KeyPanel
    private let dock: DockObserver
    private let music: MusicController
    private let system: SystemMonitor
    private let batteries: BatteryMonitor
    private let caffeine: Caffeine
    private let usage: ClaudeUsage
    private let calendar: CalendarMonitor
    private let weather: WeatherMonitor

    private var timer: Timer?
    private var openKind: PopoverKind?
    private var outsideMonitor: Any?

    init(dock: DockObserver, music: MusicController, system: SystemMonitor, batteries: BatteryMonitor,
         caffeine: Caffeine, usage: ClaudeUsage, calendar: CalendarMonitor, weather: WeatherMonitor) {
        self.dock = dock
        self.music = music
        self.system = system
        self.batteries = batteries
        self.caffeine = caffeine
        self.usage = usage
        self.calendar = calendar
        self.weather = weather
        settings = BarSettings()
        popover = KeyPanel()
        for side in BarSide.allCases {
            let p = FloatingPanel()
            // No Dock in full-screen apps, so no strip either.
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            p.appearance = nil          // follow light/dark like the Dock
            p.hasShadow = false         // the glass draws its own shadow
            panels[side] = p
        }
    }

    func start() {
        guard timer == nil else { return }
        update()
        setRate(0.4, force: true)
    }

    /// 60 fps near the Dock or while sliding, much slower otherwise.
    private func setRate(_ r: TimeInterval, force: Bool = false) {
        guard force || abs(r - rate) > 0.001 else { return }
        rate = r
        timer?.invalidate()
        let t = Timer(timeInterval: r, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: layout

    private func compactWidth(_ k: PopoverKind) -> CGFloat {
        switch k {
        case .battery: return 16 + CGFloat(min(batteries.devices.count, 3)) * 40
        case .caffeine: return 50
        default: return 60
        }
    }

    private func width(_ k: PopoverKind) -> CGFloat {
        switch k {
        case .music: return 260
        case .calendar: return 210
        case .weather: return 180
        case .system: return 236
        case .usage: return 200
        case .caffeine: return 122
        case .battery: return 20 + CGFloat(min(batteries.devices.count, 4)) * 66
        }
    }

    private func isVisible(_ k: PopoverKind) -> Bool {
        guard settings.enabled.contains(k) else { return false }
        switch k {
        case .music: return music.hasTrack
        case .battery: return !batteries.devices.isEmpty
        default: return true
        }
    }

    /// Pills that fit in the space on that side. Low-priority ones go compact first,
    /// and get hidden if that's still not enough.
    private func pills(_ side: BarSide, available: CGFloat = .infinity) -> [BarSlot] {
        var slots = PopoverKind.allCases
            .filter { settings.side($0) == side && isVisible($0) }
            .map { BarSlot(kind: $0, compact: settings.compactAlways, width: settings.compactAlways ? compactWidth($0) : width($0)) }
        while !slots.isEmpty && contentWidth(slots) > available {
            let byPriority = slots.indices.sorted { slots[$0].kind.priority > slots[$1].kind.priority }
            if let i = byPriority.first(where: { !slots[$0].compact }) {
                slots[i].compact = true
                slots[i].width = compactWidth(slots[i].kind)
            } else {
                slots.remove(at: byPriority[0])
            }
        }
        return slots
    }

    private func contentWidth(_ list: [BarSlot]) -> CGFloat {
        guard !list.isEmpty else { return 0 }
        return list.reduce(0) { $0 + $1.width } + CGFloat(list.count - 1) * BarLayout.separator + BarLayout.inset * 2
    }

    private func hideAll() {
        DockReveal.shared.release("bar")
        for p in panels.values where p.isVisible { p.orderOut(nil) }
        closePopover()
    }

    private func update() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 0.1)
        lastTick = now
        guard isEnabled, let dockAX = dock.dockFrameAX(), dockAX.width > 0, dockAX.height > 0 else { hideAll(); return }
        let dockFrame = Geometry.cocoa(fromAX: dockAX)
        if dockAX != lastLoggedDock {
            lastLoggedDock = dockAX
            let items = dock.itemsFrameAX().map { "\($0)" } ?? "-"
            let tile = UserDefaults(suiteName: "com.apple.dock")?.double(forKey: "tilesize") ?? 0
            Diag.log("dock frame AX=\(dockAX) items=\(items) tilesize=\(tile)")
        }
        let screen = Geometry.screen(containing: CGPoint(x: dockFrame.midX, y: dockFrame.midY)).frame
        guard DockOrientation.detect(anchor: dockFrame, screen: screen) == .bottom else { hideAll(); return }

        let mouse = NSEvent.mouseLocation
        let autohide = UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
        let st = settings.style
        // The visible Dock glass: as tall as the AX frame, axShift lower.
        let glassH = max(dockFrame.height, 24)
        let glassMidY = dockFrame.midY - BarLayout.axShift
        if abs(measuredDockHeight - glassH) > 0.5 {
            measuredDockHeight = glassH
            UserDefaults.standard.set(Double(glassH), forKey: Prefs.barMeasuredDock)
        }
        let rawH = st.heightMode == .manual ? st.manualHeight : glassH + st.heightAdjust
        let h = min(max(rawH, 28), 120).rounded()
        if settings.height != h { settings.height = h }

        var y = glassMidY - h / 2 + st.offsetY
        // Keep an auto-hiding Dock up while the pointer is on the strip or its popover is open.
        let overBar = panels.values.contains { $0.isVisible && $0.frame.insetBy(dx: -6, dy: -6).contains(mouse) }
        if autohide && reveal > 0.5 && (overBar || openKind != nil) {
            DockReveal.shared.hold("bar")
        } else {
            DockReveal.shared.release("bar")
        }
        if autohide {
            // If the AX position moves while the Dock slides, just follow it (best sync).
            if let last = lastAXMinY, abs(last - dockFrame.minY) > 0.5 { dockMoving = now }
            if let last = lastAXMinY, abs(last - dockFrame.minY) > 0.5, !axTracks {
                axTracks = true
                Diag.log("dock AX position moves while sliding -> follow mode")
            }
            lastAXMinY = dockFrame.minY
            if axTracks {
                reveal = dockFrame.maxY > screen.minY + 1 ? 1 : 0
            } else {
                // Otherwise mimic the Dock: slide up when the pointer rests on the bottom
                // edge, slide down once it leaves the Dock area.
                let onScreenX = mouse.x >= screen.minX && mouse.x <= screen.maxX
                var want = false
                if openKind != nil || overBar || DockReveal.shared.isHeld {
                    want = true
                } else if reveal > 0.01 {
                    want = onScreenX && mouse.y <= screen.minY + h + 18
                } else if onScreenX && mouse.y <= screen.minY + 2 {
                    if edgeSince == nil { edgeSince = now }
                    want = now.timeIntervalSince(edgeSince!) >= revealDelay
                }
                if !want && mouse.y > screen.minY + 2 { edgeSince = nil }
                let step = CGFloat(dt / max(revealDuration, 0.05))
                reveal = want ? min(1, reveal + step) : max(0, reveal - step)
                let t = 1 - pow(1 - reveal, 3)                 // ease-out
                let travel = dockFrame.maxY - screen.minY + 6
                y -= (1 - t) * travel
            }
        } else {
            reveal = 1
            axTracks = false
            lastAXMinY = nil
        }

        let near = mouse.y < screen.minY + h + 90
        // Fast while the Dock slides (even with the pointer far away, e.g. on a preview) so the
        // strip moves with it; a slower watch otherwise catches the start of a slide quickly.
        let sliding = now.timeIntervalSince(dockMoving) < 0.5
        setRate(autohide ? (near || sliding || (reveal > 0 && reveal < 1) ? 1.0 / 60 : 0.1) : 0.4)

        if reveal <= 0.001 {
            for p in panels.values where p.isVisible { p.orderOut(nil) }
            if openKind != nil { closePopover() }
            return
        }

        for side in BarSide.allCases {
            guard let panel = panels[side] else { continue }
            let gap = st.gap
            let available = side == .left
                ? dockFrame.minX - gap - screen.minX - 6
                : screen.maxX - 6 - dockFrame.maxX - gap
            let list = pills(side, available: available)
            lastSlots[side] = list
            let w = contentWidth(list)
            let x = side == .left ? dockFrame.minX - gap - w : dockFrame.maxX + gap
            guard !list.isEmpty else {
                if panel.isVisible { panel.orderOut(nil) }
                continue
            }
            let kinds = list.map { "\($0.kind.rawValue):\(Int($0.width)):\($0.compact)" } + ["h\(Int(h))"]
            if hostedKinds[side] != kinds || panel.contentView == nil {
                hostedKinds[side] = kinds
                let view = BarView(side: side, settings: settings, music: music, system: system, batteries: batteries,
                                   caffeine: caffeine, usage: usage, calendar: calendar, weather: weather,
                                   kinds: list, onOpen: { [weak self] k in self?.togglePopover(k) })
                let host = NSHostingView(rootView: view)
                host.sizingOptions = []
                panel.contentView = host
            }
            let frame = CGRect(x: x, y: y, width: w, height: h).integral
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    // MARK: popovers

    private func togglePopover(_ kind: PopoverKind) {
        if openKind == kind { closePopover(); return }
        openKind = kind
        system.wantsProcesses = (kind == .system)

        let size: CGSize
        let root: AnyView
        switch kind {
        case .music:
            size = CGSize(width: 340, height: 220)
            root = AnyView(MusicPopover(music: music))
        case .system:
            size = CGSize(width: 390, height: 460)
            root = AnyView(ProcessPopover(system: system, onClose: { [weak self] in self?.closePopover() }))
        case .battery:
            batteries.refreshNow()
            size = CGSize(width: 340, height: CGFloat(36 + max(batteries.devices.count, 1) * 64))
            root = AnyView(BatteryPopover(batteries: batteries))
        case .usage:
            usage.refresh()
            size = CGSize(width: 340, height: 250)
            root = AnyView(UsagePopover(usage: usage))
        case .calendar:
            calendar.reload()
            size = CGSize(width: 340, height: 320)
            root = AnyView(CalendarPopover(calendar: calendar))
        case .weather:
            size = CGSize(width: 460, height: 190)
            root = AnyView(WeatherPopover(weather: weather))
        case .caffeine:
            size = CGSize(width: 540, height: 52)
            root = AnyView(CaffeineChooser(caffeine: caffeine)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(PanelBackground()))
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        popover.contentView = host

        // find the middle of the pill
        let side = settings.side(kind)
        guard let panel = panels[side] else { return }
        var centerX = panel.frame.midX
        let slots = lastSlots[side] ?? []
        var cursor = panel.frame.minX + BarLayout.inset
        for slot in slots {
            if slot.kind == kind { centerX = cursor + slot.width / 2; break }
            cursor += slot.width + BarLayout.separator
        }
        let screen = Geometry.screen(containing: CGPoint(x: panel.frame.midX, y: panel.frame.midY)).frame
        var origin = CGPoint(x: centerX - size.width / 2, y: panel.frame.maxY + 10)
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(origin.y, screen.maxY - size.height - 8)
        popover.setFrame(CGRect(origin: origin, size: size), display: true)
        popover.invalidateShadow()
        popover.orderFrontRegardless()
        popover.makeKey()

        if outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.closePopover() }
            }
        }
    }

    func closePopover() {
        guard openKind != nil || popover.isVisible else { return }
        openKind = nil
        system.wantsProcesses = false
        popover.orderOut(nil)
        popover.contentView = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
    }
}
