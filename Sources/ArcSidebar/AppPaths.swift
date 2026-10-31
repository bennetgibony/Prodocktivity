import Foundation

/// Where proDOCKtivity keeps its files: ~/Library/Application Support/proDOCKtivity.
/// Tests point `directory` at a temporary folder first, so they never touch real data.
enum AppPaths {
    nonisolated(unsafe) static var directory: URL = {
        // Inside a test run never the real folder, even if a test forgot to set one.
        if isTestRun {
            // One fresh folder per test run, so runs never see each other's files.
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("proDOCKtivity-tests/\(UUID().uuidString)", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("proDOCKtivity", isDirectory: true)
        // Carry over data saved under the app's earlier name.
        let old = support.appendingPathComponent("producTABity", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: dir)
        }
        return dir
    }()

    static var isTestRun: Bool {
        // swift test (swiftpm-testing-helper), Xcode (xctest), or a test bundle run directly.
        ["swiftpm-testing-helper", "xctest"].contains(ProcessInfo.processInfo.processName)
            || Bundle.main.bundlePath.hasSuffix(".xctest")
            || CommandLine.arguments.contains { $0.contains(".xctest/") }
    }

    /// Reads a saved JSON file. Missing: nil. There but unreadable (damaged, or written by a
    /// newer version): it's moved aside as "<name>.damaged-<date>.json" before returning nil,
    /// so starting fresh can never overwrite data that might still be recovered.
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let name = url.deletingPathExtension().lastPathComponent + ".damaged-\(stamp)." + url.pathExtension
            let backup = url.deletingLastPathComponent().appendingPathComponent(name)
            try? FileManager.default.moveItem(at: url, to: backup)
            Log.write("couldn't read \(url.lastPathComponent) (\(error)); kept it as \(name)")
            return nil
        }
    }

    /// A file in the folder (the folder is created when needed).
    static func file(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
}
