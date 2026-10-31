import Foundation

/// Appends diagnostics to ~/Library/Logs/ArcSidebar.log. Past 1 MB the log moves to
/// ArcSidebar.old.log (replacing the previous one), so it never grows without end.
enum Log {
    // (Test runs log next to their own files, not into the app's log.)
    private static let url = AppPaths.isTestRun
        ? FileManager.default.temporaryDirectory.appendingPathComponent("proDOCKtivity-tests/ArcSidebar.log")
        : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ArcSidebar.log")
    private static let oldURL = url.deletingLastPathComponent().appendingPathComponent("ArcSidebar.old.log")
    private static let queue = DispatchQueue(label: "ArcSidebar.log")
    private static let maxSize: UInt64 = 1_000_000
    // Both only touched on `queue`.
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()
    nonisolated(unsafe) private static var handle: FileHandle?

    static func write(_ message: String) {
        let date = Date()
        queue.async {
            guard let data = "\(formatter.string(from: date)) \(message)\n".data(using: .utf8),
                  let file = openHandle() else { return }
            if ((try? file.seekToEnd()) ?? 0) > maxSize {
                try? file.close()
                handle = nil
                try? FileManager.default.removeItem(at: oldURL)
                try? FileManager.default.moveItem(at: url, to: oldURL)
            }
            try? openHandle()?.write(contentsOf: data)
        }
    }

    private static func openHandle() -> FileHandle? {
        if let handle { return handle }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }
}
