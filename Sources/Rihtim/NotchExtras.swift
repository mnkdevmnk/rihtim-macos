import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

enum NotchTab: String, CaseIterable, Identifiable {
    case home, claude, shelf, clipboard, notes, calendar, mirror
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .claude: return "sparkle"
        case .shelf: return "tray.full.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .notes: return "note.text"
        case .calendar: return "calendar"
        case .mirror: return "camera.fill"
        }
    }
    var title: String {
        switch self {
        case .home: return L("Home")
        case .claude: return "Claude"
        case .shelf: return L("Shelf")
        case .clipboard: return L("Clipboard")
        case .notes: return L("Note")
        case .calendar: return L("Calendar")
        case .mirror: return L("Mirror")
        }
    }
}

// MARK: - File shelf

/// Files dropped onto the notch. Nothing is copied, we only remember where they are.
@MainActor
final class NotchShelf: ObservableObject {
    @Published private(set) var files: [URL] = []
    private let key = "notch.shelf"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        files = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ url: URL) {
        guard !files.contains(url) else { return }
        files.insert(url, at: 0)
        save()
    }

    func remove(_ url: URL) { files.removeAll { $0 == url }; save() }
    func clear() { files = []; save() }
    private func save() { UserDefaults.standard.set(files.map(\.path), forKey: key) }

    func handle(_ providers: [NSItemProvider]) -> Bool {
        var any = false
        for p in providers where p.canLoadObject(ofClass: NSURL.self) {
            any = true
            _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                guard let url = (obj as? NSURL) as URL?, url.isFileURL else { return }
                Task { @MainActor in self.add(url) }
            }
        }
        return any
    }
}

struct ShelfView: View {
    @ObservedObject var shelf: NotchShelf
    @State private var targeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundColor(targeted ? .accentColor : .white.opacity(0.2))
                .background(RoundedRectangle(cornerRadius: 14).fill(targeted ? Color.accentColor.opacity(0.12) : .clear))
            if shelf.files.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 26)).foregroundColor(.secondary)
                    Text(L("Drag files here, then drag them back out wherever you need them, even on another desktop."))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(shelf.files, id: \.self) { url in
                            VStack(spacing: 4) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable().frame(width: 52, height: 52)
                                Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                                    .frame(width: 76)
                            }
                            .overlay(alignment: .topTrailing) {
                                Button(action: { shelf.remove(url) }) {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                                        .symbolRenderingMode(.palette).foregroundStyle(.white, .gray)
                                }
                                .buttonStyle(.plain)
                                .offset(x: 4, y: -4)
                            }
                            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                            .help(url.path)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .overlay(alignment: .bottomTrailing) {
                    Button(L("Clear")) { shelf.clear() }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(.secondary).padding(8)
                }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { shelf.handle($0) }
    }
}

// MARK: - Clipboard history

struct ClipItem: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let date: Date
}

/// Text only. Copies that password managers mark as concealed are skipped.
/// History never touches the disk and is gone when the app quits.
@MainActor
final class ClipboardHistory: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    var isEnabled = true { didSet { if !isEnabled { items = [] } } }
    private var lastCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private static let skipTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
    ]

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        guard isEnabled else { return }
        let types = Set((pb.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.skipTypes),
              let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        items.removeAll { $0.text == s }
        items.insert(ClipItem(text: s, date: Date()), at: 0)
        if items.count > 40 { items.removeLast(items.count - 40) }
    }

    func copy(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.text, forType: .string)
    }

    func remove(_ item: ClipItem) { items.removeAll { $0 == item } }
    func clear() { items = [] }
}

struct ClipboardView: View {
    @ObservedObject var clipboard: ClipboardHistory
    @State private var copied: UUID?

    var body: some View {
        if clipboard.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 24)).foregroundColor(.secondary)
                Text(clipboard.isEnabled ? L("Text you copy collects here.") : L("Clipboard history is turned off in Settings."))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(clipboard.items) { item in
                        HStack(spacing: 8) {
                            Text(item.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                                .font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                            Spacer()
                            Text(copied == item.id ? L("Copied") : Fmt.clock(item.date))
                                .font(.system(size: 9.5)).foregroundColor(copied == item.id ? .green : .secondary)
                            Button(action: { clipboard.remove(item) }) { Image(systemName: "xmark").font(.system(size: 9)) }
                                .buttonStyle(.plain).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            clipboard.copy(item)
                            copied = item.id
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Quick note

struct NotesView: View {
    @AppStorage("notch.note") private var note = ""

    var body: some View {
        TextEditor(text: $note)
            .font(.system(size: 12.5))
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
            .overlay(alignment: .topLeading) {
                if note.isEmpty {
                    Text(L("Quick note… (saved automatically)")).font(.system(size: 12.5)).foregroundColor(.secondary)
                        .padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Calendar grid

struct CalendarGridView: View {
    @ObservedObject var calendar: CalendarMonitor
    @State private var monthOffset = 0

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = L10n.locale
        c.firstWeekday = L10n.code == "en" ? Calendar.current.firstWeekday : 2
        return c
    }

    /// Two-letter weekday headers, starting at the first weekday.
    private var weekdayHeaders: [String] {
        let c = cal
        let base = L10n.code == "tr" ? ["Pz", "Pt", "Sa", "Ça", "Pe", "Cu", "Ct"]
                                     : c.shortStandaloneWeekdaySymbols.map { String($0.prefix(2)) }
        let start = c.firstWeekday - 1
        return Array(base[start...] + base[..<start])
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            grid.frame(width: 230)
            VStack(alignment: .leading, spacing: 5) {
                Text(L("Today")).font(.system(size: 12, weight: .semibold))
                if calendar.access != .granted {
                    Button(L("Allow calendar access")) { calendar.start() }.buttonStyle(.plain).foregroundColor(.accentColor).font(.system(size: 11))
                } else if calendar.todayEvents.isEmpty {
                    Text(L("No events")).font(.system(size: 11)).foregroundColor(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(calendar.todayEvents) { e in
                            HStack(spacing: 6) {
                                Capsule().fill(Color(nsColor: e.color)).frame(width: 3, height: 24)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(e.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                    Text(e.isAllDay ? L("All day") : Fmt.clock(e.start))
                                        .font(.system(size: 9.5)).foregroundColor(.secondary)
                                }
                                Spacer()
                                if let link = e.link {
                                    Button(action: { NSWorkspace.shared.open(link) }) { Image(systemName: "video.fill") }
                                        .buttonStyle(.plain).font(.system(size: 10))
                                }
                            }
                            .opacity(e.end < Date() ? 0.45 : 1)
                        }
                    }
                }
            }
        }
    }

    private var grid: some View {
        let base = cal.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
        let comps = cal.dateComponents([.year, .month], from: base)
        let first = cal.date(from: comps) ?? base
        let days = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let cells: [Int?] = Array(repeating: nil, count: lead) + (1...days).map { Optional($0) }
        let isThisMonth = monthOffset == 0
        let today = cal.component(.day, from: Date())

        return VStack(spacing: 4) {
            HStack {
                Button(action: { monthOffset -= 1 }) { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Spacer()
                Text(first.formatted(.dateTime.month(.wide).year().locale(L10n.locale)).capitalized(with: L10n.locale)).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: { monthOffset += 1 }) { Image(systemName: "chevron.right") }.buttonStyle(.plain)
            }
            .font(.system(size: 10))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(Array(weekdayHeaders.enumerated()), id: \.offset) {
                    Text($0.element).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, d in
                    Text(d.map(String.init) ?? "")
                        .font(.system(size: 10.5, weight: isThisMonth && d == today ? .bold : .regular).monospacedDigit())
                        .frame(width: 24, height: 17)
                        .background(Circle().fill(isThisMonth && d == today ? Color.red : .clear).frame(width: 19, height: 19))
                }
            }
        }
    }
}

// MARK: - Mirror (camera)

final class CameraPreviewView: NSView {
    private let session = AVCaptureSession()
    private var configured = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { nil }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { return }
            DispatchQueue.main.async { self.configureAndRun() }
        }
    }

    private func configureAndRun() {
        if !configured {
            configured = true
            session.sessionPreset = .medium
            guard let dev = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else { return }
            session.addInput(input)
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = bounds
            preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            if let c = preview.connection, c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = true
            }
            layer?.addSublayer(preview)
        }
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { if !s.isRunning { s.startRunning() } }
    }

    func stop() {
        let s = session
        DispatchQueue.global(qos: .utility).async { if s.isRunning { s.stopRunning() } }
    }
}

struct MirrorView: NSViewRepresentable {
    func makeNSView(context: Context) -> CameraPreviewView {
        let v = CameraPreviewView(frame: .zero)
        v.start()
        return v
    }
    func updateNSView(_ nsView: CameraPreviewView, context: Context) {}
    static func dismantleNSView(_ nsView: CameraPreviewView, coordinator: ()) { nsView.stop() }
}
