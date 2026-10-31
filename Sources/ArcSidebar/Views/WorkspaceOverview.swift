import AppKit
import SwiftUI

/// "Show All Spaces": every workspace as a card side by side (its Workbench and Open area), to
/// tidy up by dragging pins, tabs and apps from one card to another. Esc or the close button ends it.
@MainActor
final class WorkspaceOverviewController: NSObject, NSWindowDelegate {
    private let browser: BrowserModel
    private let apps: AppsModel
    private var window: NSWindow?

    init(browser: BrowserModel, apps: AppsModel) {
        self.browser = browser
        self.apps = apps
    }

    var isShown: Bool { window?.isVisible == true }

    func toggle() { isShown ? close() : show() }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame.insetBy(dx: screen.visibleFrame.width * 0.06, dy: screen.visibleFrame.height * 0.08)
        let window = OverviewWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
        window.title = "All Workspaces"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.onEscape = { [weak self] in self?.close() }
        window.contentView = NSHostingView(rootView: WorkspaceOverview(browser: browser, apps: apps) { [weak self] in self?.close() })
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
        Log.write("overview: shown")
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

/// A window that closes on Esc.
private final class OverviewWindow: NSWindow {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

struct WorkspaceOverview: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var apps: AppsModel
    let close: () -> Void
    @ObservedObject private var settings = Settings.shared
    @State private var dropTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("All Workspaces").textRole(.title2).foregroundStyle(Palette.text)
                Text("Drag pins, tabs and apps from one workspace to another.")
                    .textRole(.footnote).foregroundStyle(Palette.text2)
                Spacer()
                Button("Done", action: close).buttonStyle(.secondary).keyboardShortcut(.defaultAction)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: DS.Space.l) {
                    ForEach(browser.displaySpaces) { space in
                        WorkspaceCard(space: space, browser: browser, apps: apps, target: dropTarget == space.id,
                                      perWorkspace: settings.openAppsPerWorkspace)
                            .onDrop(of: [.plainText], delegate: SpaceIconDropDelegate(spaceID: space.id, browser: browser, hovering: $dropTarget))
                    }
                }
                .padding(.bottom, DS.Space.m)
            }
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.top, DS.Space.xxxl)
        .padding(.bottom, DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.canvas)
        .dsAnimation(DS.Motion.standard, value: browser.displaySpaces.map { $0.pinned.count + $0.unpinned.count })
    }
}

/// One workspace in the overview: its color on top, then the Workbench and the Open area.
private struct WorkspaceCard: View {
    let space: BrowserSpace
    @ObservedObject var browser: BrowserModel
    @ObservedObject var apps: AppsModel
    let target: Bool
    let perWorkspace: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
        let openApps = perWorkspace ? apps.openApps(inSpace: space.id, perWorkspace: true).filter { $0.id != browser.provider.bundleID } : []
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s) {
                SpaceIconView(space: space, size: DS.Size.icon)
                Text(space.title.isEmpty ? "Workspace" : space.title).textRole(.headline).foregroundStyle(Palette.text).lineLimit(1)
                Spacer(minLength: 0)
                if space.id == browser.activeSpace?.id {
                    Text("Current").textRole(.caption).foregroundStyle(Palette.text2)
                }
            }
            .padding(DS.Space.m)
            .background(space.area.fill)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { browser.focus(space: space) }
            .help("Double-click to switch to “\(space.title)”")

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    SectionLabel(title: "Pinned").padding(.top, DS.Space.s)
                    if space.pinned.isEmpty { empty("Nothing pinned") }
                    ForEach(flattened(space.pinned), id: \.item.id) { entry in
                        OverviewRow(item: entry.item, depth: entry.depth, apps: apps)
                    }
                    SectionLabel(title: "Open").padding(.top, DS.Space.m)
                    if space.unpinned.isEmpty && openApps.isEmpty { empty("No open tabs") }
                    ForEach(openApps) { app in OverviewAppRow(app: app, apps: apps) }
                    ForEach(space.unpinned) { item in OverviewRow(item: item, depth: 0, apps: apps) }
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.bottom, DS.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: DS.Size.overviewColumn)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(shape.fill(Palette.surface))
        .clipShape(shape)
        .overlay(shape.strokeBorder(target ? space.accent.color : Palette.border, lineWidth: target ? DS.Line.focus : DS.Line.hairline))
        .overlay { if target { shape.fill(space.accent.soft.opacity(DS.Opacity.overlay)).allowsHitTesting(false) } }
        .accent(space.accent)
    }

    private func empty(_ text: String) -> some View {
        Text(text).textRole(.footnote).foregroundStyle(Palette.text3).padding(.horizontal, DS.Space.xs)
    }

    /// Folders and what's in them, one row each.
    private func flattened(_ items: [BrowserItem], depth: Int = 0) -> [(item: BrowserItem, depth: Int)] {
        items.flatMap { [($0, depth)] + flattened($0.children, depth: depth + 1) }
    }
}

/// A pin, folder or open tab: drag it onto another card to move it there.
private struct OverviewRow: View {
    let item: BrowserItem
    let depth: Int
    @ObservedObject var apps: AppsModel
    @Environment(\.dsAccent) private var accent

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Group {
                switch item.kind {
                case .folder: Image(systemName: "folder.fill").resizable().scaledToFit().foregroundStyle(accent.color)
                case .app:
                    if let app = apps.appItem(for: item.url) { Image(nsImage: app.icon).resizable() } else { Image(systemName: "app") }
                default: FaviconView(url: item.url)
                }
            }
            .frame(width: DS.Size.icon, height: DS.Size.icon)
            Text(title).textRole(.body).foregroundStyle(Palette.text).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * DS.Space.l + DS.Space.xs)
        .frame(height: DS.Size.row)
        .contentShape(Rectangle())
        .onDrag {
            if let id = Library.libraryID(item.id) {
                TabDrag.libraryItem = id
                TabDrag.currentItem = nil
            } else {
                TabDrag.libraryItem = nil
                TabDrag.currentItem = item
            }
            apps.draggingID = nil
            return NSItemProvider(object: item.id as NSString)
        } preview: {
            DragPreview(title: title, favicon: item.host)
        }
        .help(item.url.isEmpty ? title : item.url)
    }

    private var title: String {
        if item.kind == .app, let app = apps.appItem(for: item.url) { return app.name }
        return item.title.isEmpty ? (item.host ?? item.url) : item.title
    }
}

/// An open app in a workspace's Open area (when open apps belong to one workspace).
private struct OverviewAppRow: View {
    let app: AppItem
    @ObservedObject var apps: AppsModel

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(nsImage: app.icon).resizable().frame(width: DS.Size.icon, height: DS.Size.icon)
            Text(app.name).textRole(.body).foregroundStyle(Palette.text).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, DS.Space.xs)
        .frame(height: DS.Size.row)
        .contentShape(Rectangle())
        .onDrag {
            TabDrag.libraryItem = nil
            TabDrag.currentItem = nil
            TabDrag.appSourceSpace = nil
            apps.draggingID = app.id
            return NSItemProvider(object: app.id as NSString)
        } preview: {
            DragPreview(title: app.name, icon: Image(nsImage: app.icon))
        }
    }
}
