import AppKit
import Carbon

/// Arc via its AppleScript dictionary, plus Arc's local sidebar file for structure
/// (folders, spaces, icons, colors) that AppleScript doesn't expose.
/// All methods block and must run off the main thread (BrowserModel serializes them).
final class ArcProvider: BrowserProvider, @unchecked Sendable {
    let displayName = "Arc"
    let bundleID = "company.thebrowser.Browser"

    private let sidebarFile = ArcSidebarFile()

    // Compiled once and reused (compiling is a large part of each AppleScript call).
    private var fastScript: NSAppleScript?
    private var fullScript: NSAppleScript?
    private var handlerScript: NSAppleScript?
    /// tab id → space id, from the slower full fetch (refreshed every 10 s).
    private var tabSpaces: [String: String] = [:]
    /// Tabs Arc last reported as open (all spaces after a full fetch).
    private var openTabs = Set<String>()
    private var lastFullFetch = Date.distantPast
    /// Seconds between the slower full fetches (which place tabs into spaces).
    var fullFetchInterval: TimeInterval = 10

    private struct LiveTab {
        let id, title, url, location: String
    }

    func fetch() throws -> BrowserSnapshot {
        guard runningApp != nil else { throw BrowserError.notRunning }
        let tree = sidebarFile.load()
        // The fast fetch reads only the front window; the full one (spaces and their tabs)
        // is needed without Arc's sidebar file, and occasionally to place new tabs in spaces.
        let full = tree == nil || fullFetchDue
        let raw = full ? try run(compiled(&fullScript, ArcScripts.fetch)) : try run(compiled(&fastScript, ArcScripts.fastFetch))
        if full { lastFullFetch = Date() }
        return snapshot(from: raw, tree: tree, full: full)
    }

    /// Whether the next fetch reads every space (a full fetch is due or was asked for).
    var fullFetchDue: Bool { Date().timeIntervalSince(lastFullFetch) > fullFetchInterval }

    /// Turns the script's answer (records split by \u{1E}, fields by \u{1F}) and Arc's sidebar
    /// file into a snapshot, and updates what's remembered between fetches.
    func snapshot(from raw: String, tree: ArcTree?, full: Bool) -> BrowserSnapshot {
        var activeTab: String?, activeSpace: String?
        var live: [String: LiveTab] = [:]
        var liveOrder: [String] = []
        var scriptedSpaces: [(id: String, title: String, tabs: [LiveTab])] = []

        for record in raw.split(separator: "\u{1E}", omittingEmptySubsequences: true) {
            let f = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "A" where f.count >= 3:
                activeTab = f[1].isEmpty ? nil : f[1]
                activeSpace = f[2].isEmpty ? nil : f[2]
            case "S" where f.count >= 3:
                scriptedSpaces.append((f[1], f[2], []))
            case "T" where f.count >= 5 && !scriptedSpaces.isEmpty:
                let t = LiveTab(id: f[1], title: f[2], url: f[3], location: f[4])
                scriptedSpaces[scriptedSpaces.count - 1].tabs.append(t)
                if live[t.id] == nil { live[t.id] = t; liveOrder.append(t.id) }
            case "W" where f.count >= 5:
                let t = LiveTab(id: f[1], title: f[2], url: f[3], location: f[4])
                if live[t.id] == nil { live[t.id] = t; liveOrder.append(t.id) }
            default:
                continue
            }
        }

        // Which open tabs Arc reported: every space on a full fetch, the front window otherwise.
        if full { openTabs = Set(live.keys) } else { openTabs.formUnion(live.keys) }
        let frontWindowIDs = Set(live.keys)

        if full {
            // Arc's own space lists sometimes miss tabs: keep earlier placements for those,
            // let Arc's answer win where it has one, and forget tabs that are gone.
            var map = tabSpaces.filter { live[$0.key] != nil }
            for s in scriptedSpaces { for t in s.tabs { map[t.id] = s.id } }
            tabSpaces = map
        }

        var snap = BrowserSnapshot(activeTabID: activeTab, activeSpaceID: activeSpace)
        guard let tree else {
            // Fallback without Arc's sidebar file: flat lists straight from AppleScript.
            var seen = Set<String>()
            for s in scriptedSpaces {
                var space = BrowserSpace(id: s.id, title: s.title)
                for t in s.tabs where seen.insert(t.id).inserted {
                    let item = BrowserItem(id: t.id, title: t.title, url: t.url, kind: .tab)
                    switch t.location {
                    case "topApp": snap.favorites.append(item)
                    case "pinned": space.pinned.append(item)
                    default: space.unpinned.append(item)
                    }
                }
                snap.spaces.append(space)
            }
            for id in liveOrder where seen.insert(id).inserted {
                let t = live[id]!
                let item = BrowserItem(id: t.id, title: t.title, url: t.url, kind: .tab)
                if t.location == "topApp" { snap.favorites.append(item) } else { snap.otherTabs.append(item) }
            }
            return snap
        }

        var placed = Set<String>()
        func build(_ id: String) -> BrowserItem? {
            guard let def = tree.items[id] else { return nil }
            switch def.kind {
            case .tab:
                placed.insert(id)
                let l = live[id]
                let title = nonEmpty(def.customTitle) ?? nonEmpty(l?.title) ?? def.savedTitle
                return BrowserItem(id: id, title: title, url: nonEmpty(l?.url) ?? def.savedURL, kind: .tab)
            case .folder, .split:
                let children = def.children.compactMap(build)
                if def.kind == .split {
                    let title = children.map(\.title).joined(separator: " | ")
                    return BrowserItem(id: id, title: title, url: children.first?.url ?? "", kind: .split, children: children)
                }
                return BrowserItem(id: id, title: def.customTitle ?? "Folder", url: "", kind: .folder, children: children)
            }
        }

        snap.favorites = tree.favoritesContainer(forProfile: tree.spaces.first(where: { $0.id == activeSpace })?.profileKey)
            .flatMap { tree.children(of: $0) }?.compactMap(build) ?? []

        for def in tree.spaces {
            var space = BrowserSpace(id: def.id, title: def.title, icon: def.icon, colors: def.colors, noise: def.noise)
            space.pinned = def.pinnedContainer.flatMap { tree.children(of: $0) }?.compactMap(build) ?? []
            space.unpinned = def.unpinnedContainer.flatMap { tree.children(of: $0) }?.compactMap(build) ?? []
            snap.spaces.append(space)
        }
        // Arc rewrites its sidebar file only now and then, so it can still list tabs that were
        // closed a while ago. An unpinned tab that Arc no longer reports as open is gone.
        // (Tabs of the active space are in every fetch; other spaces only in full ones.)
        let closed = placedUnpinned(snap).filter { id in
            full || snap.activeSpaceID == tabSpaceInTree(id, snap) ? !frontWindowIDs.contains(id) : !openTabs.contains(id)
        }
        if !closed.isEmpty { snap.removeTabs(closed) }

        // Open tabs Arc hasn't written to its sidebar file yet (usually new "Today" tabs).
        for id in liveOrder where !placed.contains(id) {
            let t = live[id]!
            let item = BrowserItem(id: t.id, title: t.title, url: t.url, kind: .tab)
            if t.location == "topApp" { snap.favorites.append(item); continue }
            if tabSpaces[id] == nil, let active = activeSpace {
                // New tab we haven't placed yet: it was almost certainly opened in the space
                // that's active right now. The next full fetch (requested below) confirms it.
                tabSpaces[id] = active
                lastFullFetch = .distantPast
            }
            if let spaceID = tabSpaces[id], let i = snap.spaces.firstIndex(where: { $0.id == spaceID }) {
                snap.spaces[i].unpinned.insert(item, at: 0)
            } else {
                snap.otherTabs.append(item)
            }
        }
        return snap
    }

    /// Ids of unpinned tabs in the snapshot.
    private func placedUnpinned(_ snap: BrowserSnapshot) -> Set<String> {
        Set(snap.spaces.flatMap { $0.unpinned.flatMap(\.allTabs) }.map(\.id))
    }

    private func tabSpaceInTree(_ id: String, _ snap: BrowserSnapshot) -> String? {
        snap.spaces.first { $0.unpinned.contains { $0.allTabs.contains { $0.id == id } } }?.id
    }

    func select(_ tab: BrowserItem, spaceID: String?) throws {
        try call("selecttab", tab.id, spaceID ?? "", tab.url)
    }

    func close(_ tab: BrowserItem) throws {
        try call("closetab", tab.id)
    }

    func open(url: String) throws {
        try call("openurl", url)
    }

    func makeTab(url: String) throws -> String {
        try call("maketab", url)
    }

    func load(url: String) throws {
        try call("seturl", url)
    }

    func navigate(_ action: NavigationAction) throws {
        try call("navigate", action.rawValue)
    }

    func focus(spaceID: String) throws {
        try call("focusspace", spaceID)
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private func compiled(_ cache: inout NSAppleScript?, _ source: String) throws -> NSAppleScript {
        if let cache { return cache }
        guard let script = NSAppleScript(source: source) else { throw BrowserError.script("Couldn't build script") }
        var error: NSDictionary?
        script.compileAndReturnError(&error)
        if let error { throw BrowserError.script(error[NSAppleScript.errorMessage] as? String ?? "Compile error") }
        cache = script
        return script
    }

    /// Calls a handler of the compiled handler script with string arguments.
    @discardableResult
    private func call(_ handler: String, _ args: String...) throws -> String {
        let script = try compiled(&handlerScript, ArcScripts.handlers)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        let list = NSAppleEventDescriptor.list()
        for (i, a) in args.enumerated() { list.insert(NSAppleEventDescriptor(string: a), at: i + 1) }
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        try check(error)
        return result.stringValue ?? ""
    }

    @discardableResult
    private func run(_ script: NSAppleScript) throws -> String {
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        try check(error)
        return result.stringValue ?? ""
    }

    private func check(_ error: NSDictionary?) throws {
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            switch code {
            case -1743, -1744: throw BrowserError.notAuthorized
            case -600, -609: throw BrowserError.notRunning
            case -1712: throw BrowserError.script("Arc isn't responding.")
            default:
                throw BrowserError.script(error[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(code)")
            }
        }
    }
}
