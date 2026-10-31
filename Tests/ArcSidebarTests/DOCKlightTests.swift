import Foundation
import Testing
@testable import ArcSidebar

@MainActor
struct DOCKlightTests {
    @Test func scoresWholeNameThenStartThenWordThenAnywhere() {
        #expect(CommandBarModel.matchScore("Mail", "mail") == 0)
        #expect(CommandBarModel.matchScore("Mailspring", "mail") == 1)
        #expect(CommandBarModel.matchScore("Apple Mail", "mail") == 2)
        #expect(CommandBarModel.matchScore("Gmail", "mail") == 3)
        #expect(CommandBarModel.matchScore("Calendar", "mail") == nil)
        #expect(CommandBarModel.matchScore("Anything", "") == nil)
    }

    @Test func caseAndAccentsDontMatter() {
        #expect(CommandBarModel.matchScore("Über uns", "uber") == 1)
        #expect(CommandBarModel.matchScore("Systemeinstellungen", "SYSTEM") == 1)
        #expect(CommandBarModel.matchScore("Café Notes", "cafe") == 1)
    }

    @Test func wordsAfterPunctuationCount() {
        #expect(CommandBarModel.matchScore("Moodle – Dashboard", "dash") == 2)
        #expect(CommandBarModel.matchScore("re:Invent/Keynote", "key") == 2)
    }

    @Test func rankingPutsTheBestMatchFirstAndKeepsOrderOnTies() {
        let names = ["Gmail", "Mailspring", "Apple Mail", "Mail", "Mailbutler"]
        #expect(CommandBarModel.ranked(names, "mail") { [$0] } == ["Mail", "Mailspring", "Mailbutler", "Apple Mail", "Gmail"])
    }

    @Test func anAppMatchesByEitherName() {
        let apps = [("System Settings", "Systemeinstellungen"), ("Settings Helper", "Settings Helper")]
        let ranked = CommandBarModel.ranked(apps, "systemein") { [$0.0, $0.1] }
        #expect(ranked.map(\.1) == ["Systemeinstellungen"])
    }

    @Test func sitesMatchByTitleBeforeAddress() {
        #expect(CommandBarModel.siteScore(title: "Moodle", url: "https://moodle.example", "moo") == 1)
        #expect(CommandBarModel.siteScore(title: "My courses", url: "https://moodle.example", "moodle") == 4)
        #expect(CommandBarModel.siteScore(title: "Mail", url: "https://x.example", "zzz") == nil)
        let sites = [("Uni portal", "https://moodle.example"), ("Moodle", "https://lms.example")]
        #expect(CommandBarModel.ranked(sites) { CommandBarModel.siteScore(title: $0.0, url: $0.1, "moodle") }.map(\.0) == ["Moodle", "Uni portal"])
    }

    @Test func addressesAreRecognized() {
        for a in ["moodle.de", "https://x.y", "localhost:3000", "sub.example.com/path", "file://a"] {
            #expect(CommandBarModel.looksLikeAddress(a), "\(a)")
        }
        for q in ["hello world", "", "version 1.2", "a.b2", "notes", "x.y z"] {
            #expect(!CommandBarModel.looksLikeAddress(q), "\(q)")
        }
    }

    @Test func appInternalFilesAreHidden() {
        let home = NSHomeDirectory()
        for p in ["/Zotero/translators/Google Books.js", "/Developer/x/node_modules/a.js", "/.cache/google.txt", "/Library/Caches/g.js"] {
            #expect(CommandBarModel.isAppInternal(home + p), "\(p)")
        }
        for p in ["/Zotero/storage/ABC/Google paper.pdf", "/Documents/google notes.md", "/myFocus/tests/suite.js"] {
            #expect(!CommandBarModel.isAppInternal(home + p), "\(p)")
        }
    }
}
