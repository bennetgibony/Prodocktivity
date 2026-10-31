import Foundation
import Testing
@testable import ArcSidebar

struct FormatTests {
    private let gb = Locale(identifier: "en_GB")
    private let de = Locale(identifier: "de_DE")
    private let us = Locale(identifier: "en_US")

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    @Test func timesAreAlways24Hour() {
        #expect(Formats.time(date("2026-10-29 14:30"), locale: us) == "14:30")
        #expect(Formats.time(date("2026-10-29 09:05"), locale: gb) == "09:05")
    }

    @Test func datesFollowTheLanguage() {
        #expect(Formats.date(date("2026-10-29 14:30"), locale: de) == "29.10.2026")
        #expect(Formats.date(date("2026-10-29 14:30"), locale: gb) == "29/10/2026")
    }

    @Test func weeksStartOnMonday() {
        #expect(Formats.calendar(locale: us).firstWeekday == 2)
        #expect(Formats.calendar(locale: us).minimumDaysInFirstWeek == 4)
    }

    @Test func relativeDaysInLists() {
        let now = date("2026-10-29 14:30")
        #expect(Formats.relativeDay(date("2026-10-29 08:00"), now: now, locale: gb) == "Today")
        #expect(Formats.relativeDay(date("2026-10-28 23:00"), now: now, locale: gb) == "Yesterday")
        #expect(Formats.relativeDay(date("2026-10-30 01:00"), now: now, locale: gb) == "Tomorrow")
    }

    @Test func durationsReadLikeSpeech() {
        #expect(Formats.duration(minutes: 45) == "45 min")
        #expect(Formats.duration(minutes: 60) == "1 h")
        #expect(Formats.duration(minutes: 90) == "1 h 30")
        #expect(Formats.duration(minutes: 1440) == "1 day")
        #expect(Formats.duration(minutes: 2880) == "2 days")
    }
}

@MainActor
struct DataExportTests {
    @Test func pinsBecomeCSVWithFolderPaths() {
        var space = LibrarySpace(title: "Uni")
        var folder = LibraryItem(kind: .folder, title: "Courses")
        folder.children = [.site("Stats, week 1", "https://a.example/\"q\"")]
        space.pinned = [.site("Mail", "https://mail.example"), folder, .app("com.apple.finder", title: "Finder")]
        let lines = DataExport.pinsCSV([space]).split(separator: "\n").map(String.init)
        #expect(lines == [
            "space,folder,kind,title,address",
            "Uni,,site,Mail,https://mail.example",
            "Uni,Courses,site,\"Stats, week 1\",\"https://a.example/\"\"q\"\"\"",
            "Uni,,app,Finder,com.apple.finder",
        ])
    }

    @Test func exportWritesANewFolderAndNeverOverwrites() throws {
        try Data("{}".utf8).write(to: AppPaths.file("library.json"))
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try DataExport.export(to: target, spaces: [LibrarySpace(title: "Home")])
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("library.json").path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("pins.csv").path))
        #expect(throws: (any Error).self) { try DataExport.export(to: target, spaces: []) }
    }

    @Test func backupsAreDailyAndKeptFourteenDays() throws {
        try Data("{}".utf8).write(to: AppPaths.file("library.json"))
        let fm = FileManager.default
        let old = Backups.folder.appendingPathComponent("2000-01-01")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        let unrelated = Backups.folder.appendingPathComponent("keep me")
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let now = Date()
        #expect(Backups.runIfDue(now: now))
        #expect(!Backups.runIfDue(now: now))
        #expect(Backups.days.first == Backups.dayName(now))
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: unrelated.path))
        #expect(Backups.runNow(now: now))
        #expect(fm.fileExists(atPath: Backups.folder.appendingPathComponent(Backups.dayName(now)).appendingPathComponent("library.json").path))
    }
}

@MainActor
struct GettingStartedTests {
    private func fresh() -> UserDefaults {
        let name = "gs-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func stepsTickThemselvesOff() {
        let guide = GettingStarted(defaults: fresh())
        #expect(guide.isShown(favorites: 0, spaces: 1))
        #expect(guide.done(favorites: 2, spaces: 3) == [.favorite, .space])
        guide.mark(.docklight)
        guide.mark(.hideBar)
        #expect(!guide.isShown(favorites: 1, spaces: 2))
    }

    @Test func closedStaysClosedUntilAskedAgain() {
        let defaults = fresh()
        GettingStarted(defaults: defaults).dismiss()
        let again = GettingStarted(defaults: defaults)
        #expect(!again.isShown(favorites: 0, spaces: 1))
        again.showAgain()
        #expect(GettingStarted(defaults: defaults).isShown(favorites: 0, spaces: 1))
    }

    @Test func whoeverSawTheOldIntroIsNotShownTheCard() {
        let defaults = fresh()
        defaults.set(true, forKey: "didShowIntro")
        #expect(!GettingStarted(defaults: defaults).isShown(favorites: 0, spaces: 1))
    }
}

@MainActor
struct SpaceSlideTests {
    @Test func theSlideFollowsTheSwipeDirectionSetting() {
        // Fingers to the left bring the next space; it comes in from the right (content moves left) …
        #expect(BrowserModel.slideDirection(from: 0, to: 1, reversed: false) == 1)
        #expect(BrowserModel.slideDirection(from: 1, to: 0, reversed: false) == -1)
        // … reversed, fingers to the right bring it, so it comes in from the left (content moves right).
        #expect(BrowserModel.slideDirection(from: 0, to: 1, reversed: true) == -1)
        #expect(BrowserModel.slideDirection(from: 1, to: 0, reversed: true) == 1)
    }
}

@Suite(.serialized)
struct CrashCollectorTests {
    private func reset() {
        try? FileManager.default.removeItem(at: CrashCollector.folder)
        try? FileManager.default.createDirectory(at: CrashCollector.folder, withIntermediateDirectories: true)
    }

    @Test func aSessionThatDidNotQuitIsNotedAtTheNextStart() throws {
        reset()
        try "pid 1\n".write(to: CrashCollector.folder.appendingPathComponent(".running"), atomically: true, encoding: .utf8)
        CrashCollector.reviewLastSession()
        #expect(CrashCollector.reports.count == 1)
        #expect(CrashCollector.reports.first?.lastPathComponent.hasSuffix("-ended-unexpectedly.txt") == true)
    }

    @Test func aCaughtSignalBecomesACrashReport() throws {
        reset()
        try "pid 1\n".write(to: CrashCollector.folder.appendingPathComponent(".running"), atomically: true, encoding: .utf8)
        try "Signal 11\n\n0 ArcSidebar 0x1\n".write(to: CrashCollector.folder.appendingPathComponent(".signal"), atomically: true, encoding: .utf8)
        CrashCollector.reviewLastSession()
        let report = try #require(CrashCollector.reports.first)
        #expect(report.lastPathComponent.hasSuffix("-crash.txt"))
        #expect(try String(contentsOf: report, encoding: .utf8).contains("Signal 11"))
    }

    @Test func aNormalQuitLeavesNothing() {
        reset()
        CrashCollector.endedNormally()
        CrashCollector.reviewLastSession()
        #expect(CrashCollector.reports.isEmpty)
    }

    @Test func macOSReportsForTheAppAreCopiedOnce() throws {
        reset()
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "{}".write(to: src.appendingPathComponent("ArcSidebar-2026-10-30-105455.ips"), atomically: true, encoding: .utf8)
        try "{}".write(to: src.appendingPathComponent("WhatsApp-2026-10-30-105455.ips"), atomically: true, encoding: .utf8)
        CrashCollector.copySystemReports(from: [src])
        #expect(CrashCollector.reports.map(\.lastPathComponent) == ["macos-ArcSidebar-2026-10-30-105455.ips"])
    }

    @Test func onlyTheNewestAreKept() {
        reset()
        for i in 0..<(CrashCollector.keep + 5) {
            CrashCollector.save("crash", text: "x", at: Date(timeIntervalSince1970: Double(i) * 10))
        }
        CrashCollector.prune()
        #expect(CrashCollector.reports.count == CrashCollector.keep)
    }
}
