import Foundation
import Testing
@testable import ArcSidebar

@MainActor
struct LibraryDisplayTests {
    private func tab(_ id: String, _ url: String) -> BrowserItem { BrowserItem(id: id, title: id, url: url, kind: .tab) }

    private func space(id: String = "lib1", arc: String? = nil, pinned: [LibraryItem] = []) -> LibrarySpace {
        LibrarySpace(id: id, title: "S", arcSpaceID: arc, pinned: pinned)
    }

    private func snapshot(_ spaces: [BrowserSpace], active: String? = nil) -> BrowserSnapshot {
        BrowserSnapshot(spaces: spaces, activeSpaceID: active)
    }

    @Test func pinnedItemsShowWithLibraryIDsAndKinds() {
        let folder = LibraryItem(id: "f", kind: .folder, title: "F", children: [.site("A", "https://a.example"), .app("com.apple.Notes", title: "Notes")])
        let shown = Library.display(folder)
        #expect(shown.id == "lib:f" && shown.kind == .folder)
        #expect(shown.children.map(\.kind) == [.tab, .app])
        #expect(Library.libraryID(shown.id) == "f")
        #expect(Library.libraryID("arc-tab") == nil)
    }

    @Test func builtInBrowserShowsItsOwnSpacesTabs() {
        var live = BrowserSpace(id: "lib1", title: "S")
        live.unpinned = [tab("t1", "https://x.example")]
        let tabs = Library.todayTabs(for: space(), live: snapshot([live, BrowserSpace(id: "other", title: "O")]), source: .sameSpaces, activeSpaceID: nil)
        #expect(tabs.map(\.id) == ["t1"])
    }

    @Test func tabsAlreadyPinnedAreNotShownTwice() {
        var live = BrowserSpace(id: "lib1", title: "S")
        live.unpinned = [tab("t1", "https://pinned.example"), tab("t2", "https://other.example"), tab("t3", "https://new.example")]
        let s = space(pinned: [.site("P", "https://pinned.example"), .site("O", "https://elsewhere.example", arcTabID: "t2")])
        #expect(Library.todayTabs(for: s, live: snapshot([live]), source: .sameSpaces, activeSpaceID: nil).map(\.id) == ["t3"])
    }

    @Test func pinnedInsideFoldersCountsToo() {
        var live = BrowserSpace(id: "lib1", title: "S")
        live.unpinned = [tab("t1", "https://deep.example")]
        let s = space(pinned: [LibraryItem(kind: .folder, title: "F", children: [.site("D", "https://deep.example")])])
        #expect(Library.todayTabs(for: s, live: snapshot([live]), source: .sameSpaces, activeSpaceID: nil).isEmpty)
    }

    @Test func chromeTabsShowOnlyInTheActiveSpace() {
        var chrome = BrowserSpace(id: "chrome", title: "Chrome")
        chrome.unpinned = [tab("c1", "https://c.example")]
        let live = snapshot([chrome], active: "chrome")
        #expect(Library.todayTabs(for: space(id: "a"), live: live, source: .noSpaces, activeSpaceID: "a").map(\.id) == ["c1"])
        #expect(Library.todayTabs(for: space(id: "b"), live: live, source: .noSpaces, activeSpaceID: "a").isEmpty)
    }

    @Test func arcSpacesShowTheirLinkedSpaceAndUnlinkedOnesTheActiveOne() {
        var uni = BrowserSpace(id: "arc-uni", title: "Uni")
        uni.pinned = [tab("p", "https://p.example")]
        uni.unpinned = [BrowserItem(id: "split", title: "", url: "", kind: .split, children: [tab("s1", "https://1.example"), tab("s2", "https://2.example")])]
        var work = BrowserSpace(id: "arc-work", title: "Work")
        work.unpinned = [tab("w", "https://w.example")]
        let live = snapshot([uni, work], active: "arc-work")
        #expect(Library.todayTabs(for: space(arc: "arc-uni"), live: live, source: .linked, activeSpaceID: nil).map(\.id) == ["p", "s1", "s2"])
        #expect(Library.todayTabs(for: space(), live: live, source: .linked, activeSpaceID: nil).map(\.id) == ["w"])
        // Linked to an Arc space that's gone: nothing (not the active space's tabs).
        #expect(Library.todayTabs(for: space(arc: "deleted"), live: live, source: .linked, activeSpaceID: nil).isEmpty)
    }

    @Test func displaySpaceKeepsTheLook() {
        let lib = Library(fileURL: sandbox().appendingPathComponent("library.json"), defaults: freshDefaults())
        let s = lib.addSpace(title: "Uni", emoji: "🎓", color: RGB(r: 1, g: 0, b: 0))
        let shown = lib.displaySpace(lib.spaces.first { $0.id == s.id }!, live: BrowserSnapshot())
        #expect(shown.title == "Uni" && shown.icon == .emoji("🎓") && shown.colors == [RGB(r: 1, g: 0, b: 0)])
    }

    @Test func activeSpaceAndOpenFoldersAreRemembered() {
        let d = freshDefaults()
        let file = sandbox().appendingPathComponent("library.json")
        let lib = Library(fileURL: file, defaults: d)
        let s = lib.addSpace(title: "A")
        lib.activeSpaceID = s.id
        lib.newFolder(in: s.id)
        let folder = lib.folders(in: s.id)[0].id // new folders start open
        lib.saveNow()
        let again = Library(fileURL: file, defaults: d)
        #expect(again.activeSpaceID == s.id)
        #expect(again.isOpen(folder))
    }
}

struct BookmarkImportTests {
    @Test func chromeBookmarksBarAndOtherBecomeFolders() throws {
        let json = """
        {"roots": {
          "bookmark_bar": {"name": "Bookmarks bar", "type": "folder", "children": [
            {"name": "Moodle", "type": "url", "url": "https://moodle.example"},
            {"name": "Empty", "type": "folder", "children": []},
            {"name": "Reading", "type": "folder", "children": [{"name": "Paper", "type": "url", "url": "https://paper.example"}]}]},
          "other": {"name": "Other bookmarks", "type": "folder", "children": []},
          "synced": {"name": "Mobile", "type": "folder", "children": [{"name": "X", "type": "url", "url": "https://x.example"}]}
        }}
        """
        let items = try #require(BookmarkImport.chrome(data: Data(json.utf8)))
        #expect(items.map(\.title) == ["Bookmarks bar"])
        #expect(items[0].children.map(\.title) == ["Moodle", "Reading"])
        #expect(items[0].children[1].children.map(\.url) == ["https://paper.example"])
    }

    @Test func notChromeBookmarksGiveNothing() {
        #expect(BookmarkImport.chrome(data: Data("[]".utf8)) == nil)
        #expect(BookmarkImport.chrome(data: Data("garbage".utf8)) == nil)
    }

    @Test func safariBookmarksSkipReadingListAndHistory() throws {
        let plist: [String: Any] = ["Children": [
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://a.example", "URIDictionary": ["title": "A"]],
            ]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://later.example", "URIDictionary": ["title": "Later"]],
            ]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksMenu", "Children": [] as [Any]],
            ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let items = try #require(BookmarkImport.safari(data: data))
        #expect(items.map(\.title) == ["Favorites Bar"])
        #expect(items[0].children.map(\.title) == ["A"])
    }

    @MainActor
    @Test func importedBookmarksGetASpaceOfTheirOwn() {
        let lib = Library(fileURL: sandbox().appendingPathComponent("library.json"), defaults: freshDefaults())
        lib.importBookmarks([.site("A", "https://a.example")], spaceTitle: "Chrome", emoji: "🔖")
        lib.importBookmarks([], spaceTitle: "Empty", emoji: "x")
        #expect(lib.spaces.map(\.title) == ["Chrome"])
        #expect(lib.spaces[0].pinned.map(\.url) == ["https://a.example"])
    }
}

@MainActor
struct PinnedTabsShowOnceTests {
    @Test func aTabOfAPinOrFavoriteIsNotListedAgain() {
        var s = LibrarySpace(title: "Uni")
        s.pinned = [.site("Moodle", "https://moodle.de/my/")]
        let live = BrowserSpace(id: s.id, title: "Uni", unpinned: [
            BrowserItem(id: "a", title: "Moodle", url: "https://moodle.de/my?lang=de", kind: .tab),
            BrowserItem(id: "b", title: "My Drive", url: "https://drive.google.com/drive/my-drive?hl=DE", kind: .tab),
            BrowserItem(id: "c", title: "SYCK", url: "https://drive.google.com/drive/folders/1o4", kind: .tab),
        ])
        var snap = BrowserSnapshot()
        snap.spaces = [live]
        let tabs = Library.todayTabs(for: s, live: snap, source: .sameSpaces, activeSpaceID: nil,
                                     favorites: ["https://drive.google.com/drive/my-drive"])
        #expect(tabs.map(\.id) == ["c"])
        #expect(Library.samePage("https://x.de/a/", "https://x.de/a#top"))
        #expect(!Library.samePage("https://x.de/a", "https://x.de/b"))
    }
}
