import Foundation

/// Plain diagnostics log at ~/Library/Logs/Rihtim/rihtim.log.
/// NSLog output doesn't reliably show up in the unified log for this app.
enum Diag {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Rihtim", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rihtim.log")
    }()
    private static let queue = DispatchQueue(label: "dev.minik.rihtim.diag")

    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                // start over past 1 MB
                if (try? h.seekToEnd()) ?? 0 > 1_000_000 { try? h.truncate(atOffset: 0) }
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
