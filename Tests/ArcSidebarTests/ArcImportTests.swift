import Foundation
import Testing
@testable import ArcSidebar

/// A small Arc sidebar file in Arc's own layout: one space with a pinned tab and a folder,
/// and one favorite.
let arcSample = """
{"sidebar": {"containers": [{"global": {}}, {
  "spaces": ["sp1", {"id": "sp1", "title": "Uni", "containerIDs": ["pinned", "c-pin", "unpinned", "c-unpin"],
                     "customInfo": {"iconType": {"emoji_v2": "🎓"}}}],
  "items": [
    "c-pin", {"id": "c-pin", "data": {"itemContainer": {}}, "childrenIds": ["t1", "f1"]},
    {"id": "t1", "data": {"tab": {"savedTitle": "Moodle", "savedURL": "https://moodle.example"}}, "childrenIds": []},
    {"id": "f1", "title": "Reading", "data": {"list": {}}, "childrenIds": ["t2"]},
    {"id": "t2", "title": "My Paper", "data": {"tab": {"savedTitle": "Paper", "savedURL": "https://paper.example"}}},
    {"id": "c-unpin", "data": {"itemContainer": {}}, "childrenIds": []},
    {"id": "c-fav", "data": {"itemContainer": {}}, "childrenIds": ["t3"]},
    {"id": "t3", "data": {"tab": {"savedTitle": "Gmail", "savedURL": "https://mail.google.com"}}}
  ],
  "topAppsContainerIDs": [{"default": true}, "c-fav"]
}]}}
"""

@MainActor
struct ArcImportTests {
    private func tree(_ json: String = arcSample) throws -> ArcTree {
        try #require(ArcSidebarFile.parse(Data(json.utf8)))
    }

    @Test func parsesSpacesItemsAndFavorites() throws {
        let t = try tree()
        #expect(t.spaces.map(\.title) == ["Uni"])
        #expect(t.spaces.first?.icon == .emoji("🎓"))
        #expect(t.children(of: "c-pin") == ["t1", "f1"])
        #expect(t.favoritesContainer(forProfile: nil) == "c-fav")
    }

    @Test func unknownOrBrokenFilesAreRejected() {
        #expect(ArcSidebarFile.parse(Data("{}".utf8)) == nil)
        #expect(ArcSidebarFile.parse(Data("not json".utf8)) == nil)
        #expect(ArcSidebarFile.parse(Data(#"{"sidebar": {"containers": []}}"#.utf8)) == nil)
    }

    @Test func importCreatesSpacesWithPinsAndFolders() throws {
        let lib = Library(fileURL: sandbox().appendingPathComponent("library.json"), defaults: freshDefaults())
        let favorites = lib.importFromArc(try tree())
        let space = try #require(lib.spaces.first)
        #expect(space.title == "Uni" && space.emoji == "🎓" && space.arcSpaceID == "sp1")
        #expect(space.pinned.map(\.title) == ["Moodle", "Reading"])
        #expect(space.pinned.last?.children.map(\.title) == ["My Paper"])
        #expect(favorites.map(\.url) == ["https://mail.google.com"])
    }

    @Test func aHalfWrittenFileKeepsTheLastGoodCopy() throws {
        let url = sandbox().appendingPathComponent("StorableSidebar.json")
        try Data(arcSample.utf8).write(to: url)
        let file = ArcSidebarFile(url: url)
        #expect(file.load()?.spaces.map(\.title) == ["Uni"])
        try Data("{\"sidebar\": {\"conta".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        #expect(file.load()?.spaces.map(\.title) == ["Uni"])
        // Once Arc has finished writing, the new contents are read.
        try Data(arcSample.replacingOccurrences(of: "\"Uni\"", with: "\"Work\"").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        #expect(file.load()?.spaces.map(\.title) == ["Work"])
    }

    @Test func noFileNoTree() {
        #expect(ArcSidebarFile(url: sandbox().appendingPathComponent("missing.json")).load() == nil)
    }

    /// The real Arc file, if this Mac has one: it must parse without crashing.
    @Test func theRealArcFileParses() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
        guard let data = try? Data(contentsOf: url) else { return }
        #expect(ArcSidebarFile.parse(data) != nil)
    }
}

@MainActor
struct ArcReimportTests {
    @Test func importingTwiceAddsNothingTwice() throws {
        let lib = Library(fileURL: sandbox().appendingPathComponent("library.json"), defaults: freshDefaults())
        let tree = try #require(ArcSidebarFile.parse(Data(arcSample.utf8)))
        lib.importFromArc(tree)
        lib.importFromArc(tree)
        #expect(lib.spaces.count == 1)
        #expect(lib.spaces[0].pinned.map(\.title) == ["Moodle", "Reading"])
        #expect(Library.allSites(lib.spaces[0].pinned).count == 2)
    }

    @Test func newItemsInAnExistingFolderAreMergedIn() throws {
        let lib = Library(fileURL: sandbox().appendingPathComponent("library.json"), defaults: freshDefaults())
        lib.importFromArc(try #require(ArcSidebarFile.parse(Data(arcSample.utf8))))
        let more = arcSample
            .replacingOccurrences(of: #""childrenIds": ["t2"]"#, with: #""childrenIds": ["t2", "t9"]"#)
            .replacingOccurrences(of: #"{"id": "c-unpin""#,
                                  with: #"{"id": "t9", "data": {"tab": {"savedTitle": "New", "savedURL": "https://new.example"}}}, {"id": "c-unpin""#)
        lib.importFromArc(try #require(ArcSidebarFile.parse(Data(more.utf8))))
        #expect(lib.spaces[0].pinned.map(\.title) == ["Moodle", "Reading"])
        #expect(lib.spaces[0].pinned[1].children.map(\.title) == ["My Paper", "New"])
    }

    @Test func aFolderContainingItselfDoesntHang() throws {
        let looped = arcSample.replacingOccurrences(of: #""childrenIds": ["t2"]"#, with: #""childrenIds": ["t2", "f1"]"#)
        let lib = Library(fileURL: sandbox().appendingPathComponent("library.json"), defaults: freshDefaults())
        lib.importFromArc(try #require(ArcSidebarFile.parse(Data(looped.utf8))))
        #expect(lib.spaces[0].pinned[1].children.map(\.title) == ["My Paper"])
    }
}
