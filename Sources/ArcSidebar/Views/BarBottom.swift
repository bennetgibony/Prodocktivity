import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The bar's bottom row: menu, space switcher, downloads.

struct BottomBar: View {
    @ObservedObject var settings: Settings
    @ObservedObject var apps: AppsModel
    @ObservedObject var browser: BrowserModel
    @ObservedObject var downloads: DownloadsModel
    let onToggleDownloads: () -> Void
    let onOpenSettings: () -> Void
    let onHide: () -> Void
    @Environment(\.dsAccent) private var accent
    /// The room inside the bar's side padding.
    private var width: CGFloat { CGFloat(settings.sidebarWidth) - 2 * DS.Space.edge }

    var body: some View {
        // One row when the spaces fit between the buttons at full size; otherwise they get a line of
        // their own, shrinking until 7 fit in a row, and more than 7 wrap to a second row.
        let count = SpaceSwitcher.spaces(browser).count + (browser.library != nil ? 1 : 0)
        let inline = width - 3 * DS.Size.hitTarget - 2 * DS.Space.xs
        let fitsInline = SpaceSwitcher.metrics(count: count, width: inline).cell >= DS.Size.hitTarget
        Group {
            if fitsInline {
                HStack(spacing: 0) {
                    settingsButton
                    moreMenu
                    Spacer(minLength: DS.Space.xs)
                    SpaceSwitcher(browser: browser, width: inline)
                    Spacer(minLength: DS.Space.xs)
                    downloadsButton
                }
            } else {
                VStack(spacing: DS.Space.xs) {
                    SpaceSwitcher(browser: browser, width: width)
                    HStack(spacing: 0) {
                        settingsButton
                        moreMenu
                        Spacer(minLength: DS.Space.xs)
                        downloadsButton
                    }
                }
            }
        }
        .padding(.horizontal, DS.Space.edge)
        .padding(.vertical, DS.Space.s)
    }

    private var settingsButton: some View {
        IconButton(symbol: "gearshape", help: "Settings  ⌘,", tint: accent.color, action: onOpenSettings)
    }

    private var moreMenu: some View {
        Menu {
            Button("Settings…", action: onOpenSettings)
            Button("Hide Sidebar  ⌃⌥S", action: onHide)
            Divider()
            if let space = browser.activeSpace {
                Menu("Workspace “\(space.title)”") {
                    SpaceMenuItems(spaceID: space.id, browser: browser)
                }
            }
            Button("New Workspace…") { SidebarActions.newSpace?() }
            Button("Show All Workspaces  ⌃⌥W") { SidebarActions.showOverview?() }
            Divider()
            Toggle("Snap windows next to sidebar", isOn: $settings.autoFitWindows)
            Toggle("Frame around everything", isOn: $settings.frameMode)
            Button("Snap front window now") { WindowManager.fillFrontmost() }
            Picker("Browser", selection: $settings.browserEngine) {
                ForEach(BrowserEngine.allCases) { Text($0.label).tag($0) }
            }
            if browser.provider.isArc {
                Button("Show/Hide Arc's Sidebar  ⌘S") { browser.toggleArcSidebar() }
            }
            Divider()
            Menu("Import") {
                Button("From Arc (spaces, pins, folders, favorites)") { SidebarActions.importArc?() }
                Button("From Chrome Bookmarks") { SidebarActions.importChrome?() }
                Button("From Safari Bookmarks") { SidebarActions.importSafari?() }
            }
            Menu("Ideas & Wishes") {
                Button("New Idea…  ⌃⌥I") { SidebarActions.newIdea?() }
                Button("Open Ideas File") { SidebarActions.openIdeas?() }
                Button("Export Ideas File…") { SidebarActions.exportIdeas?() }
                Button("Email Ideas to Bennet…") { SidebarActions.emailIdeas?() }
            }
            Button("Setup Tour…") { SidebarActions.showSetupTour?() }
            Button("Setup Guide") { SidebarActions.openGuide?() }
            Button("Show Getting Started") { GettingStarted.shared.showAgain() }
            Divider()
            Button("Quit proDOCKtivity") { NSApp.terminate(nil) }
        } label: {
            // Secondary actions behind the horizontal "more" button.
            Image(systemName: "ellipsis")
                .textRole(.body)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: DS.Size.hitTarget, height: DS.Size.hitTarget)
        .foregroundStyle(accent.color)
        .tint(accent.color)
        .help("More: workspaces, hide sidebar, import, ideas")
    }

    private var downloadsButton: some View {
        IconButton(symbol: "arrow.down.circle", help: "Downloads", tint: accent.color, action: onToggleDownloads)
            .overlay(alignment: .topTrailing) {
                if downloads.items.contains(where: \.isInProgress) {
                    // Downloading: a dot in the accent (the word is in the tooltip).
                    Circle().fill(Palette.text).frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                        .offset(x: -DS.Space.xs, y: DS.Space.xs)
                }
            }
    }
}

/// Arc's row of space icons at the bottom of the sidebar. The icons shrink until 7 spaces (and +) fit in
/// `width`; more than 7 wrap to further rows.
struct SpaceSwitcher: View {
    @ObservedObject var browser: BrowserModel
    let width: CGFloat
    @Environment(\.dsAccent) private var accent
    /// Space icon an item is being dragged over.
    @State private var dropTarget: String?
    /// The current space's chip glides to the new space.
    @Namespace private var chip

    static func spaces(_ browser: BrowserModel) -> [BrowserSpace] {
        browser.library?.spaces.isEmpty == false ? browser.displaySpaces : (browser.status == .ok ? browser.snapshot.spaces : [])
    }

    /// Size of each space (and +) and how many go in a row, for `count` items in `width`.
    /// Full size while they fit; then smaller, down to the minimum, so up to 7 spaces plus + share a row.
    static func metrics(count: Int, width: CGFloat) -> (cell: CGFloat, perRow: Int) {
        guard count > 0, width > 0 else { return (DS.Size.hitTarget, max(count, 1)) }
        let step = DS.Space.xxs
        // A row holds at most 7 spaces and the + (8 items), fewer when not even the minimum size fits.
        let fitting = Int((width + step) / (DS.Size.spaceDotMin + step))
        let perRow = max(1, min(count, DS.Size.spacesPerRow + 1, fitting))
        let cell = min(DS.Size.hitTarget, ((width + step) / CGFloat(perRow) - step).rounded(.down))
        return (max(cell, 1), perRow)
    }

    /// All in one row if they fit; otherwise rows of up to 7 spaces, the + (nil) at the end of the last one.
    static func rows(_ ids: [String], plus: Bool, perRow: Int) -> [[String?]] {
        let items: [String?] = ids + (plus ? [nil] : [])
        if perRow >= items.count { return items.isEmpty ? [] : [items] }
        let chunk = max(1, min(DS.Size.spacesPerRow, plus ? perRow - 1 : perRow))
        var rows: [[String?]] = stride(from: 0, to: ids.count, by: chunk).map { Array(ids[$0..<min($0 + chunk, ids.count)]) }
        if plus { rows[rows.count - 1].append(nil) }
        return rows
    }

    var body: some View {
        let spaces = Self.spaces(browser)
        let m = Self.metrics(count: spaces.count + (browser.library != nil ? 1 : 0), width: width)
        let rows = Self.rows(spaces.map(\.id), plus: browser.library != nil, perRow: m.perRow)
        VStack(spacing: DS.Space.xxs) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: DS.Space.xxs) {
                    ForEach(rows[r], id: \.self) { id in
                        if let id, let space = spaces.first(where: { $0.id == id }) {
                            SpaceDot(space: space, active: space.id == browser.activeSpace?.id, target: dropTarget == space.id,
                                     chip: chip, size: m.cell) {
                                DS.Motion.perform(DS.Motion.standard) { browser.focus(space: space) }
                            }
                            .onDrop(of: [.plainText], delegate: SpaceIconDropDelegate(spaceID: space.id, browser: browser, hovering: $dropTarget))
                            .contextMenu { SpaceMenuItems(spaceID: space.id, browser: browser) }
                        } else {
                            IconButton(symbol: "plus", help: "New Workspace", small: true, target: m.cell, tint: accent.color) {
                                SidebarActions.newSpace?()
                            }
                        }
                    }
                }
            }
        }
        .dsAnimation(DS.Motion.standard, value: browser.activeSpace?.id)
    }
}

/// One space in the switcher: the current one in color on a soft chip, the others quiet.
struct SpaceDot: View {
    let space: BrowserSpace
    let active: Bool
    /// Something is being dragged over it.
    let target: Bool
    let chip: Namespace.ID
    var size: CGFloat = DS.Size.hitTarget
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.dsAccent) private var accent

    var body: some View {
        let lit = active || target
        let shape = RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
        Button(action: action) {
            // The icon keeps its share of the square as the square shrinks.
            SpaceIconView(space: space, size: min(DS.Size.icon, size * DS.Size.icon / DS.Size.hitTarget), colored: lit || hovering, bold: lit)
                .frame(width: size, height: size)
                .opacity(lit || hovering ? 1 : DS.Opacity.quiet)
                // The current space on a white chip (it glides from space to space); a drop target in
                // the accent's soft fill and outline.
                .background {
                    if active && !target {
                        shape.fill(Palette.selectedOnFill).matchedGeometryEffect(id: "chip", in: chip)
                    } else {
                        shape.fill(target ? accent.soft : hovering ? Palette.hover : .clear)
                    }
                }
                .overlay(shape.strokeBorder(target ? accent.color : .clear, lineWidth: DS.Line.focus))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help(space.title)
        .accessibilityLabel("Workspace \(space.title)")
        .accessibilityAddTraits(active ? .isSelected : [])
        .onHover { h in DS.Motion.perform(DS.Motion.quick) { hovering = h } }
    }
}
