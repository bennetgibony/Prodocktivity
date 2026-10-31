import AppKit
import SwiftUI

// Apps and websites of the same tool (an app and its website both in the bar).

/// The website twin of an app, if one is open/pinned in the browser.
/// Websites the sidebar shows right now: top pins, space pins and today's open tabs.
/// (Arc's own favorites and pins don't count; the sidebar is in charge.)
@MainActor func visibleWebsites(_ browser: BrowserModel) -> [BrowserItem] {
    // Every app tile asks on every redraw: worked out again only when what it's made of changed.
    let key = VisibleWebsitesCache.Key(snapshot: browser.snapshot, status: browser.status, spaces: browser.library?.spaces ?? [],
                                       pins: DuplicateActions.apps?.pinnedIDs ?? [], sync: browser.showsLiveTabs,
                                       activeSpace: browser.library?.activeSpaceID)
    if let cached = VisibleWebsitesCache.items, VisibleWebsitesCache.browser === browser, VisibleWebsitesCache.key == key { return cached }
    let items = collectVisibleWebsites(browser)
    VisibleWebsitesCache.items = items
    VisibleWebsitesCache.browser = browser
    VisibleWebsitesCache.key = key
    return items
}

@MainActor private enum VisibleWebsitesCache {
    struct Key: Equatable {
        let snapshot: BrowserSnapshot
        let status: BrowserModel.Status
        let spaces: [LibrarySpace]
        let pins: [String]
        let sync: Bool
        let activeSpace: String?
    }
    static var items: [BrowserItem]?
    static weak var browser: BrowserModel?
    static var key: Key?
}

@MainActor private func collectVisibleWebsites(_ browser: BrowserModel) -> [BrowserItem] {
    var items: [BrowserItem] = []
    for entry in DuplicateActions.apps?.pinnedEntries(favorites: browser.snapshot.favorites) ?? [] {
        switch entry {
        case .tab(let t): items.append(BrowserItem(id: t.id, title: t.title, url: t.url, kind: .tab))
        case .favorite(let f): items.append(f)
        case .app: break
        }
    }
    if let library = browser.library {
        for space in library.spaces {
            items += Library.allSites(space.pinned).map { BrowserItem(id: Library.idPrefix + $0.id, title: $0.title, url: $0.url, kind: .tab) }
        }
    }
    if browser.status == .ok {
        items += browser.displaySpaces.flatMap(\.unpinned).flatMap(\.allTabs) + browser.snapshot.otherTabs
    }
    return items
}

@MainActor func websiteTwin(of app: AppItem, in browser: BrowserModel) -> BrowserItem? {
    guard app.id != browser.provider.bundleID else { return nil }
    return visibleWebsites(browser).first {
        Duplicates.matches(appName: app.name, bundleID: app.id, url: $0.url)
            && !(DuplicateActions.apps?.isKeptDuplicate(app: app.id, url: $0.url) ?? false)
    }
}

/// The app twin of a website, among apps that are pinned or running.
@MainActor func appTwin(of url: String, in apps: AppsModel) -> AppItem? {
    let candidates = apps.pinnedEntries(favorites: []).compactMap { entry -> AppItem? in
        if case .app(let a) = entry { return a } else { return nil }
    } + apps.unpinnedRunningItems
    return candidates.first {
        Duplicates.matches(appName: $0.name, bundleID: $0.id, url: url) && !apps.isKeptDuplicate(app: $0.id, url: url)
    }
}

/// What to do with a duplicate pair (an app and a website of the same tool).
@MainActor enum DuplicateActions {
    static weak var apps: AppsModel?
    static weak var browser: BrowserModel?

    /// Keep the app; drop the website from the sidebar (favorite → removed in Arc,
    /// sidebar-only pin → unpinned, open tab → closed).
    static func keepApp(_ app: AppItem, dropping site: BrowserItem) {
        guard let apps, let browser else { return }
        let snap = browser.snapshot
        let todayTabs = (snap.spaces.flatMap(\.unpinned) + snap.otherTabs).flatMap(\.allTabs)
        if let libraryID = Library.libraryID(site.id) {
            // A website pinned in a space: remove it from the sidebar.
            browser.library?.remove(libraryID)
        } else if site.id.hasPrefix("tab\u{1F}") {
            apps.unpin(site.id)
        } else if snap.favorites.contains(where: { $0.id == site.id }) {
            browser.setFavorite(site, false) { _ in }
        } else if todayTabs.contains(where: { $0.id == site.id }) {
            browser.close(site)
        } else {
            // Pinned Arc tabs are never closed from here.
            browser.showHint("“\(site.title)” is pinned in Arc. Unpin it there if you don't need it.")
        }
        for raw in apps.pinnedIDs where raw.hasPrefix("tab\u{1F}\(site.url)\u{1F}") { apps.unpin(raw) }
    }

    /// Keep the website; take the app out of the sidebar (unpinned, out of spaces and the
    /// tab list). The app itself stays installed.
    static func keepWebsite(_ site: BrowserItem, dropping app: AppItem) {
        guard let apps, let browser else { return }
        apps.unpin(app.id)
        for space in browser.snapshot.spaces { apps.removeApp(app.id, fromSpace: space.id) }
        apps.setHiddenFromTabs(app.id, true)
        browser.showHint("\(app.name) is hidden from the bar. Settings → Bar & Docks brings it back.")
    }
}

/// Small "two copies" mark for tools you have both as an app and as a website.
struct DuplicateBadge: View {
    let other: String
    var body: some View {
        // A state ("you have this twice"), so the warning color with a symbol.
        Image(systemName: "square.on.square.fill")
            .font(.system(size: DS.Size.badge * DS.Size.badgeGlyph, weight: .bold))
            .foregroundStyle(Palette.onAccent)
            .frame(width: DS.Size.badge, height: DS.Size.badge)
            .background(Circle().fill(Palette.warning))
            .overlay(Circle().strokeBorder(Palette.surface, lineWidth: DS.Line.hairline))
            .help("Duplicate: also open as \(other)")
    }
}


/// Marks websites: a small globe on a soft chip that stays readable on any background.
struct WebBadge: View {
    var size: CGFloat = DS.Size.iconSmall

    var body: some View {
        Image(systemName: "globe")
            .font(.system(size: size * DS.Size.badgeGlyph, weight: .semibold))
            .foregroundStyle(Palette.text2)
            .frame(width: size, height: size)
            .background(Circle().fill(Palette.surface))
            .overlay(Circle().strokeBorder(Palette.border, lineWidth: DS.Line.hairline))
            .accessibilityLabel("Website")
    }
}
