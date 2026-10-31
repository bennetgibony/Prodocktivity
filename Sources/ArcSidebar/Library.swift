import AppKit
import SwiftUI

/// A website or folder kept in the sidebar (the sidebar owns these; the browser only shows pages).
struct LibraryItem: Codable, Identifiable, Equatable {
    /// A website, a folder, or an app (then `url` holds the app's bundle id).
    enum Kind: String, Codable { case site, folder, app }
    var id: String = UUID().uuidString
    var kind: Kind
    var title: String
    var url: String = ""
    /// The browser tab this item was imported from or last opened as, to find it again.
    var arcTabID: String?
    var children: [LibraryItem] = []

    static func app(_ bundleID: String, title: String) -> LibraryItem {
        LibraryItem(kind: .app, title: title, url: bundleID)
    }

    static func site(_ title: String, _ url: String, arcTabID: String? = nil) -> LibraryItem {
        LibraryItem(kind: .site, title: title, url: url, arcTabID: arcTabID)
    }
}

struct LibrarySpace: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var title: String
    var emoji: String?
    var symbol: String?
    /// The color the space was imported or made with (kept so the nearest color can be found again).
    var colors: [RGB] = []
    var noise: Double?
    /// The space's color (an `Area`) and accent, by name (an unknown name falls back, never breaks loading).
    var colorName: String?
    var accentName: String?
    /// The browser space this one is linked to (switching here switches there too).
    var arcSpaceID: String?
    /// Login profile of the built-in browser (nil = the first profile).
    var profileID: String?
    var pinned: [LibraryItem] = []

    var icon: SpaceIcon? {
        if let emoji { return .emoji(emoji) }
        if let symbol { return .symbol(symbol) }
        return nil
    }

    var area: Area? {
        get { colorName.flatMap(Area.init(rawValue:)) }
        set { colorName = newValue?.rawValue }
    }
    var accent: Accent? {
        get { accentName.flatMap(Accent.init(rawValue:)) }
        set { accentName = newValue?.rawValue }
    }
}

/// A set of logins (cookies, website data) for the built-in browser. Several spaces can
/// share one profile, e.g. "Private" for both Socializing and Uni.
struct BrowserProfile: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
}

/// The sidebar's own data: spaces with pinned websites and folders. Saved to
/// ~/Library/Application Support/proDOCKtivity/library.json.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var spaces: [LibrarySpace] = [] { didSet { save(); browser?.objectWillChange.send() } }
    @Published var activeSpaceID: String? {
        didSet {
            defaults.set(activeSpaceID, forKey: "library.activeSpace")
            browser?.objectWillChange.send()
        }
    }
    @Published private(set) var openFolders: Set<String> {
        didSet {
            defaults.set(Array(openFolders), forKey: "library.openFolders")
            browser?.objectWillChange.send()
        }
    }
    /// Views mostly observe the browser model; library changes are forwarded to it.
    weak var browser: BrowserModel?
    /// False until something was imported or created; triggers the automatic first import.
    private(set) var isSetUp: Bool

    @Published private(set) var profiles: [BrowserProfile] = [] { didSet { saveProfiles() } }

    private var profilesURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("profiles.json") }

    private func saveProfiles() {
        guard loaded, let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: profilesURL, options: .atomic)
        browser?.objectWillChange.send()
    }

    /// The profile a space uses.
    func profile(forSpace spaceID: String) -> BrowserProfile? {
        let id = spaces.first { $0.id == spaceID }?.profileID
        return profiles.first { $0.id == id } ?? profiles.first
    }

    /// Replaces every workspace (a setup file): its profiles are added to the ones here (logins stay),
    /// and the first workspace becomes the open one.
    func replaceAll(spaces new: [LibrarySpace], profiles newProfiles: [BrowserProfile]) {
        profiles += newProfiles.filter { p in !profiles.contains { $0.id == p.id } }
        spaces = Self.withColors(new.isEmpty ? [LibrarySpace(title: "Home")] : new)
        activeSpaceID = spaces.first?.id
        saveNow()
    }

    @discardableResult
    func addProfile(name: String) -> BrowserProfile {
        let p = BrowserProfile(name: name)
        profiles.append(p)
        return p
    }

    func renameProfile(_ id: String, to name: String) {
        if let i = profiles.firstIndex(where: { $0.id == id }) { profiles[i].name = name }
    }

    func deleteProfile(_ id: String) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        for i in spaces.indices where spaces[i].profileID == id { spaces[i].profileID = nil }
    }

    func setProfile(_ profileID: String, forSpace spaceID: String) {
        updateSpace(spaceID) { $0.profileID = profileID }
    }

    private let fileURL: URL
    private let defaults: UserDefaults

    /// Saving starts only after loading, so setting up doesn't overwrite the file.
    private var loaded = false

    init(fileURL: URL = AppPaths.file("library.json"), defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
        let saved = AppPaths.load([LibrarySpace].self, from: fileURL)
        isSetUp = false
        openFolders = Set(defaults.stringArray(forKey: "library.openFolders") ?? [])
        activeSpaceID = defaults.string(forKey: "library.activeSpace")
        spaces = saved ?? []
        isSetUp = saved != nil
        profiles = AppPaths.load([BrowserProfile].self, from: profilesURL) ?? []
        loaded = true
        assignMissingColors()
        if profiles.isEmpty { profiles = [BrowserProfile(name: "Private")] }
    }

    private var saveWork: DispatchWorkItem?

    /// Changes come in bursts (a drag reorders on every step): written once things settle.
    private func save() {
        guard loaded else { return }
        isSetUp = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes the spaces right away (on quit).
    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard loaded, let data = try? JSONEncoder().encode(spaces) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    var activeSpace: LibrarySpace? {
        spaces.first { $0.id == activeSpaceID } ?? spaces.first
    }

    func space(linkedTo arcSpaceID: String?) -> LibrarySpace? {
        guard let arcSpaceID else { return nil }
        return spaces.first { $0.arcSpaceID == arcSpaceID }
    }

    // MARK: Spaces

    /// A new space gets the next unused space color (or the one nearest to `color`) and the
    /// accent nearest to it.
    @discardableResult
    func addSpace(title: String, emoji: String? = nil, color: RGB? = nil) -> LibrarySpace {
        let area = color.map(Area.nearest) ?? Area.next(after: spaces.compactMap(\.area))
        var space = LibrarySpace(title: title, emoji: emoji, colors: [color ?? area.lightRGB])
        space.area = area
        space.accent = Accent.nearest(to: color ?? area.lightRGB)
        spaces.append(space)
        activeSpaceID = space.id
        return space
    }

    /// Spaces from before the 18 colors and 16 accents get the nearest ones to their old color
    /// (or, without one, the next unused color), once.
    static func withColors(_ spaces: [LibrarySpace]) -> [LibrarySpace] {
        var result = spaces
        for i in result.indices where result[i].area == nil || result[i].accent == nil {
            let old = result[i].colors.first
            if result[i].area == nil {
                result[i].area = old.map(Area.nearest) ?? Area.next(after: result.compactMap(\.area))
            }
            if result[i].accent == nil {
                result[i].accent = Accent.nearest(to: old ?? result[i].area?.lightRGB ?? Area.slate.lightRGB)
            }
        }
        return result
    }

    func assignMissingColors() {
        let colored = Self.withColors(spaces)
        if colored != spaces { spaces = colored }
    }

    func updateSpace(_ id: String, _ change: (inout LibrarySpace) -> Void) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        change(&spaces[i])
    }

    /// Called after a space is deleted, with its id and the space to use instead (if any).
    var onSpaceDeleted: ((String, String?) -> Void)?

    /// Puts a deleted workspace back where it was (Undo).
    func restoreSpace(_ space: LibrarySpace, at index: Int) {
        guard !spaces.contains(where: { $0.id == space.id }) else { return }
        spaces.insert(space, at: min(max(index, 0), spaces.count))
        activeSpaceID = space.id
    }

    /// Puts a deleted profile back, with the workspaces that used it (Undo).
    func restoreProfile(_ profile: BrowserProfile, at index: Int, forSpaces spaceIDs: [String]) {
        guard !profiles.contains(where: { $0.id == profile.id }) else { return }
        profiles.insert(profile, at: min(max(index, 0), profiles.count))
        for id in spaceIDs { updateSpace(id) { $0.profileID = profile.id } }
    }

    func deleteSpace(_ id: String) {
        spaces.removeAll { $0.id == id }
        if activeSpaceID == id { activeSpaceID = spaces.first?.id }
        onSpaceDeleted?(id, activeSpace?.id)
    }

    func moveSpace(_ id: String, by offset: Int) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(i + offset, 0), spaces.count - 1)
        guard i != j else { return }
        let s = spaces.remove(at: i)
        spaces.insert(s, at: j)
    }

    // MARK: Items

    func add(_ item: LibraryItem, toSpace spaceID: String, inFolder folderID: String? = nil, before targetID: String? = nil) {
        updateSpace(spaceID) { space in
            // A folder that's gone (e.g. deleted meanwhile): the item goes to the top level, never nowhere.
            if let folderID, Self.find(space.pinned, id: folderID) != nil {
                Self.mutate(&space.pinned, id: folderID) { $0.children.append(item) }
            } else if let targetID, Self.insert(item, before: targetID, in: &space.pinned) {
                // inserted next to the target, wherever it sits (also inside folders)
            } else {
                space.pinned.append(item)
            }
        }
    }

    func contains(url: String, inSpace spaceID: String) -> Bool {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return false }
        return Self.allSites(space.pinned).contains { $0.url == url }
    }

    func remove(_ id: String) {
        for i in spaces.indices { Self.removeItem(&spaces[i].pinned, id: id) }
    }

    /// Removes a folder but keeps its contents in its place.
    func dissolveFolder(_ id: String) {
        for i in spaces.indices {
            Self.replaceItem(&spaces[i].pinned, id: id) { $0.children }
        }
    }

    func rename(_ id: String, to title: String) {
        for i in spaces.indices { Self.mutate(&spaces[i].pinned, id: id) { $0.title = title } }
    }

    func setArcTabID(_ itemID: String, _ tabID: String?) {
        for i in spaces.indices { Self.mutate(&spaces[i].pinned, id: itemID) { $0.arcTabID = tabID } }
    }

    /// Moves an item before `targetID` (same or other list), or into a folder.
    func move(_ id: String, before targetID: String? = nil, intoFolder folderID: String? = nil, space spaceID: String) {
        guard id != targetID, id != folderID, let item = find(id) else { return }
        // A folder can't go into (or next to something inside) itself: it would vanish with the move.
        if let folderID, Self.find(item.children, id: folderID) != nil { return }
        if let targetID, Self.find(item.children, id: targetID) != nil { return }
        remove(id)
        add(item, toSpace: spaceID, inFolder: folderID, before: targetID)
    }

    func newFolder(in spaceID: String, title: String = "New Folder") {
        let folder = LibraryItem(kind: .folder, title: title)
        add(folder, toSpace: spaceID)
        openFolders.insert(folder.id)
    }

    func find(_ id: String) -> LibraryItem? {
        for s in spaces { if let hit = Self.find(s.pinned, id: id) { return hit } }
        return nil
    }

    func folders(in spaceID: String) -> [LibraryItem] {
        guard let s = spaces.first(where: { $0.id == spaceID }) else { return [] }
        return Self.allFolders(s.pinned)
    }

    func isOpen(_ folderID: String) -> Bool { openFolders.contains(folderID) }
    func toggleFolder(_ folderID: String) {
        if openFolders.contains(folderID) { openFolders.remove(folderID) } else { openFolders.insert(folderID) }
    }

    // MARK: Import

    /// Imports spaces, pinned tabs and folders from Arc's sidebar data. Spaces already linked to
    /// an Arc space get the missing items added; others are created. Returns Arc's favorites.
    @discardableResult
    func importFromArc(_ tree: ArcTree) -> [(title: String, url: String)] {
        // `path`: the folders on the way here. Arc's file is undocumented; a folder that lists
        // itself (or a parent) must not send this round in circles.
        func convert(_ id: String, path: Set<String> = []) -> LibraryItem? {
            guard let def = tree.items[id], !path.contains(id) else { return nil }
            switch def.kind {
            case .tab:
                return .site(def.customTitle ?? (def.savedTitle.isEmpty ? def.savedURL : def.savedTitle), def.savedURL, arcTabID: id)
            case .folder, .split:
                return LibraryItem(kind: .folder, title: def.customTitle ?? "Folder",
                                   children: def.children.compactMap { convert($0, path: path.union([id])) })
            }
        }
        var result = spaces
        for arc in tree.spaces {
            let items = arc.pinnedContainer.flatMap { tree.children(of: $0) }?.compactMap { convert($0) } ?? []
            if let i = result.firstIndex(where: { $0.arcSpaceID == arc.id }) {
                // Imported before: only what's new is added; folders merge into the one of the same name.
                var known = Set(Self.allSites(result[i].pinned).map(\.url))
                Self.merge(items, into: &result[i].pinned, known: &known)
            } else {
                var space = LibrarySpace(title: arc.title, colors: arc.colors, noise: arc.noise, arcSpaceID: arc.id, pinned: items)
                switch arc.icon {
                case .emoji(let e): space.emoji = e
                case .symbol(let s): space.symbol = s
                case nil: break
                }
                result.append(space)
            }
        }
        spaces = Self.withColors(result)
        if activeSpaceID == nil { activeSpaceID = spaces.first?.id }
        let favorites = tree.favoritesContainer(forProfile: nil).flatMap { tree.children(of: $0) } ?? []
        return favorites.compactMap { id in
            guard let def = tree.items[id], def.kind == .tab else { return nil }
            return (def.customTitle ?? def.savedTitle, def.savedURL)
        }
    }

    /// Imports a bookmark tree (from Chrome or Safari) into a new space.
    func importBookmarks(_ items: [LibraryItem], spaceTitle: String, emoji: String) {
        guard !items.isEmpty else { return }
        let space = addSpace(title: spaceTitle, emoji: emoji)
        updateSpace(space.id) { $0.pinned = items }
    }

    /// Adds `incoming` to `items`, skipping websites already there (`known` URLs) and merging
    /// folders into an existing folder with the same name.
    private static func merge(_ incoming: [LibraryItem], into items: inout [LibraryItem], known: inout Set<String>) {
        for item in incoming {
            switch item.kind {
            case .site, .app:
                guard !known.contains(item.url) else { continue }
                known.insert(item.url)
                items.append(item)
            case .folder:
                if let i = items.firstIndex(where: { $0.kind == .folder && $0.title == item.title }) {
                    merge(item.children, into: &items[i].children, known: &known)
                } else {
                    var folder = item
                    folder.children = []
                    merge(item.children, into: &folder.children, known: &known)
                    if !folder.children.isEmpty || item.children.isEmpty { items.append(folder) }
                }
            }
        }
    }

    // MARK: Display (library + live browser tabs)

    static let idPrefix = "lib:"

    static func libraryID(_ displayID: String) -> String? {
        displayID.hasPrefix(idPrefix) ? String(displayID.dropFirst(idPrefix.count)) : nil
    }

    static func display(_ item: LibraryItem) -> BrowserItem {
        BrowserItem(id: idPrefix + item.id, title: item.title, url: item.url,
                    kind: item.kind == .site ? .tab : item.kind == .app ? .app : .folder, children: item.children.map(display))
    }

    /// A space as shown: its pinned items from the library, and as "today" the live browser
    /// tabs of the linked browser space that aren't pinned here.
    func displaySpace(_ s: LibrarySpace, live: BrowserSnapshot) -> BrowserSpace {
        var space = BrowserSpace(id: s.id, title: s.title, icon: s.icon, colors: s.colors, noise: s.noise,
                                 areaChoice: s.area, accentChoice: s.accent)
        space.pinned = s.pinned.map(Self.display)
        let provider = browser?.provider
        let source: LiveSource = provider?.spacesAreLibrary == true ? .sameSpaces : provider?.hasSpaces == false ? .noSpaces : .linked
        // With browser syncing off, the sidebar shows only its own pins (no live tab list).
        space.unpinned = browser?.showsLiveTabs == false ? []
            : Self.todayTabs(for: s, live: live, source: source, activeSpaceID: activeSpaceID, favorites: favoriteURLs)
        return space
    }

    /// Websites on Favorites ("tab␟address␟title" pins): their open tab shows as the tile, not twice.
    private var favoriteURLs: [String] {
        (defaults.stringArray(forKey: "pinnedBundleIDs") ?? []).compactMap { pin in
            let parts = pin.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            return parts.count >= 2 && parts[0] == "tab" ? String(parts[1]) : nil
        }
    }

    /// The same page: same address, or same host and path (a different "?hl=DE" or "#…" doesn't count).
    static func samePage(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let ua = URL(string: a), let ub = URL(string: b), let host = ua.host else { return false }
        let trim = { (p: String) in p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p }
        return host == ub.host && trim(ua.path) == trim(ub.path)
    }

    /// How the browser's spaces relate to the sidebar's.
    enum LiveSource {
        /// The built-in browser: its spaces are the sidebar's own.
        case sameSpaces
        /// A browser without spaces (Chrome): its tabs show in the active space.
        case noSpaces
        /// Arc: each sidebar space shows the Arc space it's linked to (an unlinked one the active Arc space).
        case linked
    }

    /// The live tabs a sidebar space shows as "today": those of its browser space that aren't pinned in
    /// it or on Favorites already (those show as their pin, lit when open, never as a second row).
    static func todayTabs(for s: LibrarySpace, live: BrowserSnapshot, source: LiveSource, activeSpaceID: String?,
                          favorites: [String] = []) -> [BrowserItem] {
        let liveSpace: BrowserSpace?
        switch source {
        case .sameSpaces: liveSpace = live.spaces.first { $0.id == s.id }
        case .noSpaces: liveSpace = s.id == activeSpaceID ? live.activeSpace : nil
        case .linked:
            liveSpace = s.arcSpaceID.flatMap { id in live.spaces.first { $0.id == id } }
                ?? (s.arcSpaceID == nil ? live.activeSpace : nil)
        }
        let liveTabs = ((liveSpace?.pinned ?? []) + (liveSpace?.unpinned ?? [])).flatMap(\.allTabs)
        let sites = allSites(s.pinned)
        return liveTabs.filter { tab in
            !sites.contains { $0.arcTabID == tab.id || samePage($0.url, tab.url) } && !favorites.contains { samePage($0, tab.url) }
        }
    }

    /// Switches to the space linked to the browser's active space (when it changes there).
    func follow(arcSpaceID: String?) {
        guard browser?.provider.hasSpaces != false else { return }
        let linked = browser?.provider.spacesAreLibrary == true ? spaces.first { $0.id == arcSpaceID } : space(linkedTo: arcSpaceID)
        if let linked, linked.id != activeSpaceID { activeSpaceID = linked.id }
    }

    // MARK: Tree helpers

    static func contains(_ items: [LibraryItem], id: String) -> Bool { find(items, id: id) != nil }

    static func allApps(_ items: [LibraryItem]) -> [LibraryItem] {
        items.flatMap { $0.kind == .app ? [$0] : allApps($0.children) }
    }

    func containsApp(_ bundleID: String, inSpace spaceID: String) -> Bool {
        spaces.first { $0.id == spaceID }.map { Self.allApps($0.pinned).contains { $0.url == bundleID } } ?? false
    }

    func containsAppAnywhere(_ bundleID: String) -> Bool {
        spaces.contains { Self.allApps($0.pinned).contains { $0.url == bundleID } }
    }

    func removeApp(_ bundleID: String, fromSpace spaceID: String) {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return }
        for item in Self.allApps(space.pinned) where item.url == bundleID { remove(item.id) }
    }

    private static func insert(_ item: LibraryItem, before targetID: String, in items: inout [LibraryItem]) -> Bool {
        if let i = items.firstIndex(where: { $0.id == targetID }) { items.insert(item, at: i); return true }
        for i in items.indices where insert(item, before: targetID, in: &items[i].children) { return true }
        return false
    }

    /// Live reordering while dragging: within the same list it moves past the target
    /// (so items can reach the end), across lists it lands before the target.
    func moveLive(_ id: String, over targetID: String, space spaceID: String) {
        guard id != targetID else { return }
        var handled = false
        updateSpace(spaceID) { space in
            handled = Self.moveWithinList(&space.pinned, id: id, over: targetID)
        }
        if !handled { move(id, before: targetID, space: spaceID) }
    }

    private static func moveWithinList(_ items: inout [LibraryItem], id: String, over targetID: String) -> Bool {
        if let from = items.firstIndex(where: { $0.id == id }), let to = items.firstIndex(where: { $0.id == targetID }) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            return true
        }
        for i in items.indices where moveWithinList(&items[i].children, id: id, over: targetID) { return true }
        return false
    }

    static func allSites(_ items: [LibraryItem]) -> [LibraryItem] {
        items.flatMap { $0.kind == .site ? [$0] : allSites($0.children) }
    }

    private static func allFolders(_ items: [LibraryItem]) -> [LibraryItem] {
        items.flatMap { $0.kind == .folder ? [$0] + allFolders($0.children) : [] }
    }

    private static func find(_ items: [LibraryItem], id: String) -> LibraryItem? {
        for item in items {
            if item.id == id { return item }
            if let hit = find(item.children, id: id) { return hit }
        }
        return nil
    }

    private static func mutate(_ items: inout [LibraryItem], id: String, _ change: (inout LibraryItem) -> Void) {
        for i in items.indices {
            if items[i].id == id { change(&items[i]); return }
            mutate(&items[i].children, id: id, change)
        }
    }

    private static func removeItem(_ items: inout [LibraryItem], id: String) {
        items.removeAll { $0.id == id }
        for i in items.indices { removeItem(&items[i].children, id: id) }
    }

    private static func replaceItem(_ items: inout [LibraryItem], id: String, with replacement: (LibraryItem) -> [LibraryItem]) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            let r = replacement(items[i])
            items.replaceSubrange(i...i, with: r)
            return
        }
        for i in items.indices { replaceItem(&items[i].children, id: id, with: replacement) }
    }
}

// MARK: - Bookmark import

enum BookmarkImport {
    /// Chrome's bookmarks bar and "Other bookmarks" as folders.
    static func chrome() -> [LibraryItem]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Bookmarks")
        return (try? Data(contentsOf: url)).flatMap(chrome(data:))
    }

    static func chrome(data: Data) -> [LibraryItem]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { return nil }
        func convert(_ node: [String: Any]) -> LibraryItem? {
            let name = node["name"] as? String ?? ""
            if node["type"] as? String == "url" {
                return .site(name, node["url"] as? String ?? "")
            }
            let children = (node["children"] as? [[String: Any]] ?? []).compactMap(convert)
            return children.isEmpty ? nil : LibraryItem(kind: .folder, title: name, children: children)
        }
        return ["bookmark_bar", "other"].compactMap { (roots[$0] as? [String: Any]).flatMap(convert) }
    }

    /// Safari's bookmarks; needs Full Disk Access, otherwise nil.
    static func safari() -> [LibraryItem]? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist")
        return (try? Data(contentsOf: url)).flatMap(safari(data:))
    }

    static func safari(data: Data) -> [LibraryItem]? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        func convert(_ node: [String: Any]) -> LibraryItem? {
            switch node["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                return .site(title, node["URLString"] as? String ?? "")
            case "WebBookmarkTypeList":
                let title = node["Title"] as? String ?? ""
                if title == "com.apple.ReadingList" || title == "History" { return nil }
                let children = (node["Children"] as? [[String: Any]] ?? []).compactMap(convert)
                let display = title == "BookmarksBar" ? "Favorites Bar" : title == "BookmarksMenu" ? "Bookmarks Menu" : title
                return children.isEmpty ? nil : LibraryItem(kind: .folder, title: display, children: children)
            default:
                return nil
            }
        }
        return (root["Children"] as? [[String: Any]] ?? []).compactMap(convert)
    }
}
