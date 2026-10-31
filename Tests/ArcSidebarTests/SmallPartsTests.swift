import AppKit
import Testing
@testable import ArcSidebar

struct BadgeTests {
    @Test func countsInTitles() {
        #expect(Badges.count(inTitle: "(3) Gmail") == "3")
        #expect(Badges.count(inTitle: "Inbox (12) – bennet@example.com") == "12")
        #expect(Badges.count(inTitle: "WhatsApp (99+)") == "99+")
    }

    @Test func noOrZeroCountIsNoBadge() {
        #expect(Badges.count(inTitle: "Gmail") == nil)
        #expect(Badges.count(inTitle: "(0) Gmail") == nil)
        #expect(Badges.count(inTitle: "Chapter (two)") == nil)
        #expect(Badges.count(inTitle: "Year (20245)") == nil)
    }
}

struct ArcThemeTests {
    private func space(_ extra: String) -> String {
        arcSample.replacingOccurrences(of: #""customInfo": {"iconType": {"emoji_v2": "🎓"}}"#, with: extra)
    }

    private func firstSpace(_ json: String) throws -> ArcTree.Space {
        try #require(ArcSidebarFile.parse(Data(json.utf8))?.spaces.first)
    }

    @Test func iconsFromEmojiCodesAndArcSymbols() throws {
        #expect(try firstSpace(space(#""customInfo": {"iconType": {"emoji": 128512}}"#)).icon == .emoji("😀"))
        #expect(try firstSpace(space(#""customInfo": {"iconType": {"icon": "flash"}}"#)).icon == .symbol("bolt.fill"))
        #expect(try firstSpace(space(#""customInfo": {"iconType": {"icon": "unknown-new-icon"}}"#)).icon == .symbol("circle.fill"))
        #expect(try firstSpace(space(#""customInfo": {}"#)).icon == nil)
    }

    @Test func singleColorWithGrain() throws {
        let theme = #""customInfo": {"windowTheme": {"background": {"single": {"_0": {"style": {"color": {"_0": {"blendedSingleColor": {"_0": {"color": {"red": 0.5, "green": 1.4, "blue": -0.2}, "modifiers": {"noiseFactor": 0.7}}}}}}}}}}}"#
        let s = try firstSpace(space(theme))
        #expect(s.colors == [RGB(r: 0.5, g: 1, b: 0)])
        #expect(s.noise == 0.7)
    }

    @Test func gradientColors() throws {
        let theme = #""customInfo": {"windowTheme": {"background": {"single": {"_0": {"style": {"color": {"_0": {"blendedGradient": {"_0": {"baseColors": [{"red": 1, "green": 0, "blue": 0}, {"red": 0, "green": 0, "blue": 1}, "junk"]}}}}}}}}}}"#
        let s = try firstSpace(space(theme))
        #expect(s.colors == [RGB(r: 1, g: 0, b: 0), RGB(r: 0, g: 0, b: 1)])
        #expect(s.noise == nil)
    }

    @Test func favoritesPerProfile() throws {
        let json = arcSample.replacingOccurrences(of: #""topAppsContainerIDs": [{"default": true}, "c-fav"]"#,
            with: #""topAppsContainerIDs": [{"default": true}, "c-fav", {"custom": {"_0": {"directoryBasename": "Profile 2"}}}, "c-fav2"]"#)
        let tree = try #require(ArcSidebarFile.parse(Data(json.utf8)))
        #expect(tree.favoritesContainer(forProfile: "Profile 2") == "c-fav2")
        #expect(tree.favoritesContainer(forProfile: nil) == "c-fav")
        #expect(tree.favoritesContainer(forProfile: "Gone") == "c-fav")
    }

    @Test func splitViewsAreKept() throws {
        let json = arcSample.replacingOccurrences(of: #""childrenIds": ["t1", "f1"]"#, with: #""childrenIds": ["t1", "f1", "sv"]"#)
            .replacingOccurrences(of: #"{"id": "c-unpin""#, with: #"{"id": "sv", "data": {"splitView": {}}, "childrenIds": ["t2", "t3"]}, {"id": "c-unpin""#)
        let tree = try #require(ArcSidebarFile.parse(Data(json.utf8)))
        #expect(tree.items["sv"]?.kind == .split)
        #expect(tree.items["sv"]?.children == ["t2", "t3"])
    }
}

struct DownloadItemTests {
    @Test func partialDownloadsAreInProgress() {
        for name in ["a.pdf.crdownload", "b.zip.download", "c.iso.part", "D.CRDOWNLOAD"] {
            #expect(DownloadItem(url: URL(fileURLWithPath: "/tmp/" + name), added: .now).isInProgress, "\(name)")
        }
        #expect(!DownloadItem(url: URL(fileURLWithPath: "/tmp/a.pdf"), added: .now).isInProgress)
        #expect(DownloadItem(url: URL(fileURLWithPath: "/tmp/a.pdf"), added: .now, downloading: true).isInProgress)
    }
}

struct SnapshotTests {
    private func tab(_ id: String) -> BrowserItem { BrowserItem(id: id, title: id, url: "https://\(id).example", kind: .tab) }

    @Test func removingTabsLeavesPinnedAndUnwrapsSplits() {
        var space = BrowserSpace(id: "s", title: "S")
        space.pinned = [tab("p")]
        space.unpinned = [tab("a"), BrowserItem(id: "sv", title: "", url: "", kind: .split, children: [tab("b"), tab("c")]),
                          BrowserItem(id: "f", title: "F", url: "", kind: .folder, children: [tab("d")])]
        var snap = BrowserSnapshot(spaces: [space], otherTabs: [tab("o")])
        snap.removeTabs(["p", "a", "b", "d", "o"])
        #expect(snap.spaces[0].pinned.map(\.id) == ["p"])
        #expect(snap.spaces[0].unpinned.map(\.id) == ["c", "f"])
        #expect(snap.spaces[0].unpinned[1].children.isEmpty)
        #expect(snap.otherTabs.isEmpty)
    }

    @Test func findingTabsEverywhere() {
        var space = BrowserSpace(id: "s", title: "S")
        space.unpinned = [BrowserItem(id: "f", title: "F", url: "", kind: .folder, children: [tab("deep")])]
        let snap = BrowserSnapshot(favorites: [tab("fav")], spaces: [space], otherTabs: [tab("other")])
        #expect(snap.tab(id: "deep")?.title == "deep")
        #expect(snap.tab(id: "fav") != nil && snap.tab(id: "other") != nil)
        #expect(snap.tab(id: "f") == nil)
        #expect(snap.tab(id: "nope") == nil)
    }

    @Test func activeSpaceFallsBackToTheFirst() {
        let snap = BrowserSnapshot(spaces: [BrowserSpace(id: "a", title: "A"), BrowserSpace(id: "b", title: "B")], activeSpaceID: "gone")
        #expect(snap.activeSpace?.id == "a")
        #expect(BrowserSnapshot(spaces: [BrowserSpace(id: "a", title: "A"), BrowserSpace(id: "b", title: "B")], activeSpaceID: "b").activeSpace?.id == "b")
    }

    @Test func itemHosts() {
        #expect(tab("x").host == "x.example")
        #expect(BrowserItem(id: "1", title: "", url: "not a url", kind: .tab).host == nil)
    }
}

@MainActor
struct PasteTests {
    @Test func commandVPastesWithoutFormattingWhereThatExists() {
        #expect(Paste.action(plain: true) { _ in true } == Paste.plainAction)
        #expect(Paste.action(plain: false) { _ in true } == Paste.formattedAction)
    }

    @Test func fieldsWithoutPlainPasteGetTheNormalOne() {
        #expect(Paste.action(plain: true) { $0 != Paste.plainAction } == Paste.formattedAction)
    }

    @Test func theEditMenuHasTheSwappedShortcuts() {
        let app = NSApplication.shared
        MainMenu.install()
        let edit = app.mainMenu?.items.first { $0.title == "Edit" }?.submenu
        let plain = edit?.items.first { $0.title == "Paste and Match Style" }
        let paste = edit?.items.first { $0.title == "Paste" }
        #expect(plain?.keyEquivalent == "v" && plain?.keyEquivalentModifierMask == NSEvent.ModifierFlags.command)
        #expect(paste?.keyEquivalent == "v" && paste?.keyEquivalentModifierMask == [.command, .shift])
    }
}
