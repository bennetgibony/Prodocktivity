import AppKit
import SwiftUI

/// Extra bars next to the main one: the website dock (websites of the space, right of the bar)
/// and the files dock (chosen folders, left next to the bars or at the right screen edge).
/// They look like the bar: their own cards, or one piece with the frame in frame mode.
@MainActor
final class DockManager {
    enum Dock { case websites, files }

    private var panels: [Dock: SidebarPanel] = [:]
    /// Which side each panel was built for (the files dock can switch sides).
    private var sides: [Dock: DockSurface<AnyView>.Side] = [:]
    private let settings: Settings
    private let apps: AppsModel
    private let browser: BrowserModel
    private let perms: PermissionsModel

    init(settings: Settings, apps: AppsModel, browser: BrowserModel, perms: PermissionsModel) {
        self.settings = settings
        self.apps = apps
        self.browser = browser
        self.perms = perms
    }

    /// Shows the docks that are switched on, next to the bar on `screen` (or hides them all).
    func update(screen: NSScreen?, visible: Bool) {
        for dock in [Dock.websites, .files] {
            guard visible, let screen, let frame = frame(of: dock, on: screen) else {
                panels[dock]?.orderOut(nil)
                continue
            }
            let panel = panels[dock] ?? make(dock)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            panel.hasShadow = !settings.frameMode
            panel.alphaValue = 1
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    private func make(_ dock: Dock) -> SidebarPanel {
        let side: DockSurface<AnyView>.Side = dock == .files && settings.filesDock == .right ? .right : .middle
        let content: AnyView
        switch dock {
        case .websites: content = AnyView(WebsiteDockView(apps: apps, browser: browser, perms: perms))
        case .files: content = AnyView(FilesDockView())
        }
        let panel = SidebarPanel(rootView: DockSurface(settings: settings, apps: apps, browser: browser, chrome: .shared,
                                                       side: side, content: content))
        panels[dock] = panel
        sides[dock] = side
        return panel
    }

    /// Where a dock goes: the website dock right of the bar, the files dock after that or at the
    /// right edge. Same vertical span as the bar, so colors line up in frame mode.
    private func frame(of dock: Dock, on screen: NSScreen) -> NSRect? {
        let width: CGFloat
        var offset = Layout.barWidth
        var right = false
        switch dock {
        case .websites:
            guard settings.websiteDock else { return nil }
            width = Layout.websiteDockWidth
        case .files:
            guard settings.filesDock != .off else { return nil }
            width = CGFloat(settings.filesDockWidth)
            offset += Layout.websiteDockWidth
            right = settings.filesDock == .right
        }
        // The files dock can switch sides: its panel is rebuilt for the other side.
        if dock == .files, let p = panels[.files], sides[.files] != (right ? .right : .middle) {
            p.orderOut(nil)
            panels[.files] = nil
        }
        let vf = screen.visibleFrame
        let gap = Layout.windowGap
        if settings.frameMode {
            let top = settings.frameUnderMenuBar ? screen.frame.maxY : vf.maxY
            let x = right ? vf.maxX - width : vf.minX + offset
            return NSRect(x: x, y: screen.frame.minY, width: width, height: top - screen.frame.minY)
        }
        let y = vf.minY + Layout.inset, h = vf.height - Layout.inset * 2
        return right
            ? NSRect(x: vf.maxX - width + gap, y: y, width: width - gap - Layout.inset, height: h)
            : NSRect(x: vf.minX + offset, y: y, width: width - gap, height: h)
    }
}

/// A dock's background and padding, matching the bar: a card of its own, or (frame mode) the
/// frame's color with the frame's gaps.
struct DockSurface<Content: View>: View {
    enum Side { case middle, right }

    @ObservedObject var settings: Settings
    @ObservedObject var apps: AppsModel
    @ObservedObject var browser: BrowserModel
    @ObservedObject var chrome: BarChrome
    let side: Side
    let content: Content

    var body: some View {
        Group {
            if let insets = chrome.framed {
                content
                    .padding(EdgeInsets(top: insets.top, leading: side == .right ? Layout.windowGap : 0,
                                        bottom: insets.bottom, trailing: side == .right ? insets.leading : Layout.windowGap))
                    .background(BarBackground())
                    .clipShape(UnevenRoundedRectangle(topTrailingRadius: side == .right && chrome.roundTop ? Layout.frameCornerRadius : 0,
                                                      style: .continuous))
            } else {
                content
                    .background(BarBackground())
                    .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous))
                    .overlay(BarOutline())
            }
        }
    }
}

// MARK: - Files dock

/// A folder shown in the files dock, and whether it starts open.
struct DockFolder: Codable, Equatable, Identifiable {
    var path: String
    var startsOpen: Bool
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

@MainActor final class FilesDockModel: ObservableObject {
    static let shared = FilesDockModel()

    @Published var folders: [DockFolder] {
        didSet { defaults.set(try? JSONEncoder().encode(folders), forKey: "dock.folders") }
    }
    /// Folders open right now (top-level ones start as chosen, subfolders closed).
    @Published var open: Set<String> = []
    private var timer: Timer?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, watch: Bool = true) {
        self.defaults = defaults
        let saved = defaults.data(forKey: "dock.folders").flatMap { try? JSONDecoder().decode([DockFolder].self, from: $0) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        // A useful start: Downloads and Desktop, Downloads open.
        folders = saved ?? [DockFolder(path: home.appendingPathComponent("Downloads").path, startsOpen: true),
                            DockFolder(path: home.appendingPathComponent("Desktop").path, startsOpen: false)]
        open = Set(folders.filter(\.startsOpen).map(\.path))
        guard watch else { return }
        // New files show up without a refresh click.
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard Settings.shared.filesDock != .off else { return }
                self?.refresh()
            }
        }
        timer?.tolerance = 2
    }

    /// Folder listings, read once and then refreshed in the background (rows redraw on every
    /// hover, and listing a cloud-synced folder can take a while: never on the main thread
    /// over and over).
    private var listings: [String: [URL]] = [:]
    private var folderFlags: [String: Bool] = [:]
    private var refreshing = false

    func children(of url: URL) -> [URL] {
        if let cached = listings[url.path] { return cached }
        let items = Self.contents(of: url)
        listings[url.path] = items
        return items
    }

    /// Re-reads the open folders off the main thread; the dock redraws only if something changed.
    func refresh() {
        guard !refreshing else { return }
        listings = listings.filter { open.contains($0.key) }
        let paths = Array(listings.keys)
        guard !paths.isEmpty else { return }
        refreshing = true
        Task.detached(priority: .utility) { [weak self] in
            let fresh = Dictionary(uniqueKeysWithValues: paths.map { ($0, Self.contents(of: URL(fileURLWithPath: $0))) })
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.refreshing = false
                var changed = false
                for (path, items) in fresh where self.listings[path] != nil && self.listings[path] != items {
                    self.listings[path] = items
                    changed = true
                }
                if changed { self.objectWillChange.send() }
            }
        }
    }

    /// Whether `url` is a folder (apps count as files); a path doesn't change kind, so it's checked once.
    func isFolder(_ url: URL) -> Bool {
        if let known = folderFlags[url.path] { return known }
        let dir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && url.pathExtension != "app"
        folderFlags[url.path] = dir
        return dir
    }

    func toggle(_ path: String) {
        if open.contains(path) { open.remove(path) } else {
            // Opened again: read it fresh rather than show what it held back then.
            listings[path] = nil
            open.insert(path)
        }
    }

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Files Dock"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !folders.contains(where: { $0.path == url.path }) {
            folders.append(DockFolder(path: url.path, startsOpen: false))
        }
    }

    func remove(_ folder: DockFolder) { folders.removeAll { $0.path == folder.path } }

    func setStartsOpen(_ folder: DockFolder, _ on: Bool) {
        guard let i = folders.firstIndex(of: folder) else { return }
        folders[i].startsOpen = on
    }

    func move(_ folder: DockFolder, by offset: Int) {
        guard let i = folders.firstIndex(of: folder) else { return }
        let j = i + offset
        guard folders.indices.contains(j) else { return }
        folders.swapAt(i, j)
    }

    /// Visible contents of a folder: folders first, then files, by name; newest first in Downloads.
    nonisolated static func contents(of url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                         options: [.skipsHiddenFiles]) else { return [] }
        if url.lastPathComponent == "Downloads" {
            func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            return items.sorted { date($0) > date($1) }
        }
        func isDir(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && u.pathExtension != "app" }
        return items.sorted {
            let (a, b) = (isDir($0), isDir($1))
            return a != b ? a : $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
}

struct FilesDockView: View {
    @ObservedObject private var model = FilesDockModel.shared

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Files") {
                IconButton(symbol: "plus", help: "Add a folder", small: true) { model.addFolders() }
            }
            .padding(.horizontal, DS.Space.edge)
            .padding(.top, DS.Space.m)
            .padding(.bottom, DS.Space.xs)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.folders) { folder in
                        FileRow(url: folder.url, depth: 0, folder: folder)
                    }
                    if model.folders.isEmpty {
                        Text("Add folders with +. Right-click a folder to choose whether it starts open.")
                            .textRole(.footnote).foregroundStyle(Palette.text2).padding(DS.Space.rowInset)
                    }
                }
                .padding(.horizontal, DS.Space.edge)
                .padding(.bottom, DS.Space.l)
            }
        }
    }
}

/// A file or folder; folders open and close in place, files open with a click and can be dragged out.
private struct FileRow: View {
    let url: URL
    let depth: Int
    /// Set for the top-level folders the user chose.
    var folder: DockFolder?
    @ObservedObject private var model = FilesDockModel.shared
    @ObservedObject private var design = Settings.shared
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    private var isFolder: Bool { model.isFolder(url) }

    var body: some View {
        let open = model.open.contains(url.path)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.xs) {
                if isFolder {
                    Image(systemName: "chevron.right")
                        .textRole(.caption, weight: .semibold)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .dsAnimation(DS.Motion.standard, value: open)
                        .foregroundStyle(Palette.text3)
                        .frame(width: DS.Size.iconSmall)
                } else {
                    Color.clear.frame(width: DS.Size.iconSmall, height: 1)
                }
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().interpolation(.high).frame(width: design.rowIcon, height: design.rowIcon)
                Text(url.lastPathComponent)
                    .textRole(.body, weight: depth == 0 ? .semibold : nil)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * DS.Space.m + DS.Space.xs)
            .padding(.trailing, DS.Space.s)
            .frame(height: DS.Size.barRow(.compact, scale: CGFloat(design.textScale)))
            .background(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .fill(hovering ? Palette.hover : .clear))
            .contentShape(Rectangle())
            .onHover { h in DS.Motion.perform(DS.Motion.quick) { hovering = h } }
            .onTapGesture {
                if isFolder { DS.Motion.perform(DS.Motion.standard) { model.toggle(url.path) } } else { NSWorkspace.shared.open(url) }
            }
            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            .contextMenu { menu }
            .help(url.path)

            if isFolder, open {
                let kids = model.children(of: url)
                ForEach(kids.prefix(200), id: \.path) { child in
                    FileRow(url: child, depth: depth + 1)
                }
                if kids.isEmpty {
                    Text("Empty").textRole(.footnote).foregroundStyle(Palette.text3)
                        .padding(.leading, CGFloat(depth + 1) * DS.Space.m + DS.Space.xxl)
                        .frame(height: DS.Size.sectionHeader)
                }
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Button(isFolder ? "Open in Finder" : "Open") { NSWorkspace.shared.open(url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        if let folder {
            Divider()
            Toggle("Starts open", isOn: Binding(get: { folder.startsOpen }, set: { model.setStartsOpen(folder, $0) }))
            Button("Move Up") { model.move(folder, by: -1) }
            Button("Move Down") { model.move(folder, by: 1) }
            Button("Remove from Files Dock") { model.remove(folder) }
        } else if isFolder {
            Divider()
            Button("Add to Files Dock") {
                if !model.folders.contains(where: { $0.path == url.path }) {
                    model.folders.append(DockFolder(path: url.path, startsOpen: false))
                }
            }
        }
    }
}
