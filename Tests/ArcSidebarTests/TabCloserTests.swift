import Foundation
import Testing
@testable import ArcSidebar

@MainActor
struct TabCloserTests {
    private func tab(_ id: String, _ url: String = "https://example.com") -> BrowserItem {
        BrowserItem(id: id, title: id, url: url, kind: .tab)
    }

    private func closer(minutes: Int = 60) -> TabCloser {
        let c = TabCloser(defaults: freshDefaults())
        c.minutes = minutes
        return c
    }

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    @Test func offByDefaultWithTwelveHours() {
        let c = TabCloser(defaults: freshDefaults())
        #expect(!c.enabled && c.minutes == 720)
    }

    @Test func favoritesTabsKeepUnlessTheyHaveATime() {
        let c = closer()
        c.setLastSeen("f", ago(120))
        let fav = tab("f", "https://fav.example")
        #expect(c.dueTabs([(fav, nil)], onScreen: [], pinnedURLs: [], favoriteURLs: ["https://fav.example"], now: now).isEmpty)
        c.favoritesMinutes = 60
        #expect(c.dueTabs([(fav, nil)], onScreen: [], pinnedURLs: [], favoriteURLs: ["https://fav.example"], now: now).first?.limit == 60)
    }

    @Test func aTabUnseenLongerThanTheLimitIsDue() {
        let c = closer()
        c.setLastSeen("old", ago(61)); c.setLastSeen("new", ago(59))
        let due = c.dueTabs([(tab("old"), nil), (tab("new"), nil)], onScreen: [], pinnedURLs: [], now: now)
        #expect(due.map(\.tab.id) == ["old"])
        #expect(due.first?.limit == 60)
    }

    @Test func exactlyAtTheLimitCounts() {
        let c = closer()
        c.setLastSeen("t", ago(60))
        #expect(c.dueTabs([(tab("t"), nil)], onScreen: [], pinnedURLs: [], now: now).count == 1)
    }

    @Test func tabsOnScreenAreNeverClosed() {
        let c = closer()
        c.setLastSeen("t", ago(1000))
        #expect(c.dueTabs([(tab("t"), nil)], onScreen: ["t"], pinnedURLs: [], now: now).isEmpty)
    }

    @Test func pinnedAddressesAreNeverClosed() {
        let c = closer()
        c.setLastSeen("t", ago(1000))
        #expect(c.dueTabs([(tab("t", "https://pinned.example"), nil)], onScreen: [], pinnedURLs: ["https://pinned.example"], now: now).isEmpty)
    }

    @Test func aTabNeverSeenIsNotDue() {
        #expect(closer().dueTabs([(tab("t"), nil)], onScreen: [], pinnedURLs: [], now: now).isEmpty)
    }

    @Test func aSpaceRuleOverridesTheDefault() {
        let c = closer()
        c.spaceRules = ["uni": 240, "keep": 0]
        c.setLastSeen("a", ago(120)); c.setLastSeen("b", ago(120)); c.setLastSeen("c", ago(10_000))
        let due = c.dueTabs([(tab("a"), "uni"), (tab("b"), nil), (tab("c"), "keep")], onScreen: [], pinnedURLs: [], now: now)
        #expect(due.map(\.tab.id) == ["b"])
    }

    @Test func aSiteExceptionWinsOverTheSpaceRuleAlsoForSubdomains() {
        let c = closer()
        c.spaceRules = ["uni": 30]
        c.siteRules = ["google.com": 0, "news.example": 10]
        c.setLastSeen("mail", ago(500)); c.setLastSeen("news", ago(15))
        let due = c.dueTabs([(tab("mail", "https://mail.google.com/u/0"), "uni"), (tab("news", "https://www.news.example/a"), "uni")],
                            onScreen: [], pinnedURLs: [], now: now)
        #expect(due.map(\.tab.id) == ["news"])
        #expect(due.first?.limit == 10)
    }

    @Test func siteRuleMatching() {
        let c = closer()
        c.siteRules = ["google.com": 0]
        #expect(c.siteRule(for: "https://docs.google.com/x") == 0)
        #expect(c.siteRule(for: "https://google.com") == 0)
        #expect(c.siteRule(for: "https://notgoogle.com") == nil)
        #expect(c.siteRule(for: "") == nil)
    }

    @Test func hostsAreNormalized() {
        #expect(TabCloser.host("www.Gmail.com") == "gmail.com")
        #expect(TabCloser.host("https://gmail.com/x?y") == "gmail.com")
        #expect(TabCloser.host("  ") == nil)
    }

    @Test func rememberForgetsClosedTabsAndStartsNewOnesNow() {
        let seen = TabCloser.remember(["gone": ago(5), "kept": ago(5)], open: ["kept", "fresh"], now: now)
        #expect(seen == ["kept": ago(5), "fresh": now])
    }

    @Test func labels() {
        #expect(TabCloser.label(0) == "Never")
        #expect(TabCloser.label(30) == "30 min")
        #expect(TabCloser.label(120) == "2 h")
        #expect(TabCloser.label(1440) == "1 day")
        #expect(TabCloser.label(4320) == "3 days")
        #expect(TabCloser.label(2160) == "36 h")
    }

    @Test func settingsAreKeptBetweenLaunches() {
        let d = freshDefaults()
        let a = TabCloser(defaults: d)
        a.enabled = true; a.minutes = 240; a.spaceRules = ["s": 0]; a.siteRules = ["x.com": 30]
        let b = TabCloser(defaults: d)
        #expect(b.enabled && b.minutes == 240 && b.spaceRules == ["s": 0] && b.siteRules == ["x.com": 30])
    }
}

@MainActor
struct WindowRuleTests {
    @Test func builtInDefaultsAndUserRules() {
        let rules = WindowRules(defaults: freshDefaults())
        #expect(rules.rule(for: "com.apple.finder").placement == .none)
        #expect(rules.rule(for: "com.apple.mail") == WindowRule(placement: .right, extraOnly: true))
        #expect(rules.rule(for: "com.unknown.app").placement == .fill)
        rules.setPlacement(.fill, for: "com.apple.finder")
        #expect(rules.rule(for: "com.apple.finder").placement == .fill)
    }

    @Test func fillAndDontSnapDropExtraOnly() {
        let rules = WindowRules(defaults: freshDefaults())
        rules.setPlacement(.fill, for: "com.apple.mail")
        #expect(rules.rule(for: "com.apple.mail") == WindowRule(placement: .fill, extraOnly: false))
        rules.setPlacement(.left, for: "x"); rules.setExtraOnly(true, for: "x")
        rules.setPlacement(.none, for: "x")
        #expect(rules.rule(for: "x").extraOnly == false)
    }

    @Test func rulesAreKept() {
        let d = freshDefaults()
        WindowRules(defaults: d).setPlacement(.center, for: "a")
        #expect(WindowRules(defaults: d).rule(for: "a").placement == .center)
    }

    @Test func newWindows() {
        #expect(WindowRules.newWindowAction(rule: WindowRule(placement: .none), framed: true) == .leave)
        #expect(WindowRules.newWindowAction(rule: WindowRule(placement: .fill), framed: false) == .leave)
        #expect(WindowRules.newWindowAction(rule: WindowRule(placement: .fill), framed: true) == .frame)
        #expect(WindowRules.newWindowAction(rule: WindowRule(placement: .right, extraOnly: true), framed: false)
                == .place(.right, extraOnly: true))
    }

    @Test func openedApps() {
        let right = WindowRule(placement: .right)
        #expect(WindowRules.openedAppAction(rule: right, frozen: true, freezeActive: true) == .frozenHalf)
        #expect(WindowRules.openedAppAction(rule: WindowRule(placement: .none), frozen: false, freezeActive: true) == .leave)
        // While something is frozen, other apps fill the free half (the usual snapping).
        #expect(WindowRules.openedAppAction(rule: right, frozen: false, freezeActive: true) == .usual)
        #expect(WindowRules.openedAppAction(rule: right, frozen: false, freezeActive: false) == .place(.right))
        #expect(WindowRules.openedAppAction(rule: WindowRule(placement: .right, extraOnly: true), frozen: false, freezeActive: false) == .usual)
        #expect(WindowRules.openedAppAction(rule: WindowRule(placement: .fill), frozen: false, freezeActive: false) == .usual)
    }

    @Test func centeredIsSixtyBySeventyTwoPercentInTheMiddle() {
        let r = WindowRules.centered(in: CGRect(x: 100, y: 50, width: 1000, height: 800))
        #expect(r == CGRect(x: 300, y: 162, width: 600, height: 576))
    }
}
