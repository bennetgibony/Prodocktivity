import AppKit

struct AppItem: Identifiable {
    let id: String // bundle identifier
    let name: String
    let icon: NSImage
    let running: NSRunningApplication?
    var isRunning: Bool { running != nil }
}

/// A browser tab pinned to the top grid next to apps.
struct PinnedTab: Identifiable {
    let id: String // the raw pin entry
    let url: String
    let title: String
    var host: String? { URL(string: url)?.host }
}

enum PinnedEntry: Identifiable {
    case app(AppItem)
    /// A website pinned only in the sidebar (couldn't be made an Arc favorite).
    case tab(PinnedTab)
    /// An Arc favorite, kept in sync with Arc.
    case favorite(BrowserItem)

    var id: String {
        switch self {
        case .app(let a): return a.id
        case .tab(let t): return t.id
        case .favorite(let f): return AppsModel.favoritePinID(f.id)
        }
    }
}

@MainActor
final class AppsModel: ObservableObject {
    /// New users start with an empty pin area (no one else's favourite apps).
    static let defaultPins: [String] = []

    @Published private(set) var pinnedIDs: [String] {
        didSet { defaults.set(pinnedIDs, forKey: "pinnedBundleIDs") }
    }
    @Published private(set) var running: [NSRunningApplication] = []
    @Published private(set) var frontmostID: String?
    /// Bundle id currently being dragged inside the sidebar (for live reordering).
    @Published var draggingID: String?

    private var observers: [NSObjectProtocol] = []
    private var iconCache: [String: NSImage] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pinnedIDs = defaults.stringArray(forKey: "pinnedBundleIDs") ?? Self.defaultPins
        pinIcons = defaults.dictionary(forKey: "pinIcons") as? [String: String] ?? [:]
        hiddenFromTabs = Set(defaults.stringArray(forKey: "hiddenFromTabs") ?? [])
        openAsWebsite = defaults.dictionary(forKey: "openAsWebsite") as? [String: String] ?? [:]
        keptDuplicates = Set(defaults.stringArray(forKey: "keptDuplicates") ?? [])
        spaceApps = defaults.dictionary(forKey: "spaceApps") as? [String: [String]] ?? [:]
        openIn = defaults.dictionary(forKey: "openApps.workspace") as? [String: String] ?? [:]
        reload()
        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let quit = name == NSWorkspace.didTerminateApplicationNotification ? app?.processIdentifier : nil
                MainActor.assumeIsolated {
                    // Any app that quits (⌘Q, the Dock, the bar, Auto-Quit) can be opened again with ⌘Y / ⌃⌥Y.
                    if quit != nil, let app, app.activationPolicy == .regular, let id = app.bundleIdentifier,
                       id != Bundle.main.bundleIdentifier {
                        Reopen.closed(.app(id))
                    }
                    self?.reload(excluding: quit)
                    // The system's app list can lag behind the notification: check again shortly.
                    if quit != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                            MainActor.assumeIsolated { self?.reload() }
                        }
                    }
                }
            })
        }
    }

    /// Re-reads the running apps. `excluding` drops an app that just quit even if the system
    /// still lists it for a moment (that lag left closed apps in the bar).
    func reload(excluding quitPID: pid_t? = nil) {
        let me = getpid()
        let now = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.processIdentifier != me
                && !$0.isTerminated && $0.processIdentifier != quitPID
        }
        // Only publish real changes: every update redraws the whole sidebar.
        let key = { (apps: [NSRunningApplication]) in apps.map { "\($0.processIdentifier)\($0.isHidden)" } }
        if key(now) != key(running) { running = now }
        let newFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if newFront != frontmostID { frontmostID = newFront }
        noteOpenApps(running: running.compactMap(\.bundleIdentifier), activeSpace: library?.activeSpaceID)
    }

    // MARK: Open apps per workspace

    /// The workspace each open app was opened in (bundle id → workspace id). Kept for every app, so
    /// "Open apps: only in their workspace" works as soon as it's switched on.
    @Published private(set) var openIn: [String: String] {
        didSet { defaults.set(openIn, forKey: "openApps.workspace") }
    }

    /// A newly opened app belongs to the workspace open at that moment; a quit app is forgotten.
    func noteOpenApps(running ids: [String], activeSpace: String?) {
        var next = openIn.filter { ids.contains($0.key) }
        if let activeSpace { for id in ids where next[id] == nil { next[id] = activeSpace } }
        if next != openIn { openIn = next }
    }

    /// Moves an open app to another workspace (drag onto a workspace icon, or Move to Workspace).
    func assignOpenApp(_ id: String, to space: String) {
        openIn[id] = space
    }

    /// Open apps shown in a workspace's Open area: all of them, or only those opened there.
    func openApps(inSpace space: String?, perWorkspace: Bool) -> [AppItem] {
        guard perWorkspace, let space else { return unpinnedRunningItems }
        return unpinnedRunningItems.filter { (openIn[$0.id] ?? space) == space }
    }

    /// Pin entries are bundle ids, "fav␟<tab id>" for Arc favorites, or
    /// "tab␟<url>␟<title>" for sidebar-only website pins.
    nonisolated static func tabPinID(url: String, title: String) -> String { "tab\u{1F}\(url)\u{1F}\(title)" }
    nonisolated static func favoritePinID(_ tabID: String) -> String { "fav\u{1F}\(tabID)" }

    private func localTabURL(_ raw: String) -> String? {
        guard raw.hasPrefix("tab\u{1F}") else { return nil }
        let parts = raw.split(separator: "\u{1F}", omittingEmptySubsequences: false)
        return parts.count >= 2 ? String(parts[1]) : nil
    }

    /// The one pin area: apps, Arc favorites and sidebar-only website pins, in the user's order.
    func pinnedEntries(favorites: [BrowserItem]) -> [PinnedEntry] {
        let favs = Dictionary(favorites.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return pinnedIDs.compactMap { raw in
            if raw.hasPrefix("fav\u{1F}") {
                return favs[String(raw.dropFirst(4))].map(PinnedEntry.favorite)
            }
            if raw.hasPrefix("tab\u{1F}") {
                let parts = raw.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 3 else { return nil }
                return .tab(PinnedTab(id: raw, url: parts[1], title: parts[2]))
            }
            return item(for: raw).map(PinnedEntry.app)
        }
    }

    /// Keeps the pin area in sync with Arc's favorites: new favorites are added, removed ones
    /// dropped, and sidebar-only website pins that became favorites are replaced in place.
    /// Only call with a fresh list from a running Arc.
    func syncFavorites(_ favorites: [BrowserItem]) {
        let favIDs = Set(favorites.map(\.id))
        var ids = pinnedIDs.filter { !$0.hasPrefix("fav\u{1F}") || favIDs.contains(String($0.dropFirst(4))) }
        for fav in favorites where !ids.contains(Self.favoritePinID(fav.id)) {
            if let i = ids.firstIndex(where: { localTabURL($0) == fav.url }) {
                ids[i] = Self.favoritePinID(fav.id)
            } else {
                ids.append(Self.favoritePinID(fav.id))
            }
        }
        if ids != pinnedIDs { pinnedIDs = ids }
    }

    // MARK: Custom pin icons

    /// Icon from the built-in set chosen for a pin (pin id or sidebar item id → icon key).
    @Published private(set) var pinIcons: [String: String] {
        didSet { defaults.set(pinIcons, forKey: "pinIcons") }
    }

    func setIcon(_ key: String?, for id: String) { pinIcons[id] = key }

    // MARK: Apps kept out of the tab list

    /// Apps that shouldn't appear among the tabs (e.g. menu-bar utilities like AlDente).
    @Published private(set) var hiddenFromTabs: Set<String> {
        didSet { defaults.set(Array(hiddenFromTabs), forKey: "hiddenFromTabs") }
    }

    func setHiddenFromTabs(_ id: String, _ hidden: Bool) {
        if hidden { hiddenFromTabs.insert(id) } else { hiddenFromTabs.remove(id) }
    }

    func displayName(for id: String) -> String {
        if let app = running.first(where: { $0.bundleIdentifier == id }) { return app.localizedName ?? id }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
    }

    // MARK: Open wrapper apps as a website

    /// Websites of common apps that are mostly a browser wrapper.
    static let knownWebApps: [String: String] = [
        "notion.id": "https://www.notion.so", "com.tinyspeck.slackmacgap": "https://app.slack.com/client",
        "net.whatsapp.WhatsApp": "https://web.whatsapp.com", "desktop.WhatsApp": "https://web.whatsapp.com",
        "com.spotify.client": "https://open.spotify.com", "me.superfocus.desktop": "https://app.superfocus.me",
        "com.hnc.Discord": "https://discord.com/app", "com.figma.Desktop": "https://www.figma.com/files",
        "com.linear": "https://linear.app", "com.microsoft.teams2": "https://teams.microsoft.com",
        "com.openai.chat": "https://chatgpt.com", "com.anthropic.claudefordesktop": "https://claude.ai",
        "io.remnote": "https://www.remnote.com", "com.readdle.SparkDesktop": "https://web.sparkmailapp.com",
    ]

    /// Apps set to open as an Arc tab instead (bundle id → URL).
    @Published private(set) var openAsWebsite: [String: String] {
        didSet { defaults.set(openAsWebsite, forKey: "openAsWebsite") }
    }

    /// Opens a URL in the browser; set by the app delegate.
    var openWebsite: ((String, Bool) -> Void)?

    func setOpenAsWebsite(_ id: String, url: String?) { openAsWebsite[id] = url }

    // MARK: Duplicates kept on purpose

    /// "bundleID␟host" pairs the user chose to keep both of (their marker is hidden).
    @Published private(set) var keptDuplicates: Set<String> {
        didSet { defaults.set(Array(keptDuplicates), forKey: "keptDuplicates") }
    }

    nonisolated static func duplicateKey(app: String, url: String) -> String {
        "\(app)\u{1F}\(URL(string: url)?.host ?? url)"
    }

    func keepBoth(app: String, url: String) { keptDuplicates.insert(Self.duplicateKey(app: app, url: url)) }

    func isKeptDuplicate(app: String, url: String) -> Bool {
        keptDuplicates.contains(Self.duplicateKey(app: app, url: url))
    }

    /// Sidebar-first: turns synced Arc-favorite pins into the sidebar's own website pins.
    func convertFavoritePins(_ favorites: [BrowserItem]) {
        let favs = Dictionary(favorites.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        pinnedIDs = pinnedIDs.compactMap { raw in
            guard raw.hasPrefix("fav\u{1F}") else { return raw }
            guard let f = favs[String(raw.dropFirst(4))] else { return nil }
            let tab = Self.tabPinID(url: f.url, title: f.title)
            return tab
        }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Moves per-space app lists from an old space id to a new one.
    func migrateSpaceApps(from old: String, to new: String) {
        guard old != new, let list = spaceApps[old] else { return }
        spaceApps[new, default: []] += list.filter { !(spaceApps[new] ?? []).contains($0) }
        spaceApps[old] = nil
    }

    // MARK: Apps per space

    /// Apps assigned to an Arc space (space id → bundle ids).
    @Published private(set) var spaceApps: [String: [String]] {
        didSet { defaults.set(spaceApps, forKey: "spaceApps") }
    }

    /// Space apps now live in the sidebar library, next to websites and inside folders.
    weak var library: Library?

    func apps(forSpace space: String) -> [AppItem] {
        guard let library, let s = library.spaces.first(where: { $0.id == space }) else { return [] }
        return Library.allApps(s.pinned).compactMap { appItem(for: $0.url) }
    }

    func addApp(_ id: String, toSpace space: String) {
        guard let library, !library.containsApp(id, inSpace: space) else { return }
        library.add(.app(id, title: displayName(for: id)), toSpace: space)
    }

    func removeApp(_ id: String, fromSpace space: String) {
        library?.removeApp(id, fromSpace: space)
    }

    /// Moves apps from the old per-space lists into the library (once).
    func migrateSpaceAppsToLibrary() {
        guard let library, !spaceApps.isEmpty else { return }
        for (space, ids) in spaceApps where library.spaces.contains(where: { $0.id == space }) {
            for id in ids.reversed() where !library.containsApp(id, inSpace: space) {
                let first = library.spaces.first { $0.id == space }?.pinned.first?.id
                library.add(.app(id, title: displayName(for: id)), toSpace: space, before: first)
            }
        }
        spaceApps = [:]
    }

    func appItem(for id: String) -> AppItem? { item(for: id) }

    /// Reorders a space's apps while dragging (moves past the target, like the pin grid).
    func moveSpaceApp(_ id: String, over target: String, space: String) {
        guard var list = spaceApps[space], let from = list.firstIndex(of: id), let to = list.firstIndex(of: target), from != to else { return }
        list.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        spaceApps[space] = list
    }

    func isInAnySpace(_ id: String) -> Bool {
        library?.containsAppAnywhere(id) ?? false
    }

    func isApp(_ id: String, inSpace space: String) -> Bool {
        library?.containsApp(id, inSpace: space) ?? false
    }

    func isTabPinned(url: String) -> Bool {
        pinnedIDs.contains { $0.hasPrefix("tab\u{1F}\(url)\u{1F}") }
    }

    func pinTab(url: String, title: String, before target: String? = nil) {
        guard !url.isEmpty, !isTabPinned(url: url) else { return }
        pin(Self.tabPinID(url: url, title: title), before: target)
    }

    var unpinnedRunningItems: [AppItem] {
        running.compactMap { app in
            // Apps assigned to a space only show inside that space's card.
            guard let id = app.bundleIdentifier, !pinnedIDs.contains(id), !isInAnySpace(id),
                  !hiddenFromTabs.contains(id) else { return nil }
            return AppItem(id: id, name: app.localizedName ?? id, icon: icon(for: id, app: app), running: app)
        }
    }

    private func item(for id: String) -> AppItem? {
        if let app = running.first(where: { $0.bundleIdentifier == id }) {
            return AppItem(id: id, name: app.localizedName ?? id, icon: icon(for: id, app: app), running: app)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return AppItem(id: id, name: name, icon: icon(for: id, app: nil), running: nil)
    }

    private func icon(for id: String, app: NSRunningApplication?) -> NSImage {
        if let cached = iconCache[id] { return cached }
        let image = app?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
        iconCache[id] = image
        return image
    }

    // MARK: Actions

    /// Launches or activates the app and snaps its front window next to the sidebar.
    /// With `split`, the previously frontmost app keeps the left half and this app takes the right.
    func open(_ id: String, split: Bool = false) {
        // ⌃-click: frozen on the left half (or released).
        if FreezeClick.consume() {
            if Freeze.shared.isFrozen(app: id) { Freeze.shared.release() } else { Freeze.shared.freezeApp(id, side: .left) }
            return
        }
        Log.write("open \(id) split=\(split)")
        if let url = openAsWebsite[id], let openWebsite {
            openWebsite(url, split)
            return
        }
        let previous = NSWorkspace.shared.frontmostApplication
        let previousTarget = split ? SplitManager.shared.currentTarget() : nil
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        // Finder is always running, so opening it may show nothing: give it a window if it has none.
        if id == "com.apple.finder", let finder = running.first(where: { $0.bundleIdentifier == id }),
           !Self.hasWindowOnScreen(pid: finder.processIdentifier) {
            finder.unhide()
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
            frontmostID = id
            return
        }
        let alreadyRunning = running.first(where: { $0.bundleIdentifier == id })
        alreadyRunning?.unhide()
        frontmostID = id
        // Split: the app in front keeps the left half, this one takes the right. The built-in
        // browser counts as the app in front while its window shows (the bar never takes the focus).
        let left: pid_t? = {
            guard split, let prev = previous, prev.bundleIdentifier != id else { return nil }
            if prev.processIdentifier == getpid() { return WebBrowser.shared.isWindowVisible ? getpid() : nil }
            return prev.processIdentifier
        }()
        let leftTarget: SplitTarget? = left == getpid()
            ? WebBrowser.shared.activeTab.map { .tab(id: $0.id, url: $0.url, title: $0.title) } : previousTarget
        let arrange = { (pid: pid_t) in
            if let left {
                Log.write("split left=\(previous?.bundleIdentifier ?? "?") right=\(id) pid=\(pid)")
                WindowManager.split(left: left, right: pid)
                if let leftTarget { SplitManager.shared.record(left: leftTarget, right: .app(bundleID: id)) }
            } else if !WindowRules.shared.placeOpenedApp(pid: pid, bundleID: id) {
                WindowManager.fillIfEnabled(pid: pid)
            }
        }
        // A running app is arranged right away: waiting for it to answer "open" first can take
        // seconds when it's busy (some apps do), and looked like a freeze. Snapping retries until
        // its window is there.
        if let alreadyRunning { arrange(alreadyRunning.processIdentifier) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        // openApplication (instead of NSRunningApplication.activate) reliably brings the app
        // forward from a background accessory app and reopens a window if it has none.
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            guard let pid = app?.processIdentifier else {
                Log.write("open \(id) failed: \(error?.localizedDescription ?? "no app")")
                return
            }
            // Also when arranged already: some apps put their window back on activation, or only
            // now have one. A window already in place isn't touched.
            Task { @MainActor in arrange(pid) }
        }
    }

    /// Whether an app shows a normal window on screen (the Finder desktop doesn't count).
    private static func hasWindowOnScreen(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return true }
        return list.contains { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == pid && (info[kCGWindowLayer as String] as? Int) == 0
                && ((info[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) > 120
        }
    }

    func quit(_ id: String) {
        guard let app = running.first(where: { $0.bundleIdentifier == id }) else { return }
        app.terminate()
        Reopen.closed(.app(id))
        // Show it as closed right away; the system notification confirms it a moment later.
        running.removeAll { $0.bundleIdentifier == id }
        // Some apps ask before quitting; re-check shortly so the list matches reality.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func hide(_ id: String) {
        running.first(where: { $0.bundleIdentifier == id })?.hide()
    }

    func revealInFinder(_ id: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }

    func pin(_ id: String, before target: String? = nil) {
        guard !pinnedIDs.contains(id) else { return }
        if let target, let idx = pinnedIDs.firstIndex(of: target) {
            pinnedIDs.insert(id, at: idx)
        } else {
            pinnedIDs.append(id)
        }
    }

    func unpin(_ id: String) {
        pinnedIDs.removeAll { $0 == id }
    }

    /// Moves pinned `id` to the position of pinned `target`.
    func movePin(_ id: String, to target: String) {
        guard id != target,
              let from = pinnedIDs.firstIndex(of: id),
              let to = pinnedIDs.firstIndex(of: target) else { return }
        pinnedIDs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }
}
