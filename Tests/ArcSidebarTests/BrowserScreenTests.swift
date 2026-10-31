import Foundation
import Testing
@testable import ArcSidebar

struct BrowserScreenTests {
    private let names = ["Built-in", "External Display"]

    @Test func besideTheBarIsTheDefault() {
        #expect(Settings.browserScreenName(setting: "bar", barName: "Built-in", names: names) == nil)
        #expect(Settings.browserScreenName(setting: "anything else", barName: "Built-in", names: names) == nil)
    }

    @Test func theOtherScreenIsTheOneWithoutTheBar() {
        #expect(Settings.browserScreenName(setting: "other", barName: "Built-in", names: names) == "External Display")
        #expect(Settings.browserScreenName(setting: "other", barName: "External Display", names: names) == "Built-in")
    }

    @Test func withOneScreenTheBrowserStaysBesideTheBar() {
        #expect(Settings.browserScreenName(setting: "other", barName: "Built-in", names: ["Built-in"]) == nil)
    }

    @Test func aChosenScreenNeedsToBeConnectedAndNotTheBars() {
        #expect(Settings.browserScreenName(setting: "display:External Display", barName: "Built-in", names: names) == "External Display")
        #expect(Settings.browserScreenName(setting: "display:External Display", barName: "Built-in", names: ["Built-in"]) == nil)
        #expect(Settings.browserScreenName(setting: "display:Built-in", barName: "Built-in", names: names) == nil)
    }
}

struct FramedAreaTests {
    private let screen = CGRect(x: 100, y: 0, width: 1000, height: 800)

    @Test func theFrameRunsAllAroundAScreenWithoutTheBar() {
        let r = Geometry.framedArea(visibleFrame: screen, gap: 8, openEdges: [])
        #expect(r == CGRect(x: 108, y: 8, width: 984, height: 784))
    }

    @Test func noFrameWhereAnotherScreenContinues() {
        let r = Geometry.framedArea(visibleFrame: screen, gap: 8, openEdges: [.minXEdge])
        #expect(r == CGRect(x: 100, y: 8, width: 992, height: 784))
    }
}
