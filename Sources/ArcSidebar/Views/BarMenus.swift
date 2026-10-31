import AppKit
import SwiftUI

// Context menus shared by the bar's rows and tiles.

/// Context-menu items to add/remove an app from the active Arc space.
struct SpaceAppMenuItems: View {
    let appID: String
    @ObservedObject var apps: AppsModel
    @ObservedObject var browser: BrowserModel

    var body: some View {
        if let space = browser.activeSpace {
            if apps.isApp(appID, inSpace: space.id) {
                Button("Remove from Workspace “\(space.title)”") { apps.removeApp(appID, fromSpace: space.id) }
            } else {
                Button("Add to Workspace “\(space.title)”") { apps.addApp(appID, toSpace: space.id) }
            }
        }
    }
}

/// Everything you can do with a space, all inside the sidebar.
struct SpaceMenuItems: View {
    let spaceID: String
    @ObservedObject var browser: BrowserModel

    var body: some View {
        if let library = browser.library, let space = library.spaces.first(where: { $0.id == spaceID }) {
            Button("Color & Accent…") {
                library.activeSpaceID = spaceID
                DS.Motion.perform {
                    Settings.shared.editingIconSpace = nil
                    Settings.shared.editingColorSpace = spaceID
                }
            }
            Button("New Folder…") { SidebarActions.newFolder?(spaceID) }
            Divider()
            Button("Rename…") {
                if let t = Prompt.text("Rename Workspace", initial: space.title) { library.updateSpace(spaceID) { $0.title = t } }
            }
            Button("Change Icon…") {
                library.activeSpaceID = spaceID
                DS.Motion.perform {
                    Settings.shared.editingColorSpace = nil
                    Settings.shared.editingIconSpace = spaceID
                }
            }
            Menu("Color") {
                ForEach(Area.allCases) { area in
                    Toggle(isOn: Binding(get: { space.area == area }, set: { _ in library.updateSpace(spaceID) { $0.area = area } })) {
                        Label { Text(area.name) } icon: { Image(nsImage: Swatch.image(area.nsBase, key: "area." + area.rawValue)) }
                    }
                }
            }
            Menu("Accent") {
                ForEach(Accent.allCases) { accent in
                    Toggle(isOn: Binding(get: { space.accent == accent }, set: { _ in library.updateSpace(spaceID) { $0.accent = accent } })) {
                        Label { Text(accent.name) } icon: { Image(nsImage: Swatch.image(accent.nsColor, key: "accent." + accent.rawValue)) }
                    }
                }
            }
            ProfileMenu(space: space, library: library)
            Menu("Link to \(browser.provider.displayName) Space") {
                Button("None (use the current one)") { library.updateSpace(spaceID) { $0.arcSpaceID = nil } }
                ForEach(browser.snapshot.spaces) { arc in
                    Button((space.arcSpaceID == arc.id ? "✓ " : "") + arc.title) { library.updateSpace(spaceID) { $0.arcSpaceID = arc.id } }
                }
            }
            Divider()
            Button("Move Left") { library.moveSpace(spaceID, by: -1) }
            Button("Move Right") { library.moveSpace(spaceID, by: 1) }
            Divider()
            Button("Delete Workspace") { UndoableDelete.workspace(space, library: library, browser: browser) }
        }
    }
}

/// Which login profile a space uses in the built-in browser (spaces can share one).
struct ProfileMenu: View {
    let space: LibrarySpace
    @ObservedObject var library: Library

    var body: some View {
        let current = library.profile(forSpace: space.id)
        Menu("Profile: \(current?.name ?? "–")") {
            ForEach(library.profiles) { p in
                Button((p.id == current?.id ? "✓ " : "") + p.name) {
                    library.setProfile(p.id, forSpace: space.id)
                    WebBrowser.shared.profileChanged(forSpace: space.id)
                }
            }
            Divider()
            Button("New Profile…") {
                if let name = Prompt.text("New Profile", message: "Workspaces with the same profile share their logins.", initial: "") , !name.isEmpty {
                    let p = library.addProfile(name: name)
                    library.setProfile(p.id, forSpace: space.id)
                    WebBrowser.shared.profileChanged(forSpace: space.id)
                }
            }
            if let current {
                Button("Rename “\(current.name)”…") {
                    if let name = Prompt.text("Rename Profile", initial: current.name), !name.isEmpty { library.renameProfile(current.id, to: name) }
                }
                Button("Sign Out of Everything in “\(current.name)”…") {
                    if Prompt.confirm("Sign out of all websites in “\(current.name)”?",
                                      message: "Deletes this profile's cookies and website data, in every workspace that uses it.", destructive: "Sign Out") {
                        WebBrowser.shared.clearData(forProfile: current.id)
                    }
                }
                if library.profiles.count > 1 {
                    Button("Delete “\(current.name)”") { UndoableDelete.profile(current, library: library) }
                }
            }
        }
    }
}

/// Options for a pinned website or folder in the sidebar.
struct LibraryItemMenu: View {
    let item: BrowserItem
    let library: Library?

    var body: some View {
        if let library, let id = Library.libraryID(item.id), let entry = library.find(id),
           let spaceID = library.spaces.first(where: { s in Library.contains(s.pinned, id: id) })?.id {
            Divider()
            Button("Rename…") {
                if let t = Prompt.text("Rename", initial: entry.title) { library.rename(id, to: t) }
            }
            if let browser = DuplicateActions.browser {
                MoveToSpaceMenu(subject: .libraryItem(id), current: spaceID, browser: browser, apps: DuplicateActions.apps)
            }
            if entry.kind != .folder {
                let folders = library.folders(in: spaceID)
                if !folders.isEmpty {
                    Menu("Move to Folder") {
                        Button("Top Level") { library.move(id, space: spaceID) }
                        ForEach(folders) { f in Button(f.title) { library.move(id, intoFolder: f.id, space: spaceID) } }
                    }
                }
                Button(entry.kind == .app ? "Remove from Workspace" : "Remove from Sidebar") { DS.Motion.perform { library.remove(id) } }
            } else {
                Button("New Folder…") { SidebarActions.newFolder?(spaceID) }
                Button("Remove Folder (keep contents)") { DS.Motion.perform { library.dissolveFolder(id) } }
                Button("Delete Folder and Contents…") {
                    if Prompt.confirm("Delete “\(entry.title)”?", message: "The folder and its pins leave the sidebar. Open tabs stay open.", destructive: "Delete") {
                        library.remove(id)
                    }
                }
            }
        }
    }
}

/// Right-click section offered on items that have a twin.
struct DuplicateMenu: View {
    let app: AppItem
    let site: BrowserItem
    let apps: AppsModel
    /// True when the menu is on the app, false when on the website.
    let onApp: Bool

    var body: some View {
        Section("Duplicate: \(app.name) app + \(site.host ?? site.title)") {
            Button(onApp ? "Keep only this app" : "Keep only the app") { DuplicateActions.keepApp(app, dropping: site) }
            Button(onApp ? "Keep only the website" : "Keep only this website") { DuplicateActions.keepWebsite(site, dropping: app) }
            Button("Keep both (hide marker)") { apps.keepBoth(app: app.id, url: site.url) }
        }
    }
}

/// Menu toggle to open an app's website in the browser instead of the app.
struct OpenAsWebsiteToggle: View {
    let app: AppItem
    @ObservedObject var apps: AppsModel
    @ObservedObject var browser: BrowserModel

    var body: some View {
        if let current = apps.openAsWebsite[app.id] {
            Button("Open as App Again (not \(URL(string: current)?.host ?? "website"))") { apps.setOpenAsWebsite(app.id, url: nil) }
        } else if let url = websiteTwin(of: app, in: browser)?.url ?? AppsModel.knownWebApps[app.id] {
            Button("Open as \(browser.provider.displayName) Tab (\(URL(string: url)?.host ?? url))") { apps.setOpenAsWebsite(app.id, url: url) }
        }
    }
}

/// Deleting a workspace or profile right away, with Undo (the toast's button or ⌘Y) instead of a
/// question first. A profile's logins are only erased once Undo is no longer offered.
@MainActor
enum UndoableDelete {
    static func workspace(_ space: LibrarySpace, library: Library, browser: BrowserModel) {
        guard let index = library.spaces.firstIndex(where: { $0.id == space.id }) else { return }
        let tabs = WebBrowser.shared.tabIDs(inSpace: space.id)
        library.deleteSpace(space.id)
        let undo = Reopen.undoable {
            library.restoreSpace(space, at: index)
            WebBrowser.shared.moveTabs(ids: tabs, to: space.id)
        }
        browser.showHint("“\(space.title)” deleted. Its open tabs moved to “\(library.activeSpace?.title ?? "")”.", action: "Undo") {
            Reopen.undo(undo)
        }
    }

    /// Erasing the logins waits this long (the toast's time, and a margin for ⌘Y).
    static let eraseAfter: Double = 60

    static func profile(_ profile: BrowserProfile, library: Library) {
        guard library.profiles.count > 1, let index = library.profiles.firstIndex(of: profile) else { return }
        let affected = library.spaces.filter { library.profile(forSpace: $0.id)?.id == profile.id }.map(\.id)
        let explicit = library.spaces.filter { $0.profileID == profile.id }.map(\.id)
        library.deleteProfile(profile.id)
        affected.forEach(WebBrowser.shared.profileChanged)
        var undone = false
        let undo = Reopen.undoable {
            undone = true
            library.restoreProfile(profile, at: index, forSpaces: explicit)
            affected.forEach(WebBrowser.shared.profileChanged)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + eraseAfter) {
            MainActor.assumeIsolated {
                guard !undone, !library.profiles.contains(where: { $0.id == profile.id }) else { return }
                Reopen.forget(.undo(undo))
                WebBrowser.shared.deleteData(forProfile: profile.id)
            }
        }
        DuplicateActions.browser?.showHint("Profile “\(profile.name)” deleted.", action: "Undo") { Reopen.undo(undo) }
    }
}
