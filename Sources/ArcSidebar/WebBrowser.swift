import AppKit
import WebKit

/// One tab of the built-in browser. Its web view is created only when the tab is first shown
/// (restored tabs stay cheap until used).
@MainActor
final class WebTab: NSObject {
    let id: String
    let spaceID: String
    /// A private tab: its own throwaway website data, never saved, not offered to extensions.
    let isIncognito: Bool
    var url: String
    var title: String
    private(set) var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    var onChange: (() -> Void)?
    /// Loading progress only: moves the progress bar without refreshing the sidebar.
    var onProgress: (() -> Void)?

    init(id: String = "w:" + UUID().uuidString, spaceID: String, url: String, title: String = "", isIncognito: Bool = false) {
        self.id = id
        self.spaceID = spaceID
        self.isIncognito = isIncognito
        self.url = url
        self.title = title
    }

    /// The tab's web view, created on first use with the space's data store.
    func loadedWebView(browser: WebBrowser, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        if let webView { return webView }
        let config = configuration ?? browser.configuration(forSpace: spaceID, incognito: isIncognito)
        let view = TabWebView(frame: .zero, configuration: config)
        view.customUserAgent = WebBrowser.userAgent
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.navigationDelegate = browser
        view.uiDelegate = browser
        if #available(macOS 13.3, *) { view.isInspectable = true }
        observations = [
            view.observe(\.title) { [weak self] v, _ in
                MainActor.assumeIsolated {
                    guard let self, let t = v.title, !t.isEmpty else { return }
                    self.title = t
                    self.onChange?()
                }
            },
            view.observe(\.url) { [weak self] v, _ in
                MainActor.assumeIsolated {
                    guard let self, let u = v.url?.absoluteString else { return }
                    self.url = u
                    self.onChange?()
                }
            },
            view.observe(\.estimatedProgress) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onProgress?() }
            },
            view.observe(\.canGoBack) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onProgress?() }
            },
            view.observe(\.canGoForward) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onProgress?() }
            },
        ]
        webView = view
        if configuration == nil, let u = URL(string: url) { view.load(URLRequest(url: u)) }
        return view
    }

    func discardWebView() {
        observations = []
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }
}

/// proDOCKtivity's own browser (WebKit): a window next to the sidebar showing the active
/// space's current tab. Every space has its own website data (cookies, logins, storage),
/// like Arc's profiles.
@MainActor
final class WebBrowser: NSObject {
    static let shared = WebBrowser()

    /// Safari's user agent, so sites (Google sign-in in particular) treat this as Safari.
    nonisolated static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private(set) var tabs: [WebTab] = []
    private(set) var activeSpaceID: String?
    /// The tab each space shows (its last selected one).
    private var currentTab: [String: String] = [:]
    /// Called whenever tabs, titles or addresses change (the sidebar refreshes).
    var onChange: (() -> Void)?
    /// ⌘L: the address field in the menu bar, or DOCKlight as the address bar.
    var focusAddress: (() -> Void)?
    /// ⌘T: opens the sidebar's command bar for a new tab.
    var onNewTab: (() -> Void)?
    /// Space color for the toolbar tint.
    var spaceColor: (String) -> NSColor? = { _ in nil }
    /// Login profile used by a space (spaces can share one).
    var profileForSpace: (String) -> String? = { _ in nil }

    private var window: BrowserWindow?
    /// Freeze: one tab in a window of its own on one half of the screen.
    private(set) var frozenTabID: String?
    private var frozenWindow: BrowserWindow?
    /// Split of two tabs: the left one shows in a window of its own, the main window shows the right one.
    private(set) var splitTabID: String?
    private var splitWindow: BrowserWindow?
    /// The tab that was showing before the current one (the left side of a ⌥-click split).
    private var previousTabID: String?
    /// The frozen tab was closed (the freeze ends).
    var onFrozenTabGone: (() -> Void)?
    private var dataStores: [String: WKWebsiteDataStore] = [:]
    /// Where each running download is being saved.
    fileprivate var downloadTargets: [ObjectIdentifier: URL] = [:]
    /// Files being downloaded right now, and a call when that changes (the downloads view).
    var activeDownloads: [URL] { Array(downloadTargets.values) }
    var onDownloadsChanged: (() -> Void)?
    /// A short message for the bar (e.g. a failed download).
    var onHint: ((String) -> Void)?
    /// Recently closed tabs, newest last (⌘⇧T brings them back).
    private var closedTabs: [(spaceID: String, url: String, title: String)] = []
    private var saveWork: DispatchWorkItem?

    private let stateURL: URL
    /// Off in tests: the tabs work the same, but no window opens on screen.
    private let showsWindows: Bool

    private struct SavedTab: Codable { let id, spaceID, url, title: String }
    private struct SavedState: Codable {
        var tabs: [SavedTab]
        var current: [String: String]
        var activeSpace: String?
    }

    init(stateURL: URL = AppPaths.file("browser-tabs.json"), showsWindows: Bool = true) {
        self.stateURL = stateURL
        self.showsWindows = showsWindows
        super.init()
        watchMemoryPressure()
        if let state = AppPaths.load(SavedState.self, from: stateURL) {
            tabs = state.tabs.map { WebTab(id: $0.id, spaceID: $0.spaceID, url: $0.url, title: $0.title) }
            tabs.forEach(observe)
            currentTab = state.current
            activeSpaceID = state.activeSpace
        }
        publishNavState()
    }

    // MARK: Memory

    private var memorySource: DispatchSourceMemoryPressure?

    /// When macOS runs short of memory, tabs nobody is looking at give their page back.
    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.releaseHiddenPages() } }
        source.resume()
        memorySource = source
    }

    /// Unloads the pages of tabs that aren't on screen and aren't playing sound or using the
    /// camera or microphone. They load again when shown (like Safari after memory pressure).
    func releaseHiddenPages() {
        let keep: Set<String?> = [activeTab?.id, frozenTabID, splitTabID]
        for tab in tabs where !keep.contains(tab.id) {
            guard let view = tab.webView, view.window == nil,
                  view.cameraCaptureState == .none, view.microphoneCaptureState == .none else { continue }
            view.requestMediaPlaybackState { [weak tab] state in
                MainActor.assumeIsolated {
                    guard let tab, state == .none, tab.webView?.window == nil else { return }
                    tab.discardWebView()
                    Log.write("memory pressure: unloaded a hidden tab")
                }
            }
        }
    }

    // MARK: Spaces and website data

    /// Each profile has its own persistent website data store (separate logins); a space
    /// uses its profile's store.
    func configuration(forSpace spaceID: String, incognito: Bool = false) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = incognito ? incognitoStore : dataStore(forProfile: profileForSpace(spaceID) ?? spaceID)
        config.preferences.isElementFullscreenEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Extensions stay out of private tabs.
        if !incognito { WebExtensionStore.shared.attach(to: config) }
        return config
    }

    /// All incognito tabs share one store that lives in memory only; it is dropped (with every
    /// cookie and login in it) when the last incognito tab closes.
    private var incognitoStoreBox: WKWebsiteDataStore?
    private var incognitoStore: WKWebsiteDataStore {
        if let store = incognitoStoreBox { return store }
        let store = WKWebsiteDataStore.nonPersistent()
        incognitoStoreBox = store
        return store
    }

    var hasIncognitoTabs: Bool { tabs.contains(where: \.isIncognito) }

    /// ⌘⇧N: a blank private tab in the current space, with the address field ready to type in.
    func newIncognitoTab() {
        newTab(url: "about:blank", incognito: true)
        focusAddress?()
    }

    private func dataStore(forProfile profileID: String) -> WKWebsiteDataStore {
        if let store = dataStores[profileID] { return store }
        let uuid = UUID(uuidString: profileID) ?? Self.stableUUID(profileID)
        let store = WKWebsiteDataStore(forIdentifier: uuid)
        dataStores[profileID] = store
        return store
    }

    /// A space switched profile: its pages reload with the other profile's logins.
    func profileChanged(forSpace spaceID: String) {
        for tab in tabs where tab.spaceID == spaceID { tab.discardWebView() }
        if spaceID == activeSpaceID, isWindowVisible { window?.display(activeTab, browser: self) }
        // A frozen tab or the left of a split would otherwise stay blank in its own window.
        if let tab = tabs.first(where: { $0.id == frozenTabID && $0.spaceID == spaceID }) { frozenWindow?.display(tab, browser: self) }
        if let tab = tabs.first(where: { $0.id == splitTabID && $0.spaceID == spaceID }) { splitWindow?.display(tab, browser: self) }
    }

    /// A profile was deleted: drop its stored logins.
    func deleteData(forProfile profileID: String) {
        dataStores[profileID] = nil
        guard let uuid = UUID(uuidString: profileID) else { return }
        WKWebsiteDataStore.remove(forIdentifier: uuid) { _ in }
    }

    /// A UUID derived from any string (space ids are UUIDs already; this covers the rest).
    private static func stableUUID(_ s: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in s.utf8.enumerated() { bytes[i % 16] = bytes[i % 16] &* 31 &+ b }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Signs out of everything in a profile (deletes its cookies and website data).
    func clearData(forProfile profileID: String) {
        let store = dataStore(forProfile: profileID)
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    // MARK: Snapshot for the sidebar

    func snapshot() -> BrowserSnapshot {
        var snap = BrowserSnapshot()
        var order: [String] = []
        var bySpace: [String: [BrowserItem]] = [:]
        for tab in tabs {
            if bySpace[tab.spaceID] == nil { order.append(tab.spaceID) }
            let title = tab.title.isEmpty ? (URL(string: tab.url)?.host ?? tab.url) : tab.title
            var item = BrowserItem(id: tab.id, title: title, url: tab.url, kind: .tab)
            item.isIncognito = tab.isIncognito
            bySpace[tab.spaceID, default: []].append(item)
        }
        if let active = activeSpaceID, bySpace[active] == nil { order.append(active); bySpace[active] = [] }
        snap.spaces = order.map { id in
            var space = BrowserSpace(id: id, title: "")
            space.unpinned = bySpace[id] ?? []
            return space
        }
        snap.activeSpaceID = activeSpaceID
        snap.activeTabID = activeSpaceID.flatMap { currentTab[$0] }
        return snap
    }

    // MARK: Tab actions

    var activeTab: WebTab? {
        guard let space = activeSpaceID, let id = currentTab[space] else { return nil }
        return tabs.first { $0.id == id }
    }

    func select(tabID: String) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        // A tab in a window of its own: that window comes forward.
        if tabID == frozenTabID || tabID == splitTabID {
            guard showsWindows else { return }
            NSApp.activate(ignoringOtherApps: true)
            (tabID == frozenTabID ? frozenWindow : splitWindow)?.makeKeyAndOrderFront(nil)
            return
        }
        rememberPrevious(tabID)
        // Another tab chosen: a split of two tabs ends, only the chosen one shows (⌥-click splits
        // again right after; ⌃-click freezes one so it stays).
        endSplit()
        activeSpaceID = tab.spaceID
        currentTab[tab.spaceID] = tab.id
        show()
        changed()
    }

    /// Opens a URL as a new tab in the active space and shows it; returns the tab id.
    @discardableResult
    func newTab(url: String, inSpace spaceID: String? = nil, configuration: WKWebViewConfiguration? = nil, show showIt: Bool = true,
                incognito: Bool = false) -> WebTab {
        let space = spaceID ?? activeSpaceID ?? "default"
        let tab = WebTab(spaceID: space, url: url, isIncognito: incognito)
        observe(tab)
        // New tabs go right after the current one, like most browsers.
        if let current = currentTab[space], let i = tabs.firstIndex(where: { $0.id == current }) {
            tabs.insert(tab, at: i + 1)
        } else {
            tabs.append(tab)
        }
        if configuration != nil { _ = tab.loadedWebView(browser: self, configuration: configuration) }
        if showIt {
            rememberPrevious(tab.id)
            activeSpaceID = space
            currentTab[space] = tab.id
            show()
        }
        changed()
        return tab
    }

    func close(tabID: String) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if tabID == frozenTabID { onFrozenTabGone?() }
        if tabID == splitTabID { endSplit() }
        // Show the neighbour in the same space, like closing a tab in a browser. Never the frozen
        // tab: its page would move out of its own window into this one, leaving that one blank.
        let shown = currentTab[tabs[i].spaceID] == tabID
        let next = shown ? Self.neighbour(of: i, in: tabs, skipping: Set([frozenTabID].compactMap { $0 })) : nil
        let tab = tabs.remove(at: i)
        if !tab.isIncognito, !tab.url.isEmpty, tab.url != "about:blank" {
            closedTabs.append((tab.spaceID, tab.url, tab.title))
            if closedTabs.count > Self.closedTabsKept { closedTabs.removeFirst() }
            Reopen.closed(.tab(spaceID: tab.spaceID, url: tab.url, title: tab.title))
        }
        tab.discardWebView()
        if tab.isIncognito, !hasIncognitoTabs { incognitoStoreBox = nil }
        if shown {
            currentTab[tab.spaceID] = next?.id
            // The neighbour is the left side of a split: the split ends, it comes back here.
            if next?.id != nil, next?.id == splitTabID { endSplit() }
        }
        if tab.spaceID == activeSpaceID { window?.display(activeTab, browser: self) }
        changed()
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    /// A closed tab came back through ⌘Y: ⌘⇧T doesn't bring it a second time.
    func closedTabsForget(url: String) {
        if let i = closedTabs.lastIndex(where: { $0.url == url }) { closedTabs.remove(at: i) }
    }
    /// How many closed tabs ⌘⇧T can bring back.
    static let closedTabsKept = 25

    /// The tab a space shows instead of the one at `index`: the next tab of the same space (the
    /// one that moves into its place when it closes), else the one before; `beforeFirst` asks
    /// for the one before first. Tabs in `skipping` never are.
    static func neighbour(of index: Int, in tabs: [WebTab], skipping: Set<String> = [], beforeFirst: Bool = false) -> WebTab? {
        let space = tabs[index].spaceID
        let fits = { (t: WebTab) in t.spaceID == space && !skipping.contains(t.id) }
        let after = tabs[(index + 1)...].first(where: fits)
        let before = tabs[..<index].last(where: fits)
        return beforeFirst ? before ?? after : after ?? before
    }

    /// Hands every tab of `old` to `new` (a space was deleted: its tabs would otherwise stay
    /// loaded and saved without ever being shown). They load again with the new space's logins.
    func moveTabs(fromSpace old: String, to new: String) {
        guard old != new, tabs.contains(where: { $0.spaceID == old }) else { return }
        // Their pages load again, so a tab in a window of its own goes back to being a normal tab.
        if tabs.contains(where: { $0.spaceID == old && $0.id == frozenTabID }) { onFrozenTabGone?() }
        if tabs.contains(where: { $0.spaceID == old && $0.id == splitTabID }) { endSplit() }
        tabs = tabs.map { tab in
            guard tab.spaceID == old else { return tab }
            tab.discardWebView()
            let moved = WebTab(id: tab.id, spaceID: new, url: tab.url, title: tab.title, isIncognito: tab.isIncognito)
            observe(moved)
            return moved
        }
        if currentTab[new] == nil { currentTab[new] = currentTab[old] }
        currentTab[old] = nil
        if activeSpaceID == old { activeSpaceID = new }
        if activeSpaceID == new, isWindowVisible { window?.display(activeTab, browser: self) }
        Log.write("moved the tabs of a removed space")
        changed()
    }

    /// Tab ids of a space (to move them back if its deletion is undone).
    func tabIDs(inSpace space: String) -> Set<String> { Set(tabs.filter { $0.spaceID == space }.map(\.id)) }

    /// Moves these tabs (still open) back into `space`, e.g. when deleting their workspace is undone.
    func moveTabs(ids: Set<String>, to space: String) {
        guard tabs.contains(where: { ids.contains($0.id) && $0.spaceID != space }) else { return }
        tabs = tabs.map { tab in
            guard ids.contains(tab.id), tab.spaceID != space else { return tab }
            if currentTab[tab.spaceID] == tab.id { currentTab[tab.spaceID] = nil }
            tab.discardWebView()
            let moved = WebTab(id: tab.id, spaceID: space, url: tab.url, title: tab.title, isIncognito: tab.isIncognito)
            observe(moved)
            return moved
        }
        if currentTab[space] == nil { currentTab[space] = tabs.first { $0.spaceID == space }?.id }
        if activeSpaceID == space, isWindowVisible { window?.display(activeTab, browser: self) }
        changed()
    }

    /// Tabs whose space no longer exists join `fallback` (see `moveTabs`).
    func adoptOrphanTabs(validSpaces: Set<String>, into fallback: String) {
        for old in Set(tabs.map(\.spaceID)) where !validSpaces.contains(old) { moveTabs(fromSpace: old, to: fallback) }
    }

    /// ⌘⌥C: the address of the page in `window` (or of the current tab) to the clipboard.
    func copyAddress(of window: BrowserWindow?) {
        guard let url = (window?.shownURL ?? activeTab?.webView?.url)?.absoluteString ?? activeTab?.url, !url.isEmpty else {
            NSSound.beep(); return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        onHint?("Link copied: \(url.count > 60 ? String(url.prefix(57)) + "…" : url)")
    }

    /// The active space's tabs in the order the bar lists them.
    private var spaceTabs: [WebTab] { tabs.filter { $0.spaceID == activeSpaceID } }

    /// ⌃Tab / ⌃⇧Tab: the next or previous tab of the space, wrapping around.
    func selectAdjacentTab(_ offset: Int) {
        let list = spaceTabs
        guard list.count > 1, let current = activeTab, let i = list.firstIndex(of: current) else { return }
        select(tabID: list[(i + offset + list.count) % list.count].id)
    }

    /// ⌘1 … ⌘8 pick that tab of the space, ⌘9 the last one (like Safari and Chrome).
    func selectTab(number: Int) {
        let list = spaceTabs
        guard let last = list.last else { return }
        let tab = number < 9 && list.indices.contains(number - 1) ? list[number - 1] : last
        select(tabID: tab.id)
    }

    /// ⌘⇧T: the last closed tab opens again in its space.
    func reopenClosedTab() {
        guard let last = closedTabs.popLast() else { NSSound.beep(); return }
        Reopen.forget(.tab(spaceID: last.spaceID, url: last.url, title: last.title))
        let tab = newTab(url: last.url, inSpace: last.spaceID)
        tab.title = last.title
    }

    func focus(spaceID: String) {
        guard activeSpaceID != spaceID else { return }
        activeSpaceID = spaceID
        if window?.isVisible == true { window?.display(activeTab, browser: self) }
        changed()
    }

    func load(url: String) {
        guard let tab = activeTab, let u = URL(string: url) else { newTab(url: url); return }
        tab.loadedWebView(browser: self).load(URLRequest(url: u))
        show()
    }

    func navigate(_ action: NavigationAction) {
        guard let view = activeTab?.webView else { return }
        switch action {
        case .back: view.goBack()
        case .forward: view.goForward()
        case .reload: view.reload()
        }
    }

    // MARK: Window

    var isWindowVisible: Bool { window?.isVisible == true }

    /// Hands the keyboard back to the page in front (after the bar's address field, or a key
    /// typed while the bar had the focus). False when no page is showing.
    @discardableResult
    func focusPage() -> Bool {
        guard let window, window.isVisible, activeTab != nil else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.focusPage()
        return true
    }
    /// The main browser window's frame (for extensions asking where the window is).
    var mainWindowFrame: CGRect? { window?.frame }

    func show() {
        guard showsWindows else { return }
        let w = window ?? makeWindow()
        w.display(activeTab, browser: self)
        if let screen = secondScreen {
            // On the other screen (Settings → Browser): it fills that screen, wherever the bar is.
            if !w.isVisible || w.screen != screen { w.setFrame(frame(on: screen), display: false) }
        } else if WindowManager.framesOwnWindows {
            // Frame mode: the browser lives inside the frame. A window already inside it (e.g. one
            // half of a split) stays where it is; one outside it, or a new one, fills it.
            if let frame = WindowManager.targetCocoaRect(), let area = WindowManager.fullCocoaRect(),
               !w.isVisible || !area.insetBy(dx: -2, dy: -2).contains(w.frame) {
                w.setFrame(frame, display: false)
            }
        } else if !w.isVisible || NSApp.isActive == false {
            if Settings.shared.autoFitWindows, let frame = WindowManager.targetCocoaRect() { w.setFrame(frame, display: false) }
        }
        w.isMovable = !WindowManager.framesOwnWindows
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// The screen the browser window fills when it isn't beside the bar (Settings → Browser).
    private var secondScreen: NSScreen? { Settings.shared.resolvedBrowserScreen(barScreen: WindowManager.screen()) }

    /// What the browser window fills on that screen: inside the frame if the frame is on there too.
    private func frame(on screen: NSScreen) -> CGRect {
        Settings.shared.frameMode && Settings.shared.frameOtherScreens ? WindowManager.otherScreenCocoaRect(screen) : screen.visibleFrame
    }

    /// The "Browser window on" setting changed: a visible window moves to its new place.
    func moveToConfiguredScreen() {
        guard let w = window, w.isVisible else { return }
        if let screen = secondScreen {
            w.setFrame(frame(on: screen), display: true)
        } else if let frame = WindowManager.targetCocoaRect() {
            w.setFrame(frame, display: true)
        }
    }

    /// Puts the window into a given frame (Cocoa coordinates), e.g. one half of a split.
    func place(in frame: CGRect) {
        window?.setFrame(frame, display: true, animate: false)
    }

    func hide() { window?.orderOut(nil) }

    private func makeWindow() -> BrowserWindow {
        let w = BrowserWindow()
        w.onNewTab = { [weak self] in self?.onNewTab?() }
        w.onCloseTab = { [weak self] in
            guard let self, let tab = self.activeTab else { self?.hide(); return }
            self.close(tabID: tab.id)
        }
        w.onAddress = { [weak self] text in
            guard let self, let url = BrowserModel.url(fromInput: text) else { return }
            self.load(url: url)
        }
        w.onNavigate = { [weak self] in self?.navigate($0) }
        window = w
        return w
    }

    // MARK: Split

    private func rememberPrevious(_ next: String) {
        if let current = activeTab?.id, current != next { previousTabID = current }
    }

    /// ⌥-click on a tab while the browser is in front: the tab that was showing goes to the left
    /// half in a window of its own, the new one stays in the main window on the right half.
    /// Returns false if there's nothing to split with.
    @discardableResult
    func splitWithPrevious(left leftFrame: CGRect, right rightFrame: CGRect) -> Bool {
        guard frozenTabID == nil, let leftID = previousTabID, let right = activeTab, leftID != right.id,
              let left = tabs.first(where: { $0.id == leftID }) else { return false }
        endSplit()
        splitTabID = leftID
        defer { changed() }
        guard showsWindows else { return true }
        let w = makeSideWindow(tabID: leftID) { [weak self] in self?.endSplit() }
        splitWindow = w
        w.display(left, browser: self)
        w.setFrame(leftFrame, display: true)
        window?.setFrame(rightFrame, display: true)
        w.orderFront(nil)
        window?.makeKeyAndOrderFront(nil)
        Log.write("split: two built-in tabs side by side")
        return true
    }

    /// A tab picked on its own (no ⌥-click): if the window was one half of a split with an app,
    /// it fills the area again and covers the other half (the app no longer stays "frozen" beside it).
    /// A split of two tabs or a frozen tab keeps its halves.
    func fillAreaAfterSplit() {
        guard splitTabID == nil, frozenTabID == nil, secondScreen == nil, let w = window, w.isVisible,
              Settings.shared.autoFitWindows, let frame = WindowManager.targetCocoaRect(),
              abs(w.frame.width - frame.width) > 2 || abs(w.frame.minX - frame.minX) > 2 else { return }
        w.setFrame(frame, display: true)
        Log.write("split ended: browser fills the area again")
    }

    /// Ends a split of two tabs: the left one goes back to being a normal tab, the main window fills the frame.
    func endSplit() {
        guard splitTabID != nil else { return }
        splitTabID = nil
        splitWindow?.display(nil, browser: self)
        splitWindow?.orderOut(nil)
        splitWindow = nil
        if let w = window, w.isVisible, Settings.shared.autoFitWindows, let frame = WindowManager.targetCocoaRect() {
            w.setFrame(frame, display: true)
        }
        changed()
    }

    /// A window showing just one tab (frozen, or the left side of a split).
    private func makeSideWindow(tabID: String, onClose: @escaping () -> Void) -> BrowserWindow {
        let w = BrowserWindow(autosave: false)
        w.onNewTab = { [weak self] in self?.onNewTab?() }
        w.onCloseTab = { [weak self] in self?.close(tabID: tabID) }
        w.onClose = onClose
        w.onAddress = { [weak self] text in
            guard let self, let url = BrowserModel.url(fromInput: text), let u = URL(string: url) else { return }
            self.tabs.first { $0.id == tabID }?.loadedWebView(browser: self).load(URLRequest(url: u))
        }
        w.onNavigate = { [weak self] action in
            guard let view = self?.tabs.first(where: { $0.id == tabID })?.webView else { return }
            switch action {
            case .back: view.goBack()
            case .forward: view.goForward()
            case .reload: view.reload()
            }
        }
        return w
    }

    // MARK: Freeze

    /// Shows `tabID` in a window of its own at `frame` (Cocoa coordinates); the main window
    /// moves on to another tab.
    func freeze(tabID: String, frame: CGRect) {
        unfreeze()
        endSplit()
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        frozenTabID = tabID
        if currentTab[tab.spaceID] == tabID, let i = tabs.firstIndex(of: tab) {
            currentTab[tab.spaceID] = Self.neighbour(of: i, in: tabs, beforeFirst: true)?.id
        }
        if window?.isVisible == true { window?.display(activeTab, browser: self) }
        defer { changed() }
        guard showsWindows else { return }
        let w = makeSideWindow(tabID: tabID) { [weak self] in self?.onFrozenTabGone?() }
        frozenWindow = w
        w.display(tab, browser: self)
        w.setFrame(frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Ends the freeze: the tab goes back to being a normal tab.
    func unfreeze() {
        guard frozenTabID != nil else { return }
        frozenTabID = nil
        frozenWindow?.display(nil, browser: self)
        frozenWindow?.orderOut(nil)
        frozenWindow = nil
        changed()
    }

    /// Puts the main window where windows snap now (e.g. the free half after freezing).
    func moveMainWindowToTarget() {
        guard let w = window, w.isVisible, Settings.shared.autoFitWindows, let frame = WindowManager.targetCocoaRect() else { return }
        w.setFrame(frame, display: true)
        w.isMovable = !WindowManager.framesOwnWindows
    }

    /// Close to `b` on every edge (it filled the frame before the frame changed size).
    private func isNearly(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 40 && abs(a.maxX - b.maxX) < 40 && abs(a.minY - b.minY) < 40 && abs(a.maxY - b.maxY) < 40
    }

    /// Frame mode changed size or place: the browser windows follow (the frozen one keeps its half).
    func followFrame() {
        if let w = window { w.isMovable = !WindowManager.framesOwnWindows }
        guard WindowManager.framesOwnWindows else { return }
        if let w = window, w.isVisible, secondScreen == nil, let frame = WindowManager.targetCocoaRect(), let area = WindowManager.fullCocoaRect(),
           !area.insetBy(dx: -2, dy: -2).contains(w.frame) || isNearly(w.frame, frame) {
            w.setFrame(frame, display: true)
        }
        if let w = frozenWindow, w.isVisible, let rect = Freeze.shared.frozenRect {
            w.setFrame(WindowManager.cocoaRect(fromAX: rect), display: true)
        }
    }

    // MARK: Changes and saving

    private func observe(_ tab: WebTab) {
        tab.onChange = { [weak self, weak tab] in
            guard let self else { return }
            if let tab, tab.id == self.activeTab?.id {
                self.window?.updateChrome(for: tab, color: self.spaceColor(tab.spaceID))
                self.publishNavState()
            }
            if let tab, tab.id == self.frozenTabID { self.frozenWindow?.updateChrome(for: tab, color: self.spaceColor(tab.spaceID)) }
            if let tab, tab.id == self.splitTabID { self.splitWindow?.updateChrome(for: tab, color: self.spaceColor(tab.spaceID)) }
            if let tab, #available(macOS 15.4, *) { WebExtensionStore.shared.host.tabChanged(tab) }
            // Titles and addresses change many times while a page loads: refresh the sidebar once.
            self.changed(soon: true)
        }
        tab.onProgress = { [weak self, weak tab] in
            guard let self, let tab else { return }
            if tab.id == self.activeTab?.id {
                self.window?.updateChrome(for: tab, color: self.spaceColor(tab.spaceID))
                self.publishNavState()
            }
            if tab.id == self.frozenTabID { self.frozenWindow?.updateChrome(for: tab, color: self.spaceColor(tab.spaceID)) }
            if tab.id == self.splitTabID { self.splitWindow?.updateChrome(for: tab, color: self.spaceColor(tab.spaceID)) }
        }
    }

    private var notifyWork: DispatchWorkItem?

    /// The bar's address field and back / forward follow the active tab right away.
    private func publishNavState() {
        let tab = activeTab
        BrowserNavState.shared.update(url: tab?.url ?? "", canGoBack: tab?.webView?.canGoBack ?? false,
                                      canGoForward: tab?.webView?.canGoForward ?? false)
    }

    /// Tells the sidebar and saves the tabs. `soon` batches bursts (page loads) into one update.
    private func changed(soon: Bool = false) {
        if let tab = activeTab { window?.updateChrome(for: tab, color: spaceColor(tab.spaceID)) }
        publishNavState()
        if #available(macOS 15.4, *) { WebExtensionStore.shared.host.syncTabs() }
        notifyWork?.cancel()
        if soon {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.onChange?() } }
            notifyWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        } else {
            onChange?()
        }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Writes the tabs right away (on quit; normally saving waits a second to batch changes).
    func saveNow() {
        saveWork?.cancel()
        save()
    }

    private func save() {
        // Private tabs are never written down; a space whose shown tab was private shows nothing after a restart.
        let kept = tabs.filter { !$0.isIncognito }
        let keptIDs = Set(kept.map(\.id))
        let state = SavedState(tabs: kept.map { SavedTab(id: $0.id, spaceID: $0.spaceID, url: $0.url, title: $0.title) },
                               current: currentTab.filter { keptIDs.contains($0.value) }, activeSpace: activeSpaceID)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    fileprivate func tab(for webView: WKWebView) -> WebTab? { tabs.first { $0.webView === webView } }
}

/// What the bar shows for the built-in browser's active tab: its address and whether back /
/// forward can be used.
@MainActor final class BrowserNavState: ObservableObject {
    static let shared = BrowserNavState()
    @Published private(set) var url = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// Bumped by ⌘L: the bar's address field takes the focus.
    @Published var focusRequest = 0

    func update(url: String, canGoBack: Bool, canGoForward: Bool) {
        if self.url != url { self.url = url }
        if self.canGoBack != canGoBack { self.canGoBack = canGoBack }
        if self.canGoForward != canGoForward { self.canGoForward = canGoForward }
    }
}

// MARK: - WebKit delegates

extension WebBrowser: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    /// Links that open a new window (target=_blank, sign-in pop-ups) become tabs.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let space = tab(for: webView)?.spaceID
        let tab = newTab(url: navigationAction.request.url?.absoluteString ?? "", inSpace: space, configuration: configuration,
                         incognito: tab(for: webView)?.isIncognito ?? false)
        return tab.webView
    }

    /// The page's process crashed or macOS ended it to free memory: the page would stay blank.
    /// The visible one reloads right away; a background one reloads when it's shown next.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        Log.write("web content ended: \(URL(string: tab.url)?.host ?? "?")")
        if webView.window != nil { webView.reload() } else { tab.discardWebView() }
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab = tab(for: webView) { close(tabID: tab.id) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        // ⌘-click or a middle click opens the link in a new tab in the background.
        if navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 2,
           navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url?.absoluteString {
            newTab(url: url, inSpace: tab(for: webView)?.spaceID, show: false)
            decisionHandler(.cancel); return
        }
        // Links to other apps (mailto:, zoommtg:, …) go to those apps.
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "data", "blob", "file", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    /// A page that couldn't load (offline, wrong address, server down) says so instead of
    /// staying blank, with a button to try again.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let e = error as NSError
        // Cancelled (another page was opened) or turned into a download: nothing went wrong.
        if e.code == NSURLErrorCancelled || (e.domain == "WebKitErrorDomain" && e.code == 102) { return }
        let failed = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        Log.write("page failed: \(failed?.host ?? "?") \(e.domain) \(e.code)")
        webView.loadHTMLString(Self.errorPage(e.localizedDescription, url: failed), baseURL: failed)
    }

    static func errorPage(_ message: String, url: URL?) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let address = escape(url?.absoluteString ?? "")
        return """
        <!doctype html><meta charset="utf-8"><title>\(escape(url?.host ?? "Can't open page"))</title>
        <style>body{font:15px -apple-system,sans-serif;color:#444;display:grid;place-items:center;height:90vh;margin:0}
        @media (prefers-color-scheme:dark){body{background:#1e1e1e;color:#ccc}}
        div{max-width:440px;text-align:center}h1{font-size:20px;font-weight:600}p{line-height:1.45}
        code{font-size:12px;opacity:.6;word-break:break-all}button{font:inherit;padding:6px 16px;border-radius:8px;border:0;
        background:#0a84ff;color:white;cursor:pointer}</style>
        <div><h1>This page couldn't be opened</h1><p>\(escape(message))</p><p><code>\(address)</code></p>
        <button onclick="location.href='\(address.replacingOccurrences(of: "'", with: "%27"))'">Try Again</button></div>
        """
    }

    /// Each site keeps the zoom it was given.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let zoom = SiteZoom.zoom(for: webView.url)
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    /// Downloads go to ~/Downloads (where the sidebar's downloads view looks).
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var url = dir.appendingPathComponent(suggestedFilename)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(name) \(n)" : "\(name) \(n).\(ext)")
            n += 1
        }
        downloadTargets[ObjectIdentifier(download)] = url
        completionHandler(url)
        onDownloadsChanged?()
    }

    /// Done: the Dock's Downloads stack bounces, like after a download in Safari.
    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloadTargets.removeValue(forKey: ObjectIdentifier(download)) else { return }
        onDownloadsChanged?()
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
        Log.write("download finished: \(url.pathExtension)")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let url = downloadTargets.removeValue(forKey: ObjectIdentifier(download))
        onDownloadsChanged?()
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        Log.write("download failed: \(error.localizedDescription)")
        onHint?("Download failed\(url.map { ": " + $0.lastPathComponent } ?? ""). \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        present(alert, on: webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, on: webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    /// Sites behind a username and password (HTTP authentication): ask, like Safari.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM].contains(method),
              challenge.previousFailureCount < 3 else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let alert = NSAlert()
        alert.messageText = "Log in to \(challenge.protectionSpace.host)"
        alert.informativeText = challenge.previousFailureCount > 0 ? "That didn't work. Try again." : (challenge.protectionSpace.realm ?? "")
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = "Username"
        user.stringValue = challenge.proposedCredential?.user ?? ""
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        password.placeholderString = "Password"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        fields.addSubview(user)
        fields.addSubview(password)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = user.stringValue.isEmpty ? user : password
        present(alert, on: webView) { response in
            guard response == .alertFirstButtonReturn else { completionHandler(.cancelAuthenticationChallenge, nil); return }
            completionHandler(.useCredential, URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
        }
    }

    /// A page's dialog as a sheet on its own window, so the bar and other tabs keep working.
    private func present(_ alert: NSAlert, on webView: WKWebView, done: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { done(response) } }
        } else {
            done(alert.runModal())
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        completionHandler(Prompt.text(prompt, initial: defaultText ?? ""))
    }

    /// Camera and microphone: ask, like Safari does.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }
}

// MARK: - Window

/// The browser window: a slim toolbar (back, forward, reload, address) above the page.
@MainActor
final class BrowserWindow: NSWindow, NSWindowDelegate {
    var onNewTab: (() -> Void)?
    var onCloseTab: (() -> Void)?
    /// Typed addresses arrive through the menu bar field or DOCKlight, not this window.
    var onAddress: ((String) -> Void)?
    var onNavigate: ((NavigationAction) -> Void)?

    /// Like Arc: just the page. No toolbar strip; back, forward, reload and the address live in
    /// the bar. The window buttons sit in a small notch in the frame's color, cut into the page's
    /// top-left corner, so they belong to the window without covering the page's content.
    private let progress = NSView()
    private let notch = CornerNotch()
    private let pageArea = NSView()
    private let empty = NSTextField(labelWithString: "No open tab in this workspace.\nPress ⌘T or click a pin in the sidebar.")
    private weak var shown: WKWebView?

    /// Called instead of hiding when the red button is clicked (the frozen window releases its freeze).
    var onClose: (() -> Void)?

    init(autosave: Bool = true) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        delegate = self
        if autosave { setFrameAutosaveName("proDOCKtivity.browser") }
        minSize = NSSize(width: 420, height: 300)
        buildContent()
    }

    private func buildContent() {
        let root = NSView()
        contentView = root

        pageArea.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pageArea)
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 13)
        empty.translatesAutoresizingMaskIntoConstraints = false
        pageArea.addSubview(empty)

        progress.wantsLayer = true
        progress.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progress.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(progress)

        root.addSubview(notch)
        layoutNotch()

        progressWidth = progress.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            pageArea.topAnchor.constraint(equalTo: root.topAnchor),
            pageArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pageArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pageArea.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: pageArea.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: pageArea.centerYAnchor),
            progress.topAnchor.constraint(equalTo: root.topAnchor),
            progress.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
            progressWidth,
        ])
    }

    private var progressWidth: NSLayoutConstraint!

    /// Wraps the notch around the red / yellow / green buttons, pinned to the top-left corner.
    private func layoutNotch() {
        guard let root = contentView else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { standardWindowButton($0) }
        guard !buttons.isEmpty else { return }
        let union = buttons.map { root.convert($0.convert($0.bounds, to: nil), from: nil) }.reduce(NSRect.null) { $0.union($1) }
        let width = union.maxX + 9
        let height = root.bounds.maxY - union.minY + 7
        let size = NSSize(width: width + CornerNotch.fillet, height: height + CornerNotch.fillet)
        notch.notchSize = NSSize(width: width, height: height)
        notch.frame = NSRect(x: 0, y: root.bounds.maxY - size.height, width: size.width, height: size.height)
        notch.autoresizingMask = [.maxXMargin, .minYMargin]
    }

    func windowDidResize(_ notification: Notification) {
        MainActor.assumeIsolated { layoutNotch() }
    }

    /// Green: back to filling the frame (or full screen when snapping is off).
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        MainActor.assumeIsolated {
            guard Settings.shared.autoFitWindows, let frame = WindowManager.targetCocoaRect() else { return true }
            setFrame(frame, display: true, animate: true)
            return false
        }
    }

    /// Shows a tab's page (or the empty state).
    func display(_ tab: WebTab?, browser: WebBrowser) {
        let view = tab?.loadedWebView(browser: browser)
        if shown !== view {
            shown?.removeFromSuperview()
            if let view {
                view.frame = pageArea.bounds
                view.autoresizingMask = [.width, .height]
                pageArea.addSubview(view)
                // Typing and ⌘C / ⌘V / ⌘A go to the page right away, not only after a click into it.
                makeFirstResponder(view)
            }
            shown = view
        }
        empty.isHidden = view != nil
        if let tab { updateChrome(for: tab, color: browser.spaceColor(tab.spaceID)) } else {
            progressWidth.constant = 0
        }
    }

    func updateChrome(for tab: WebTab, color: NSColor?) {
        title = tab.title
        notch.color = color ?? .windowBackgroundColor
        guard let view = tab.webView else { return }
        let p = view.isLoading ? max(0.05, view.estimatedProgress) : 0
        progressWidth.constant = (contentView?.bounds.width ?? 0) * p
    }

    // MARK: Keys and closing

    /// The red button hides the window; tabs stay open.
    /// Frame mode: a resize that reaches past the frame is pulled back inside it.
    func windowDidEndLiveResize(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard WindowManager.framesOwnWindows, let area = WindowManager.fullCocoaRect() else { return }
            let inside = frame.intersection(area)
            if !inside.isNull, inside != frame { setFrame(inside, display: true, animate: true) }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let onClose { onClose(); return false }
        orderOut(nil)
        return false
    }

    // Menu commands (MainMenu): ⌘T, ⌘W, ⌘L, ⌘R, ⌘[, ⌘], ⌘+, ⌘-, ⌘0 for this window's tab.
    @objc func newTab(_ sender: Any?) { onNewTab?() }
    @objc func newIncognitoTab(_ sender: Any?) { WebBrowser.shared.newIncognitoTab() }
    @objc func closeTab(_ sender: Any?) { onCloseTab?() }
    @objc func reopenClosedTab(_ sender: Any?) { WebBrowser.shared.reopenClosedTab() }
    @objc func nextTab(_ sender: Any?) { WebBrowser.shared.selectAdjacentTab(1) }
    /// ⌘⌥C: the page's address to the clipboard.
    @objc func copyPageAddress(_ sender: Any?) { WebBrowser.shared.copyAddress(of: self) }
    var shownURL: URL? { shown?.url }

    /// Typing goes to the page again (its own text cursor may already be blinking).
    func focusPage() {
        guard let shown else { return }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(shown)
    }
    @objc func previousTab(_ sender: Any?) { WebBrowser.shared.selectAdjacentTab(-1) }
    @objc func selectTabNumber(_ sender: NSMenuItem) { WebBrowser.shared.selectTab(number: sender.tag) }
    @objc func openLocation(_ sender: Any?) { WebBrowser.shared.focusAddress?() }
    @objc func reloadPage(_ sender: Any?) { onNavigate?(.reload) }
    @objc func goBackPage(_ sender: Any?) { onNavigate?(.back) }
    @objc func goForwardPage(_ sender: Any?) { onNavigate?(.forward) }
    @objc func zoomIn(_ sender: Any?) { shown.map { setZoom(min(3, $0.pageZoom + 0.1), on: $0) } }
    @objc func zoomOut(_ sender: Any?) { shown.map { setZoom(max(0.3, $0.pageZoom - 0.1), on: $0) } }
    @objc func actualSize(_ sender: Any?) { shown.map { setZoom(1, on: $0) } }

    private func setZoom(_ zoom: CGFloat, on view: WKWebView) {
        view.pageZoom = zoom
        SiteZoom.set(zoom, for: view.url)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBackPage(_:)): return shown?.canGoBack == true
        case #selector(goForwardPage(_:)): return shown?.canGoForward == true
        case #selector(reopenClosedTab(_:)): return WebBrowser.shared.canReopenClosedTab
        case #selector(copyPageAddress(_:)): return shown?.url != nil
        case #selector(reloadPage(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualSize(_:)): return shown != nil
        default: return super.validateMenuItem(item)
        }
    }
}

/// The frame's color reaching into the page's top-left corner, with the window buttons on it:
/// rounded where it meets the page, flowing into the top and left edges like a tab's corner.
final class CornerNotch: NSView {
    static let fillet: CGFloat = 8
    var notchSize = NSSize(width: 70, height: 28) { didSet { needsDisplay = true } }
    var color: NSColor = .windowBackgroundColor { didSet { if color != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let w = notchSize.width, h = notchSize.height, f = Self.fillet, r: CGFloat = 10
        let path = NSBezierPath()
        path.move(to: .zero)
        path.line(to: NSPoint(x: w + f, y: 0))
        path.curve(to: NSPoint(x: w, y: f), controlPoint1: NSPoint(x: w, y: 0), controlPoint2: NSPoint(x: w, y: 0))
        path.line(to: NSPoint(x: w, y: h - r))
        path.curve(to: NSPoint(x: w - r, y: h), controlPoint1: NSPoint(x: w, y: h), controlPoint2: NSPoint(x: w, y: h))
        path.line(to: NSPoint(x: f, y: h))
        path.curve(to: NSPoint(x: 0, y: h + f), controlPoint1: NSPoint(x: 0, y: h), controlPoint2: NSPoint(x: 0, y: h))
        path.close()
        color.setFill()
        path.fill()
    }
}

// MARK: - Provider

/// The built-in browser as a BrowserModel engine. Calls arrive on the model's background
/// queue and are forwarded to the main thread, where WebKit lives.
final class WebKitProvider: BrowserProvider, @unchecked Sendable {
    let displayName = "proDOCKtivity Browser"
    let bundleID = Bundle.main.bundleIdentifier ?? "app.prodocktivity.sidebar"
    var isBuiltIn: Bool { true }
    var spacesAreLibrary: Bool { true }

    private func onMain<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    func fetch() throws -> BrowserSnapshot { onMain { WebBrowser.shared.snapshot() } }
    func select(_ tab: BrowserItem, spaceID: String?) throws { onMain { WebBrowser.shared.select(tabID: tab.id) } }
    func close(_ tab: BrowserItem) throws { onMain { WebBrowser.shared.close(tabID: tab.id) } }
    func focus(spaceID: String) throws { onMain { WebBrowser.shared.focus(spaceID: spaceID) } }
    func open(url: String) throws { onMain { _ = WebBrowser.shared.newTab(url: url) } }
    func navigate(_ action: NavigationAction) throws { onMain { WebBrowser.shared.navigate(action) } }
    func load(url: String) throws { onMain { WebBrowser.shared.load(url: url) } }
    func makeTab(url: String) throws -> String { onMain { WebBrowser.shared.newTab(url: url).id } }
    func activate() { onMain { WebBrowser.shared.show() } }
}

/// Page zoom per site (host), like Safari's per-website zoom.
@MainActor enum SiteZoom {
    private static let key = "siteZoom"
    private static var zooms: [String: Double] = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]

    private static func site(_ url: URL?) -> String? {
        guard let host = url?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func zoom(for url: URL?) -> CGFloat { site(url).flatMap { zooms[$0] }.map { CGFloat($0) } ?? 1 }

    static func set(_ zoom: CGFloat, for url: URL?) {
        guard let site = site(url) else { return }
        zooms[site] = abs(zoom - 1) < 0.01 ? nil : Double(zoom)
        UserDefaults.standard.set(zooms, forKey: key)
    }
}


/// A tab's web view; adds the extensions' entries (e.g. Bitwarden's auto-fill) to the right-click menu.
final class TabWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let items = WebExtensionStore.shared.contextMenuItems(for: self)
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        items.forEach { menu.addItem($0) }
    }
}
