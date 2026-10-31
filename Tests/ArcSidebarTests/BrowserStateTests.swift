import Foundation
import Testing
@testable import ArcSidebar

@MainActor
struct BrowserStateTests {
    @Test func tabsAreSavedAndRestoredPerSpace() throws {
        let file = sandbox().appendingPathComponent("browser-tabs.json")
        let web = WebBrowser(stateURL: file)
        web.newTab(url: "https://a.example", inSpace: "s1", show: false)
        web.newTab(url: "https://b.example", inSpace: "s1", show: false)
        web.newTab(url: "https://c.example", inSpace: "s2", show: false)
        web.saveNow()

        let restored = WebBrowser(stateURL: file)
        #expect(restored.tabs.map(\.url) == ["https://a.example", "https://b.example", "https://c.example"])
        #expect(restored.tabs.map(\.spaceID) == ["s1", "s1", "s2"])
        #expect(restored.tabs.allSatisfy { $0.webView == nil })
    }

    @Test func closedTabsCanBeReopenedNewestFirst() {
        let web = WebBrowser(stateURL: sandbox().appendingPathComponent("t.json"))
        let a = web.newTab(url: "https://a.example", inSpace: "s", show: false)
        let b = web.newTab(url: "https://b.example", inSpace: "s", show: false)
        #expect(!web.canReopenClosedTab)
        web.close(tabID: a.id)
        web.close(tabID: b.id)
        #expect(web.tabs.isEmpty && web.canReopenClosedTab)
    }

    @Test func aDamagedStateFileStartsEmptyWithoutCrashing() throws {
        let file = sandbox().appendingPathComponent("browser-tabs.json")
        try Data("{ not json".utf8).write(to: file)
        #expect(WebBrowser(stateURL: file).tabs.isEmpty)
    }
}

@MainActor
struct ErrorPageTests {
    @Test func messagesAndAddressesAreEscaped() {
        let html = WebBrowser.errorPage("<script>alert(1)</script>", url: URL(string: "https://x.example/?q=%22%3E%3Cb%3E"))
        #expect(!html.contains("<script>alert"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("Try Again"))
    }

    @Test func aPageWithoutAddressStillRenders() {
        #expect(WebBrowser.errorPage("Offline", url: nil).contains("Offline"))
    }
}

@MainActor
struct SpaceTabTests {
    @Test func tabsOfADeletedSpaceMoveInsteadOfVanishing() {
        let web = WebBrowser(stateURL: sandbox().appendingPathComponent("t.json"))
        let a = web.newTab(url: "https://a.example", inSpace: "old", show: false)
        web.newTab(url: "https://b.example", inSpace: "keep", show: false)
        web.moveTabs(fromSpace: "old", to: "keep")
        #expect(web.tabs.map(\.spaceID) == ["keep", "keep"])
        #expect(web.tabs.first?.id == a.id)
    }

    @Test func orphanTabsAreAdopted() {
        let web = WebBrowser(stateURL: sandbox().appendingPathComponent("t.json"))
        web.newTab(url: "https://a.example", inSpace: "gone", show: false)
        web.newTab(url: "https://b.example", inSpace: "home", show: false)
        web.adoptOrphanTabs(validSpaces: ["home"], into: "home")
        #expect(Set(web.tabs.map(\.spaceID)) == ["home"])
    }

    @Test func deletingASpaceTellsWhereToGo() throws {
        let lib = Library(fileURL: sandbox().appendingPathComponent("library.json"), defaults: freshDefaults())
        let a = lib.addSpace(title: "A"), b = lib.addSpace(title: "B")
        lib.activeSpaceID = b.id
        var got: (String, String?)?
        lib.onSpaceDeleted = { got = ($0, $1) }
        lib.deleteSpace(b.id)
        #expect(got?.0 == b.id && got?.1 == a.id)
    }
}
