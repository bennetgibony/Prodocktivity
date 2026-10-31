import SwiftUI

/// Moving pins, open tabs and apps to another space, by drag onto a space icon or the
/// "Move to Space" menu.
@MainActor enum SpaceMove {
    enum Subject {
        /// A pin, app or folder kept in the sidebar.
        case libraryItem(String)
        /// An open browser tab that isn't pinned in the sidebar.
        case tab(BrowserItem)
        /// An open app; `from` is the space it belongs to, if any.
        case app(String, from: String?)
    }

    static func move(_ subject: Subject, to spaceID: String, browser: BrowserModel, apps: AppsModel?) {
        guard let library = browser.library, let target = library.spaces.first(where: { $0.id == spaceID }) else { return }
        // Dropped where it already is (e.g. back onto its own card in Show All Workspaces): nothing to do.
        if case .tab(let tab) = subject,
           browser.displaySpaces.first(where: { $0.id == spaceID })?.unpinned.contains(where: { $0.id == tab.id }) == true { return }
        if case .app(let id, nil) = subject, Settings.shared.openAppsPerWorkspace, apps?.openIn[id] == spaceID { return }
        DS.Motion.perform(DS.Motion.standard) {
            switch subject {
            case .libraryItem(let id):
                guard !Library.contains(target.pinned, id: id) else { return }
                library.move(id, space: spaceID)
            case .tab(let tab):
                if let arcSpace = browser.browserSpaceID(for: target), browser.showsLiveTabs, browser.provider.hasSpaces {
                    // Stays an open tab, now in the browser space linked to the target.
                    browser.moveTab(tab, toBrowserSpace: arcSpace)
                } else {
                    library.add(.site(tab.title, tab.url), toSpace: spaceID)
                    browser.close(tab)
                }
            case .app(let id, let from):
                // An open app that lives in the Open area: it just moves to that workspace's Open area.
                if from == nil, Settings.shared.openAppsPerWorkspace, let apps,
                   apps.unpinnedRunningItems.contains(where: { $0.id == id }) {
                    apps.assignOpenApp(id, to: spaceID)
                    return
                }
                if let from, from != spaceID { library.removeApp(id, fromSpace: from) }
                if !library.containsApp(id, inSpace: spaceID) {
                    library.add(.app(id, title: apps?.displayName(for: id) ?? id), toSpace: spaceID)
                }
            }
        }
        browser.showHint("Moved to “\(target.title)”")
    }

    /// What is being dragged right now, if anything.
    static func dragged(apps: AppsModel?) -> Subject? {
        if let id = TabDrag.libraryItem { return .libraryItem(id) }
        if let tab = TabDrag.currentItem, Library.libraryID(tab.id) == nil { return .tab(tab) }
        // Pin-area entries for websites ("tab␟…", "fav␟…") aren't apps.
        if let app = apps?.draggingID, !app.contains("\u{1F}") { return .app(app, from: TabDrag.appSourceSpace) }
        return nil
    }
}

/// "Move to Space" submenu listing every other space.
struct MoveToSpaceMenu: View {
    let subject: SpaceMove.Subject
    /// The space the item is in now (left out of the list).
    let current: String?
    @ObservedObject var browser: BrowserModel
    var apps: AppsModel?

    var body: some View {
        if let spaces = browser.library?.spaces.filter({ $0.id != current }), !spaces.isEmpty {
            Menu("Move to Workspace") {
                ForEach(spaces) { space in
                    Button(space.emoji.map { "\($0)  \(space.title)" } ?? space.title) {
                        SpaceMove.move(subject, to: space.id, browser: browser, apps: apps)
                    }
                }
            }
        }
    }
}

/// Space icons take items dropped on them.
struct SpaceIconDropDelegate: DropDelegate {
    let spaceID: String
    let browser: BrowserModel
    @Binding var hovering: String?

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { SpaceMove.dragged(apps: DuplicateActions.apps) != nil }
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated { DS.Motion.perform(DS.Motion.quick) { hovering = spaceID } }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { if hovering == spaceID { DS.Motion.perform(DS.Motion.quick) { hovering = nil } } }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            let apps = DuplicateActions.apps
            defer {
                hovering = nil
                TabDrag.libraryItem = nil; TabDrag.current = nil; TabDrag.currentItem = nil; TabDrag.appSourceSpace = nil
                apps?.draggingID = nil
            }
            guard let subject = SpaceMove.dragged(apps: apps) else { return false }
            SpaceMove.move(subject, to: spaceID, browser: browser, apps: apps)
            return true
        }
    }
}
