import Foundation
import Testing
@testable import ArcSidebar

struct ExtensionFileTests {
    /// A minimal extension folder, zipped the way extensions are shipped (one folder inside).
    private func sampleZip(in dir: URL) throws -> URL {
        let folder = dir.appendingPathComponent("sample-ext", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version": 3, "name": "Sample", "version": "1.0"}"#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        let zip = dir.appendingPathComponent("sample.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        try p.run()
        p.waitUntilExit()
        return zip
    }

    @Test func aZipIsUnpackedIntoTheAppsOwnFolder() throws {
        let dir = sandbox()
        let (kind, path) = try WebExtensionStore.prepare(try sampleZip(in: dir))
        #expect(kind == .folder)
        _ = dir
        #expect(path.standardizedFileURL.path.hasPrefix(appStorage.appendingPathComponent("Extensions").standardizedFileURL.path))
        #expect(FileManager.default.fileExists(atPath: path.appendingPathComponent("manifest.json").path))
    }

    @Test func aFolderWithoutManifestIsRefused() throws {
        let dir = sandbox()
        let empty = dir.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: ExtensionError.self) { try WebExtensionStore.prepare(empty) }
    }

    @Test func otherFilesAreRefused() throws {
        let file = sandbox().appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)
        #expect(throws: ExtensionError.self) { try WebExtensionStore.prepare(file) }
    }

    private func extensionsFolders() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: WebExtensionStore.directory.path)) ?? [])
    }

    private func zip(_ folder: URL, to zip: URL, keepParent: Bool) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k"] + (keepParent ? ["--keepParent"] : []) + [folder.path, zip.path]
        try p.run()
        p.waitUntilExit()
    }

    /// A .crx (version 3): "Cr24", version, header length, header, then the zip.
    private func crx(from zip: URL, headerLength: UInt32 = 4, version: UInt32 = 3) throws -> URL {
        func le(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var data = Data("Cr24".utf8) + le(version) + le(headerLength)
        data += Data(repeating: 0, count: 4)
        data += try Data(contentsOf: zip)
        let file = zip.deletingPathExtension().appendingPathExtension("crx")
        try data.write(to: file)
        return file
    }

    @Test func aChromeExtensionFileIsUnpacked() throws {
        let dir = sandbox()
        let (kind, path) = try WebExtensionStore.prepare(try crx(from: try sampleZip(in: dir)))
        #expect(kind == .folder)
        #expect(FileManager.default.fileExists(atPath: path.appendingPathComponent("manifest.json").path))
    }

    @Test func aDamagedChromeExtensionFileIsRefusedNotACrash() throws {
        let dir = sandbox()
        let zip = try sampleZip(in: dir)
        #expect(throws: ExtensionError.self) { try WebExtensionStore.prepare(try crx(from: zip, headerLength: 0xFFFF_FFF0)) }
        #expect(throws: ExtensionError.self) { try WebExtensionStore.prepare(try crx(from: zip, version: 7)) }
        let tiny = dir.appendingPathComponent("tiny.crx")
        try Data("Cr24".utf8).write(to: tiny)
        #expect(throws: ExtensionError.self) { try WebExtensionStore.prepare(tiny) }
    }

    @Test func aZipWithoutManifestIsRefusedAndLeavesNothingBehind() throws {
        let dir = sandbox()
        let folder = dir.appendingPathComponent("not-an-extension", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        let file = dir.appendingPathComponent("x.zip")
        try zip(folder, to: file, keepParent: true)
        let before = extensionsFolders()
        #expect(throws: ExtensionError.self) { try WebExtensionStore.prepare(file) }
        // (Tests run in parallel: only check that nothing of ours with this content stayed.)
        let added = extensionsFolders().subtracting(before)
        for name in added {
            let inner = WebExtensionStore.directory.appendingPathComponent(name).appendingPathComponent("not-an-extension")
            #expect(!FileManager.default.fileExists(atPath: inner.path))
        }
    }

    @Test func ownCopiesAreFoundAlsoForAFolderInside() {
        let top = WebExtensionStore.directory.appendingPathComponent("ABC", isDirectory: true)
        #expect(WebExtensionStore.ownCopy(top.appendingPathComponent("inner"))?.standardizedFileURL == top.standardizedFileURL)
        #expect(WebExtensionStore.ownCopy(top)?.standardizedFileURL == top.standardizedFileURL)
        #expect(WebExtensionStore.ownCopy(WebExtensionStore.directory) == nil)
        #expect(WebExtensionStore.ownCopy(URL(fileURLWithPath: "/Applications/Zotero.app/Contents/PlugIns/x.appex")) == nil)
        // A look-alike folder next to ours isn't ours.
        let twin = URL(fileURLWithPath: WebExtensionStore.directory.path + "-other/x")
        #expect(WebExtensionStore.ownCopy(twin) == nil)
    }
}
