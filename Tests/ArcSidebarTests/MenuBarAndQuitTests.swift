import Foundation
import Testing
@testable import ArcSidebar

@MainActor
struct MenuBarAddressTests {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func sitsAfterTheMenusAtItsPreferredWidth() throws {
        let slot = try #require(MenuBarAddress.slot(screen: screen, visibleMaxY: 945, menusWidth: 400, notchLeftEnd: nil, statusIconsMinX: 1200))
        #expect(slot.minX == 414 && slot.width == 340)
        #expect(slot.height == 24)
        #expect(slot.midY == 963.5)
    }

    @Test func shrinksBeforeTheNotchAndStatusIcons() throws {
        let slot = try #require(MenuBarAddress.slot(screen: screen, visibleMaxY: 945, menusWidth: 400, notchLeftEnd: 680, statusIconsMinX: 1200))
        #expect(slot.maxX == 670)
        let byIcons = try #require(MenuBarAddress.slot(screen: screen, visibleMaxY: 945, menusWidth: 400, notchLeftEnd: nil, statusIconsMinX: 640))
        #expect(byIcons.maxX == 626)
    }

    @Test func noRoomOrHiddenMenuBarMeansNoSlot() {
        #expect(MenuBarAddress.slot(screen: screen, visibleMaxY: 945, menusWidth: 600, notchLeftEnd: 700, statusIconsMinX: nil) == nil)
        #expect(MenuBarAddress.slot(screen: screen, visibleMaxY: 982, menusWidth: 200, notchLeftEnd: nil, statusIconsMinX: nil) == nil)
    }

    @Test func aSecondScreenUsesItsOwnLeftEdge() throws {
        let right = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let slot = try #require(MenuBarAddress.slot(screen: right, visibleMaxY: 1055, menusWidth: 300, notchLeftEnd: nil, statusIconsMinX: nil))
        #expect(slot.minX == 1826)
        #expect(slot.height == 19)
    }

    @Test func showsTheSiteOnly() {
        #expect(MenuBarAddress.site("https://www.career.example.com/jobs?id=1") == "career.example.com")
        #expect(MenuBarAddress.site("https://github.com") == "github.com")
        #expect(MenuBarAddress.site("not a url") == "not a url")
    }
}

@MainActor
struct AutoQuitSettingsTests {
    @Test func offByDefaultHidingAfterHalfAnHour() {
        let q = AutoQuitManager(defaults: freshDefaults())
        #expect(!q.enabled && q.defaultRule == AutoQuitRule(action: .hide, minutes: 30))
    }

    @Test func rulesAreKept() {
        let d = freshDefaults()
        let a = AutoQuitManager(defaults: d)
        a.enabled = true
        a.defaultRule = AutoQuitRule(action: .quit, minutes: 60)
        a.setOverride(AutoQuitRule(action: .off, minutes: 0), for: "com.spotify.client")
        let b = AutoQuitManager(defaults: d)
        #expect(b.enabled && b.defaultRule.action == .quit && b.rule(for: "com.spotify.client").action == .off)
        #expect(b.rule(for: "other").minutes == 60)
        b.setOverride(nil, for: "com.spotify.client")
        #expect(b.rule(for: "com.spotify.client") == b.defaultRule)
    }

    @Test func minutesLeftCountsDown() {
        let q = AutoQuitManager(defaults: freshDefaults())
        q.defaultRule = AutoQuitRule(action: .hide, minutes: 30)
        q.setLastActive("x", Date().addingTimeInterval(-10 * 60 - 5))
        #expect(q.minutesLeft(for: "x") == nil) // switched off
        q.enabled = true
        #expect(q.minutesLeft(for: "x") == 20)
        q.setLastActive("x", Date().addingTimeInterval(-90 * 60))
        #expect(q.minutesLeft(for: "x") == 0)
        #expect(q.minutesLeft(for: "com.apple.finder") == nil)
        q.setOverride(AutoQuitRule(action: .off, minutes: 5), for: "x")
        #expect(q.minutesLeft(for: "x") == nil)
    }

    @Test func brokenStoredRulesFallBack() {
        let d = freshDefaults()
        d.set(Data("x".utf8), forKey: "autoQuit.default")
        d.set(Data("y".utf8), forKey: "autoQuit.overrides")
        let q = AutoQuitManager(defaults: d)
        #expect(q.defaultRule == AutoQuitRule(action: .hide, minutes: 30) && q.overrides.isEmpty)
    }
}
