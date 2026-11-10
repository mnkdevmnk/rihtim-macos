import AppKit
import SwiftUI

enum Layout {
    static let cardWidth: CGFloat = 200
    static let thumbHeight: CGFloat = 120
    static let titleHeight: CGFloat = 18
    static let spacing: CGFloat = 10
    static let padding: CGFloat = 12
    static let headerHeight: CGFloat = 22
    static var cardHeight: CGFloat { thumbHeight + 6 + titleHeight }
    // Dock preview: list mode and mini player
    static let listWidth: CGFloat = 340
    static let listRowHeight: CGFloat = 30
    static let maxListRows = 14
    static let playerHeight: CGFloat = 52
    static let playerWidth: CGFloat = 320
    static let minPreviewWidth: CGFloat = 230

    static func gridSize(count: Int, columns: Int, scale: CGFloat = 1) -> CGSize {
        let cols = max(columns, 1)
        let rows = max(Int(ceil(Double(count) / Double(cols))), 1)
        let cardH = thumbHeight * scale + 6 + titleHeight
        let w = padding * 2 + CGFloat(cols) * cardWidth * scale + CGFloat(cols - 1) * spacing
        let h = padding * 2 + CGFloat(rows) * cardH + CGFloat(rows - 1) * spacing
        return CGSize(width: w, height: h)
    }
}

extension NSPanel {
    func configureFloating() {
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

/// Panel that never takes keyboard focus (previews, switcher, widget bar).
final class FloatingPanel: NSPanel {
    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: false)
        configureFloating()
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Panel that can take key input without activating the app (popovers with a search field).
final class KeyPanel: NSPanel {
    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: false)
        configureFloating()
        becomesKeyOnlyIfNeeded = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Liquid Glass (regular / clear) or the classic frosted blur.
enum GlassKind: String, CaseIterable, Identifiable {
    case regular, clear, frosted
    var id: String { rawValue }
    var title: String {
        switch self {
        case .regular: return "Liquid Glass"
        case .clear: return L("Liquid Glass (clear)")
        case .frosted: return L("Frosted (classic)")
        }
    }
    static var liquidAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

/// Liquid Glass on macOS 26+, HUD blur on older systems or when "frosted" is picked.
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat
    var kind: GlassKind = .regular
    /// 0 = no tint; >0 tints toward black, <0 toward white.
    var tint: CGFloat = 0

    private var tintColor: NSColor? {
        guard abs(tint) > 0.01 else { return nil }
        return (tint > 0 ? NSColor.black : NSColor.white).withAlphaComponent(min(abs(tint), 0.9))
    }

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *), kind != .frosted {
            let g = NSGlassEffectView()
            apply(g)
            return g
        }
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        updateNSView(v, context: context)
        return v
    }

    @available(macOS 26.0, *)
    private func apply(_ g: NSGlassEffectView) {
        if g.cornerRadius != cornerRadius { g.cornerRadius = cornerRadius }
        let style: NSGlassEffectView.Style = kind == .clear ? .clear : .regular
        if g.style != style { g.style = style }
        if g.tintColor != tintColor { g.tintColor = tintColor }
    }

    func updateNSView(_ v: NSView, context: Context) {
        if #available(macOS 26.0, *), let g = v as? NSGlassEffectView {
            apply(g)
        } else {
            v.layer?.cornerRadius = cornerRadius
            v.layer?.backgroundColor = tintColor?.cgColor
        }
    }
}

private struct FlatPillKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// In the Dock strip pills skip their own background and sit inside one shared glass container.
    var flatPill: Bool {
        get { self[FlatPillKey.self] }
        set { self[FlatPillKey.self] = newValue }
    }
}

struct PanelBackground: ViewModifier {
    var radius: CGFloat = 16
    @Environment(\.flatPill) private var flat

    func body(content: Content) -> some View {
        if flat {
            content
        } else {
            content
                .background(GlassBackground(cornerRadius: radius))
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

struct WindowCard: View {
    let window: WindowInfo
    let thumbnail: NSImage?
    let isSelected: Bool
    let showsClose: Bool
    let onSelect: @MainActor () -> Void
    let onClose: @MainActor () -> Void
    var onMinimize: (@MainActor () -> Void)? = nil
    var scale: CGFloat = 1
    @State private var hovering = false

    private var width: CGFloat { Layout.cardWidth * scale }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.2))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(4)
                } else if let icon = window.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 56 * scale, height: 56 * scale).opacity(0.85)
                }
            }
            .frame(width: width, height: Layout.thumbHeight * scale)
            .overlay(alignment: .bottom) {
                if window.isMinimized || window.isOnOtherSpace {
                    Text(window.isMinimized ? L("Minimized") : L("Other desktop"))
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .foregroundColor(.white)
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsClose && hovering {
                    HStack(spacing: 4) {
                        if let onMinimize {
                            Button(action: { onMinimize() }) {
                                Image(systemName: window.isMinimized ? "arrow.up.circle.fill" : "minus.circle.fill")
                                    .font(.system(size: 16))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.black.opacity(0.7), .yellow)
                            }
                            .buttonStyle(.plain)
                            .help(window.isMinimized ? L("Restore") : L("Minimize"))
                        }
                        Button(action: { onClose() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .red)
                        }
                        .buttonStyle(.plain)
                        .help(L("Close"))
                    }
                    .padding(6)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: (isSelected || hovering) ? 2.5 : 0)
            )

            Text(window.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: width, height: Layout.titleHeight)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onSelect() }
    }
}

// MARK: - Dock preview

enum PreviewAppAction { case minimizeAll, closeAll, hide, quit }

@MainActor
final class PreviewModel: ObservableObject {
    @Published var appName = ""
    @Published var appIcon: NSImage?
    @Published var windows: [WindowInfo] = []
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    @Published var columns = 1
    @Published var scale: CGFloat = 1
    @Published var listMode = false
    @Published var showsPlayer = false
}

struct PreviewView: View {
    @ObservedObject var model: PreviewModel
    @ObservedObject var music: MusicController
    let onSelect: @MainActor (WindowInfo) -> Void
    let onClose: @MainActor (WindowInfo) -> Void
    let onMinimize: @MainActor (WindowInfo) -> Void
    let onAppAction: @MainActor (PreviewAppAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header.frame(height: Layout.headerHeight)

            if model.showsPlayer {
                PreviewPlayer(music: music).frame(height: Layout.playerHeight)
            }

            if model.listMode {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(model.windows) { w in
                            WindowRow(window: w,
                                      onSelect: { onSelect(w) },
                                      onClose: { onClose(w) },
                                      onMinimize: { onMinimize(w) })
                        }
                    }
                }
            } else if !model.windows.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Layout.cardWidth * model.scale), spacing: Layout.spacing),
                                         count: max(model.columns, 1)),
                          alignment: .leading, spacing: Layout.spacing) {
                    ForEach(model.windows) { w in
                        WindowCard(window: w,
                                   thumbnail: model.thumbnails[w.windowID],
                                   isSelected: false,
                                   showsClose: true,
                                   onSelect: { onSelect(w) },
                                   onClose: { onClose(w) },
                                   onMinimize: { onMinimize(w) },
                                   scale: model.scale)
                    }
                }
            }
        }
        .padding(Layout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(PanelBackground())
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let icon = model.appIcon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }
            Text(model.appName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if !model.windows.isEmpty {
                Text("· " + L("%d windows", model.windows.count)).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                if !model.windows.isEmpty {
                    headerButton("minus.circle", L("Minimize all")) { onAppAction(.minimizeAll) }
                    headerButton("xmark.circle", L("Close all")) { onAppAction(.closeAll) }
                }
                headerButton("eye.slash", L("Hide")) { onAppAction(.hide) }
                headerButton("power", L("Quit")) { onAppAction(.quit) }
            }
            .foregroundColor(.secondary)
        }
    }

    private func headerButton(_ symbol: String, _ help: String, _ action: @escaping @MainActor () -> Void) -> some View {
        HeaderIconButton(symbol: symbol, action: action).help(help)
    }
}

private struct HeaderIconButton: View {
    let symbol: String
    let action: @MainActor () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: { action() }) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.15 : 0)))
                .foregroundColor(hovering ? .primary : .secondary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Row in list mode (apps with lots of windows).
struct WindowRow: View {
    let window: WindowInfo
    let onSelect: @MainActor () -> Void
    let onClose: @MainActor () -> Void
    let onMinimize: @MainActor () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon = window.appIcon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            }
            Text(window.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if window.isMinimized || window.isOnOtherSpace {
                Text(window.isMinimized ? L("minimized") : L("other desktop"))
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            if hovering {
                Button(action: { onMinimize() }) {
                    Image(systemName: window.isMinimized ? "arrow.up.circle.fill" : "minus.circle.fill")
                        .symbolRenderingMode(.palette).foregroundStyle(.black.opacity(0.7), .yellow)
                }.buttonStyle(.plain)
                Button(action: { onClose() }) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette).foregroundStyle(.white, .red)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Layout.listRowHeight)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.12 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onSelect() }
    }
}

/// Now playing, shown in the Music / Spotify icon preview.
struct PreviewPlayer: View {
    @ObservedObject var music: MusicController

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let art = music.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.system(size: 18)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white.opacity(0.08))
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(music.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(music.artist).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                if music.duration > 0 {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Capsule().fill(Color.white.opacity(0.8))
                                .frame(width: g.size.width * CGFloat(min(max(music.position / music.duration, 0), 1)))
                        }
                    }
                    .frame(height: 3)
                }
            }
            Spacer(minLength: 0)
            PillButton(symbol: "backward.fill", size: 12) { music.previous() }
            PillButton(symbol: music.isPlaying ? "pause.fill" : "play.fill", size: 15) { music.playPause() }
            PillButton(symbol: "forward.fill", size: 12) { music.next() }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

// MARK: - Shared bits

struct LevelBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(color).frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
    }
    private var color: Color { value < 0.2 ? .red : (value < 0.4 ? .orange : .green) }
}

struct Sparkline: Shape {
    var values: [Double]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let maxV = max(values.max() ?? 1, 25)
        let step = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: CGFloat(i) * step, y: rect.maxY - CGFloat(v / maxV) * rect.height)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

struct PillButton: View {
    let symbol: String
    var size: CGFloat = 13
    let action: @MainActor () -> Void
    var body: some View {
        Button(action: { action() }) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 14, height: size + 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum Fmt {
    static func bytes(_ v: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .memory)
    }
    static func rate(_ v: Double) -> String {
        let b = max(v, 0)
        if b < 1024 { return "0 KB/s" }
        if b < 1024 * 1024 { return "\(Int(b / 1024)) KB/s" }
        return String(format: "%.1f MB/s", b / 1024 / 1024)
    }
    /// Short time ("14:05" / "2:05 PM") in the UI language.
    static func clock(_ d: Date) -> String {
        d.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))
    }
    /// "42%" / "%42" / "42 %" depending on the UI language.
    static func pct(_ v: Int) -> String {
        switch L10n.code {
        case "tr": return "%\(v)"
        case "de": return "\(v) %"
        default: return "\(v)%"
        }
    }
    static func time(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
