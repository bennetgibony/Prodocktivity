import Foundation
import Testing
@testable import ArcSidebar

@MainActor
struct LibraryItemTests {
    private func fresh() -> Library { Library(fileURL: sandbox().appendingPathComponent("library.json"), defaults: freshDefaults()) }

    @Test func newSpacesBecomeActiveWithColorsFromThePalette() {
        let lib = fresh()
        let a = lib.addSpace(title: "A"), b = lib.addSpace(title: "B")
        #expect(lib.activeSpaceID == b.id)
        #expect(a.colors.count == 1 && a.colors != b.colors)
        #expect(lib.addSpace(title: "C", color: RGB(r: 0, g: 0, b: 0)).colors == [RGB(r: 0, g: 0, b: 0)])
    }

    @Test func movingSpacesStaysInBounds() {
        let lib = fresh()
        let a = lib.addSpace(title: "A"); lib.addSpace(title: "B"); lib.addSpace(title: "C")
        lib.moveSpace(a.id, by: 10)
        #expect(lib.spaces.map(\.title) == ["B", "C", "A"])
        lib.moveSpace(a.id, by: -10)
        #expect(lib.spaces.map(\.title) == ["A", "B", "C"])
        lib.moveSpace("nope", by: 1)
        #expect(lib.spaces.map(\.title) == ["A", "B", "C"])
    }

    @Test func addingBeforeAnItemInsideAFolder() throws {
        let lib = fresh()
        let s = lib.addSpace(title: "S")
        lib.newFolder(in: s.id, title: "F")
        let folder = try #require(lib.folders(in: s.id).first)
        let inner = LibraryItem.site("Inner", "https://inner")
        lib.add(inner, toSpace: s.id, inFolder: folder.id)
        lib.add(.site("New", "https://new"), toSpace: s.id, before: inner.id)
        #expect(lib.folders(in: s.id).first?.children.map(\.title) == ["New", "Inner"])
    }

    @Test func addingBeforeAMissingItemAppends() {
        let lib = fresh()
        let s = lib.addSpace(title: "S")
        lib.add(.site("A", "https://a"), toSpace: s.id)
        lib.add(.site("B", "https://b"), toSpace: s.id, before: "gone")
        #expect(lib.spaces[0].pinned.map(\.title) == ["A", "B"])
    }

    @Test func movingIntoAFolderAndOut() throws {
        let lib = fresh()
        let s = lib.addSpace(title: "S")
        let a = LibraryItem.site("A", "https://a")
        lib.add(a, toSpace: s.id)
        lib.newFolder(in: s.id, title: "F")
        let folder = try #require(lib.folders(in: s.id).first)
        lib.move(a.id, intoFolder: folder.id, space: s.id)
        #expect(lib.spaces[0].pinned.map(\.title) == ["F"])
        #expect(lib.find(folder.id)?.children.map(\.title) == ["A"])
        lib.move(a.id, before: folder.id, space: s.id)
        #expect(lib.spaces[0].pinned.map(\.title) == ["A", "F"])
    }

    @Test func movingBetweenSpaces() {
        let lib = fresh()
        let s1 = lib.addSpace(title: "One"), s2 = lib.addSpace(title: "Two")
        let a = LibraryItem.site("A", "https://a")
        lib.add(a, toSpace: s1.id)
        lib.move(a.id, space: s2.id)
        #expect(lib.spaces[0].pinned.isEmpty)
        #expect(lib.spaces[1].pinned.map(\.title) == ["A"])
    }

    @Test func renamingAndRememberingTheTab() {
        let lib = fresh()
        let s = lib.addSpace(title: "S")
        let a = LibraryItem.site("A", "https://a")
        lib.add(a, toSpace: s.id)
        lib.rename(a.id, to: "Renamed")
        lib.setArcTabID(a.id, "tab-7")
        #expect(lib.find(a.id)?.title == "Renamed" && lib.find(a.id)?.arcTabID == "tab-7")
    }

    @Test func containsAddressesAlsoInFolders() throws {
        let lib = fresh()
        let s = lib.addSpace(title: "S")
        lib.newFolder(in: s.id)
        let folder = try #require(lib.folders(in: s.id).first)
        lib.add(.site("Deep", "https://deep"), toSpace: s.id, inFolder: folder.id)
        #expect(lib.contains(url: "https://deep", inSpace: s.id))
        #expect(!lib.contains(url: "https://deep", inSpace: "other"))
        #expect(!lib.contains(url: "https://nope", inSpace: s.id))
    }

    @Test func appsInSpaces() throws {
        let lib = fresh()
        let s1 = lib.addSpace(title: "One"), s2 = lib.addSpace(title: "Two")
        lib.add(.app("com.apple.Notes", title: "Notes"), toSpace: s1.id)
        lib.newFolder(in: s2.id)
        let folder = try #require(lib.folders(in: s2.id).first)
        lib.add(.app("com.apple.Notes", title: "Notes"), toSpace: s2.id, inFolder: folder.id)
        #expect(lib.containsApp("com.apple.Notes", inSpace: s1.id) && lib.containsApp("com.apple.Notes", inSpace: s2.id))
        lib.removeApp("com.apple.Notes", fromSpace: s2.id)
        #expect(!lib.containsApp("com.apple.Notes", inSpace: s2.id))
        #expect(lib.containsAppAnywhere("com.apple.Notes"))
        lib.removeApp("com.apple.Notes", fromSpace: s1.id)
        #expect(!lib.containsAppAnywhere("com.apple.Notes"))
    }

    @Test func spacesLinkedToArc() {
        let lib = fresh()
        let s = lib.addSpace(title: "S")
        lib.updateSpace(s.id) { $0.arcSpaceID = "arc-1" }
        #expect(lib.space(linkedTo: "arc-1")?.id == s.id)
        #expect(lib.space(linkedTo: nil) == nil && lib.space(linkedTo: "arc-2") == nil)
    }

    @Test func profilesFallBackToTheFirst() {
        let lib = fresh()
        let s = lib.addSpace(title: "S")
        let work = lib.addProfile(name: "Work")
        #expect(lib.profile(forSpace: s.id)?.name == "Private")
        lib.setProfile(work.id, forSpace: s.id)
        #expect(lib.profile(forSpace: s.id)?.name == "Work")
        lib.renameProfile(work.id, to: "Job")
        #expect(lib.profile(forSpace: s.id)?.name == "Job")
    }

    @Test func theActiveSpaceFallsBackToTheFirst() {
        let lib = fresh()
        let a = lib.addSpace(title: "A")
        lib.activeSpaceID = "gone"
        #expect(lib.activeSpace?.id == a.id)
    }

    @Test func allSitesAndAppsWalkFolders() {
        let items: [LibraryItem] = [
            .site("A", "https://a"),
            LibraryItem(kind: .folder, title: "F", children: [.app("x.y", title: "X"), LibraryItem(kind: .folder, title: "G", children: [.site("B", "https://b")])]),
        ]
        #expect(Library.allSites(items).map(\.title) == ["A", "B"])
        #expect(Library.allApps(items).map(\.url) == ["x.y"])
        #expect(Library.contains(items, id: items[1].children[1].id))
    }
}
