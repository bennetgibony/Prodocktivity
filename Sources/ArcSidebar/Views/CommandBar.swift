import AppKit
import SwiftUI

/// One search result in the command bar.
struct CommandResult: Identifiable {
    enum Icon {
        case image(NSImage)
        case favicon(String?)
        case symbol(String)
        case emoji(String)
    }
    enum Kind: String { case app = "App", pin = "Pin", tab = "Open Tab", space = "Workspace", file = "File", web = "Web", command = "Command" }

    let id: String
    let title: String
    let subtitle: String
    let icon: Icon
    let kind: Kind
    /// Runs the result; `split` is true for ⌥⏎.
    let run: (_ split: Bool) -> Void
}

/// Spotlight-style search ("DOCKlight") over apps, files, pins, open tabs and spaces.
/// "&" first: web search (opens as a tab in the current space). "/" first: Finder search.
@MainActor
final class CommandBarModel: ObservableObject {
    @Published var query = "" { didSet { update() } }
    @Published private(set) var results: [CommandResult] = []
    @Published var selection = 0

    private let apps: AppsModel
    private let browser: BrowserModel
    private let library: Library
    var close: () -> Void = {}

    /// Installed apps with both their file name and the name the Mac shows (e.g. "Systemeinstellungen").
    private var installedApps: [(name: String, altName: String, url: URL, id: String)] = []
    private var fileQuery: NSMetadataQuery?
    private var fileResults: [CommandResult] = []
    private var fileObserver: NSObjectProtocol?
    private var appFolderWatchers: [DispatchSourceFileSystemObject] = []
    private var pendingAppScan: DispatchWorkItem?
    private var appScanRunning = false

    init(apps: AppsModel, browser: BrowserModel, library: Library) {
        self.apps = apps
        self.browser = browser
        self.library = library
    }

    enum Mode { case all, web, finder, address }

    /// ⌘L in the browser: the bar works like the browser's address bar for the current tab.
    @Published private(set) var addressMode = false
    private(set) var currentURL: String?

    var mode: Mode {
        if addressMode { return .address }
        return query.hasPrefix("&") ? .web : query.hasPrefix("/") ? .finder : .all
    }

    func prepare(address: String? = nil) {
        addressMode = address != nil
        currentURL = address
        query = ""
        selection = 0
        if installedApps.isEmpty { scanApps(); watchAppFolders() } else { rescanAppsInBackground() }
        update()
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    func runSelected(split: Bool) {
        guard results.indices.contains(selection) else { return }
        let result = results[selection]
        close()
        result.run(split)
    }

    // MARK: Results

    private func update() {
        selection = 0
        let q = query.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .address:
            results = addressResults(q)
            stopFileSearch()
            return
        case .web:
            let text = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
            results = webResults(for: text, forced: true)
            stopFileSearch()
            return
        case .finder:
            let text = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
            results = finderResults(for: text)
            if text.count >= 2 { startFileSearch(text, limit: 8) } else { stopFileSearch() }
            return
        case .all:
            break
        }
        guard !q.isEmpty else {
            results = recentTabs()
            stopFileSearch()
            return
        }
        var list: [CommandResult] = []
        // Typed an address? Going there is the first suggestion.
        if Self.looksLikeAddress(q) { list += webResults(for: q, forced: false).filter { $0.id == "web:open" } }
        list += commandResults(q)
        list += appResults(q, limit: 4)
        list += pinResults(q).prefix(4)
        list += tabResults(q).prefix(4)
        list += spaceResults(q).prefix(2)
        list += fileResults.prefix(4)
        list += webResults(for: q, forced: false).filter { !(Self.looksLikeAddress(q) && $0.id == "web:open") }
        results = list
        startFileSearch(q)
    }

    /// "moodle.de", "https://…", "localhost:3000" — something to open rather than search for.
    static func looksLikeAddress(_ q: String) -> Bool {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(" ") else { return false }
        if t.contains("://") || t.hasPrefix("localhost") { return true }
        let parts = t.split(separator: "/").first?.split(separator: ".") ?? []
        return parts.count >= 2 && (parts.last?.count ?? 0) >= 2 && parts.last!.allSatisfy(\.isLetter)
    }

    /// ⌘L results: load in this tab, or jump to something already open/pinned.
    private func addressResults(_ q: String) -> [CommandResult] {
        guard !q.isEmpty else {
            let host = currentURL.flatMap { URL(string: $0)?.host } ?? "this tab"
            return [CommandResult(id: "addr:hint", title: "Type an address or search", subtitle: "Loads in the current tab (\(host))",
                                  icon: .symbol("arrow.right.circle"), kind: .web) { _ in }]
        }
        let isAddress = Self.looksLikeAddress(q)
        var out = [CommandResult(id: "addr:go", title: isAddress ? "Go to \(q)" : "Search the web for “\(q)”",
                                 subtitle: "In the current tab · ⌥⏎ new tab in split view",
                                 icon: isAddress ? .favicon(URL(string: BrowserModel.url(fromInput: q) ?? "")?.host) : .symbol("magnifyingglass"),
                                 kind: .web) { [browser] split in
            if split { browser.createTab(input: q, split: true) } else { browser.loadInCurrentTab(input: q) }
        }]
        out += pinResults(q).prefix(3)
        out += tabResults(q).prefix(3)
        return out
    }

    /// How well `text` matches what was typed (lower is better, nil = no match): the whole
    /// name, its start, the start of a word, anywhere. Case and accents don't matter.
    static func matchScore(_ text: String, _ q: String) -> Int? {
        let t = fold(text), q = fold(q)
        guard !q.isEmpty else { return nil }
        if t == q { return 0 }
        if t.hasPrefix(q) { return 1 }
        if t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return 2 }
        if t.contains(q) { return 3 }
        return nil
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Matching items, best first (equally good ones keep their order).
    static func ranked<T>(_ items: [T], _ q: String, _ texts: (T) -> [String]) -> [T] {
        ranked(items) { item in texts(item).compactMap { matchScore($0, q) }.min() }
    }

    static func ranked<T>(_ items: [T], by score: (T) -> Int?) -> [T] {
        items.enumerated().compactMap { i, item in score(item).map { (item, $0, i) } }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .map(\.0)
    }

    /// A website by its title, or (less good) by its address.
    static func siteScore(title: String, url: String, _ q: String) -> Int? {
        matchScore(title, q) ?? (url.localizedCaseInsensitiveContains(q) ? 4 : nil)
    }

    private func ranked<T>(_ items: [T], _ q: String, _ text: (T) -> String) -> [T] {
        Self.ranked(items, q) { [text($0)] }
    }

    /// The best `limit` apps (icons are only loaded for those).
    private func appResults(_ q: String, limit: Int) -> [CommandResult] {
        Self.ranked(installedApps, q) { [$0.name, $0.altName] }
        .prefix(limit)
        .map { app in
            CommandResult(id: "app:" + app.id, title: app.altName, subtitle: app.altName == app.name ? "Application" : "Application · \(app.name)",
                          icon: .image(NSWorkspace.shared.icon(forFile: app.url.path)), kind: .app) { [apps] split in
                apps.open(app.id, split: split)
            }
        }
    }

    private func pinResults(_ q: String) -> [CommandResult] {
        var out: [(CommandResult, Int)] = []
        for space in library.spaces {
            for site in Library.allSites(space.pinned) {
                guard let score = Self.siteScore(title: site.title, url: site.url, q) else { continue }
                let item = BrowserItem(id: Library.idPrefix + site.id, title: site.title, url: site.url, kind: .tab)
                let here = space.id == library.activeSpace?.id
                out.append((CommandResult(id: "pin:" + site.id, title: site.title,
                                         subtitle: "\(here ? space.title : "Opens here · from \(space.title)") · \(URL(string: site.url)?.host ?? site.url)",
                                         icon: .favicon(URL(string: site.url)?.host), kind: .pin) { [browser] split in
                    // A pin of another space opens in this one; you stay where you are.
                    if here { browser.openSite(item, split: split) } else { browser.openPinned(url: site.url, split: split) }
                }, score))
            }
        }
        for entry in apps.pinnedEntries(favorites: []) {
            if case .tab(let tab) = entry, let score = Self.siteScore(title: tab.title, url: tab.url, q) {
                out.append((CommandResult(id: "top:" + tab.id, title: tab.title, subtitle: "Pinned · \(tab.host ?? "")",
                                         icon: .favicon(tab.host), kind: .pin) { [browser] split in
                    browser.openPinned(url: tab.url, split: split)
                }, score))
            }
        }
        return Self.ranked(out) { $0.1 }.map(\.0)
    }

    private func tabResults(_ q: String) -> [CommandResult] {
        Self.ranked(browser.liveTabs) { Self.siteScore(title: $0.title, url: $0.url, q) }.map { tab in
            CommandResult(id: "tab:" + tab.id, title: tab.title,
                          subtitle: browser.isInCurrentSpace(tab) ? tab.host ?? tab.url : "Opens here · \(tab.host ?? tab.url)",
                          icon: .favicon(tab.host), kind: .tab) { [browser] split in
                browser.openHere(tab, split: split)
            }
        }
    }

    private func recentTabs() -> [CommandResult] {
        Array(browser.liveTabs.prefix(6)).map { tab in
            CommandResult(id: "tab:" + tab.id, title: tab.title,
                          subtitle: browser.isInCurrentSpace(tab) ? tab.host ?? tab.url : "Opens here · \(tab.host ?? tab.url)",
                          icon: .favicon(tab.host), kind: .tab) { [browser] split in
                browser.openHere(tab, split: split)
            }
        }
    }

    /// The app's own commands, found by name or a word for them.
    static let commands: [(title: String, words: [String], symbol: String)] = [
        ("Show All Workspaces", ["overview", "spaces", "workspaces", "tidy", "alle"], "square.grid.3x1.below.line.grid.1x2"),
    ]

    private func commandResults(_ q: String) -> [CommandResult] {
        Self.ranked(Self.commands, q) { [$0.title] + $0.words }.map { command in
            CommandResult(id: "cmd:" + command.title, title: command.title, subtitle: "⌃⌥W · every workspace side by side",
                          icon: .symbol(command.symbol), kind: .command) { _ in SidebarActions.showOverview?() }
        }
    }

    private func spaceResults(_ q: String) -> [CommandResult] {
        ranked(library.spaces, q, \.title).map { space in
            let icon: CommandResult.Icon = space.emoji.map { .emoji($0) } ?? .symbol(space.symbol ?? "circle.fill")
            return CommandResult(id: "space:" + space.id, title: space.title, subtitle: "Switch to workspace", icon: icon, kind: .space) { [browser] _ in
                if let display = browser.displaySpaces.first(where: { $0.id == space.id }) { browser.focus(space: display) }
            }
        }
    }

    private func webResults(for text: String, forced: Bool) -> [CommandResult] {
        guard !text.isEmpty else {
            return forced ? [CommandResult(id: "web:hint", title: "Type to search the web", subtitle: "Opens as a tab in this workspace",
                                           icon: .symbol("globe"), kind: .web) { _ in }] : []
        }
        var out: [CommandResult] = []
        if let url = BrowserModel.url(fromInput: text), url != BrowserModel.searchURL(text) {
            out.append(CommandResult(id: "web:open", title: "Open \(text)", subtitle: url, icon: .favicon(URL(string: url)?.host), kind: .web) { [browser] split in
                browser.createTab(input: text, split: split)
            })
        }
        out.append(CommandResult(id: "web:search", title: "Search the web for “\(text)”", subtitle: "\(Settings.shared.searchEngine.name) · new tab in this workspace",
                                 icon: .symbol("magnifyingglass"), kind: .web) { [browser] split in
            browser.createTab(input: BrowserModel.searchURL(text), split: split)
        })
        return out
    }

    // MARK: Apps & files

    /// All installed apps, also in subfolders (e.g. /Applications/Stata/StataSE.app).
    private func scanApps() {
        installedApps = InstalledApps.scan().map { ($0.fileName, $0.name, $0.url, $0.id) }
        Log.write("command bar: \(installedApps.count) apps indexed")
    }

    /// Picks up apps installed or deleted since the last scan, without holding up the bar.
    private func rescanAppsInBackground() {
        guard !appScanRunning else { return }
        appScanRunning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = InstalledApps.scan().map { (name: $0.fileName, altName: $0.name, url: $0.url, id: $0.id) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.appScanRunning = false
                    guard found.map(\.url) != self.installedApps.map(\.url) else { return }
                    let before = self.installedApps.count
                    self.installedApps = found
                    Log.write("command bar: apps changed, \(before) → \(found.count) indexed")
                    if self.mode == .all, !self.query.trimmingCharacters(in: .whitespaces).isEmpty { self.update() }
                }
            }
        }
    }

    /// Rescans when an app is added to or removed from an app folder (installer, drag-in, App Store, Trash).
    /// Waits 2 s so an app that is still being copied has its Info.plist by then.
    private func watchAppFolders() {
        let folders = ["/Applications", NSHomeDirectory() + "/Applications"]
        for folder in folders {
            let fd = Darwin.open(folder, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleAppScan() }
            }
            src.setCancelHandler { Darwin.close(fd) }
            src.resume()
            appFolderWatchers.append(src)
        }
    }

    private func scheduleAppScan() {
        pendingAppScan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rescanAppsInBackground() }
        }
        pendingAppScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// "/" mode: files and folders, plus a row that opens the full search in Finder.
    private func finderResults(for text: String) -> [CommandResult] {
        guard !text.isEmpty else {
            return [CommandResult(id: "finder:hint", title: "Type to search your files", subtitle: "Results from Finder / Spotlight",
                                  icon: .symbol("folder"), kind: .file) { _ in }]
        }
        return [CommandResult(id: "finder:all", title: "Show all results for “\(text)” in Finder", subtitle: "Opens a Finder search window",
                              icon: .image(NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")), kind: .file) { _ in
            Self.openFinderSearch(text)
        }]
    }

    /// Opens a Finder window searching file names for `text` (via a temporary saved search).
    static func openFinderSearch(_ text: String) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("proDOCKtivity")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Search “\(text.replacingOccurrences(of: "/", with: "-"))”.savedSearch")
        let escaped = text.replacingOccurrences(of: "\"", with: "")
        let plist: [String: Any] = [
            "CompatibleVersion": 1,
            "RawQuery": "(kMDItemDisplayName = \"*\(escaped)*\"cd)",
            "RawQueryDict": ["FinderFilesOnly": true, "RawQuery": "(kMDItemDisplayName = \"*\(escaped)*\"cd)",
                             "SearchScopes": ["kMDQueryScopeComputer"], "UserFilesOnly": true],
            "SearchCriteria": ["CurrentFolderPath": [NSHomeDirectory()], "FXScopeArrayOfPaths": ["kMDQueryScopeComputer"]],
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: url)
            NSWorkspace.shared.open(url)
        }
    }

    /// Files and folders by name, via the Mac's own Spotlight index.
    private var fileLimit = 4

    private func startFileSearch(_ q: String, limit: Int = 4) {
        fileLimit = limit
        stopFileSearch()
        guard q.count >= 2 else { return }
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemDisplayName LIKE[cd] %@", "*\(q)*")
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        fileObserver = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.collectFiles(q) }
        }
        fileQuery = query
        query.start()
    }

    private func collectFiles(_ q: String) {
        guard let query = fileQuery else { return }
        query.disableUpdates()
        var files: [CommandResult] = []
        for i in 0..<min(query.resultCount, 30) {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !Self.isAppInternal(path) else { continue }
            let url = URL(fileURLWithPath: path)
            files.append(CommandResult(id: "file:" + path, title: url.lastPathComponent,
                                       subtitle: url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                                       icon: .image(NSWorkspace.shared.icon(forFile: path)), kind: .file) { _ in
                NSWorkspace.shared.open(url)
            })
            if files.count == fileLimit { break }
        }
        stopFileSearch()
        let current = self.query.trimmingCharacters(in: .whitespaces)
        guard current == q || current == "/" + q || current.dropFirst().trimmingCharacters(in: .whitespaces) == q else { return }
        fileResults = files
        // Insert files before the web results, keeping the current selection.
        let tail = results.filter { $0.kind == .web || $0.id == "finder:all" }
        results = results.filter { $0.kind != .web && $0.kind != .file } + files + tail
        fileResults = []
    }

    /// Files that belong to an app rather than to the user: Library, app bundles, hidden folders, node_modules,
    /// and Zotero's own data (its ~700 translator scripts, "Google Books.js", match most web searches).
    /// Zotero's attachments (~/Zotero/storage) stay findable.
    static func isAppInternal(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        if path.contains("/Library/") || path.hasSuffix(".app") || path.contains("/node_modules/") || path.contains("/.") { return true }
        return path.hasPrefix(home + "/Zotero/") && !path.hasPrefix(home + "/Zotero/storage/")
    }

    private func stopFileSearch() {
        fileQuery?.stop()
        fileQuery = nil
        if let fileObserver { NotificationCenter.default.removeObserver(fileObserver) }
        fileObserver = nil
    }
}

/// Borderless key panel for typing without activating the app.
final class CommandPanel: NSPanel {
    var onResign: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        EditKeys.perform(event, in: self) || super.performKeyEquivalent(with: event)
    }
    override func resignKey() {
        super.resignKey()
        onResign()
    }
}

@MainActor
final class CommandBarController {
    private let model: CommandBarModel
    private var panel: CommandPanel?

    private var resultsSink: Any?

    init(model: CommandBarModel) {
        self.model = model
        model.close = { [weak self] in self?.close() }
        // The panel is as tall as its results (up to 8 rows), growing downward from the search field.
        resultsSink = model.$results.sink { [weak self] results in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fitHeight(rows: results.count) } }
        }
    }

    /// The search field (48) and result rows (38), grown with the text size.
    @MainActor static var fieldHeight: CGFloat { (DS.Size.paletteField * CGFloat(Settings.shared.textScale)).rounded() }
    @MainActor static var rowHeight: CGFloat { (DS.Size.paletteRow * CGFloat(Settings.shared.textScale)).rounded() }

    private func height(rows: Int) -> CGFloat {
        rows == 0 ? Self.fieldHeight
            : Self.fieldHeight + DS.Line.hairline + CGFloat(min(rows, 8)) * Self.rowHeight + DS.Space.s * 2
    }

    private func fitHeight(rows: Int) {
        guard let panel, panel.isVisible else { return }
        let h = height(rows: rows)
        guard abs(panel.frame.height - h) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - h
        frame.size.height = h
        panel.setFrame(frame, display: true, animate: false)
    }

    var isShown: Bool { panel?.isVisible == true }

    func toggle() { isShown ? close() : show() }

    /// ⌘L: open as the address bar for the browser's current tab.
    func showAddressBar(currentURL: String?) {
        show(address: currentURL ?? "")
    }

    func show(address: String? = nil) {
        GettingStarted.shared.mark(.docklight)
        model.prepare(address: address)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: DS.Size.palette, height: height(rows: model.results.count))
        let vf = screen.visibleFrame
        // The search field always sits at the same height; results hang below it.
        let top = vf.maxY - vf.height * DS.Size.paletteTop - Self.fieldHeight
        panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: top + Self.fieldHeight - size.height,
                              width: size.width, height: size.height), display: false)
        panel.contentView = NSHostingView(rootView: CommandBarView(model: model).designRoot())
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        Log.write("command bar shown key=\(panel.isKeyWindow) visible=\(panel.isVisible)")
    }

    func close() {
        panel?.orderOut(nil)
    }

    func debugQuery(_ q: String) { model.query = q }

    private func makePanel() -> CommandPanel {
        let p = CommandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .modalPanel
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.onResign = { [weak self] in
            Log.write("command bar resigned key")
            self?.close()
        }
        return p
    }
}

struct CommandBarView: View {
    @ObservedObject var model: CommandBarModel
    @FocusState private var focused: Bool
    @State private var lastMouse = NSEvent.mouseLocation
    @Environment(\.dsAccent) private var accent

    private var symbol: String {
        switch model.mode {
        case .web: return "globe"
        case .finder: return "folder"
        case .address: return "link"
        default: return "magnifyingglass"
        }
    }

    private var prompt: String {
        switch model.mode {
        case .address: return model.currentURL.flatMap { $0.isEmpty ? nil : $0 } ?? "Address or search"
        case .web: return "Search the web…"
        case .finder: return "Search your files…"
        default: return "Apps, files, pins, tabs, addresses — “&” web, “/” Finder"
        }
    }

    private var modeLabel: String {
        model.mode == .web ? "Web" : model.mode == .finder ? "Finder" : "This tab"
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            if !model.results.isEmpty {
                Rectangle().fill(Palette.separator).frame(height: DS.Line.hairline)
                results
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .floatingSurface()
        .dsAnimation(DS.Motion.quick, value: model.mode)
        .onAppear { focused = true }
    }

    /// The search field: 48 high, `title3`, no border.
    private var field: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: symbol)
                .textRole(.title3)
                .foregroundStyle(model.mode == .all ? Palette.text3 : accent.color)
            TextField("", text: $model.query, prompt: Text(prompt).foregroundColor(Palette.text3))
                .textFieldStyle(.plain)
                .textRole(.title3, weight: .regular)
                .foregroundStyle(Palette.text)
                .focused($focused)
                .onSubmit { model.runSelected(split: NSEvent.modifierFlags.contains(.option)) }
                .onExitCommand {
                    // Esc clears the text first, then closes.
                    if model.query.isEmpty { model.close() } else { model.query = "" }
                }
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.downArrow) { model.move(1); return .handled }
            if model.mode != .all {
                Text(modeLabel)
                    .textRole(.caption, weight: .semibold)
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Space.xxs)
                    .background(accent.soft, in: RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: CommandBarController.fieldHeight)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                        ResultRow(result: result, selected: index == model.selection)
                            .id(result.id)
                            .onHover { inside in
                                // Only a moving mouse picks a row: rows scrolling under a resting
                                // pointer (arrow keys) must not steal the selection.
                                let point = NSEvent.mouseLocation
                                guard inside, point != lastMouse else { return }
                                lastMouse = point
                                model.selection = index
                            }
                            .onTapGesture {
                                model.selection = index
                                model.runSelected(split: NSEvent.modifierFlags.contains(.option))
                            }
                    }
                }
                .padding(DS.Space.s)
            }
            .onChange(of: model.selection) { _, i in
                if model.results.indices.contains(i) { proxy.scrollTo(model.results[i].id) }
            }
        }
    }
}

/// A result: 16 pt icon, title, its context in `text3` ("Tab · linkedin.com"), and on the
/// selected row the Return keycap.
private struct ResultRow: View {
    let result: CommandResult
    let selected: Bool
    @Environment(\.dsAccent) private var accent

    var body: some View {
        HStack(spacing: DS.Space.m) {
            icon.frame(width: DS.Size.paletteIcon, height: DS.Size.paletteIcon)
            Text(result.title)
                .textRole(.body)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .layoutPriority(1)
            Text(result.subtitle.isEmpty ? result.kind.rawValue : result.kind.rawValue + " · " + result.subtitle)
                .textRole(.footnote)
                .foregroundStyle(Palette.text3)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DS.Space.s)
            Keycap(text: "⏎").opacity(selected ? 1 : 0)
        }
        .padding(.horizontal, DS.Space.s)
        .frame(height: CommandBarController.rowHeight)
        .background(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
            .fill(selected ? accent.soft : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch result.icon {
        case .image(let img): Image(nsImage: img).resizable().interpolation(.high)
        case .favicon(let host): FaviconView(host: host).padding(DS.Space.xxs)
        case .symbol(let name): Image(systemName: name).textRole(.headline).foregroundStyle(Palette.text2)
        case .emoji(let e): Text(e).textRole(.headline)
        }
    }
}
