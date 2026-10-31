import Foundation

/// Spots tools you have both as an app and as a website (e.g. the Notion app and a
/// notion.so tab). They're only marked, never merged.
enum Duplicates {
    /// Words too generic to identify a product.
    private static let generic: Set<String> = [
        "com", "net", "org", "io", "me", "so", "co", "app", "apps", "desktop", "mac", "macos", "www", "web",
        "open", "mail", "the", "for", "and", "client", "electron", "helper", "inc", "google", "apple", "id",
    ]

    /// Keywords are looked up for every tile on every redraw: each name and address is
    /// split up only once.
    private static let cache = KeywordCache()

    /// Distinctive lowercase words from an app's name and bundle id.
    static func keywords(appName: String, bundleID: String) -> Set<String> {
        cache.words(for: "app\u{1F}\(appName)\u{1F}\(bundleID)") { appKeywords(appName: appName, bundleID: bundleID) }
    }

    private static func appKeywords(appName: String, bundleID: String) -> Set<String> {
        var words = Set<String>()
        for part in appName.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) { words.insert(String(part)) }
        for part in bundleID.lowercased().split(separator: ".") { words.insert(String(part)) }
        return words.filter { $0.count >= 4 && !generic.contains($0) }
    }

    /// Distinctive lowercase labels of a URL's host (e.g. "app.superfocus.me" → ["superfocus"]).
    static func keywords(url: String) -> Set<String> {
        cache.words(for: "url\u{1F}" + url) { urlKeywords(url) }
    }

    private static func urlKeywords(_ url: String) -> Set<String> {
        guard let host = URL(string: url)?.host?.lowercased() else { return [] }
        return Set(host.split(separator: ".").map(String.init)).filter { $0.count >= 4 && !generic.contains($0) }
    }

    static func matches(appName: String, bundleID: String, url: String) -> Bool {
        let site = keywords(url: url)
        guard !site.isEmpty else { return false }
        return keywords(appName: appName, bundleID: bundleID).contains { word in
            site.contains { $0 == word || ($0.count >= 5 && word.hasPrefix($0)) || (word.count >= 5 && $0.hasPrefix(word)) }
        }
    }
}

/// A small thread-safe memo of keyword sets (cleared when it grows large).
private final class KeywordCache: @unchecked Sendable {
    private var store: [String: Set<String>] = [:]
    private let lock = NSLock()

    func words(for key: String, _ make: () -> Set<String>) -> Set<String> {
        lock.lock()
        if let hit = store[key] { lock.unlock(); return hit }
        lock.unlock()
        let words = make()
        lock.lock()
        if store.count > 2000 { store.removeAll() }
        store[key] = words
        lock.unlock()
        return words
    }
}
