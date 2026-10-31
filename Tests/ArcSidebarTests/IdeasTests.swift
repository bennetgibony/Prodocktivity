import Foundation
import Testing
@testable import ArcSidebar

@MainActor
@Suite(.serialized)
struct IdeasTests {
    @Test func ideasAreAppendedAndCounted() {
        _ = sandbox()
        let ideas = IdeasModel()
        try? FileManager.default.removeItem(at: ideas.fileURL)
        ideas.add("First idea")
        ideas.add("  ")
        ideas.add("Second idea")
        #expect(ideas.count == 2)
        #expect(ideas.entries().last?.contains("Second idea") == true)
    }

    @Test func savingReportsSuccessAndEmptyNotesAreNotSaved() {
        _ = sandbox()
        let ideas = IdeasModel()
        #expect(ideas.add("An idea"))
        #expect(!ideas.add("   "))
    }

    @Test func theDraftSurvivesUntilSaved() {
        _ = sandbox()
        let ideas = IdeasModel()
        ideas.draft = "half a thought"
        #expect(IdeasModel().draft == "half a thought")
        ideas.draft = ""
    }

    @Test func exportReplacesAFileOnlyWithTheNewCopy() throws {
        let dir = sandbox()
        let ideas = IdeasModel()
        ideas.add("Keep me")
        let target = dir.appendingPathComponent("export.txt")
        try Data("old".utf8).write(to: target)
        #expect(ideas.exportCopy(to: target))
        #expect(try String(contentsOf: target, encoding: .utf8).contains("Keep me"))
        // Into a folder that doesn't exist: fails, nothing is lost.
        #expect(!ideas.exportCopy(to: dir.appendingPathComponent("missing/export.txt")))
    }
}
