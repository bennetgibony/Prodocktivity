import Foundation
import Testing
@testable import ArcSidebar

@MainActor
struct LibraryTests {
    private func fresh() -> (Library, URL) {
        let file = sandbox().appendingPathComponent("library.json")
        return (Library(fileURL: file, defaults: freshDefaults()), file)
    }

    @Test func savesAndLoadsSpacesPinsAndFolders() throws {
        let (lib, file) = fresh()
        let space = lib.addSpace(title: "Uni", emoji: "🎓")
        lib.add(.site("Moodle", "https://moodle.example"), toSpace: space.id)
        lib.newFolder(in: space.id, title: "Reading")
        let folder = try #require(lib.folders(in: space.id).first)
        lib.add(.site("Paper", "https://paper.example"), toSpace: space.id, inFolder: folder.id)
        lib.saveNow()

        let again = Library(fileURL: file, defaults: freshDefaults())
        let loaded = try #require(again.spaces.first { $0.id == space.id })
        #expect(loaded.title == "Uni" && loaded.emoji == "🎓")
        #expect(Library.allSites(loaded.pinned).map(\.title) == ["Moodle", "Paper"])
        #expect(again.folders(in: space.id).first?.children.map(\.title) == ["Paper"])
        #expect(again.isSetUp)
    }

    @Test func changesAreSavedAfterAMomentWithoutSaveNow() async throws {
        let (lib, file) = fresh()
        lib.addSpace(title: "Work")
        try await Task.sleep(for: .seconds(0.8))
        #expect(Library(fileURL: file, defaults: freshDefaults()).spaces.map(\.title) == ["Work"])
    }

    @Test func movingAndRemoving() throws {
        let (lib, _) = fresh()
        let s = lib.addSpace(title: "S")
        let a = LibraryItem.site("A", "https://a"), b = LibraryItem.site("B", "https://b"), c = LibraryItem.site("C", "https://c")
        for item in [a, b, c] { lib.add(item, toSpace: s.id) }
        lib.move(c.id, before: a.id, space: s.id)
        #expect(lib.spaces[0].pinned.map(\.title) == ["C", "A", "B"])
        lib.moveLive(c.id, over: b.id, space: s.id)
        #expect(lib.spaces[0].pinned.map(\.title) == ["A", "B", "C"])
        lib.remove(b.id)
        #expect(lib.spaces[0].pinned.map(\.title) == ["A", "C"])
    }

    @Test func dissolvingAFolderKeepsItsContentsInPlace() throws {
        let (lib, _) = fresh()
        let s = lib.addSpace(title: "S")
        lib.add(.site("First", "https://1"), toSpace: s.id)
        lib.newFolder(in: s.id, title: "F")
        let folder = try #require(lib.folders(in: s.id).first)
        lib.add(.site("Inside", "https://2"), toSpace: s.id, inFolder: folder.id)
        lib.add(.site("Last", "https://3"), toSpace: s.id)
        lib.dissolveFolder(folder.id)
        #expect(lib.spaces[0].pinned.map(\.title) == ["First", "Inside", "Last"])
    }

    @Test func spacesMoveAndDelete() {
        let (lib, _) = fresh()
        let a = lib.addSpace(title: "A"), b = lib.addSpace(title: "B")
        lib.moveSpace(b.id, by: -1)
        #expect(lib.spaces.map(\.title) == ["B", "A"])
        lib.deleteSpace(b.id)
        #expect(lib.spaces.map(\.id) == [a.id])
    }

    @Test func profilesAreSharedAndDeletedSafely() throws {
        let (lib, _) = fresh()
        let s = lib.addSpace(title: "S")
        let work = lib.addProfile(name: "Work")
        lib.setProfile(work.id, forSpace: s.id)
        #expect(lib.profile(forSpace: s.id)?.name == "Work")
        lib.deleteProfile(work.id)
        #expect(lib.profile(forSpace: s.id)?.name == "Private")
        // The last profile can't be deleted.
        lib.deleteProfile(try #require(lib.profiles.first).id)
        #expect(lib.profiles.count == 1)
    }
}

@MainActor
struct DamagedFileTests {
    @Test func aDamagedLibraryIsKeptAsideNotOverwritten() throws {
        let dir = sandbox()
        let file = dir.appendingPathComponent("library.json")
        let broken = Data(#"[{"id": "x", "title": 42}]"#.utf8)
        try broken.write(to: file)
        let lib = Library(fileURL: file, defaults: freshDefaults())
        #expect(lib.spaces.isEmpty && !lib.isSetUp)
        lib.addSpace(title: "New")
        lib.saveNow()
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("library.damaged-") }
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(kept[0])) == broken)
    }

    @Test func damagedBrowserTabsAreKeptAside() throws {
        let dir = sandbox()
        let file = dir.appendingPathComponent("browser-tabs.json")
        try Data("{ not json".utf8).write(to: file)
        _ = WebBrowser(stateURL: file)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("browser-tabs.damaged-") })
    }

    @Test func aMissingFileIsSimplyEmpty() {
        let dir = sandbox()
        #expect(Library(fileURL: dir.appendingPathComponent("library.json"), defaults: freshDefaults()).spaces.isEmpty)
        #expect(try! FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("damaged") }.isEmpty)
    }
}

@MainActor
struct FolderSafetyTests {
    @Test func aFolderCantBeMovedIntoItsOwnSubfolder() throws {
        let lib = Library(fileURL: sandbox().appendingPathComponent("library.json"), defaults: freshDefaults())
        let s = lib.addSpace(title: "S")
        lib.newFolder(in: s.id, title: "Outer")
        let outer = try #require(lib.folders(in: s.id).first)
        lib.add(LibraryItem(kind: .folder, title: "Inner"), toSpace: s.id, inFolder: outer.id)
        lib.add(.site("Kept", "https://kept"), toSpace: s.id, inFolder: outer.id)
        let inner = try #require(lib.folders(in: s.id).first { $0.title == "Inner" })
        lib.move(outer.id, intoFolder: inner.id, space: s.id)
        lib.move(outer.id, before: inner.id, space: s.id)
        #expect(lib.find(outer.id)?.children.count == 2)
        #expect(Library.allSites(lib.spaces[0].pinned).map(\.title) == ["Kept"])
    }

    @Test func addingToAMissingFolderKeepsTheItem() {
        let lib = Library(fileURL: sandbox().appendingPathComponent("library.json"), defaults: freshDefaults())
        let s = lib.addSpace(title: "S")
        lib.add(.site("Orphan", "https://o"), toSpace: s.id, inFolder: "no-such-folder")
        #expect(lib.spaces[0].pinned.map(\.title) == ["Orphan"])
    }
}

struct StorageSafetyTests {
    @Test func testsNeverUseTheRealStorageFolder() {
        #expect(AppPaths.isTestRun)
        #expect(!appStorage.path.contains("Application Support"))
    }
}
