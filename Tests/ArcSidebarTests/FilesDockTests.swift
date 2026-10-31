import Foundation
import Testing
@testable import ArcSidebar

@MainActor
struct FilesDockTests {
    private func touch(_ url: URL, modified: Date? = nil) throws {
        try Data("x".utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    @Test func foldersFirstThenFilesInNaturalOrderHiddenSkipped() throws {
        let dir = sandbox()
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("b folder"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("Tool.app"), withIntermediateDirectories: true)
        for name in ["file10.txt", "file2.txt", "A.txt", ".hidden"] { try touch(dir.appendingPathComponent(name)) }
        let names = FilesDockModel.contents(of: dir).map(\.lastPathComponent)
        #expect(names == ["b folder", "A.txt", "file2.txt", "file10.txt", "Tool.app"])
    }

    @Test func downloadsAreNewestFirst() throws {
        let dir = sandbox().appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try touch(dir.appendingPathComponent("old.pdf"), modified: Date(timeIntervalSinceNow: -3600))
        try touch(dir.appendingPathComponent("new.pdf"), modified: Date())
        try touch(dir.appendingPathComponent("middle.pdf"), modified: Date(timeIntervalSinceNow: -60))
        #expect(FilesDockModel.contents(of: dir).map(\.lastPathComponent) == ["new.pdf", "middle.pdf", "old.pdf"])
    }

    @Test func aMissingFolderIsEmpty() {
        #expect(FilesDockModel.contents(of: sandbox().appendingPathComponent("nope")).isEmpty)
    }

    @Test func startsWithDownloadsOpenAndDesktop() {
        let model = FilesDockModel(defaults: freshDefaults(), watch: false)
        #expect(model.folders.map(\.url.lastPathComponent) == ["Downloads", "Desktop"])
        #expect(model.open == [model.folders[0].path])
    }

    @Test func chosenFoldersAndOrderAreKept() {
        let d = freshDefaults()
        let a = FilesDockModel(defaults: d, watch: false)
        a.setStartsOpen(a.folders[1], true)
        a.move(a.folders[1], by: -1)
        a.move(a.folders[0], by: -1) // already first: nothing happens
        a.remove(a.folders[1])
        let b = FilesDockModel(defaults: d, watch: false)
        #expect(b.folders.map(\.url.lastPathComponent) == ["Desktop"])
        #expect(b.open == [b.folders[0].path])
    }

    @Test func listingsAreCachedAndRefreshedInTheBackground() async throws {
        let dir = sandbox()
        try touch(dir.appendingPathComponent("one.txt"))
        let model = FilesDockModel(defaults: freshDefaults(), watch: false)
        model.toggle(dir.path)
        #expect(model.children(of: dir).map(\.lastPathComponent) == ["one.txt"])
        try touch(dir.appendingPathComponent("two.txt"))
        // Cached until the next refresh.
        #expect(model.children(of: dir).count == 1)
        model.refresh()
        for _ in 0..<100 where model.children(of: dir).count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(model.children(of: dir).map(\.lastPathComponent) == ["one.txt", "two.txt"])
    }

    @Test func reopeningAFolderReadsItFresh() throws {
        let dir = sandbox()
        let model = FilesDockModel(defaults: freshDefaults(), watch: false)
        model.toggle(dir.path)
        #expect(model.children(of: dir).isEmpty)
        try touch(dir.appendingPathComponent("new.txt"))
        model.toggle(dir.path); model.toggle(dir.path)
        #expect(model.children(of: dir).map(\.lastPathComponent) == ["new.txt"])
    }

    @Test func appsAreFilesNotFolders() throws {
        let dir = sandbox()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("X.app"), withIntermediateDirectories: true)
        let model = FilesDockModel(defaults: freshDefaults(), watch: false)
        #expect(!model.isFolder(dir.appendingPathComponent("X.app")))
        #expect(model.isFolder(dir))
    }
}
