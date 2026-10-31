import Foundation
import Testing
@testable import ArcSidebar

/// Rough timings of the hot paths (redrawn or polled often), with generous limits so they only
/// fail on a real slowdown. The measured times go to the test output.
@MainActor
struct PerformanceTests {
    private func measure(_ label: String, repeat n: Int = 1, _ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<n { work() }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / Double(n)
        print("⏱ \(label): \(String(format: "%.3f", ms)) ms")
        return ms
    }

    @Test func fiftyTabsSaveRestoreAndList() {
        let file = sandbox().appendingPathComponent("tabs.json")
        let web = WebBrowser(stateURL: file)
        for i in 0..<50 { web.newTab(url: "https://site\(i).example/page", inSpace: "s\(i % 5)", show: false) }
        let save = measure("save 50 tabs") { web.saveNow() }
        var restored: WebBrowser?
        let restore = measure("restore 50 tabs") { restored = WebBrowser(stateURL: file) }
        #expect(restored?.tabs.count == 50)
        // Saved tabs come back without a page loaded: they cost nothing until shown.
        #expect(restored?.tabs.allSatisfy { $0.webView == nil } == true)
        let list = measure("tab list (snapshot) of 50 tabs", repeat: 200) { _ = web.snapshot() }
        #expect(save < 200 && restore < 200 && list < 5)
    }

    @Test func bigArcAnswerParsesQuickly() {
        var records: [[String]] = [["A", "t0", "sp0"]]
        for s in 0..<8 {
            records.append(["S", "sp\(s)", "Space \(s)"])
            for t in 0..<40 { records.append(["T", "t\(s)-\(t)", "Title \(t)", "https://x\(t).example/\(s)", t < 5 ? "pinned" : "unpinned"]) }
        }
        let raw = records.map { $0.joined(separator: "\u{1F}") + "\u{1E}" }.joined()
        let arc = ArcProvider()
        let ms = measure("parse Arc answer with 320 tabs", repeat: 50) { _ = arc.snapshot(from: raw, tree: nil, full: true) }
        #expect(ms < 20)
    }

    @Test func librarySpacesWithManyPinsDisplayQuickly() {
        let lib = Library(fileURL: sandbox().appendingPathComponent("library.json"), defaults: freshDefaults())
        for s in 0..<6 {
            let space = lib.addSpace(title: "Space \(s)")
            for i in 0..<60 { lib.add(.site("Site \(i)", "https://s\(s)-\(i).example"), toSpace: space.id) }
        }
        var live = BrowserSpace(id: "x", title: "")
        live.unpinned = (0..<50).map { BrowserItem(id: "t\($0)", title: "T", url: "https://t\($0).example", kind: .tab) }
        let snap = BrowserSnapshot(spaces: [live], activeSpaceID: "x")
        let ms = measure("display 6 spaces × 60 pins + 50 tabs", repeat: 50) {
            for s in lib.spaces { _ = lib.displaySpace(s, live: snap) }
        }
        #expect(ms < 30)
    }

    @Test func docklightRanksHundredsOfAppsPerKeystroke() {
        let names = (0..<600).map { "Application Number \($0) Helper" } + ["Mail", "Mailspring", "Maps"]
        let ms = measure("rank 603 app names", repeat: 50) { _ = CommandBarModel.ranked(names, "ma") { [$0] } }
        #expect(ms < 30)
    }

    @Test func duplicateCheckForEveryPinAndApp() {
        let apps = (0..<80).map { ("App \($0)", "com.vendor\($0).app\($0)") }
        let urls = (0..<100).map { "https://www.site\($0).example/path" }
        let ms = measure("duplicates 80 apps × 100 sites") {
            for (n, id) in apps { for u in urls { _ = Duplicates.matches(appName: n, bundleID: id, url: u) } }
        }
        #expect(ms < 500)
    }
}
