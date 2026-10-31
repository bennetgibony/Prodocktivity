import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The current space: its pins, folders, apps and open tabs, plus split views.

struct AppsSection: View {
    @ObservedObject var apps: AppsModel
    @ObservedObject var browser: BrowserModel
    @ObservedObject private var badges = Badges.shared

    var body: some View {
        let items = apps.unpinnedRunningItems
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            SectionHeader(title: "Apps")
            ForEach(items) { item in
                SidebarRow(
                    title: item.name,
                    isSelected: apps.frontmostID == item.id,
                    closeHelp: "Quit \(item.name)",
                    icon: { Image(nsImage: item.icon).resizable().interpolation(.high).notificationDot(badges.apps[item.id]) },
                    onTap: { apps.open(item.id, split: optionHeld) },
                    onClose: { apps.quit(item.id) }
                )
                .onDrag {
                    apps.draggingID = item.id
                    TabDrag.clearSidebarDrag()
                    return NSItemProvider(object: item.id as NSString)
                }
                .contextMenu {
                    Button("Open in Split Screen") { apps.open(item.id, split: true) }
                    Button("Pin to Sidebar") { apps.pin(item.id) }
                    SpaceAppMenuItems(appID: item.id, apps: apps, browser: browser)
                    MoveToSpaceMenu(subject: .app(item.id, from: nil), current: nil, browser: browser, apps: apps)
                    WindowRuleMenu(appID: item.id)
                    FreezeMenu(subject: .app(item.id))
                    Button("Hide") { apps.hide(item.id) }
                    Button("Quit \(item.name)") { apps.quit(item.id) }
                }
            }
            if items.isEmpty {
                Text("No other apps running")
                    .textRole(.footnote)
                    .foregroundStyle(Palette.text2)
                    .padding(.horizontal, DS.Space.rowInset)
            }
        }
    }
}

struct BrowserSection: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var apps: AppsModel
    @ObservedObject var perms: PermissionsModel
    var mode: SpaceContent.Mode = .all

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            statusNotice
            // Sidebar-first: the space and its pins show even when the browser is closed.
            if let space = browser.activeSpace, browser.status == .ok || browser.library?.spaces.isEmpty == false {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    SpaceContent(space: space, browser: browser, apps: apps, mode: mode)
                        .id(space.id)
                        // Switching spaces (click or two-finger swipe): the new space slides in
                        // from the side it lies on in the switcher and pushes the old one out.
                        .transition(.spaceSlide(browser.spaceSlide))
                }
                .clipped()
                .dsAnimation(DS.Motion.slide, value: space.id)
            }
        }
    }

    @ViewBuilder private var statusNotice: some View {
        switch browser.status {
        case .idle:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(DS.Space.s)
        case .notRunning:
            SidebarRow(
                title: "Open \(browser.provider.displayName)",
                dimmed: true,
                icon: { Image(systemName: "arrow.up.forward.app").resizable() },
                onTap: { browser.launchBrowser() }
            )
        case .notAuthorized:
            PermissionCard(
                symbol: "lock.shield",
                title: "Allow access to \(browser.provider.displayName)",
                message: "To open and sync tabs, turn on \(browser.provider.displayName) for proDOCKtivity under Privacy & Security → Automation.",
                buttonTitle: "Open Automation Settings…",
                action: perms.openAutomationSettings
            )
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .textRole(.footnote)
                .foregroundStyle(Palette.danger)
                .padding(.horizontal, DS.Space.rowInset)
        case .ok:
            EmptyView()
        }
    }
}

/// One Arc space: title, pinned tabs and folders, divider, "+ New Tab", today's tabs.
struct SpaceContent: View {
    /// Everything, or (with the website dock) only the apps here and only the websites there.
    enum Mode { case all, apps, websites }

    let space: BrowserSpace
    @ObservedObject var browser: BrowserModel
    @ObservedObject var apps: AppsModel
    var mode: Mode = .all
    @ObservedObject private var settings = Settings.shared
    @Namespace private var selection

    /// What is selected right now (the pill glides when this changes).
    private var selectionKey: String { (apps.frontmostID ?? "") + "|" + (browser.snapshot.activeTabID ?? "") }

    private var pinned: [BrowserItem] {
        switch mode {
        case .all: return space.pinned
        case .apps: return space.pinned.filter { $0.kind == .app }
        case .websites: return space.pinned.filter { $0.kind != .app }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(spacing: DS.Space.s) {
                SpaceIconView(space: space, size: DS.Size.icon)
                    .frame(width: settings.rowIcon)
                Text(space.title.isEmpty ? "Workspace" : space.title)
                    .textRole(.headline)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if browser.library?.spaces.contains(where: { $0.id == space.id }) == true {
                    IconButton(symbol: "folder.badge.plus", help: "New folder in this workspace", small: true, tint: space.accent.color) { SidebarActions.newFolder?(space.id) }
                }
            }
            .padding(.leading, DS.Space.rowInset)
            .padding(.trailing, DS.Space.xxs)
            .frame(minHeight: settings.rowHeight)
            .contentShape(Rectangle())
            .contextMenu { SpaceMenuItems(spaceID: space.id, browser: browser) }

            if settings.editingColorSpace == space.id {
                SpaceColorEditor(space: space, library: browser.library, settings: settings)
                    .transition(.appear)
            }
            if settings.editingIconSpace == space.id, let library = browser.library,
               let saved = library.spaces.first(where: { $0.id == space.id }) {
                SpaceIconPicker(current: saved.iconChoice) { choice in
                    library.updateSpace(space.id) { $0.setIcon(choice) }
                } done: {
                    DS.Motion.perform { settings.editingIconSpace = nil }
                }
                .card(padding: DS.Space.m)
                .padding(.bottom, DS.Space.xs)
                .transition(.appear)
            }

            ForEach(pinned) { item in
                ItemRow(item: item, depth: 0, spaceID: space.id, closable: false, browser: browser, apps: apps)
                    .transition(.row)
            }

            BarDivider()

            if mode != .apps { NewTabRow(browser: browser) }

            // The Open area: open apps, then open tabs. Labelled as two groups, or one list when open
            // apps belong to the workspace they were opened in.
            let merged = settings.openAppsPerWorkspace
            let todayApps = mode == .websites ? [] : apps.openApps(inSpace: space.id, perWorkspace: merged)
                .filter { $0.id != browser.provider.bundleID }
            if !todayApps.isEmpty {
                if !merged { KindLabel(kind: .apps) }
                ForEach(todayApps) { item in
                    AppTabRow(item: item, apps: apps, browser: browser, spaceID: nil)
                        .transition(.row)
                }
                if !merged, !space.unpinned.isEmpty, mode == .all { KindLabel(kind: .tabs).padding(.top, DS.Space.s) }
            }

            ForEach(mode == .apps ? [] : space.unpinned) { item in
                ItemRow(item: item, depth: 0, spaceID: space.id, closable: true, browser: browser, apps: apps)
                    .transition(.row)
            }

            if mode != .apps, !browser.snapshot.otherTabs.isEmpty, Settings.shared.arcSync != .off {
                SectionHeader(title: "Other open tabs").padding(.top, DS.Space.m)
                ForEach(browser.snapshot.otherTabs) { item in
                    ItemRow(item: item, depth: 0, spaceID: nil, closable: true, browser: browser, apps: apps)
                        .transition(.row)
                }
            }
        }
        .environment(\.selectionNamespace, selection)
        .dsAnimation(DS.Motion.standard, value: selectionKey)
        .dsAnimation(DS.Motion.standard, value: space.unpinned.map(\.id))
        .dsAnimation(DS.Motion.standard, value: pinned.map(\.id))
    }
}

/// A tab, folder (expandable) or split view, indented by depth.
struct ItemRow: View {
    let item: BrowserItem
    let depth: Int
    let spaceID: String?
    let closable: Bool
    @ObservedObject var browser: BrowserModel
    // Observed, so the selection and outline follow which app is in front.
    @ObservedObject var apps: AppsModel

    private var arcInFront: Bool { apps.frontmostID == browser.provider.bundleID }
    private var isLibrary: Bool { Library.libraryID(item.id) != nil }
    @ObservedObject private var dragState = DragState.shared
    @ObservedObject private var freeze = Freeze.shared
    @ObservedObject private var badges = Badges.shared
    @Environment(\.dsAccent) private var accent

    /// The page's current title (sidebar pins keep their own name).
    private var liveTitle: String? {
        guard let id = liveTabID else { return item.title }
        return browser.snapshot.tab(id: id)?.title ?? item.title
    }

    /// The built-in browser tab this row stands for (a sidebar pin remembers its tab).
    private var liveTabID: String? {
        guard let id = Library.libraryID(item.id) else { return item.id }
        return browser.library?.find(id)?.arcTabID
    }

    private func open(split: Bool) {
        if isLibrary { browser.openSite(item, split: split) } else { browser.select(item, spaceID: nil, split: split) }
    }

    /// Keeps a live tab as a sidebar pin in the space being shown.
    private func pinHere() {
        guard let library = browser.library, let spaceID = library.activeSpace?.id else { return }
        library.add(.site(item.title, item.url, arcTabID: item.id), toSpace: spaceID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            switch item.kind {
            case .tab:
                let current = isLibrary ? browser.isActiveSite(item) : browser.snapshot.activeTabID == item.id
                SidebarRow(
                    title: item.title,
                    isSelected: current && arcInFront,
                    isRecent: current && !arcInFront,
                    icon: {
                        Group {
                            if let custom = SuiteIcon.find(apps.pinIcons[item.id]) {
                                SuiteIconView(icon: custom, size: Settings.shared.rowIcon)
                            } else if item.isIncognito {
                                Image(systemName: "theatermasks.fill").textRole(.footnote)
                            } else {
                                FaviconView(url: item.url)
                            }
                        }
                            .overlay(alignment: .bottomTrailing) { WebBadge(size: DS.Size.badgeSmall).offset(x: DS.Space.xs, y: DS.Space.xs) }
                            .notificationDot(liveTitle.flatMap(Badges.count(inTitle:)))
                            .overlay(alignment: .topTrailing) {
                                if let twin = appTwin(of: item.url, in: apps) {
                                    DuplicateBadge(other: "app “\(twin.name)”").offset(x: DS.Space.xs, y: -DS.Space.xs)
                                }
                            }
                    },
                    onTap: { open(split: optionHeld) },
                    onClose: closable ? { DS.Motion.perform(DS.Motion.standard) { browser.close(item) } } : nil
                )
                .onDrag({
                    let raw = AppsModel.tabPinID(url: item.url, title: item.title)
                    TabDrag.current = raw
                    TabDrag.currentItem = item
                    TabDrag.libraryItem = isLibrary ? Library.libraryID(item.id) : nil
                    return NSItemProvider(object: raw as NSString)
                }, preview: { DragPreview(title: item.title, favicon: item.host) })
                .onDrop(of: [.plainText], delegate: LibraryDropDelegate(targetID: Library.libraryID(item.id), intoFolder: false, library: browser.library))
                .contextMenu {
                    Button("Open in Split Screen") { open(split: true) }
                    Button("Pin to Top") { TabDrag.pin?(item) }
                    if isLibrary {
                        Button("Change Icon…") { SidebarActions.chooseIcon?(item.id, item.title) }
                        LibraryItemMenu(item: item, library: browser.library)
                    } else {
                        Button("Pin in This Workspace") { pinHere() }
                        MoveToSpaceMenu(subject: .tab(item), current: browser.library?.activeSpaceID, browser: browser, apps: apps)
                    }
                    Button("Copy Link") { copyToPasteboard(item.url) }
                    if browser.provider.isBuiltIn {
                        FreezeMenu(subject: .site(tabID: liveTabID, open: { open(split: false) }))
                    }
                    if let twin = appTwin(of: item.url, in: apps) { DuplicateMenu(app: twin, site: item, apps: apps, onApp: false) }
                }
                .overlay(alignment: .trailing) { if freeze.isFrozen(tab: liveTabID) { FrozenBadge().padding(.trailing, DS.Space.s) } }
                .help(item.url)
            case .app:
                if let app = apps.appItem(for: item.url) {
                    SidebarRow(
                        title: app.name,
                        isSelected: apps.frontmostID == app.id,
                            dimmed: !app.isRunning,
                        closeHelp: "Quit \(app.name)",
                        icon: {
                            Group {
                                if let custom = SuiteIcon.find(apps.pinIcons[item.id]) {
                                    SuiteIconView(icon: custom, size: Settings.shared.rowIcon)
                                } else {
                                    Image(nsImage: app.icon).resizable().interpolation(.high)
                                }
                            }
                            .notificationDot(badges.apps[app.id])
                        },
                        onTap: { apps.open(app.id, split: optionHeld) },
                        onClose: app.isRunning ? { apps.quit(app.id) } : nil
                    )
                    .help("\(app.name) — app. ⌥-click for split screen")
                    .onDrag({
                        TabDrag.libraryItem = Library.libraryID(item.id)
                        TabDrag.currentItem = nil
                        apps.draggingID = nil
                        return NSItemProvider(object: item.id as NSString)
                    }, preview: { DragPreview(title: app.name, icon: Image(nsImage: app.icon)) })
                    .onDrop(of: [.plainText], delegate: LibraryDropDelegate(targetID: Library.libraryID(item.id), intoFolder: false, library: browser.library))
                    .contextMenu {
                        Button("Open in Split Screen") { apps.open(app.id, split: true) }
                        Button("Pin to Top") { apps.pin(app.id) }
                        Button("Change Icon…") { SidebarActions.chooseIcon?(item.id, app.name) }
                        LibraryItemMenu(item: item, library: browser.library)
                        WindowRuleMenu(appID: app.id)
                        FreezeMenu(subject: .app(app.id))
                        if app.isRunning {
                            Divider()
                            Button("Hide") { apps.hide(app.id) }
                            Button("Quit \(app.name)") { apps.quit(app.id) }
                        }
                    }
                    .overlay(alignment: .trailing) { if freeze.isFrozen(app: app.id) { FrozenBadge().padding(.trailing, DS.Space.s) } }
                }
            case .split:
                let selected = arcInFront && item.children.contains { $0.id == browser.snapshot.activeTabID }
                SidebarRow(
                    title: item.title,
                    isSelected: selected,
                    icon: { Image(systemName: "rectangle.split.2x1").resizable().scaledToFit() },
                    onTap: {
                        if let first = item.children.first { browser.select(first, spaceID: spaceID, split: optionHeld) }
                    }
                )
            case .folder:
                let expanded = browser.isOpen(item)
                SidebarRow(
                    title: item.title,
                    icon: {
                        // Workbench folders in the workspace's accent.
                        Image(systemName: expanded ? "folder" : "folder.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(accent.color)
                    },
                    onTap: { DS.Motion.perform(DS.Motion.standard) { browser.toggle(item) } }
                )
                .onDrag({
                    TabDrag.libraryItem = Library.libraryID(item.id)
                    TabDrag.currentItem = nil
                    return NSItemProvider(object: item.id as NSString)
                }, preview: { DragPreview(title: item.title, icon: Image(systemName: "folder.fill")) })
                .overlay {
                    // A drop target: the accent's soft fill and a 2 pt accent outline.
                    if dragState.folderTarget == Library.libraryID(item.id) {
                        DropTargetHighlight()
                    }
                }
                .onDrop(of: [.plainText], delegate: LibraryDropDelegate(targetID: Library.libraryID(item.id), intoFolder: true, library: browser.library))
                .contextMenu {
                    if isLibrary { LibraryItemMenu(item: item, library: browser.library) }
                }
                if expanded {
                    ForEach(item.children) { child in
                        ItemRow(item: child, depth: depth + 1, spaceID: spaceID, closable: false, browser: browser, apps: apps)
                    }
                    .transition(.appear)
                }
            }
        }
        .padding(.leading, depth > 0 ? DS.Space.l : 0)
    }
}

struct SpaceIconView: View {
    let space: BrowserSpace
    let size: CGFloat
    /// Only the open space is shown in color.
    var colored = true
    var bold = false

    var body: some View {
        switch space.icon {
        case .emoji(let e):
            Text(e).font(.system(size: size)).saturation(colored ? 1 : 0).opacity(colored ? 1 : DS.Opacity.inactive)
        case .symbol(let name):
            // Symbols and dots carry the space's color (`base`), the others are quiet.
            Image(systemName: name)
                .font(.system(size: size, weight: bold ? .bold : .regular))
                .foregroundStyle(colored ? space.area.base : Palette.text3)
        case nil:
            Circle()
                .fill(colored ? space.area.base : Palette.text3)
                .frame(width: DS.Size.dot, height: DS.Size.dot)
        }
    }
}

/// Small label separating apps from websites inside a space.
struct KindLabel: View {
    enum Kind { case apps, websites, tabs }
    let kind: Kind

    var body: some View {
        SectionHeader(title: kind == .apps ? "Apps" : kind == .websites ? "Websites" : "Tabs")
        .help(kind == .apps ? "Apps that belong to this workspace. Drag an app here to add it."
              : kind == .websites ? "Websites saved in this workspace. Drag a tab here to keep it."
              : "Tabs open right now in this workspace.")
    }
}

/// Split views made with ⌥-click, each shown as its own tab (like Arc's split-view tabs).
struct SplitViewsSection: View {
    @ObservedObject var splits: SplitManager
    @ObservedObject var apps: AppsModel
    @ObservedObject var browser: BrowserModel

    var body: some View {
        if !splits.pairs.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                SectionHeader(title: "Split View")
                ForEach(splits.pairs) { pair in
                    SidebarRow(
                        title: "\(name(pair.left)) | \(name(pair.right))",
                        isSelected: isFront(pair),
                        closeHelp: "Remove split",
                        icon: {
                            HStack(spacing: -DS.Space.xs) {
                                icon(pair.left).frame(width: DS.Size.iconSmall, height: DS.Size.iconSmall)
                                icon(pair.right).frame(width: DS.Size.iconSmall, height: DS.Size.iconSmall)
                            }
                        },
                        onTap: { splits.restore(pair) },
                        onClose: { DS.Motion.perform(DS.Motion.standard) { splits.remove(pair) } }
                    )
                    .contextMenu {
                        Button("Open Split View") { splits.restore(pair) }
                        Button("Swap Sides") {
                            splits.record(left: pair.right, right: pair.left)
                            splits.restore(SplitPair(id: pair.id, left: pair.right, right: pair.left))
                        }
                        Button("Remove") { splits.remove(pair) }
                    }
                }
            }
            .dsAnimation(DS.Motion.standard, value: splits.pairs)
        }
    }

    private func isFront(_ pair: SplitPair) -> Bool {
        guard let front = splits.currentTarget() else { return false }
        return front == pair.left || front == pair.right
    }

    private func name(_ t: SplitTarget) -> String {
        switch t {
        case .app(let id):
            if let app = apps.running.first(where: { $0.bundleIdentifier == id }) { return app.localizedName ?? id }
            return AppIcons.name(of: id) ?? id
        case .tab(_, let url, let title):
            return title.isEmpty ? (URL(string: url)?.host ?? url) : title
        }
    }

    @ViewBuilder private func icon(_ t: SplitTarget) -> some View {
        switch t {
        case .app(let id):
            if let image = AppIcons.icon(of: id) { Image(nsImage: image).resizable().interpolation(.high) }
        case .tab(_, let url, _):
            FaviconView(url: url)
        }
    }
}

/// An app shown as a tab row inside a space card, on a light neutral background.
struct AppTabRow: View {
    let item: AppItem
    @ObservedObject var apps: AppsModel
    @ObservedObject private var freeze = Freeze.shared
    @ObservedObject private var badges = Badges.shared
    @ObservedObject var browser: BrowserModel
    /// Set when the row is one of a space's own apps (reorderable there).
    var spaceID: String?

    var body: some View {
        SidebarRow(
            title: item.name,
            isSelected: apps.frontmostID == item.id,
            dimmed: !item.isRunning,
            closeHelp: "Quit \(item.name)",
            icon: {
                Image(nsImage: item.icon).resizable().interpolation(.high)
                    .notificationDot(badges.apps[item.id])
                    .overlay(alignment: .topTrailing) {
                        if let twin = websiteTwin(of: item, in: browser) {
                            DuplicateBadge(other: "website “\(twin.title)”").offset(x: DS.Space.xs, y: -DS.Space.xs)
                        }
                    }
            },
            onTap: { apps.open(item.id, split: optionHeld) },
            onClose: item.isRunning ? { apps.quit(item.id) } : nil
        )
        .help("\(item.name) — app. ⌥-click for split screen")
        .onDrag({
            apps.draggingID = item.id
            TabDrag.currentItem = nil
            TabDrag.libraryItem = nil
            TabDrag.appSourceSpace = spaceID
            return NSItemProvider(object: item.id as NSString)
        }, preview: { DragPreview(title: item.name, icon: Image(nsImage: item.icon)) })
        .onDrop(of: [.plainText], delegate: SpaceAppDropDelegate(target: item.id, spaceID: spaceID, apps: apps))
        .contextMenu {
            Button("Open in Split Screen") { apps.open(item.id, split: true) }
            Button("Pin to Top") { apps.pin(item.id) }
            SpaceAppMenuItems(appID: item.id, apps: apps, browser: browser)
            MoveToSpaceMenu(subject: .app(item.id, from: spaceID), current: spaceID, browser: browser, apps: apps)
            Button("Hide from Tab List (menu bar only)") { apps.setHiddenFromTabs(item.id, true) }
            OpenAsWebsiteToggle(app: item, apps: apps, browser: browser)
            WindowRuleMenu(appID: item.id)
            FreezeMenu(subject: .app(item.id))
            if let twin = websiteTwin(of: item, in: browser) { DuplicateMenu(app: item, site: twin, apps: apps, onApp: true) }
            if item.isRunning {
                Divider()
                Button("Hide") { apps.hide(item.id) }
                Button("Quit \(item.name)") { apps.quit(item.id) }
            }
        }
        .overlay(alignment: .trailing) { if freeze.isFrozen(app: item.id) { FrozenBadge().padding(.trailing, DS.Space.s) } }
    }
}

/// The space's color (one of the 18) and accent (one of the 16), shown under its title.
/// Changes apply at once; Done closes it.
struct SpaceColorEditor: View {
    let space: BrowserSpace
    let library: Library?
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                SectionLabel(title: "Color")
                SwatchGrid(items: Area.allCases, columns: 6, selected: space.area, color: \.base, name: \.name) { area in
                    library?.updateSpace(space.id) { $0.area = area }
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.s) {
                SectionLabel(title: "Accent")
                SwatchGrid(items: Accent.allCases, columns: 4, selected: space.accent, color: \.color, name: \.name) { accent in
                    library?.updateSpace(space.id) { $0.accent = accent }
                }
            }
            HStack {
                Spacer()
                Button("Done") { DS.Motion.perform { settings.editingColorSpace = nil } }
                    .buttonStyle(.ghostSmall)
            }
        }
        .card(padding: DS.Space.m)
        .padding(.bottom, DS.Space.xs)
    }
}

/// Swatches in a grid: 20 pt circles, the chosen one with a 2 pt ring in `text`, names in tooltips.
struct SwatchGrid<Item: Hashable>: View {
    let items: [Item]
    let columns: Int
    let selected: Item?
    let color: KeyPath<Item, Color>
    let name: KeyPath<Item, String>
    let choose: (Item) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(DS.Size.hitTarget), spacing: DS.Space.xxs), count: columns),
                  alignment: .leading, spacing: DS.Space.xxs) {
            ForEach(items, id: \.self) { item in
                Button { choose(item) } label: {
                    Circle()
                        .fill(item[keyPath: color])
                        .frame(width: DS.Size.swatch, height: DS.Size.swatch)
                        .padding(DS.Line.ring + DS.Space.xxs)
                        .overlay(Circle().strokeBorder(item == selected ? Palette.text : .clear, lineWidth: DS.Line.ring))
                        .frame(width: DS.Size.hitTarget, height: DS.Size.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .help(item[keyPath: name])
                .accessibilityLabel(item[keyPath: name])
                .accessibilityAddTraits(item == selected ? .isSelected : [])
            }
        }
    }
}

/// Something dragged over a row or folder: the accent's soft fill and a 2 pt accent outline.
struct DropTargetHighlight: View {
    @Environment(\.dsAccent) private var accent
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
        shape.fill(accent.soft.opacity(DS.Opacity.overlay))
            .overlay(shape.strokeBorder(accent.color, lineWidth: DS.Line.focus))
            .allowsHitTesting(false)
    }
}

/// "+ New Tab" that turns into an address/search field right in the sidebar. The tab is then
/// created in the browser (synced), with matching open tabs offered while typing.
struct NewTabRow: View {
    @ObservedObject var browser: BrowserModel
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        if editing {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                // The quick-capture field: a card, 40 high, reading size.
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "magnifyingglass").textRole(.body).foregroundStyle(Palette.text3)
                        .frame(width: settings.rowIcon)
                    TextField("", text: $text, prompt: Text("Search or enter address").foregroundColor(Palette.text3))
                        .textFieldStyle(.plain)
                        .textRole(.bodyLarge)
                        .focused($focused)
                        .onSubmit(submit)
                        .onExitCommand(perform: cancel)
                }
                .padding(.horizontal, DS.Space.rowInset)
                .frame(height: DS.Size.captureField * CGFloat(settings.textScale))
                .card(padding: 0)
                .foregroundStyle(Palette.text)

                ForEach(matches) { tab in
                    SidebarRow(
                        title: tab.title,
                        dimmed: true,
                        icon: { FaviconView(url: tab.url) },
                        onTap: {
                            browser.openHere(tab, split: NSEvent.modifierFlags.contains(.option))
                            cancel()
                        }
                    )
                    .help("Switch to this open tab")
                }
            }
            .onAppear {
                PanelFocus.makeKey?()
                DispatchQueue.main.async { focused = true }
            }
        } else {
            SidebarRow(
                title: "New Tab",
                dimmed: true,
                icon: { Image(systemName: "plus").textRole(.body) },
                onTap: { DS.Motion.perform(DS.Motion.quick) { editing = true } }
            )
            .contextMenu { Button("New Incognito Tab") { WebBrowser.shared.newIncognitoTab() } }
        }
    }

    private var matches: [BrowserItem] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        let snap = browser.snapshot
        let all = (snap.favorites + snap.spaces.flatMap { $0.pinned + $0.unpinned } + snap.otherTabs).flatMap(\.allTabs)
        return Array(all.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.url.localizedCaseInsensitiveContains(q) }.prefix(4))
    }

    private func submit() {
        browser.createTab(input: text, split: NSEvent.modifierFlags.contains(.option))
        cancel()
    }

    private func cancel() {
        DS.Motion.perform(DS.Motion.quick) {
            editing = false
            text = ""
        }
    }
}
