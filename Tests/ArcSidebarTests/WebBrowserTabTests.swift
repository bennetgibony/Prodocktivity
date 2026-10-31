import Foundation
import Testing
@testable import ArcSidebar

@MainActor
struct WebBrowserTabTests {
    private func browser(_ state: URL = sandbox().appendingPathComponent("tabs.json")) -> WebBrowser {
        let web = WebBrowser(stateURL: state, showsWindows: false)
        // What Freeze does when the frozen tab goes away.
        web.onFrozenTabGone = { [weak web] in web?.unfreeze() }
        return web
    }

    /// Opens tabs in `space` and shows the first, like clicking it in the bar; returns their ids.
    @discardableResult
    private func open(_ hosts: [String], in space: String, on web: WebBrowser) -> [String] {
        let ids = hosts.map { web.newTab(url: "https://\($0).example", inSpace: space, show: false).id }
        if let first = ids.first { web.select(tabID: first) }
        return ids
    }

    private func hosts(_ web: WebBrowser, space: String? = nil) -> [String] {
        web.tabs.filter { space == nil || $0.spaceID == space }.map { URL(string: $0.url)?.host?.replacingOccurrences(of: ".example", with: "") ?? "?" }
    }

    private func active(_ web: WebBrowser) -> String? {
        web.activeTab.flatMap { URL(string: $0.url)?.host?.replacingOccurrences(of: ".example", with: "") }
    }

    @Test func newTabsGoRightAfterTheCurrentOne() {
        let web = browser()
        open(["a", "b", "c"], in: "s", on: web)
        web.newTab(url: "https://new.example", inSpace: "s")
        #expect(hosts(web) == ["a", "new", "b", "c"])
        #expect(active(web) == "new")
    }

    @Test func closingTheShownTabShowsTheNextOneElseThePreviousOne() {
        let web = browser()
        let ids = open(["a", "b", "c"], in: "s", on: web)
        web.select(tabID: ids[1])
        web.close(tabID: ids[1])
        #expect(active(web) == "c")
        web.close(tabID: ids[2])
        #expect(active(web) == "a")
        web.close(tabID: ids[0])
        #expect(web.activeTab == nil)
    }

    @Test func closingATabInTheBackgroundKeepsTheShownOne() {
        let web = browser()
        let ids = open(["a", "b", "c"], in: "s", on: web)
        web.close(tabID: ids[2])
        #expect(active(web) == "a")
    }

    @Test func closingOnlyLooksForANeighbourInTheSameSpace() {
        let web = browser()
        let mine = open(["a"], in: "s1", on: web)
        open(["other"], in: "s2", on: web)
        web.select(tabID: mine[0])
        web.newTab(url: "https://b.example", inSpace: "s1")
        web.close(tabID: web.activeTab!.id)
        #expect(active(web) == "a")
        web.close(tabID: mine[0])
        #expect(web.activeTab == nil)
    }

    @Test func closingTheShownTabNeverShowsTheFrozenOneInstead() {
        // The frozen tab's page would move out of its own window into the main one, leaving the
        // frozen half of the screen blank.
        let web = browser()
        let ids = open(["a", "frozen", "c"], in: "s", on: web)
        web.freeze(tabID: ids[1], frame: .zero)
        web.select(tabID: ids[0])
        web.close(tabID: ids[0])
        #expect(active(web) == "c")
        web.close(tabID: ids[2])
        #expect(web.activeTab == nil)
        #expect(web.frozenTabID == ids[1])
    }

    @Test func freezingTheShownTabShowsTheOneBeforeItElseTheNextOne() {
        let web = browser()
        let ids = open(["a", "b", "c"], in: "s", on: web)
        web.select(tabID: ids[1])
        web.freeze(tabID: ids[1], frame: .zero)
        #expect(active(web) == "a")
        web.unfreeze()
        web.select(tabID: ids[0])
        web.freeze(tabID: ids[0], frame: .zero)
        #expect(active(web) == "b")
    }

    @Test func closingTheFrozenTabEndsTheFreeze() {
        let web = browser()
        let ids = open(["a", "b"], in: "s", on: web)
        web.freeze(tabID: ids[1], frame: .zero)
        web.close(tabID: ids[1])
        #expect(web.frozenTabID == nil)
        #expect(active(web) == "a")
    }

    @Test func movingTheTabsOfARemovedSpaceEndsAFreezeOfOneOfThem() {
        let web = browser()
        let ids = open(["a", "b"], in: "old", on: web)
        web.freeze(tabID: ids[1], frame: .zero)
        web.moveTabs(fromSpace: "old", to: "new")
        #expect(web.frozenTabID == nil)
        #expect(web.tabs.allSatisfy { $0.spaceID == "new" })
    }

    @Test func aSplitEndsWhenItsLeftTabIsClosedOrComesBack() {
        let web = browser()
        let ids = open(["left", "right", "c"], in: "s", on: web)
        web.select(tabID: ids[1])
        #expect(web.splitWithPrevious(left: .zero, right: .zero))
        #expect(web.splitTabID == ids[0])
        web.close(tabID: ids[0])
        #expect(web.splitTabID == nil)
        #expect(active(web) == "right")

        // Closing the right side brings the left one back into the main window.
        let more = open(["l2", "r2"], in: "t", on: web)
        web.select(tabID: more[1])
        web.splitWithPrevious(left: .zero, right: .zero)
        web.close(tabID: more[1])
        #expect(web.splitTabID == nil)
        #expect(active(web) == "l2")
    }

    @Test func thereIsNothingToSplitWithoutAnEarlierTab() {
        let web = browser()
        open(["only"], in: "s", on: web)
        #expect(!web.splitWithPrevious(left: .zero, right: .zero))
    }

    @Test func ctrlTabGoesRoundTheSpacesTabs() {
        let web = browser()
        open(["a", "b", "c"], in: "s", on: web)
        open(["elsewhere"], in: "t", on: web)
        web.focus(spaceID: "s")
        web.selectAdjacentTab(-1)
        #expect(active(web) == "c")
        web.selectAdjacentTab(1)
        #expect(active(web) == "a")
        web.selectAdjacentTab(1)
        #expect(active(web) == "b")
    }

    @Test func commandNumberPicksThatTabAndNineTheLast() {
        let web = browser()
        open(["a", "b", "c"], in: "s", on: web)
        web.selectTab(number: 2)
        #expect(active(web) == "b")
        web.selectTab(number: 9)
        #expect(active(web) == "c")
        web.selectTab(number: 7)
        #expect(active(web) == "c")
    }

    @Test func reopeningBringsBackTheLastClosedTabInItsSpaceWithItsTitle() {
        let web = browser()
        let ids = open(["a", "b"], in: "s", on: web)
        web.tabs[1].title = "Bee"
        web.close(tabID: ids[1])
        open(["x"], in: "t", on: web)
        web.reopenClosedTab()
        #expect(web.activeTab?.spaceID == "s")
        #expect(web.activeTab?.title == "Bee")
        #expect(!web.canReopenClosedTab)
    }

    @Test func onlyTheLast25ClosedTabsAreKept() {
        let web = browser()
        let ids = open((0..<30).map { "t\($0)" }, in: "s", on: web)
        ids.forEach(web.close)
        var back: [String] = []
        while web.canReopenClosedTab {
            web.reopenClosedTab()
            back.append(active(web) ?? "?")
        }
        #expect(back.count == WebBrowser.closedTabsKept)
        #expect(back.first == "t29" && back.last == "t5")
    }

    @Test func tabsTheShownTabsAndTheSpaceComeBackAfterARestart() {
        let state = sandbox().appendingPathComponent("tabs.json")
        let web = browser(state)
        let ids = open(["a", "b"], in: "s1", on: web)
        open(["c"], in: "s2", on: web)
        web.select(tabID: ids[1])
        web.tabs[0].title = "Ay"
        web.saveNow()

        let again = browser(state)
        #expect(again.tabs.map(\.id) == web.tabs.map(\.id))
        #expect(again.tabs[0].title == "Ay")
        #expect(again.activeSpaceID == "s1")
        #expect(again.activeTab?.id == ids[1])
        again.focus(spaceID: "s2")
        #expect(active(again) == "c")
        // Restored tabs stay cheap: no page is loaded until one is shown.
        #expect(again.tabs.allSatisfy { $0.webView == nil })
    }

    @Test func snapshotGroupsTabsBySpaceInOrder() {
        let web = browser()
        web.newTab(url: "https://a.example", inSpace: "s1", show: false)
        web.newTab(url: "https://b.example", inSpace: "s2", show: false)
        web.newTab(url: "https://c.example", inSpace: "s1", show: false)
        let snap = web.snapshot()
        #expect(snap.spaces.map(\.id) == ["s1", "s2"])
        #expect(snap.spaces[0].unpinned.map(\.url) == ["https://a.example", "https://c.example"])
    }

    @Test func untitledTabsShowTheirHost() {
        let web = browser()
        web.newTab(url: "https://untitled.example/page", inSpace: "s", show: false)
        #expect(web.snapshot().spaces[0].unpinned[0].title == "untitled.example")
    }

    @Test func theActiveSpaceIsListedEvenWithoutTabs() {
        let web = browser()
        web.newTab(url: "https://a.example", inSpace: "s1", show: false)
        web.focus(spaceID: "empty")
        let snap = web.snapshot()
        #expect(snap.activeSpaceID == "empty")
        #expect(snap.spaces.map(\.id) == ["s1", "empty"])
        #expect(snap.activeTabID == nil)
    }

    @Test func blankTabsAreNotRememberedForReopening() {
        let web = browser()
        let blank = web.newTab(url: "about:blank", inSpace: "s", show: false)
        web.close(tabID: blank.id)
        #expect(!web.canReopenClosedTab)
    }

    @Test func closingAnUnknownTabDoesNothing() {
        let web = browser()
        web.newTab(url: "https://a.example", inSpace: "s", show: false)
        web.close(tabID: "nope")
        #expect(web.tabs.count == 1)
    }

    @Test func movingTabsToTheSameSpaceOrFromAnEmptyOneDoesNothing() {
        let web = browser()
        let a = web.newTab(url: "https://a.example", inSpace: "s", show: false)
        web.moveTabs(fromSpace: "s", to: "s")
        web.moveTabs(fromSpace: "none", to: "s")
        #expect(web.tabs.map(\.id) == [a.id])
    }

    @Test func movedTabsKeepTheirIdAndTitleButLoadAgain() {
        let web = browser()
        let a = web.newTab(url: "https://a.example", inSpace: "old", show: false)
        a.title = "A"
        web.moveTabs(fromSpace: "old", to: "new")
        #expect(web.tabs[0].id == a.id && web.tabs[0].title == "A" && web.tabs[0].spaceID == "new")
        #expect(web.tabs[0].webView == nil)
    }
}

@MainActor
struct SiteZoomTests {
    @Test func zoomIsPerSiteIgnoringWww() {
        let url = URL(string: "https://www.zoomtest-\(UUID().uuidString.prefix(6)).example/a")!
        #expect(SiteZoom.zoom(for: url) == 1)
        SiteZoom.set(1.3, for: url)
        let other = URL(string: "https://\(url.host!.dropFirst(4))/b")!
        #expect(abs(SiteZoom.zoom(for: other) - 1.3) < 0.001)
        SiteZoom.set(1.0, for: url)
        #expect(SiteZoom.zoom(for: url) == 1)
        #expect(SiteZoom.zoom(for: nil) == 1)
    }
}
