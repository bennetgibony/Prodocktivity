import Foundation
import Testing
@testable import ArcSidebar

@MainActor
struct SetupFileTests {
    private func fixture() -> (UserDefaults, [LibrarySpace]) {
        let defaults = UserDefaults(suiteName: "setup-\(UUID().uuidString)")!
        defaults.set("dark", forKey: "appearance.theme")
        defaults.set(["com.apple.mail", "tab\u{1F}https://moodle.de\u{1F}Moodle"], forKey: "pinnedBundleIDs")
        defaults.set(["com.apple.mail": "right"], forKey: "windowRules")
        defaults.set(Date(), forKey: "ideas.lastAsked") // state, never in a setup file
        var folder = LibraryItem(kind: .folder, title: "Admin")
        folder.children = [.site("PULS", "https://puls.de"), .app("com.apple.Terminal", title: "Terminal")]
        let uni = LibrarySpace(title: "Uni", emoji: "🎓", pinned: [folder, .app("com.apple.mail", title: "Mail")])
        return (defaults, [uni])
    }

    @Test func setupNALeavesOutApps() throws {
        let (defaults, spaces) = fixture()
        let data = try #require(SetupFile.make(.noApps, defaults: defaults, spaces: spaces, profiles: []))
        let contents = try SetupFile.read(data)
        #expect(contents.kind == .noApps)
        #expect(contents.settings["appearance.theme"] as? String == "dark")
        #expect(contents.settings["windowRules"] == nil && contents.settings["ideas.lastAsked"] == nil)
        #expect(contents.settings["pinnedBundleIDs"] as? [String] == ["tab\u{1F}https://moodle.de\u{1F}Moodle"])
        #expect(contents.workspaces[0].pinned.count == 1)
        #expect(contents.workspaces[0].pinned[0].children.map(\.title) == ["PULS"])
    }

    @Test func setupWAKeepsAppsAndTheirRules() throws {
        let (defaults, spaces) = fixture()
        let contents = try SetupFile.read(try #require(SetupFile.make(.withApps, defaults: defaults, spaces: spaces, profiles: [])))
        #expect(contents.kind == .withApps)
        #expect(contents.settings["windowRules"] as? [String: String] == ["com.apple.mail": "right"])
        #expect(contents.workspaces == spaces)
    }

    @Test func applyingSetupNAKeepsThisMacsApps() throws {
        let (source, spaces) = fixture()
        let file = try SetupFile.read(try #require(SetupFile.make(.noApps, defaults: source, spaces: spaces, profiles: [])))
        let here = UserDefaults(suiteName: "setup-here-\(UUID().uuidString)")!
        here.set(["com.apple.Notes"], forKey: "pinnedBundleIDs")
        here.set(["com.apple.Notes": "left"], forKey: "windowRules")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let library = Library(fileURL: dir.appendingPathComponent("library.json"), defaults: here)
        SetupFile.apply(file, defaults: here, library: library)
        #expect(here.stringArray(forKey: "pinnedBundleIDs") == ["com.apple.Notes", "tab\u{1F}https://moodle.de\u{1F}Moodle"])
        #expect(here.dictionary(forKey: "windowRules") as? [String: String] == ["com.apple.Notes": "left"])
        #expect(here.string(forKey: "appearance.theme") == "dark")
        #expect(library.spaces.map(\.title) == ["Uni"])
    }

    @Test func otherFilesAreRefused() {
        #expect(throws: SetupFile.Problem.self) { try SetupFile.read(Data("{\"a\":1}".utf8)) }
    }
}
