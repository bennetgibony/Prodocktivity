import AppKit
import Testing
@testable import ArcSidebar

@MainActor
struct SettingsTests {
    @Test func freshSettingsHaveTheDefaults() {
        let s = Settings(defaults: freshDefaults())
        #expect(s.theme == .system && s.textScale == 1 && s.accent == .indigo && s.density == .standard && s.readingFont == .sans)
        #expect(s.arcSync == .light && s.browserEngine == .builtIn && s.searchEngine == .google)
        #expect(s.frameMode && !s.websiteDock && s.filesDock == .off && !s.menuBarAddress)
        #expect(s.sidebarWidth == 240 && s.tileSize == 48 && s.frameWidth == 8)
        #expect(s.barScreen == "main")
    }

    @Test func changesAreKept() {
        let d = freshDefaults()
        let a = Settings(defaults: d)
        a.theme = .dark; a.textScale = 1.15; a.accent = .gold; a.density = .compact; a.readingFont = .serif
        a.arcSync = .off; a.filesDock = .right; a.sidebarWidth = 300; a.frameMode = false; a.barScreen = "display:LG"
        let b = Settings(defaults: d)
        #expect(b.theme == .dark && b.textScale == 1.15 && b.accent == .gold && b.density == .compact && b.readingFont == .serif)
        #expect(b.arcSync == .off && b.filesDock == .right && b.sidebarWidth == 300 && !b.frameMode && b.barScreen == "display:LG")
    }

    @Test func unknownStoredValuesFallBackToDefaults() {
        let d = freshDefaults()
        d.set("turbo", forKey: "arcSync"); d.set("chrome-ish", forKey: "browserEngine"); d.set("left?", forKey: "dock.files")
        d.set("sepia", forKey: "appearance.theme"); d.set("neon", forKey: "appearance.accent"); d.set("huge", forKey: "appearance.density")
        let s = Settings(defaults: d)
        #expect(s.arcSync == .light && s.browserEngine == .builtIn && s.filesDock == .off)
        #expect(s.theme == .system && s.accent == .indigo && s.density == .standard)
    }

    @Test func theOldMenuBarAddressSettingIsIgnored() {
        // Earlier builds had the menu bar address on under the old key; v2 starts it off.
        let d = freshDefaults()
        d.set(true, forKey: "menuBarAddress")
        #expect(!Settings(defaults: d).menuBarAddress)
    }

    @Test(arguments: [(11.0, 0.9), (13.0, 1.0), (14.0, 1.0), (15.0, 1.15), (17.0, 1.3)])
    func theOldPointSizeBecomesTheNearestTextSize(old: Double, scale: Double) {
        let d = freshDefaults()
        d.set(old, forKey: "design.textSize")
        #expect(Settings(defaults: d).textScale == scale)
    }

    @Test func aStoredTextSizeSnapsToAStep() {
        let d = freshDefaults()
        d.set(1.2, forKey: "appearance.textScale")
        #expect(Settings(defaults: d).textScale == 1.15)
    }

    @Test func rowsGrowWithTheTextSize() {
        let s = Settings(defaults: freshDefaults())
        #expect(s.rowHeight == DS.Size.sidebarItem)
        s.density = .compact
        #expect(s.rowHeight == DS.Size.rowCompact)
        s.density = .standard
        s.textScale = 1.3
        #expect(s.rowHeight == 38 && s.rowIcon == 21)
        s.textScale = 0.9
        #expect(s.rowHeight == 30)
    }

    @Test func hexColorsRoundTrip() {
        #expect(NSColor(hex: "#8E7CF6")?.hexString == "#8E7CF6")
        #expect(NSColor(hex: "  00ff00 ")?.hexString == "#00FF00")
        #expect(NSColor(hex: "#12345") == nil)
        #expect(NSColor(hex: "#GGGGGG") == nil)
    }
}

@MainActor
struct AppsModelMigrationTests {
    @Test func spaceAppListsMoveToTheNewSpaceWithoutDuplicates() {
        let d = freshDefaults()
        d.set(["arc": ["a", "b"], "lib": ["b", "c"]], forKey: "spaceApps")
        let apps = AppsModel(defaults: d)
        apps.migrateSpaceApps(from: "arc", to: "lib")
        #expect(apps.spaceApps == ["lib": ["b", "c", "a"]])
        #expect(d.dictionary(forKey: "spaceApps") as? [String: [String]] == ["lib": ["b", "c", "a"]])
    }

    @Test func spaceAppsMoveIntoTheLibraryOnce() {
        let d = freshDefaults()
        let lib = Library(fileURL: sandbox().appendingPathComponent("library.json"), defaults: freshDefaults())
        let space = lib.addSpace(title: "Work")
        d.set([space.id: ["com.apple.TextEdit", "com.apple.Notes"], "gone": ["x"]], forKey: "spaceApps")
        let apps = AppsModel(defaults: d)
        apps.library = lib
        apps.migrateSpaceAppsToLibrary()
        #expect(Library.allApps(lib.spaces[0].pinned).map(\.url) == ["com.apple.TextEdit", "com.apple.Notes"])
        #expect(apps.spaceApps.isEmpty)
        apps.migrateSpaceAppsToLibrary()
        #expect(Library.allApps(lib.spaces[0].pinned).count == 2)
    }

    @Test func arcFavoritePinsBecomeWebsitePins() {
        let d = freshDefaults()
        d.set(["com.apple.Notes", "fav\u{1F}f1", "fav\u{1F}gone", "tab\u{1F}https://a.example\u{1F}A"], forKey: "pinnedBundleIDs")
        let apps = AppsModel(defaults: d)
        apps.convertFavoritePins([BrowserItem(id: "f1", title: "A", url: "https://a.example", kind: .tab)])
        #expect(apps.pinnedIDs == ["com.apple.Notes", "tab\u{1F}https://a.example\u{1F}A"])
    }

    @Test func syncingFavoritesReplacesMatchingWebsitePinsInPlace() {
        let d = freshDefaults()
        d.set(["tab\u{1F}https://a.example\u{1F}A", "com.apple.Notes", "fav\u{1F}old"], forKey: "pinnedBundleIDs")
        let apps = AppsModel(defaults: d)
        apps.syncFavorites([BrowserItem(id: "f1", title: "A", url: "https://a.example", kind: .tab),
                            BrowserItem(id: "f2", title: "B", url: "https://b.example", kind: .tab)])
        #expect(apps.pinnedIDs == ["fav\u{1F}f1", "com.apple.Notes", "fav\u{1F}f2"])
    }

    @Test func keptDuplicatesAreRememberedPerAppAndSite() {
        let d = freshDefaults()
        AppsModel(defaults: d).keepBoth(app: "notion.id", url: "https://www.notion.so/page")
        let apps = AppsModel(defaults: d)
        #expect(apps.isKeptDuplicate(app: "notion.id", url: "https://www.notion.so/other"))
        #expect(!apps.isKeptDuplicate(app: "notion.id", url: "https://notion.com"))
    }
}
