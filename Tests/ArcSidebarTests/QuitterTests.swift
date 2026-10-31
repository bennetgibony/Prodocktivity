import Foundation
import Testing
@testable import ArcSidebar

struct QuitterTests {
    let now = Date()
    func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    @Test func nothingHappensBeforeTheTimeIsUp() {
        let rule = AutoQuitRule(action: .quit, minutes: 30)
        #expect(AutoQuitManager.decision(rule: rule, lastActive: ago(29), now: now, isHidden: false) == .off)
    }

    @Test func quitsOrHidesOnceTheTimeIsUp() {
        #expect(AutoQuitManager.decision(rule: .init(action: .quit, minutes: 30), lastActive: ago(30), now: now, isHidden: false) == .quit)
        #expect(AutoQuitManager.decision(rule: .init(action: .hide, minutes: 5), lastActive: ago(60), now: now, isHidden: false) == .hide)
    }

    @Test func aHiddenAppIsNotHiddenAgainButStillQuit() {
        #expect(AutoQuitManager.decision(rule: .init(action: .hide, minutes: 5), lastActive: ago(60), now: now, isHidden: true) == .off)
        #expect(AutoQuitManager.decision(rule: .init(action: .quit, minutes: 5), lastActive: ago(60), now: now, isHidden: true) == .quit)
    }

    @Test func keepOpenNeverDoesAnything() {
        #expect(AutoQuitManager.decision(rule: .init(action: .off, minutes: 1), lastActive: ago(9999), now: now, isHidden: false) == .off)
    }

    @Test @MainActor func protectedAppsAreNeverQuit() {
        #expect(AutoQuitManager.protected.contains("com.apple.finder"))
    }
}

struct BusyAppTests {
    let holders = [
        BusyApps.Holder(pid: 100, path: "/Applications/zoom.us.app/Contents/MacOS/zoom.us"),
        BusyApps.Holder(pid: 200, path: "/Applications/Spotify.app/Contents/Frameworks/Spotify Helper.app/Contents/MacOS/Spotify Helper"),
    ]

    @Test func anAppHoldingAnAssertionIsBusy() {
        #expect(BusyApps.isBusy(pid: 100, bundlePath: "/Applications/zoom.us.app", holders: holders))
    }

    @Test func anAppWhoseHelperHoldsOneIsBusy() {
        #expect(BusyApps.isBusy(pid: 150, bundlePath: "/Applications/Spotify.app", holders: holders))
    }

    @Test func otherAppsAreNot() {
        #expect(!BusyApps.isBusy(pid: 300, bundlePath: "/Applications/Notes.app", holders: holders))
        // A bundle whose name only starts the same isn't inside it.
        #expect(!BusyApps.isBusy(pid: 301, bundlePath: "/Applications/Spot", holders: holders))
        #expect(!BusyApps.isBusy(pid: 302, bundlePath: nil, holders: holders))
    }

    @Test func readingTheSystemsAssertionsWorks() {
        _ = BusyApps.holders()
    }
}

@MainActor
struct AreaRuleTests {
    @Test func theRuleFollowsWhereTheAppIs() {
        let q = AutoQuitManager(defaults: freshDefaults())
        q.defaultRule = AutoQuitRule(action: .hide, minutes: 30)
        q.favoritesRule = AutoQuitRule(action: .off, minutes: 30)
        q.spaceRules["uni"] = AutoQuitRule(action: .quit, minutes: 10)
        q.place = { id in
            switch id {
            case "fav": .favorites
            case "uni": .workspace("uni")
            case "work": .workspace("work")
            default: .open
            }
        }
        #expect(q.rule(for: "fav").action == .off)
        #expect(q.rule(for: "uni") == AutoQuitRule(action: .quit, minutes: 10))
        #expect(q.rule(for: "work") == q.defaultRule)
        #expect(q.rule(for: "other") == q.defaultRule)
        q.setOverride(AutoQuitRule(action: .quit, minutes: 1), for: "fav")
        #expect(q.rule(for: "fav").action == .quit)
    }

    @Test func areaRulesAreKept() {
        let d = freshDefaults()
        let q = AutoQuitManager(defaults: d)
        q.favoritesRule = AutoQuitRule(action: .quit, minutes: 60)
        q.spaceRules["uni"] = AutoQuitRule(action: .off, minutes: 30)
        let again = AutoQuitManager(defaults: d)
        #expect(again.favoritesRule == q.favoritesRule && again.spaceRules == q.spaceRules)
        q.favoritesRule = nil
        #expect(AutoQuitManager(defaults: d).favoritesRule == nil)
    }
}

