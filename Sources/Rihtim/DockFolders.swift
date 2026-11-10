import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Popup listing a Dock folder's contents (Downloads, Documents…) on hover.
/// Click a file to open it, or drag it into another app.
struct FolderEntry: Identifiable {
    var id: URL { url }
    let url: URL
    let name: String
    let icon: NSImage
    let date: Date
    let isDirectory: Bool
}

enum FolderSort: String, CaseIterable, Identifiable {
    case added, modified, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .added: return L("Date added")
        case .modified: return L("Date modified")
        case .name: return L("Name")
        }
    }
}

@MainActor
final class FolderModel: ObservableObject {
    @Published var name = ""
    @Published var url: URL?
    @Published var icon: NSImage?
    @Published var entries: [FolderEntry] = []
    @Published var total = 0
    @Published var error: String?
}

enum FolderLayout {
    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 30
    static let maxRows = 12
    static let headerHeight: CGFloat = 26
    static let padding: CGFloat = 10
    static let limit = 60
}

@MainActor
final class FolderPopController {
    var isEnabled = true { didSet { if !isEnabled { hide() } } }
    var sort: FolderSort = .added
    var onShow: (@MainActor () -> Void)?

    private let panel = FloatingPanel()
    private let model = FolderModel()
    private var hoveredURL: URL?
    private var currentURL: URL?
    private var anchor: CGRect = .zero
    private var orientation: DockOrientation = .bottom
    private var pendingTimer: Timer?
    private var pollTimer: Timer?
    private var mouseMonitor: Any?

    init() {
        let view = FolderView(model: model,
                              onOpen: { [weak self] e in self?.open(e) },
                              onReveal: { [weak self] e in self?.reveal(e) },
                              onOpenFolder: { [weak self] in self?.openFolder() })
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        panel.contentView = host
    }

    func dockHoverChanged(_ item: DockHoverItem?) {
        guard isEnabled else { return }
        pendingTimer?.invalidate()
        guard let item, item.kind == .folder, let url = item.url else { hoveredURL = nil; return }
        hoveredURL = url
        let delay: TimeInterval = panel.isVisible ? 0.05 : 0.3
        pendingTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hoveredURL == url else { return }
                self.show(url: url, title: item.title, anchorAX: item.frameAX)
            }
        }
    }

    private func show(url: URL, title: String, anchorAX: CGRect) {
        let entries = Self.read(url, sort: sort)
        model.name = title.isEmpty ? url.lastPathComponent : title
        model.url = url
        model.icon = NSWorkspace.shared.icon(forFile: url.path)
        switch entries {
        case .success(let (list, total)):
            model.entries = list
            model.total = total
            model.error = nil
        case .failure(let e):
            model.entries = []
            model.total = 0
            model.error = e.localizedDescription
        }
        currentURL = url

        anchor = Geometry.cocoa(fromAX: anchorAX)
        let screen = Geometry.screen(containing: CGPoint(x: anchor.midX, y: anchor.midY))
        orientation = DockOrientation.detect(anchor: anchor, screen: screen.frame)
        let rows = CGFloat(max(1, min(model.entries.count, FolderLayout.maxRows)))
        let size = CGSize(width: FolderLayout.width,
                          height: FolderLayout.padding * 2 + FolderLayout.headerHeight + 6
                                  + rows * FolderLayout.rowHeight + (rows - 1) * 2)
        place(size: size, screen: screen.frame)
        if !panel.isVisible { onShow?() }
        panel.orderFrontRegardless()
        DockReveal.shared.hold("folder")
        startTracking()
    }

    nonisolated static func read(_ url: URL, sort: FolderSort) -> Result<([FolderEntry], Int), Error> {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey,
                                      .isDirectoryKey, .localizedNameKey, .isPackageKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                options: [.skipsHiddenFiles])
        } catch { return .failure(error) }

        struct Raw { let url: URL; let name: String; let date: Date; let dir: Bool }
        var raws: [Raw] = urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let date = (sort == .modified ? v?.contentModificationDate : v?.addedToDirectoryDate)
                ?? v?.contentModificationDate ?? .distantPast
            let dir = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
            return Raw(url: u, name: v?.localizedName ?? u.lastPathComponent, date: date, dir: dir)
        }
        switch sort {
        case .name: raws.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .added, .modified: raws.sort { $0.date > $1.date }
        }
        let total = raws.count
        let list = raws.prefix(FolderLayout.limit).map {
            FolderEntry(url: $0.url, name: $0.name, icon: NSWorkspace.shared.icon(forFile: $0.url.path),
                        date: $0.date, isDirectory: $0.dir)
        }
        return .success((Array(list), total))
    }

    private func place(size: CGSize, screen: CGRect) {
        let gap: CGFloat = 8
        var o: CGPoint
        switch orientation {
        case .bottom: o = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
        case .left:   o = CGPoint(x: anchor.maxX + gap, y: anchor.midY - size.height / 2)
        case .right:  o = CGPoint(x: anchor.minX - gap - size.width, y: anchor.midY - size.height / 2)
        }
        o.x = min(max(o.x, screen.minX + 8), screen.maxX - size.width - 8)
        o.y = min(max(o.y, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrame(CGRect(origin: o, size: size), display: true)
        panel.invalidateShadow()
    }

    // MARK: tracking

    private func startTracking() {
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        }
        if mouseMonitor == nil {
            // Clicking the folder opens macOS's own stack; don't draw on top of it.
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    private func stopTracking() {
        pollTimer?.invalidate(); pollTimer = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    private func poll() {
        guard panel.isVisible else { stopTracking(); return }
        // Stay open while a file is being dragged out to another app.
        if NSEvent.pressedMouseButtons & 1 != 0 { return }
        let m = NSEvent.mouseLocation
        if panel.frame.insetBy(dx: -6, dy: -6).contains(m) { return }
        let u = anchor.union(panel.frame)
        let bridge: CGRect
        switch orientation {
        case .bottom: bridge = CGRect(x: anchor.minX - 30, y: u.minY, width: anchor.width + 60, height: u.height)
        case .left, .right: bridge = CGRect(x: u.minX, y: anchor.minY - 30, width: u.width, height: anchor.height + 60)
        }
        if bridge.contains(m) { return }
        if let h = hoveredURL, h != currentURL { return }
        hide()
    }

    func hide() {
        pendingTimer?.invalidate()
        panel.orderOut(nil)
        currentURL = nil
        stopTracking()
        DockReveal.shared.release("folder")
    }

    // MARK: actions

    private func open(_ e: FolderEntry) {
        hide()
        NSWorkspace.shared.open(e.url)
    }

    private func reveal(_ e: FolderEntry) {
        hide()
        NSWorkspace.shared.activateFileViewerSelecting([e.url])
    }

    private func openFolder() {
        guard let url = model.url else { return }
        hide()
        NSWorkspace.shared.open(url)
    }
}

struct FolderView: View {
    @ObservedObject var model: FolderModel
    let onOpen: @MainActor (FolderEntry) -> Void
    let onReveal: @MainActor (FolderEntry) -> Void
    let onOpenFolder: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let icon = model.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                Text(model.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(model.total > model.entries.count ? "· \(model.entries.count)/\(model.total)" : "· " + L("%d items", model.total))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Spacer(minLength: 4)
                Button(action: { onOpenFolder() }) {
                    Label("Finder", systemImage: "folder")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(L("Open the folder in Finder"))
            }
            .frame(height: FolderLayout.headerHeight)

            if let error = model.error {
                Text(L("Couldn't read: %@\nAllow Rıhtım in System Settings › Privacy › Files and Folders.", error))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if model.entries.isEmpty {
                Text(L("Folder is empty")).font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: FolderLayout.rowHeight)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(model.entries) { e in
                            FolderRow(entry: e, onOpen: { onOpen(e) }, onReveal: { onReveal(e) })
                        }
                    }
                }
            }
        }
        .padding(FolderLayout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(PanelBackground())
    }
}

private struct FolderRow: View {
    let entry: FolderEntry
    let onOpen: @MainActor () -> Void
    let onReveal: @MainActor () -> Void
    @State private var hovering = false

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = L10n.locale
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: entry.icon).resizable().frame(width: 20, height: 20)
            Text(entry.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if hovering {
                Button(action: { onReveal() }) {
                    Image(systemName: "magnifyingglass.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Show in Finder"))
            } else if entry.date != .distantPast {
                Text(Self.rel.localizedString(for: entry.date, relativeTo: Date()))
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: FolderLayout.rowHeight)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.12 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onOpen() }
        .onDrag { NSItemProvider(contentsOf: entry.url) ?? NSItemProvider() }
    }
}
