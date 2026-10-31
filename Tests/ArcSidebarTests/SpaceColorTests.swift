import Foundation
import Testing
@testable import ArcSidebar

@MainActor
struct SpaceColorTests {
    private func library() -> Library {
        Library(fileURL: sandbox().appendingPathComponent("library.json"), defaults: freshDefaults())
    }

    @Test func newSpacesTakeThePrimaryColorsInOrderThenTheFallbacks() {
        let lib = library()
        for i in 0..<9 { lib.addSpace(title: "S\(i)") }
        #expect(lib.spaces.compactMap(\.area) == Area.primary + [.indigo])
        #expect(lib.spaces.allSatisfy { $0.accent != nil })
    }

    @Test func aGivenColorBecomesTheNearestOne() {
        let space = library().addSpace(title: "Red", color: RGB(r: 0.86, g: 0.26, b: 0.24))
        #expect(space.area == .red && space.accent == .red)
    }

    @Test func oldSpacesGetTheNearestColorAndAccentOnce() {
        // The old presets: Lavender, Mint, Sky.
        let old = [RGB(hex: 0x8E7CF6), RGB(hex: 0x73D2A8), RGB(hex: 0x6FB6F2)].enumerated().map { i, c in
            LibrarySpace(title: "S\(i)", colors: [c])
        }
        let migrated = Library.withColors(old)
        #expect(migrated.map(\.area) == [.violet, .cyan, .sky])
        #expect(migrated.map(\.accent) == [.purple, .teal, .sky])
        // Chosen ones stay.
        var chosen = migrated
        chosen[0].area = .stone
        #expect(Library.withColors(chosen)[0].area == .stone)
    }

    @Test func aSpaceWithoutAnyColorGetsTheNextFreeOne() {
        var a = LibrarySpace(title: "A"); a.area = .blue
        let b = LibrarySpace(title: "B")
        #expect(Library.withColors([a, b])[1].area == .teal)
    }

    @Test func unknownColorNamesDontBreakLoading() throws {
        var s = LibrarySpace(title: "A")
        s.colorName = "plaid"; s.accentName = "neon"
        let data = try JSONEncoder().encode([s])
        let back = try JSONDecoder().decode([LibrarySpace].self, from: data)
        #expect(back[0].area == nil && back[0].accent == nil)
        #expect(Library.withColors(back)[0].area != nil)
    }

    @Test func theSpaceShownUsesItsChosenColors() {
        var space = BrowserSpace(id: "x", title: "X", colors: [RGB(hex: 0x3D7BF2)])
        #expect(space.area == .blue)
        space.areaChoice = .rose; space.accentChoice = .gold
        #expect(space.area == .rose && space.accent == .gold)
        #expect(BrowserSpace(id: "y", title: "Y").area == .slate)
    }
}

struct ColorToneTests {
    @Test func toneMovesLightnessOnly() {
        let base = RGB(hex: 0xE2F0E1)
        let lighter = base.shiftingLightness(0.05), darker = base.shiftingLightness(-0.1)
        #expect(lighter.r + lighter.g + lighter.b > base.r + base.g + base.b)
        #expect(darker.r + darker.g + darker.b < base.r + base.g + base.b)
        // Still green: the green channel stays the largest.
        #expect(darker.g > darker.r && darker.g > darker.b)
        #expect(base.distance(to: base.shiftingLightness(0)) < 1e-9)
    }
}
