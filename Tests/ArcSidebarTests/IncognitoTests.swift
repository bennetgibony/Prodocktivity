import Foundation
import Testing
@testable import ArcSidebar

@MainActor
struct IncognitoTests {
    private func browser(_ state: URL = sandbox().appendingPathComponent("tabs.json")) -> WebBrowser {
        WebBrowser(stateURL: state, showsWindows: false)
    }

    @Test func privateTabsAreNeverSavedAndAShownOneLeavesNothingBehind() {
        let state = sandbox().appendingPathComponent("tabs.json")
        let web = browser(state)
        web.newTab(url: "https://a.example", inSpace: "s")
        let secret = web.newTab(url: "https://secret.example", inSpace: "s", incognito: true)
        #expect(web.activeTab?.id == secret.id)
        web.saveNow()
        let again = browser(state)
        #expect(again.tabs.map(\.url) == ["https://a.example"])
        #expect(again.activeTab == nil)
    }

    @Test func closedPrivateTabsCannotBeReopened() {
        let web = browser()
        let tab = web.newTab(url: "https://secret.example", inSpace: "s", incognito: true)
        web.close(tabID: tab.id)
        #expect(!web.canReopenClosedTab)
    }

    @Test func privateTabsAreMarkedInTheSidebarAndShareOneStoreUntilTheLastCloses() {
        let web = browser()
        let normal = web.newTab(url: "https://a.example", inSpace: "s")
        let p1 = web.newTab(url: "https://p1.example", inSpace: "s", incognito: true)
        let p2 = web.newTab(url: "https://p2.example", inSpace: "s", incognito: true)
        let items = web.snapshot().spaces.first?.unpinned ?? []
        #expect(items.first { $0.id == normal.id }?.isIncognito == false)
        #expect(items.first { $0.id == p1.id }?.isIncognito == true)
        let store = web.configuration(forSpace: "s", incognito: true).websiteDataStore
        #expect(store === web.configuration(forSpace: "s", incognito: true).websiteDataStore)
        #expect(!store.isPersistent)
        web.close(tabID: p1.id)
        #expect(store === web.configuration(forSpace: "s", incognito: true).websiteDataStore)
        web.close(tabID: p2.id)
        #expect(!web.hasIncognitoTabs)
        #expect(store !== web.configuration(forSpace: "s", incognito: true).websiteDataStore)
    }

    @Test func movingTabsToAnotherSpaceKeepsThemPrivate() {
        let web = browser()
        let tab = web.newTab(url: "https://p.example", inSpace: "old", incognito: true)
        web.moveTabs(fromSpace: "old", to: "new")
        #expect(web.tabs.first { $0.id == tab.id }?.isIncognito == true)
    }
}
