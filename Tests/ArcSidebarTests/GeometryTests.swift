import CoreGraphics
import Testing
@testable import ArcSidebar

struct GeometryTests {
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)

    @Test func areaLeavesRoomForTheBarAndAGapAround() {
        let r = Geometry.area(visibleFrame: screen, left: 200, rightDock: 0, gap: 6, openEdges: [])
        #expect(r == CGRect(x: 200, y: 6, width: 1728 - 200 - 6, height: 1080 - 12))
    }

    @Test func noBarMeansNoGap() {
        #expect(Geometry.area(visibleFrame: screen, left: 0, rightDock: 0, gap: 6, openEdges: []) == screen)
    }

    @Test func aRightDockReplacesTheRightGap() {
        let r = Geometry.area(visibleFrame: screen, left: 200, rightDock: 180, gap: 6, openEdges: [])
        #expect(r.maxX == CGFloat(1548))
    }

    @Test func edgesThatContinueOntoAnotherScreenGetNoGap() {
        let r = Geometry.area(visibleFrame: screen, left: 200, rightDock: 0, gap: 6, openEdges: [.maxXEdge, .minYEdge])
        #expect(r.maxX == 1728 && r.minY == 0 && r.maxY == 1080 - 6)
    }

    @Test func tinyScreensNeverGiveNegativeSizes() {
        let r = Geometry.area(visibleFrame: CGRect(x: 0, y: 0, width: 150, height: 100), left: 200, rightDock: 0, gap: 6, openEdges: [])
        #expect(r.width == 0)
    }

    @Test func halvesSplitWithAGapAndWholePoints() {
        let full = CGRect(x: 200, y: 0, width: 1001, height: 800)
        let (l, r) = Geometry.halves(of: full, gap: 6)
        #expect(l.minX == 200 && r.maxX == full.maxX)
        #expect(l.width == 497 && r.width == 497)
        #expect(r.minX - l.maxX >= 6)
    }

    @Test func flippingBetweenCoordinateSystemsRoundTrips() {
        let r = CGRect(x: 10, y: 20, width: 300, height: 400)
        #expect(Geometry.flipped(Geometry.flipped(r, primaryHeight: 1117), primaryHeight: 1117) == r)
        #expect(Geometry.flipped(r, primaryHeight: 1117).minY == CGFloat(697))
    }
}

struct ScreenChangeTests {
    let laptop = ScreenLayout.Screen(name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                     visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 923))

    /// Feeds the layouts in turn; whether each one counted as a change.
    private func changes(from first: [ScreenLayout.Screen], _ next: [[ScreenLayout.Screen]]) -> [Bool] {
        var filter = ScreenChangeFilter(last: ScreenLayout(screens: first))
        return next.map { filter.changed(to: ScreenLayout(screens: $0)) }
    }

    @Test func theSameScreensAgainAreNoChange() {
        // The display fading in after waking reports "changed" about 120 times with nothing moved.
        #expect(changes(from: [laptop], Array(repeating: [laptop], count: 120)).allSatisfy { !$0 })
    }

    @Test func aScreenPluggedInOrOutIsAChangeOnce() {
        let monitor = ScreenLayout.Screen(name: "Studio Display", frame: CGRect(x: 1470, y: 0, width: 2560, height: 1440),
                                          visibleFrame: CGRect(x: 1470, y: 0, width: 2560, height: 1415))
        #expect(changes(from: [laptop], [[laptop, monitor], [laptop, monitor], [laptop]]) == [true, false, true])
    }

    @Test func theDockOrMenuBarShowingOrHidingIsAChange() {
        let dockHidden = ScreenLayout.Screen(name: laptop.name, frame: laptop.frame, visibleFrame: laptop.frame)
        #expect(changes(from: [laptop], [[dockHidden], [laptop]]) == [true, true])
    }

    @Test func anotherScreenOfTheSameSizeIsAChange() {
        // The bar can be set to one particular screen by name.
        let other = ScreenLayout.Screen(name: "Projector", frame: laptop.frame, visibleFrame: laptop.visibleFrame)
        #expect(changes(from: [laptop], [[other]]) == [true])
    }
}
