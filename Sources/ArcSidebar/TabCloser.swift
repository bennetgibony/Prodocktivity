import AppKit

/// Closes today's browser tabs you haven't looked at for a while (like Arc's auto-archive),
/// with a default time and per-space rules. Pinned websites (in spaces or the top pin area)
/// and the current tab are never closed.
@MainActor
final class TabCloser: ObservableObject {
    static let choices: [Int] = [30, 60, 120, 240, 480, 720, 1440, 2880, 4320, 10080] // minutes

    /// Off by default; turned on in Settings → Auto-Quit → Tabs.
    @Published var enabled: Bool { didSet { save() } }
    @Published var minutes: Int { didSet { save() } }
    /// Space id → minutes; 0 = never close tabs in that space. Missing = default.
    @Published var spaceRules: [String: Int] { didSet { save() } }
    /// Website exceptions: host → minutes; 0 = never close tabs of that site.
    @Published var siteRules: [String: Int] { didSet { save() } }
    /// Open tabs of websites in Favorites: 0 = never closed (the default), otherwise after this
    /// time the tab closes and the Favorite stays.
    @Published var favoritesMinutes: Int { didSet { save() } }

    private weak var browser: BrowserModel?
    private weak var apps: AppsModel?
    private var lastSeen: [String: Date] = [:]
    private var timer: Timer?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "tabs.autoClose")
        minutes = defaults.object(forKey: "tabs.autoCloseMinutes") as? Int ?? 720
        spaceRules = defaults.dictionary(forKey: "tabs.spaceRules") as? [String: Int] ?? [:]
        siteRules = defaults.dictionary(forKey: "tabs.siteRules") as? [String: Int] ?? [:]
        favoritesMinutes = defaults.object(forKey: "tabs.favoritesMinutes") as? Int ?? 0
        // When each tab was last looked at survives a restart; otherwise every launch starts
        // all the clocks over and tabs are never closed for anyone who restarts daily.
        let saved = defaults.dictionary(forKey: "tabs.lastSeen") as? [String: Double] ?? [:]
        lastSeen = saved.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// "www.gmail.com", "https://gmail.com/x" → "gmail.com".
    static func host(_ input: String) -> String? {
        let t = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        let host = URL(string: t.contains("://") ? t : "https://" + t)?.host ?? t
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The exception for a tab's address, if one matches (also subdomains: mail.google.com → google.com).
    func siteRule(for url: String) -> Int? {
        guard var host = Self.host(url) else { return nil }
        while true {
            if let r = siteRules[host] { return r }
            guard let dot = host.firstIndex(of: "."), host[host.index(after: dot)...].contains(".") else { return nil }
            host = String(host[host.index(after: dot)...])
        }
    }

    func attach(browser: BrowserModel, apps: AppsModel) {
        self.browser = browser
        self.apps = apps
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 2
    }

    static func label(_ minutes: Int) -> String {
        minutes == 0 ? "Never" : Formats.duration(minutes: minutes)
    }

    func rule(forSpace id: String?) -> Int {
        guard let id, let r = spaceRules[id] else { return minutes }
        return r
    }

    private func tick() {
        guard let browser, browser.status == .ok else { return }
        let now = Date()
        let snap = browser.snapshot
        // Remember when each tab was last on screen: the one in front, and a tab frozen on one
        // half or shown on the left of a split (visible too, though not the "current" tab).
        let onScreen = [snap.activeTabID, WebBrowser.shared.frozenTabID, WebBrowser.shared.splitTabID]
        for case let id? in onScreen { lastSeen[id] = now }

        // Today's tabs per browser space, plus tabs not placed in any space.
        var candidates: [(tab: BrowserItem, arcSpace: String?)] = []
        for space in snap.spaces { for tab in space.unpinned.flatMap(\.allTabs) { candidates.append((tab, space.id)) } }
        for tab in snap.otherTabs { candidates.append((tab, nil)) }

        let before = lastSeen
        lastSeen = Self.remember(lastSeen, open: Set(candidates.map(\.tab.id)), now: now)
        defer { if lastSeen != before { defaults.set(lastSeen.mapValues(\.timeIntervalSince1970), forKey: "tabs.lastSeen") } }
        guard enabled else { return }

        // Never close what's pinned in a workspace; Favorites have a time of their own.
        let pins = visibleWebsites(browser).filter { !$0.id.isEmpty && isPin($0.id) }
        let favoriteURLs = Set(pins.filter { isFavorite($0.id) }.map(\.url))
        let pinnedURLs = Set(pins.filter { !isFavorite($0.id) }.map(\.url))
        let due = dueTabs(candidates.map { ($0.tab, browser.library?.space(linkedTo: $0.arcSpace)?.id) },
                          onScreen: Set(onScreen.compactMap { $0 }), pinnedURLs: pinnedURLs,
                          favoriteURLs: favoriteURLs, now: now)
        for (tab, limit) in due {
            Log.write("auto-close tab after \(Self.label(limit)): \(tab.url)")
            lastSeen[tab.id] = nil
            browser.close(tab)
        }
    }

    /// When each tab was last seen: closed tabs are forgotten, newly seen ones start now.
    static func remember(_ lastSeen: [String: Date], open: Set<String>, now: Date) -> [String: Date] {
        var seen = lastSeen.filter { open.contains($0.key) }
        for id in open where seen[id] == nil { seen[id] = now }
        return seen
    }

    /// Today's tabs (with the sidebar space they're in) whose time is up, with the limit that
    /// applied: a site exception wins over the Favorites time, that over the space's rule; 0 means never.
    func dueTabs(_ candidates: [(tab: BrowserItem, space: String?)], onScreen: Set<String>,
                 pinnedURLs: Set<String>, favoriteURLs: Set<String> = [], now: Date) -> [(tab: BrowserItem, limit: Int)] {
        candidates.compactMap { c in
            guard !onScreen.contains(c.tab.id), !pinnedURLs.contains(c.tab.url) else { return nil }
            let limit = siteRule(for: c.tab.url)
                ?? (favoriteURLs.contains(c.tab.url) ? favoritesMinutes : rule(forSpace: c.space))
            guard limit > 0, let seen = lastSeen[c.tab.id], now.timeIntervalSince(seen) >= Double(limit * 60) else { return nil }
            return (c.tab, limit)
        }
    }

    /// For tests: pretend a tab was last looked at then.
    func setLastSeen(_ id: String, _ date: Date) { lastSeen[id] = date }

    /// Sidebar pins: space pins ("lib:…") and top pins ("tab␟…" / favorites).
    private func isPin(_ id: String) -> Bool {
        id.hasPrefix(Library.idPrefix) || id.hasPrefix("tab\u{1F}") || (browser?.snapshot.favorites.contains { $0.id == id } ?? false)
    }

    /// Favorites: the top pins ("tab␟…" and the browser's own favorites).
    private func isFavorite(_ id: String) -> Bool {
        id.hasPrefix("tab\u{1F}") || (browser?.snapshot.favorites.contains { $0.id == id } ?? false)
    }

    private func save() {
        defaults.set(favoritesMinutes, forKey: "tabs.favoritesMinutes")
        defaults.set(enabled, forKey: "tabs.autoClose")
        defaults.set(minutes, forKey: "tabs.autoCloseMinutes")
        defaults.set(spaceRules, forKey: "tabs.spaceRules")
        defaults.set(siteRules, forKey: "tabs.siteRules")
    }
}
