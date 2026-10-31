import Foundation
@testable import ArcSidebar

/// The test run's storage folder: inside a test run the app's files (AppPaths) always go to a
/// temporary folder of their own, never to the real ~/Library/Application Support.
private let testRoot: URL = {
    let dir = AppPaths.directory
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

/// A fresh, empty folder for one test's own files (inside the test storage folder).
func sandbox() -> URL {
    let dir = testRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Where the app itself keeps files during tests.
var appStorage: URL { _ = testRoot; return AppPaths.directory }

/// Empty settings of their own for one test, kept in memory only (never the app's real ones,
/// and no settings file left behind).
func freshDefaults() -> UserDefaults { MemoryDefaults() }

private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: nil)! }
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func dictionaryRepresentation() -> [String: Any] { values }
}
