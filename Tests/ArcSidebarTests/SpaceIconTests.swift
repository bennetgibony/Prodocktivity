import Foundation
import Testing
@testable import ArcSidebar

@MainActor
struct SpaceIconTests {
    @Test func emojiAreFoundByName() {
        #expect(SpaceIcons.emoji(matching: "books").contains("📚"))
        #expect(SpaceIcons.emoji(matching: "red heart").contains("❤️") || SpaceIcons.emoji(matching: "heart").contains("❤️"))
        #expect(SpaceIcons.emoji(matching: "rocket").first == "🚀")
        #expect(SpaceIcons.emoji(matching: "zzzqqq").isEmpty)
        #expect(SpaceIcons.allEmoji.count > 900)
    }

    @Test func symbolsAreFoundByName() {
        #expect(SpaceIcons.symbols(matching: "") == SpaceIcons.symbols)
        #expect(SpaceIcons.symbols(matching: "person 2").contains("person.2.fill"))
        #expect(!SpaceIcons.symbols.isEmpty)
    }

    @Test func aTypedEmojiIsRecognized() {
        #expect(SpaceIcons.typedEmoji("🫠") == "🫠")
        #expect(SpaceIcons.typedEmoji(" 👨‍👩‍👧 ") == "👨‍👩‍👧")
        #expect(SpaceIcons.typedEmoji("a") == nil)
        #expect(SpaceIcons.typedEmoji("1") == nil)
        #expect(SpaceIcons.typedEmoji("📚📚") == nil)
    }

    @Test func choosingAnIconReplacesTheOther() {
        var space = LibrarySpace(title: "Uni")
        space.setIcon(.emoji("🎓"))
        #expect(space.iconChoice == .emoji("🎓"))
        space.setIcon(.symbol("book.fill"))
        #expect(space.emoji == nil && space.iconChoice == .symbol("book.fill"))
        space.setIcon(.none)
        #expect(space.icon == nil)
    }
}

@MainActor
struct SpaceSwitcherTests {
    @Test func spacesShrinkUntilSevenFitThenWrap() {
        // Wide enough: full size.
        #expect(SpaceSwitcher.metrics(count: 4, width: 300) == (DS.Size.hitTarget, 4))
        // A 190 pt bar (174 inside): 5 spaces and + at full size would not fit, so they get smaller.
        let five = SpaceSwitcher.metrics(count: 6, width: 174)
        #expect(five.perRow == 6 && five.cell < DS.Size.hitTarget && 6 * five.cell + 5 * DS.Space.xxs <= 174)
        // 7 spaces and + still share one row, at least at the minimum size.
        let seven = SpaceSwitcher.metrics(count: 8, width: 174)
        #expect(seven.perRow == 8 && seven.cell >= DS.Size.spaceDotMin)
        // More than 7 spaces: rows of 8 items (7 spaces, then the rest with +).
        #expect(SpaceSwitcher.metrics(count: 10, width: 174).perRow == 8)
    }
}

@MainActor
struct SpaceSwitcherRowTests {
    @Test func moreThanSevenSpacesWrap() {
        let ids = (1...10).map(String.init)
        let rows = SpaceSwitcher.rows(ids, plus: true, perRow: 8)
        #expect(rows.count == 2 && rows[0].count == 7 && rows[1] == ["8", "9", "10", nil])
        #expect(SpaceSwitcher.rows(Array(ids.prefix(7)), plus: true, perRow: 8).count == 1)
    }
}

@MainActor
struct OpenAppsPerWorkspaceTests {
    @Test func appsBelongToTheWorkspaceTheyWereOpenedIn() {
        let defaults = UserDefaults(suiteName: "openapps-\(UUID().uuidString)")!
        let apps = AppsModel(defaults: defaults)
        apps.noteOpenApps(running: [], activeSpace: "uni")
        apps.noteOpenApps(running: ["a.mail"], activeSpace: "uni")
        apps.noteOpenApps(running: ["a.mail", "a.slack"], activeSpace: "work")
        #expect(apps.openIn == ["a.mail": "uni", "a.slack": "work"])
        apps.assignOpenApp("a.mail", to: "work")
        #expect(apps.openIn["a.mail"] == "work")
        // Quit: forgotten, so the next start belongs to the workspace open then.
        apps.noteOpenApps(running: ["a.slack"], activeSpace: "uni")
        #expect(apps.openIn == ["a.slack": "work"])
    }
}
