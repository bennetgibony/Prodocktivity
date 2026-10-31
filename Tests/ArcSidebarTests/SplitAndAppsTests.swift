import Foundation
import Testing
@testable import ArcSidebar

@MainActor
struct SplitPairTests {
    private let notes = SplitTarget.app(bundleID: "com.apple.Notes")
    private let mail = SplitTarget.app(bundleID: "com.apple.mail")
    private let tab = SplitTarget.tab(id: "t1", url: "https://a.example", title: "A")

    @Test func newestFirstAndTheSamePairOnlyOnce() {
        let s = SplitManager(defaults: freshDefaults())
        s.record(left: notes, right: mail)
        s.record(left: tab, right: notes)
        s.record(left: mail, right: notes)
        #expect(s.pairs.count == 2)
        #expect(s.pairs[0].left == mail && s.pairs[0].right == notes)
    }

    @Test func aSplitWithItselfIsIgnored() {
        let s = SplitManager(defaults: freshDefaults())
        s.record(left: notes, right: notes)
        #expect(s.pairs.isEmpty)
    }

    @Test func atMostSixAreKept() {
        let s = SplitManager(defaults: freshDefaults())
        for i in 0..<9 { s.record(left: .app(bundleID: "a\(i)"), right: mail) }
        #expect(s.pairs.count == 6)
        #expect(s.pairs.first?.left == .app(bundleID: "a8"))
    }

    @Test func pairsAreKeptBetweenLaunches() {
        let d = freshDefaults()
        SplitManager(defaults: d).record(left: tab, right: mail)
        #expect(SplitManager(defaults: d).pairs.map(\.left) == [tab])
    }
}

struct InstalledAppsTests {
    private func makeApp(_ name: String, id: String, in dir: URL) throws {
        let contents = dir.appendingPathComponent("\(name).app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    @Test func findsAppsAlsoInSubfoldersOnce() throws {
        let root = sandbox(), other = sandbox()
        try makeApp("Alpha", id: "test.alpha", in: root)
        try makeApp("Beta", id: "test.beta", in: root.appendingPathComponent("Vendor"))
        try makeApp("TooDeep", id: "test.deep", in: root.appendingPathComponent("a/b/c"))
        try makeApp("Alpha Copy", id: "test.alpha", in: other)
        let apps = InstalledApps.scan(folders: [root.path, other.path], addFinder: false)
        #expect(Set(apps.map(\.id)) == ["test.alpha", "test.beta"])
        #expect(apps.first { $0.id == "test.alpha" }?.fileName == "Alpha")
    }

    @Test func missingFoldersAreSkipped() {
        #expect(InstalledApps.scan(folders: ["/nonexistent-\(UUID().uuidString)"], addFinder: false).isEmpty)
    }

    @Test func theRealScanFindsFinderAndIsQuick() {
        let start = Date()
        let apps = InstalledApps.scan()
        let ms = Date().timeIntervalSince(start) * 1000
        print("⏱ scan installed apps: \(apps.count) apps in \(Int(ms)) ms")
        #expect(apps.contains { $0.id == "com.apple.finder" })
        #expect(apps.contains { $0.id == "com.apple.Safari" })
    }
}
