import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The Pinwall: the grid of pinned apps and websites at the top of the bar, the same in every workspace.

struct PinnedAppsGrid: View {
    @ObservedObject var apps: AppsModel
    @ObservedObject var browser: BrowserModel
    @ObservedObject private var design = Settings.shared
    @ObservedObject private var badges = Badges.shared

    private var tile: CGFloat { CGFloat(design.tileSize) }
    private var iconSize: CGFloat { (tile * DS.Size.tileIconRatio).rounded() }
    /// As many columns as fit the bar's width at the chosen tile size, and at least three down to 170 pt.
    private var columns: [GridItem] {
        let count = min(6, max(design.sidebarWidth >= 170 ? 3 : 2,
                               Int((design.sidebarWidth - DS.Size.hitTarget) / (design.tileSize + DS.Space.xl))))
        return Array(repeating: GridItem(.flexible(), spacing: DS.Space.s), count: count)
    }

    /// A count in the title of the open tab for `url` (e.g. Gmail's "(3)").
    private func siteCount(url: String) -> String? {
        let host = URL(string: url)?.host
        let tab = browser.snapshot.spaces.flatMap(\.unpinned).first { $0.url == url || ($0.host != nil && $0.host == host) }
        return tab.flatMap { Badges.count(inTitle: $0.title) }
    }

    /// The chosen icon from the set, if any, else the original.
    @ViewBuilder private func pinIcon<Original: View>(_ id: String, @ViewBuilder original: () -> Original) -> some View {
        if let icon = SuiteIcon.find(apps.pinIcons[id]) {
            SuiteIconView(icon: icon, size: iconSize)
        } else {
            original()
        }
    }

    var body: some View {
        let entries = apps.pinnedEntries(favorites: browser.status == .ok ? browser.snapshot.favorites : [])
        Group {
            if entries.isEmpty {
                Text("Drag apps or websites here")
                    .textRole(.footnote)
                    .foregroundStyle(Palette.text2)
                    .frame(maxWidth: .infinity, minHeight: tile)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: DS.Line.outline, dash: DS.Line.dash))
                            .foregroundStyle(Palette.border)
                    )
            } else {
                LazyVGrid(columns: columns, spacing: DS.Space.s) {
                    ForEach(entries) { entry in
                        tile(for: entry)
                            .onDrag {
                                apps.draggingID = entry.id
                                TabDrag.clearSidebarDrag()
                                return NSItemProvider(object: entry.id as NSString)
                            }
                            .onDrop(of: [.plainText], delegate: PinDropDelegate(target: entry.id, apps: apps, browser: browser))
                    }
                }
            }
        }
        .onDrop(of: [.plainText], delegate: PinDropDelegate(target: nil, apps: apps, browser: browser))
    }

    @ViewBuilder private func tile(for entry: PinnedEntry) -> some View {
        switch entry {
        case .app(let item):
            Tile(selected: apps.frontmostID == item.id, height: tile) {
                pinIcon(item.id) {
                    Image(nsImage: item.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: iconSize, height: iconSize)
                }
                .notificationDot(badges.apps[item.id], size: iconSize)
                .saturation(item.isRunning ? 1 : DS.Opacity.inactive)
                .opacity(item.isRunning ? 1 : DS.Opacity.notRunning)
            }
            .overlay(alignment: .bottom) {
                if item.isRunning && apps.frontmostID != item.id {
                    // Running, like the Dock: a short line under the icon.
                    Capsule().fill(Palette.text3).frame(width: DS.Size.dot, height: DS.Size.runningLine).padding(.bottom, DS.Space.xs)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let twin = websiteTwin(of: item, in: browser) { DuplicateBadge(other: "website “\(twin.title)”").padding(DS.Space.xs) }
            }
            .overlay(alignment: .bottomTrailing) {
                if apps.openAsWebsite[item.id] != nil { WebBadge(size: DS.Size.badge).padding(DS.Space.xs).help("Opens as a website") }
            }
            .help("\(item.name) — ⌥-click for split screen")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { apps.open(item.id, split: false) }
            .onTapGesture { apps.open(item.id, split: optionHeld) }
            .contextMenu {
                Button("Open in Split Screen") { apps.open(item.id, split: true) }
                Button("Change Icon…") { SidebarActions.chooseIcon?(item.id, item.name) }
                Button("Unpin") { apps.unpin(item.id) }
                SpaceAppMenuItems(appID: item.id, apps: apps, browser: browser)
                OpenAsWebsiteToggle(app: item, apps: apps, browser: browser)
                WindowRuleMenu(appID: item.id)
                FreezeMenu(subject: .app(item.id))
                if let twin = websiteTwin(of: item, in: browser) { DuplicateMenu(app: item, site: twin, apps: apps, onApp: true) }
                if item.isRunning {
                    Button("Hide") { apps.hide(item.id) }
                    Button("Quit \(item.name)") { apps.quit(item.id) }
                }
                Divider()
                Button("Show in Finder") { apps.revealInFinder(item.id) }
            }
        case .favorite(let fav):
            let selected = apps.frontmostID == browser.provider.bundleID && browser.snapshot.activeTabID == fav.id
            Tile(selected: selected, height: tile) {
                pinIcon(entry.id) { FaviconView(url: fav.url).frame(width: iconSize * DS.Size.faviconRatio, height: iconSize * DS.Size.faviconRatio) }
                    .overlay(alignment: .bottomTrailing) { WebBadge(size: DS.Size.badge).offset(x: DS.Space.s, y: DS.Space.xs) }
            }
            .overlay(alignment: .topTrailing) {
                if let twin = appTwin(of: fav.url, in: apps) { DuplicateBadge(other: "app “\(twin.name)”").padding(DS.Space.xs) }
            }
            .help("\(fav.title) — Arc favorite. ⌥-click for split screen")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(fav.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { browser.select(fav, spaceID: nil, split: false) }
            .onTapGesture { browser.select(fav, spaceID: nil, split: optionHeld) }
            .contextMenu {
                Button("Open in Split Screen") { browser.select(fav, spaceID: nil, split: true) }
                Button("Copy Link") { copyToPasteboard(fav.url) }
                Button("Change Icon…") { SidebarActions.chooseIcon?(entry.id, fav.title) }
                Button("Remove from Arc Favorites") { browser.setFavorite(fav, false) { _ in } }
                if let twin = appTwin(of: fav.url, in: apps) { DuplicateMenu(app: twin, site: fav, apps: apps, onApp: false) }
            }
        case .tab(let tab):
            let selected = apps.frontmostID == browser.provider.bundleID && browser.isActive(url: tab.url)
            Tile(selected: selected, height: tile) {
                pinIcon(entry.id) { FaviconView(url: tab.url).frame(width: iconSize * DS.Size.faviconRatio, height: iconSize * DS.Size.faviconRatio) }
                    .overlay(alignment: .bottomTrailing) { WebBadge(size: DS.Size.badge).offset(x: DS.Space.s, y: DS.Space.xs) }
                    .notificationDot(siteCount(url: tab.url), size: iconSize)
            }
            .help("\(tab.title) — ⌥-click for split screen")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { browser.openPinned(url: tab.url, split: false) }
            .onTapGesture { browser.openPinned(url: tab.url, split: optionHeld) }
            .contextMenu {
                Button("Open in Split Screen") { browser.openPinned(url: tab.url, split: true) }
                Button("Copy Link") { copyToPasteboard(tab.url) }
                Button("Change Icon…") { SidebarActions.chooseIcon?(tab.id, tab.title) }
                Button("Unpin") { apps.unpin(tab.id) }
                if browser.provider.isBuiltIn {
                    FreezeMenu(subject: .site(tabID: nil, open: { browser.openPinned(url: tab.url) }))
                }
            }
        }
    }
}

@MainActor func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

/// A Favorites tile (pinned apps and websites): the icon on a square in the space's accent; the one
/// open right now a bit stronger and outlined.
struct Tile<Content: View>: View {
    let selected: Bool
    let height: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var hovering = false
    @Environment(\.dsAccent) private var accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
        content()
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background {
                if selected {
                    shape.fill(accent.color.opacity(DS.Opacity.accentSelected))
                        .overlay(shape.strokeBorder(accent.color, lineWidth: DS.Line.outline))
                } else {
                    shape.fill(accent.color.opacity(hovering ? DS.Opacity.accentTileHover : DS.Opacity.accentTile))
                }
            }
            .contentShape(shape)
            .onHover { h in DS.Motion.perform(DS.Motion.quick) { hovering = h } }
            .dsAnimation(DS.Motion.quick, value: selected)
    }
}

/// Reorders pins while dragging; drops of unpinned apps add a new pin.
struct PinDropDelegate: DropDelegate {
    let target: String?
    let apps: AppsModel
    let browser: BrowserModel

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let dragging = apps.draggingID, let target, apps.isPinned(dragging) else { return }
            apps.movePin(dragging, to: target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            defer { apps.draggingID = nil; TabDrag.current = nil; TabDrag.currentItem = nil }
            if let dragging = apps.draggingID ?? TabDrag.current {
                if !apps.isPinned(dragging) { apps.pin(dragging, before: target) }
                // A dropped website also becomes an Arc favorite (then replaces this pin in place).
                if let tab = TabDrag.currentItem { browser.setFavorite(tab, true) { _ in } }
                return true
            }
            return false
        }
    }
}
