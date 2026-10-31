import Foundation
import Testing
@testable import ArcSidebar

/// A script answer as the AppleScript builds it: records split by \u{1E}, fields by \u{1F}.
func scriptAnswer(_ records: [String]...) -> String {
    records.map { $0.joined(separator: "\u{1F}") + "\u{1E}" }.joined()
}

struct ChromeParsingTests {
    @Test func readsActiveTabAndAllTabsInOrder() {
        let snap = ChromeProvider.snapshot(from: scriptAnswer(
            ["A", "12"], ["T", "11", "Mail", "https://mail.example"], ["T", "12", "Docs", "https://docs.example"]))
        #expect(snap.activeTabID == "12")
        #expect(snap.activeSpaceID == ChromeProvider.spaceID)
        #expect(snap.spaces.count == 1)
        #expect(snap.spaces[0].unpinned.map(\.title) == ["Mail", "Docs"])
        #expect(snap.spaces[0].unpinned.map(\.url) == ["https://mail.example", "https://docs.example"])
    }

    @Test func noWindowsGivesAnEmptySpace() {
        let snap = ChromeProvider.snapshot(from: "")
        #expect(snap.activeTabID == nil)
        #expect(snap.spaces.map(\.unpinned.isEmpty) == [true])
    }

    @Test func titlesWithSeparatorsLikeCharactersAndEmptyFieldsSurvive() {
        let snap = ChromeProvider.snapshot(from: scriptAnswer(["T", "1", "", "about:blank"], ["T", "2", "A | B — ü", "https://x.example/?a=1&b=2"]))
        #expect(snap.spaces[0].unpinned.map(\.title) == ["", "A | B — ü"])
        #expect(snap.spaces[0].unpinned[1].url == "https://x.example/?a=1&b=2")
    }

    @Test func brokenAndUnknownRecordsAreSkipped() {
        let snap = ChromeProvider.snapshot(from: scriptAnswer(["T", "1", "short"], ["X", "whatever"], ["A"], ["T", "2", "Ok", "https://ok.example"]))
        #expect(snap.spaces[0].unpinned.map(\.id) == ["2"])
        #expect(snap.activeTabID == nil)
    }
}

struct ArcParsingTests {
    private var tree: ArcTree { ArcSidebarFile.parse(Data(arcSample.utf8))! }

    @Test func withoutTheSidebarFileTabsAreSortedByLocation() {
        let snap = ArcProvider().snapshot(from: scriptAnswer(
            ["A", "t2", "sp1"], ["S", "sp1", "Uni"],
            ["T", "t1", "Moodle", "https://moodle.example", "pinned"],
            ["T", "t2", "News", "https://news.example", "unpinned"],
            ["T", "t3", "Gmail", "https://mail.google.com", "topApp"],
            ["W", "t4", "Loose", "https://loose.example", "unpinned"]), tree: nil, full: true)
        #expect(snap.activeTabID == "t2" && snap.activeSpaceID == "sp1")
        #expect(snap.favorites.map(\.id) == ["t3"])
        #expect(snap.spaces.map(\.title) == ["Uni"])
        #expect(snap.spaces[0].pinned.map(\.id) == ["t1"])
        #expect(snap.spaces[0].unpinned.map(\.id) == ["t2"])
        #expect(snap.otherTabs.map(\.id) == ["t4"])
    }

    @Test func aTabListedInTwoSpacesShowsOnceWithoutTheSidebarFile() {
        let snap = ArcProvider().snapshot(from: scriptAnswer(
            ["S", "a", "A"], ["T", "t1", "X", "https://x.example", "unpinned"],
            ["S", "b", "B"], ["T", "t1", "X", "https://x.example", "unpinned"]), tree: nil, full: true)
        #expect(snap.spaces.flatMap(\.unpinned).map(\.id) == ["t1"])
    }

    @Test func tabsBeforeAnySpaceAreIgnored() {
        let snap = ArcProvider().snapshot(from: scriptAnswer(["T", "t1", "X", "https://x.example", "unpinned"]), tree: nil, full: true)
        #expect(snap.spaces.isEmpty && snap.otherTabs.isEmpty)
    }

    @Test func theSidebarFileGivesStructureAndLiveTitlesWin() {
        let snap = ArcProvider().snapshot(from: scriptAnswer(
            ["A", "t1", "sp1"], ["S", "sp1", "Uni"],
            ["T", "t1", "Moodle – Dashboard", "https://moodle.example/my", "pinned"]), tree: tree, full: true)
        let space = snap.spaces[0]
        #expect(space.title == "Uni" && space.icon == .emoji("🎓"))
        #expect(space.pinned.map(\.title) == ["Moodle – Dashboard", "Reading"])
        #expect(space.pinned[0].url == "https://moodle.example/my")
        // Custom names from Arc beat live titles; saved ones fill in for tabs that aren't loaded.
        #expect(space.pinned[1].kind == .folder)
        #expect(space.pinned[1].children.map(\.title) == ["My Paper"])
        #expect(snap.favorites.map(\.url) == ["https://mail.google.com"])
    }

    @Test func newTabsNotYetInTheSidebarFileGoToTheActiveSpace() {
        let arc = ArcProvider()
        let snap = arc.snapshot(from: scriptAnswer(
            ["A", "new", "sp1"], ["W", "new", "Fresh", "https://fresh.example", "unpinned"]), tree: tree, full: false)
        #expect(snap.spaces[0].unpinned.map(\.id) == ["new"])
        // ...and the next fetch reads every space to confirm where it belongs.
        #expect(arc.fullFetchDue)
    }

    @Test func aNewFavoriteGoesToFavorites() {
        let snap = ArcProvider().snapshot(from: scriptAnswer(
            ["A", "", "sp1"], ["W", "fav", "Cal", "https://cal.example", "topApp"]), tree: tree, full: false)
        #expect(snap.favorites.map(\.id).contains("fav"))
        #expect(snap.spaces[0].unpinned.isEmpty)
    }

    @Test func unpinnedTabsArcNoLongerReportsAreDropped() {
        // The sidebar file still lists an unpinned tab that Arc doesn't report as open.
        let withUnpinned = arcSample
            .replacingOccurrences(of: #"{"id": "c-unpin", "data": {"itemContainer": {}}, "childrenIds": []}"#,
                                  with: #"{"id": "c-unpin", "data": {"itemContainer": {}}, "childrenIds": ["u1", "u2"]}, {"id": "u1", "data": {"tab": {"savedTitle": "Old", "savedURL": "https://old.example"}}}, {"id": "u2", "data": {"tab": {"savedTitle": "Open", "savedURL": "https://open.example"}}}"#)
        let tree = ArcSidebarFile.parse(Data(withUnpinned.utf8))!
        let snap = ArcProvider().snapshot(from: scriptAnswer(
            ["A", "u2", "sp1"], ["S", "sp1", "Uni"], ["T", "u2", "Open", "https://open.example", "unpinned"]), tree: tree, full: true)
        #expect(snap.spaces[0].unpinned.map(\.id) == ["u2"])
        // Pinned tabs stay even when they're not loaded.
        #expect(snap.spaces[0].pinned.map(\.id) == ["t1", "f1"])
    }

    @Test func aTabPlacedByAFullFetchKeepsItsSpaceWhenArcForgetsIt() {
        let twoSpaces = arcSample.replacingOccurrences(of: #""spaces": ["sp1", "#, with: #""spaces": ["sp1", {"id": "sp2", "title": "Work", "containerIDs": []}, "#)
        let tree = ArcSidebarFile.parse(Data(twoSpaces.utf8))!
        let arc = ArcProvider()
        _ = arc.snapshot(from: scriptAnswer(["A", "", "sp1"], ["S", "sp1", "Uni"], ["S", "sp2", "Work"],
                                            ["T", "n", "New", "https://n.example", "unpinned"]), tree: tree, full: true)
        // Next full fetch: Arc lists the tab in no space, but it's still open in the window.
        let snap = arc.snapshot(from: scriptAnswer(["A", "", "sp1"], ["S", "sp1", "Uni"], ["S", "sp2", "Work"],
                                                   ["W", "n", "New", "https://n.example", "unpinned"]), tree: tree, full: true)
        #expect(snap.spaces.first { $0.id == "sp2" }?.unpinned.map(\.id) == ["n"])
    }

    @Test func emptyAnswerGivesNoActiveTab() {
        let snap = ArcProvider().snapshot(from: "", tree: tree, full: true)
        #expect(snap.activeTabID == nil)
        #expect(snap.spaces.count == 1)
    }
}
