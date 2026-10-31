import AppKit
import SwiftUI

struct RGB: Codable, Equatable, Sendable {
    var r: Double, g: Double, b: Double
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

/// A sidebar entry: a tab, a folder, or a split view holding tabs.
struct BrowserItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case tab, folder, split, app }
    let id: String
    var title: String
    var url: String
    let kind: Kind
    var children: [BrowserItem] = []
    /// A private tab (built-in browser): shown with a mask in the bar.
    var isIncognito = false

    var host: String? { URL(string: url)?.host }

    /// Every tab inside this item, including itself.
    var allTabs: [BrowserItem] { kind == .tab ? [self] : children.flatMap(\.allTabs) }
}

enum SpaceIcon: Equatable, Sendable {
    case emoji(String)
    case symbol(String)
}

struct BrowserSpace: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var icon: SpaceIcon?
    /// The browser's own color(s) for the space (Arc: one color or gradient stops).
    var colors: [RGB] = []
    /// Arc's grain setting for this space (0…1).
    var noise: Double?
    var pinned: [BrowserItem] = []
    var unpinned: [BrowserItem] = []
    /// The space's color and accent as chosen in the sidebar (nil: derived from `colors`).
    var areaChoice: Area?
    var accentChoice: Accent?

    /// The space's color (one of the 18): the bar, the frame and its dot.
    var area: Area { areaChoice ?? colors.first.map(Area.nearest) ?? .slate }
    /// The space's accent (one of the 16): selection, focus, switches.
    var accent: Accent { accentChoice ?? colors.first.map(Accent.nearest) ?? .indigo }
}

struct BrowserSnapshot: Equatable, Sendable {
    /// Tabs shown in the browser's favorites/top area (Arc's "top apps").
    var favorites: [BrowserItem] = []
    var spaces: [BrowserSpace] = []
    /// Open tabs that couldn't be assigned to a space.
    var otherTabs: [BrowserItem] = []
    var activeTabID: String?
    var activeSpaceID: String?

    var activeSpace: BrowserSpace? {
        spaces.first(where: { $0.id == activeSpaceID }) ?? spaces.first
    }

    func tab(id: String) -> BrowserItem? {
        (favorites + spaces.flatMap { $0.pinned + $0.unpinned } + otherTabs)
            .lazy.flatMap(\.allTabs).first(where: { $0.id == id })
    }

    /// The open (unpinned) tabs, splits taken apart.
    var openTabs: [BrowserItem] { (spaces.flatMap(\.unpinned) + otherTabs).flatMap(\.allTabs) }

    /// Drops closed tabs from the open-tab lists (pinned tabs stay: closing only unloads them).
    mutating func removeTabs(_ ids: Set<String>) {
        func prune(_ items: [BrowserItem]) -> [BrowserItem] {
            items.compactMap { item in
                if item.kind == .tab { return ids.contains(item.id) ? nil : item }
                var copy = item
                copy.children = prune(item.children)
                // A split with one tab left is just that tab again.
                if item.kind == .split, copy.children.count < 2 { return copy.children.first }
                return copy
            }
        }
        for i in spaces.indices { spaces[i].unpinned = prune(spaces[i].unpinned) }
        otherTabs = prune(otherTabs)
    }
}

enum BrowserError: Error, Sendable {
    case notRunning
    case notAuthorized
    case script(String)
}

/// A scriptable browser. Implementations block and are called on a background queue,
/// so adding Chrome or Safari later means writing one more conforming type.
protocol BrowserProvider: AnyObject, Sendable {
    var displayName: String { get }
    var bundleID: String { get }
    func fetch() throws -> BrowserSnapshot
    func select(_ tab: BrowserItem, spaceID: String?) throws
    func close(_ tab: BrowserItem) throws
    func focus(spaceID: String) throws
    /// Opens a URL as a new tab in the current space.
    func open(url: String) throws
    /// Back / forward / reload in the active tab.
    func navigate(_ action: NavigationAction) throws
    /// Loads a URL in the active tab.
    func load(url: String) throws
    /// Creates a tab in the current space; returns its id if the browser reports it.
    func makeTab(url: String) throws -> String
    // Defaults below (Arc-like); listed here so engines can override them.
    var isBuiltIn: Bool { get }
    var hasSpaces: Bool { get }
    var spacesAreLibrary: Bool { get }
    func activate()
}

enum NavigationAction: String, Sendable { case back, forward, reload }

extension BrowserProvider {
    var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }
    /// The browser built into proDOCKtivity (no separate app, no polling limits).
    var isBuiltIn: Bool { false }
    /// Whether the browser has spaces of its own (Chrome doesn't: its tabs follow the active space).
    var hasSpaces: Bool { true }
    /// Whether the browser's spaces are the sidebar's own spaces (same ids).
    var spacesAreLibrary: Bool { false }
    var isArc: Bool { self is ArcProvider }

    /// Brings the browser to the front (launching it if needed).
    func activate() {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}

/// Where typed searches go.
enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckDuckGo, ecosia, bing, startpage
    var id: String { rawValue }
    var name: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .ecosia: return "Ecosia"
        case .bing: return "Bing"
        case .startpage: return "Startpage"
        }
    }
    var base: String {
        switch self {
        case .google: return "https://www.google.com/search?q="
        case .duckDuckGo: return "https://duckduckgo.com/?q="
        case .ecosia: return "https://www.ecosia.org/search?q="
        case .bing: return "https://www.bing.com/search?q="
        case .startpage: return "https://www.startpage.com/do/search?q="
        }
    }
}

/// Which browser shows websites.
enum BrowserEngine: String, CaseIterable, Identifiable {
    case builtIn, chrome, arc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .builtIn: return "Built-in (WebKit, separate logins per workspace)"
        case .chrome: return "Google Chrome (extensions, Claude in Chrome)"
        case .arc: return "Arc"
        }
    }

    func makeProvider() -> BrowserProvider {
        switch self {
        case .builtIn: return WebKitProvider()
        case .chrome: return ChromeProvider()
        case .arc: return ArcProvider()
        }
    }
}

@MainActor
final class BrowserModel: ObservableObject {
    enum Status: Equatable { case idle, ok, notRunning, notAuthorized, error(String) }

    private(set) var provider: BrowserProvider
    /// Bumped when the engine changes, so answers from the old one are ignored.
    private var generation = 0
    @Published private(set) var snapshot = BrowserSnapshot()
    @Published private(set) var status: Status = .idle
    /// Folder expansion, persisted (folder id → expanded).
    @Published private(set) var openFolders: Set<String> {
        didSet { UserDefaults.standard.set(Array(openFolders), forKey: "openFolders") }
    }

    /// Polling pauses while the sidebar is hidden.
    var isVisible = true { didSet { if isVisible { refresh() } } }

    private let queue = DispatchQueue(label: "ArcSidebar.browser-scripting", qos: .userInitiated)
    private var inFlight = false
    /// Ignore polled active-space values briefly after the user switches spaces here.
    private var pendingSpace: (id: String, until: Date)?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(provider: BrowserProvider) {
        self.provider = provider
        openFolders = Set(UserDefaults.standard.stringArray(forKey: "openFolders") ?? [])
    }

    /// Switches the browser engine; the sidebar's spaces and pins stay as they are.
    func use(_ newProvider: BrowserProvider) {
        guard type(of: newProvider) != type(of: provider) else { return }
        generation += 1
        provider = newProvider
        inFlight = false
        pendingSpace = nil
        recentlyClosed = [:]
        snapshot = BrowserSnapshot()
        status = .idle
        Log.write("browser engine -> \(newProvider.displayName)")
        refresh()
        updatePolling()
        if let space = library?.activeSpace, let id = browserSpaceID(for: space) {
            queue.async { try? newProvider.focus(spaceID: id) }
        }
    }

    /// The browser's space for a sidebar space (the linked Arc space, or the space itself
    /// for the built-in browser).
    func browserSpaceID(for space: LibrarySpace) -> String? {
        provider.spacesAreLibrary ? space.id : space.arcSpaceID
    }

    /// Whether open tabs are listed (always for the built-in browser; per sync level otherwise).
    var showsLiveTabs: Bool { provider.isBuiltIn || Settings.shared.arcSync != .off }

    /// The sidebar's own library (sidebar-first). When set, spaces and pins come from it.
    weak var library: Library?

    var activeSpace: BrowserSpace? {
        if let library, let s = library.activeSpace { return library.displaySpace(s, live: snapshot) }
        return snapshot.activeSpace
    }

    /// Spaces shown in the switcher.
    var displaySpaces: [BrowserSpace] {
        if let library, !library.spaces.isEmpty { return library.spaces.map { library.displaySpace($0, live: snapshot) } }
        return snapshot.spaces
    }

    /// Every live tab the browser reports.
    var liveTabs: [BrowserItem] {
        (snapshot.favorites + snapshot.spaces.flatMap { $0.pinned + $0.unpinned } + snapshot.otherTabs).flatMap(\.allTabs)
    }

    /// Open tabs of the space you're in, plus the favorites every space shares. Searching or
    /// opening a site only ever jumps to one of these; anything else opens here, in this space.
    var currentSpaceTabs: [BrowserItem] {
        let id = library?.activeSpace.flatMap(browserSpaceID) ?? snapshot.activeSpaceID
        let space = snapshot.spaces.first { $0.id == id }
        return (snapshot.favorites + (space.map { $0.pinned + $0.unpinned } ?? [])).flatMap(\.allTabs)
    }

    /// After a ⌃-click: the website opens and is frozen on the left half (released if it's frozen
    /// already). Only the built-in browser can freeze a tab; Arc and Chrome just open it.
    private func freezeInstead(tabID: String?, open: @escaping () -> Void) -> Bool {
        guard FreezeClick.consume() else { return false }
        guard provider.isBuiltIn else { open(); return true }
        if Freeze.shared.isFrozen(tab: tabID) { Freeze.shared.release() } else { Freeze.shared.freezeSite(side: .left, open: open) }
        return true
    }

    func isInCurrentSpace(_ tab: BrowserItem) -> Bool { currentSpaceTabs.contains { $0.id == tab.id } }

    /// An open tab: switches to it if it's in this space, otherwise opens its page here.
    func openHere(_ tab: BrowserItem, split: Bool = false) {
        if freezeInstead(tabID: tab.id, open: { [weak self] in self?.openHere(tab) }) { return }
        if isInCurrentSpace(tab) { select(tab, spaceID: nil, split: split) } else { openPinned(url: tab.url, split: split) }
    }

    /// Opens a sidebar website: selects its tab if open, otherwise creates it in the linked space.
    func openSite(_ item: BrowserItem, split: Bool = false) {
        if freezeInstead(tabID: nil, open: { [weak self] in self?.openSite(item) }) { return }
        withFreshSnapshot { [weak self] in self?.openSiteNow(item, split: split) }
    }

    private func openSiteNow(_ item: BrowserItem, split: Bool) {
        guard let id = Library.libraryID(item.id), let site = library?.find(id) else { return }
        let arcSpace = library?.spaces.first { s in Library.allSites(s.pinned).contains { $0.id == id } }.flatMap(browserSpaceID)
        let tabs = currentSpaceTabs
        if let tab = tabs.first(where: { $0.id == site.arcTabID }) ?? tabs.first(where: { $0.url == site.url })
            ?? tabs.first(where: { sameHostAndPath($0.url, site.url) }) {
            select(tab, spaceID: arcSpace, split: split)
        } else {
            // Remember the new tab, so the pin finds it again after navigating.
            createTab(input: site.url, split: split) { [weak self] tabID in self?.library?.setArcTabID(id, tabID) }
        }
    }

    /// Whether a sidebar website is the browser's current tab.
    func isActiveSite(_ item: BrowserItem) -> Bool {
        guard let id = Library.libraryID(item.id), let site = library?.find(id),
              let activeID = snapshot.activeTabID else { return false }
        if site.arcTabID == activeID { return true }
        guard let tab = snapshot.tab(id: activeID) else { return false }
        return tab.url == site.url || sameHostAndPath(tab.url, site.url)
    }

    func start() {
        refresh()
        updatePolling()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didDeactivateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self, !self.provider.isBuiltIn, app?.bundleIdentifier == self.provider.bundleID else { return }
                    if name == NSWorkspace.didTerminateApplicationNotification {
                        // Clear the browser's tabs right away, whatever the sync level.
                        self.status = .notRunning
                        self.snapshot = BrowserSnapshot()
                        return
                    }
                    guard Settings.shared.arcSync != .off else { return }
                    self.refresh()
                }
            })
        }
    }

    /// Arc and Chrome are asked for their tabs every second; the built-in browser reports its
    /// own changes, so it needs no timer (that only woke the Mac up for nothing).
    private func updatePolling() {
        if provider.isBuiltIn {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollIfNeeded() }
            }
            t.tolerance = 0.2
            timer = t
        }
    }

    private var lastFetch = Date.distantPast
    /// Run once with the next fresh snapshot (used when syncing is off).
    private var afterFetch: [() -> Void] = []

    /// Decides, per sync level, whether to ask the browser for its tabs right now.
    private func pollIfNeeded() {
        // The built-in browser reports its own changes; no need to ask every second.
        if provider.isBuiltIn { if status == .idle { refresh() }; return }
        let mode = Settings.shared.arcSync
        (provider as? ArcProvider)?.fullFetchInterval = mode == .live ? 10 : 60
        switch mode {
        case .live:
            refresh()
        case .light:
            let browserInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == provider.bundleID
            if browserInFront || Date().timeIntervalSince(lastFetch) > 15 { refresh() }
        case .off:
            // Only the initial check, so the sidebar knows whether the browser is there.
            if status == .idle { refresh() }
        }
    }

    /// With syncing off, fetches once right before acting on fresh data.
    func withFreshSnapshot(_ action: @escaping () -> Void) {
        guard !showsLiveTabs, Date().timeIntervalSince(lastFetch) > 2 else { action(); return }
        afterFetch.append(action)
        refresh()
    }

    func refresh() {
        guard isVisible, !inFlight else { return }
        guard provider.runningApp != nil else {
            if status != .notRunning { status = .notRunning; snapshot = BrowserSnapshot() }
            return
        }
        inFlight = true
        let provider = provider
        let generation = generation
        queue.async {
            let result: Result<BrowserSnapshot, Error> = Result { try provider.fetch() }
            Task { @MainActor [weak self] in
                guard let self, generation == self.generation else { return }
                self.apply(result)
            }
        }
    }

    private func apply(_ result: Result<BrowserSnapshot, Error>) {
        inFlight = false
        lastFetch = Date()
        defer {
            let pending = afterFetch
            afterFetch = []
            pending.forEach { $0() }
        }
        switch result {
        case .success(var snap):
            // Tabs closed from the sidebar stay hidden even if a fetch that started before
            // the close (or Arc's slowly written sidebar file) still lists them.
            recentlyClosed = recentlyClosed.filter { Date().timeIntervalSince($0.value) < 30 }
            if !recentlyClosed.isEmpty { snap.removeTabs(Set(recentlyClosed.keys)) }
            if let pending = pendingSpace {
                if Date() < pending.until, snap.activeSpaceID != pending.id {
                    snap.activeSpaceID = pending.id
                } else {
                    pendingSpace = nil
                }
            }
            if snap.activeSpaceID != snapshot.activeSpaceID {
                if pendingSpace == nil { library?.follow(arcSpaceID: snap.activeSpaceID) }
                Log.write("active space -> \(snap.activeSpace?.title ?? "?") colors=\(snap.activeSpace?.colors.count ?? 0)")
            }
            // Arc / Chrome: a tab closed there (⌘W in the browser) can come back with ⌘Y / ⌃⌥Y too.
            // (The built-in browser notes its own; tabs closed from the bar are noted when closed.)
            if !provider.isBuiltIn, status == .ok {
                let now = Set(snap.openTabs.map(\.id))
                for tab in snapshot.openTabs where !now.contains(tab.id) && !tab.isIncognito && recentlyClosed[tab.id] == nil {
                    Reopen.closed(.tab(spaceID: nil, url: tab.url, title: tab.title))
                }
            }
            if snap != snapshot { snapshot = snap }
            if status != .ok { status = .ok }
        case .failure(BrowserError.notAuthorized):
            status = .notAuthorized
        case .failure(BrowserError.notRunning):
            status = .notRunning
            snapshot = BrowserSnapshot()
        case .failure(BrowserError.script(let msg)):
            status = .error(msg)
        case .failure(let e):
            status = .error(e.localizedDescription)
        }
    }

    func isOpen(_ folder: BrowserItem) -> Bool {
        if let id = Library.libraryID(folder.id) { return library?.isOpen(id) ?? false }
        return openFolders.contains(folder.id)
    }

    func toggle(_ folder: BrowserItem) {
        if let id = Library.libraryID(folder.id) { library?.toggleFolder(id); return }
        if openFolders.contains(folder.id) { openFolders.remove(folder.id) } else { openFolders.insert(folder.id) }
    }

    /// Shows a space in the sidebar and switches Arc to it (or to the Arc space it's linked to).
    /// Which way the space content slides: 1 = the new space comes in from the right (it's further
    /// along in the switcher), -1 = from the left.
    @Published private(set) var spaceSlide = 1

    /// 1: the new space comes in from the right, -1: from the left. The slide always goes the way
    /// the fingers swipe:
    /// normally fingers to the left bring the next space in from the right; with "Reverse swipe
    /// direction" fingers to the right bring it, so it comes in from the left.
    static func slideDirection(from: Int, to: Int, reversed: Bool) -> Int {
        (to > from ? 1 : -1) * (reversed ? -1 : 1)
    }

    func focus(space: BrowserSpace) {
        let spaces = displaySpaces
        if let from = spaces.firstIndex(where: { $0.id == activeSpace?.id }), let to = spaces.firstIndex(where: { $0.id == space.id }),
           from != to, Self.slideDirection(from: from, to: to, reversed: Settings.shared.reverseSpaceSwipe) != spaceSlide {
            // The slide direction first, then the switch: the outgoing space has to leave with it too.
            spaceSlide = Self.slideDirection(from: from, to: to, reversed: Settings.shared.reverseSpaceSwipe)
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.switchSpace(to: space) } }
            return
        }
        switchSpace(to: space)
    }

    private func switchSpace(to space: BrowserSpace) {
        var arcID = space.id
        if let library, library.spaces.contains(where: { $0.id == space.id }) {
            library.activeSpaceID = space.id
            guard let linked = library.spaces.first(where: { $0.id == space.id }).flatMap(browserSpaceID) else { return }
            arcID = linked
        }
        snapshot.activeSpaceID = arcID
        pendingSpace = (arcID, Date().addingTimeInterval(4))
        let provider = provider
        queue.async {
            try? provider.focus(spaceID: arcID)
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Switching spaces no longer pulls the browser to the front; the sidebar
                // shows the space right away and the browser follows in the background.
                self.refresh()
            }
        }
    }

    /// Short message shown at the bottom of the sidebar for a few seconds.
    @Published var hint: String?
    /// A button in the toast (Undo), if any.
    @Published var hintAction: (title: String, run: () -> Void)?
    private var hintWork: DispatchWorkItem?

    /// A toast with a button (Undo); it stays a little longer than a plain one.
    func showHint(_ text: String, action title: String, seconds: Double = 10, run: @escaping () -> Void) {
        showHint(text, seconds: seconds)
        hintAction = (title, run)
    }

    func showHint(_ text: String, seconds: Double = 6) {
        hint = text
        hintAction = nil
        hintWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hint = nil; self?.hintAction = nil } }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Adds a tab to Arc's favorites or removes it. Arc offers this neither in AppleScript nor
    /// in its menu bar, so this opens the tab's context menu in Arc's own sidebar via
    /// Accessibility. If that fails, Arc shows the tab so it can be done by hand.
    func setFavorite(_ tab: BrowserItem, _ favorite: Bool, completion: @escaping (Bool) -> Void) {
        guard provider.isArc else { completion(false); return }
        guard AXIsProcessTrusted() else {
            showHint("Needs Accessibility access to change Arc favorites.")
            completion(false); return
        }
        select(tab, spaceID: nil, arrange: false, activate: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let pid = self.provider.runningApp?.processIdentifier else { completion(false); return }
                let sets: [[String]] = favorite ? [["add", "favorite"], ["pin", "favorite"]] : [["remove", "favorite"], ["unfavorite"], ["unpin"]]
                let ok = ArcSidebarAX.pressContextItem(pid: pid, itemTitle: tab.title, keywordSets: sets)
                if !ok {
                    _ = MenuBar.press(pid: pid, path: ["Tabs", "Reveal Tab in Sidebar"])
                    self.showHint(favorite
                        ? "Arc didn't let me add it. Right-click the tab in Arc → Add to Favorites."
                        : "Arc didn't let me remove it. Right-click the tile in Arc → Remove from Favorites.")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    MainActor.assumeIsolated { self.refresh() }
                }
                completion(ok)
            }
        }
    }

    /// Switches to the next (+1) or previous (-1) space, like swiping in Arc.
    func focusAdjacentSpace(_ offset: Int) {
        let spaces = displaySpaces
        guard let current = activeSpace, let i = spaces.firstIndex(where: { $0.id == current.id }) else { return }
        let j = i + offset
        guard spaces.indices.contains(j) else { return }
        focus(space: spaces[j])
    }

    /// Opens a pinned tab: selects the open tab with that URL in this space, or opens the URL in a new tab here.
    func openPinned(url: String, split: Bool = false) {
        if freezeInstead(tabID: nil, open: { [weak self] in self?.openPinned(url: url) }) { return }
        // Only a tab of this space (or a favorite): a tab in another space doesn't pull you over there.
        let all = currentSpaceTabs
        if let tab = all.first(where: { $0.url == url }) ?? all.first(where: { sameHostAndPath($0.url, url) }) {
            select(tab, spaceID: nil, split: split)
            return
        }
        let previous = NSWorkspace.shared.frontmostApplication
        let previousTarget = split ? SplitManager.shared.currentTarget() : nil
        let provider = provider
        queue.async {
            try? provider.open(url: url)
            Task { @MainActor [weak self] in self?.bringForward() }
            Task { @MainActor [weak self] in
                self?.arrangeWindows(previous: previous, split: split,
                                     record: previousTarget.map { ($0, .tab(id: "", url: url, title: URL(string: url)?.host ?? url)) })
                self?.refresh()
            }
        }
    }

    private func sameHostAndPath(_ a: String, _ b: String) -> Bool { Library.samePage(a, b) }

    /// Whether the open tab `id` is the one pinned with `url` (for highlighting pinned tiles).
    func isActive(url: String) -> Bool {
        guard let id = snapshot.activeTabID, let tab = snapshot.tab(id: id) else { return false }
        return tab.url == url || sameHostAndPath(tab.url, url)
    }

    private func arrangeWindows(previous: NSRunningApplication?, split: Bool, record: (SplitTarget, SplitTarget)? = nil) {
        if provider.isBuiltIn {
            // Two of its own tabs: the one that was showing goes left in a window of its own.
            if split, previous?.processIdentifier == getpid(), let halves = WindowManager.splitRects() {
                WebBrowser.shared.splitWithPrevious(left: WindowManager.cocoaRect(fromAX: halves.left),
                                                    right: WindowManager.cocoaRect(fromAX: halves.right))
                return
            }
            // The built-in window places itself; for a split, the other app takes the left half.
            if split, let prev = previous, prev.processIdentifier != getpid(), let halves = WindowManager.splitRects() {
                WindowManager.fillNow(pid: prev.processIdentifier, rect: halves.left)
                WebBrowser.shared.place(in: WindowManager.cocoaRect(fromAX: halves.right))
                if let record { SplitManager.shared.record(left: record.0, right: record.1) }
                return
            }
            if !split { WebBrowser.shared.fillAreaAfterSplit() }
            return
        }
        guard let pid = provider.runningApp?.processIdentifier else { return }
        if split, let prev = previous, prev.bundleIdentifier != provider.bundleID, prev.processIdentifier != getpid() {
            WindowManager.split(left: prev.processIdentifier, right: pid)
            if let record { SplitManager.shared.record(left: record.0, right: record.1) }
        } else {
            WindowManager.fillIfEnabled(pid: pid)
        }
    }

    /// Selects a tab in the browser. With `split`, the previously frontmost app's window
    /// goes to the left half and the browser to the right.
    func select(_ tab: BrowserItem, spaceID: String?, split: Bool = false, arrange: Bool = true, activate: Bool = true) {
        if freezeInstead(tabID: tab.id, open: { [weak self] in self?.select(tab, spaceID: spaceID) }) { return }
        let previous = NSWorkspace.shared.frontmostApplication
        let previousTarget = split ? SplitManager.shared.currentTarget() : nil
        snapshot.activeTabID = tab.id
        if let spaceID { snapshot.activeSpaceID = spaceID }
        if activate { bringForward() }
        let provider = provider
        queue.async {
            let result: Result<Void, Error> = Result { try provider.select(tab, spaceID: spaceID) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .failure(BrowserError.notAuthorized) = result { self.status = .notAuthorized }
                if case .failure(let e) = result { Log.write("select tab failed: \(e)") }
                if arrange {
                    self.arrangeWindows(previous: previous, split: split,
                                        record: previousTarget.map { ($0, .tab(id: tab.id, url: tab.url, title: tab.title)) })
                }
                self.refresh()
            }
        }
    }

    /// Tab id → when it was closed from the sidebar.
    private var recentlyClosed: [String: Date] = [:]

    func close(_ tab: BrowserItem) {
        // The built-in browser notes its own closed tabs (also ⌘W in its window).
        if !provider.isBuiltIn, !tab.isIncognito { Reopen.closed(.tab(spaceID: nil, url: tab.url, title: tab.title)) }
        recentlyClosed[tab.id] = Date()
        snapshot.removeTabs([tab.id])
        let provider = provider
        queue.async {
            let result: Result<Void, Error> = Result { try provider.close(tab) }
            Task { @MainActor [weak self] in
                if case .failure(let e) = result { Log.write("close tab \(tab.url) failed: \(e)") } else { Log.write("closed tab \(tab.url)") }
                self?.refresh()
            }
        }
    }

    /// Moves an open tab to another browser space: Arc can't move tabs by script, so the tab
    /// is reopened there and closed here. The browser stays on the space it was showing.
    func moveTab(_ tab: BrowserItem, toBrowserSpace arcID: String) {
        recentlyClosed[tab.id] = Date()
        snapshot.removeTabs([tab.id])
        let current = snapshot.activeSpaceID
        let provider = provider
        queue.async {
            do {
                try provider.focus(spaceID: arcID)
                _ = try provider.makeTab(url: tab.url)
                if let current, current != arcID { try provider.focus(spaceID: current) }
                try provider.close(tab)
                Log.write("moved tab \(tab.url) to space \(arcID)")
            } catch {
                Log.write("move tab \(tab.url) failed: \(error)")
            }
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// Opens a new tab in the browser (⌘T), like Arc's "+ New Tab" row.
    /// Makes sure Arc's own sidebar is shown (so it doesn't pop out on hover). Returns true if it
    /// had to be shown.
    @discardableResult
    func showArcSidebarIfHidden() -> Bool {
        guard provider.isArc, let pid = provider.runningApp?.processIdentifier,
              let entry = MenuBar.entries(pid: pid, menu: "View").first(where: { $0.title.localizedCaseInsensitiveContains("show sidebar") })
        else { return false }
        return MenuBar.press(pid: pid, path: entry.path)
    }

    /// Shows or hides Arc's own sidebar via its View menu.
    func toggleArcSidebar() {
        guard let pid = provider.runningApp?.processIdentifier else { return }
        let entry = MenuBar.entries(pid: pid, menu: "View").first { $0.title.localizedCaseInsensitiveContains("sidebar") }
        if let entry { _ = MenuBar.press(pid: pid, path: entry.path) } else { showHint("Needs Accessibility access.") }
    }

    /// Turns what was typed in the sidebar's New Tab field into a URL (address or web search).
    static func url(fromInput input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://") && !text.contains(" ") { return text }
        let lower = text.lowercased()
        if ["about:", "mailto:", "data:", "file:"].contains(where: lower.hasPrefix) { return text }
        if !text.contains(" "), let host = URL(string: "http://\(text)")?.host {
            // localhost, a local name with a port (nas.local:5000) or an IP address: plain http, like other browsers.
            let local = host == "localhost" || host.hasSuffix(".local") || host.allSatisfy { $0.isNumber || $0 == "." }
            if local, host.contains(".") || host == "localhost" { return "http://\(text)" }
            if host.contains("."), host.split(separator: ".").last.map({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }) == true {
                return "https://\(text)"
            }
        }
        return searchURL(text)
    }

    /// A web search for `text`. "c++ & rust" stays one search: & + = # ? are encoded too.
    static func searchURL(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#?")
        return Settings.shared.searchEngine.base + (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text)
    }

    /// Creates a tab from the sidebar (typed address or search) and syncs it to the browser.
    func createTab(input: String, split: Bool = false, created: ((String) -> Void)? = nil) {
        guard let url = Self.url(fromInput: input) else { return }
        let previous = NSWorkspace.shared.frontmostApplication
        let previousTarget = split ? SplitManager.shared.currentTarget() : nil
        let provider = provider
        let arcSpace = library?.activeSpace.flatMap(browserSpaceID)
        queue.async {
            if let arcSpace { try? provider.focus(spaceID: arcSpace) }
            let id = (try? provider.makeTab(url: url)) ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !id.isEmpty { self.snapshot.activeTabID = id; created?(id) }
                self.bringForward()
                self.arrangeWindows(previous: previous, split: split,
                                    record: previousTarget.map { ($0, .tab(id: id, url: url, title: URL(string: url)?.host ?? url)) })
                self.refresh()
            }
        }
    }

    /// Pins a today tab in its space, or unpins a pinned one, using Arc's Tabs menu
    /// (AppleScript can't change this). Arc isn't brought forward.
    func setPinned(_ tab: BrowserItem, _ pinned: Bool) {
        guard provider.isArc else { return }
        guard AXIsProcessTrusted() else { showHint("Needs Accessibility access to pin or unpin in Arc."); return }
        select(tab, spaceID: nil, arrange: false, activate: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let pid = self.provider.runningApp?.processIdentifier else { return }
                let entries = MenuBar.entries(pid: pid, menu: "Tabs")
                let entry = pinned
                    ? entries.first { $0.title.hasPrefix("Pin") }
                    : entries.first { $0.title.localizedCaseInsensitiveContains("unpin") }
                Log.write("setPinned \(pinned) \(tab.url): tabs menu=\(entries.map(\.title)) chosen=\(entry?.title ?? "none")")
                if let entry, MenuBar.press(pid: pid, path: entry.path) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self.refresh() } }
                } else {
                    self.showHint(pinned ? "Arc didn't offer “Pin Tab” for this tab." : "Arc didn't offer “Unpin Tab” for this tab.")
                }
            }
        }
    }

    /// ⌘L: loads an address or search in the current tab (like the browser's own address bar).
    func loadInCurrentTab(input: String) {
        guard let url = Self.url(fromInput: input) else { return }
        let provider = provider
        bringForward()
        queue.async {
            try? provider.load(url: url)
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    var activeTabURL: String? {
        snapshot.activeTabID.flatMap { snapshot.tab(id: $0)?.url }
    }

    func navigate(_ action: NavigationAction) {
        let provider = provider
        queue.async {
            try? provider.navigate(action)
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// Activates the browser right away, in parallel with the (slower) script call.
    private func bringForward() {
        provider.activate()
    }

    func launchBrowser(then: ((pid_t) -> Void)? = nil) {
        if provider.isBuiltIn { provider.activate(); return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: provider.bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
            guard let pid = app?.processIdentifier else { return }
            Task { @MainActor in
                WindowManager.fillIfEnabled(pid: pid)
                then?(pid)
            }
        }
    }
}
