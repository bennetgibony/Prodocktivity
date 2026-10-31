import AppKit

/// Everything proDOCKtivity keeps, in open formats: export to a folder of your choice, and a
/// daily copy in the app's own folder kept for 14 days (Settings → Data).
@MainActor
enum DataExport {
    /// The files that make up your data (all in AppPaths.directory).
    static let files = ["library.json", "browser-tabs.json", "profiles.json", "extensions.json", "proDOCKtivity Ideas.txt"]

    /// Writes a new folder at `folder`: the data files as they are, the settings as a property
    /// list, and the pins of every space as CSV. Nothing is overwritten: an existing folder fails.
    static func export(to folder: URL, spaces: [LibrarySpace], defaults: UserDefaults = .standard) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try copyFiles(to: folder)
        if let id = Bundle.main.bundleIdentifier, let prefs = defaults.persistentDomain(forName: id) {
            let data = try PropertyListSerialization.data(fromPropertyList: prefs, format: .xml, options: 0)
            try data.write(to: folder.appendingPathComponent("settings.plist"))
        }
        try pinsCSV(spaces).write(to: folder.appendingPathComponent("pins.csv"), atomically: true, encoding: .utf8)
    }

    static func copyFiles(to folder: URL) throws {
        let fm = FileManager.default
        for name in files {
            let source = AppPaths.directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.copyItem(at: source, to: folder.appendingPathComponent(name))
        }
    }

    /// One line per pinned website or app, folders written as a path ("Uni / Courses").
    static func pinsCSV(_ spaces: [LibrarySpace]) -> String {
        var lines = ["space,folder,kind,title,address"]
        func walk(_ items: [LibraryItem], space: String, path: [String]) {
            for item in items {
                if item.kind == .folder {
                    walk(item.children, space: space, path: path + [item.title])
                } else {
                    lines.append([space, path.joined(separator: " / "), item.kind.rawValue, item.title, item.url].map(csvField).joined(separator: ","))
                }
            }
        }
        for space in spaces { walk(space.pinned, space: space.title, path: []) }
        return lines.joined(separator: "\n") + "\n"
    }

    static func csvField(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    /// Asks where to put the export (Desktop by default) and writes it.
    static func exportWithPanel(spaces: [LibrarySpace]) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "proDOCKtivity Export " + Backups.dayName(Date())
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try export(to: url, spaces: spaces)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return nil
        } catch {
            Log.write("export failed: \(error)")
            return "Couldn't export to “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }
}

/// Daily copies of the data files in AppPaths.directory/Backups/<yyyy-MM-dd>, kept 14 days.
enum Backups {
    static let keepDays = 14
    static var folder: URL { AppPaths.directory.appendingPathComponent("Backups", isDirectory: true) }

    static func dayName(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Makes today's copy if there is none yet, then removes copies older than 14 days.
    @MainActor @discardableResult
    static func runIfDue(now: Date = Date()) -> Bool {
        let today = folder.appendingPathComponent(dayName(now), isDirectory: true)
        var made = false
        if !FileManager.default.fileExists(atPath: today.path) {
            do {
                try FileManager.default.createDirectory(at: today, withIntermediateDirectories: true)
                try DataExport.copyFiles(to: today)
                made = true
            } catch {
                Log.write("backup failed: \(error)")
                try? FileManager.default.removeItem(at: today)
            }
        }
        prune(now: now)
        return made
    }

    static func prune(now: Date = Date()) {
        let fm = FileManager.default
        let cutoff = dayName(now.addingTimeInterval(-Double(keepDays) * 86_400))
        // Folder names sort like dates; only our own yyyy-MM-dd folders are touched.
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where isDayName(name) && name < cutoff {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    static func isDayName(_ name: String) -> Bool {
        name.count == 10 && name.enumerated().allSatisfy { i, c in [4, 7].contains(i) ? c == "-" : c.isASCII && c.isNumber }
    }

    /// Days with a copy, newest first.
    static var days: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter(isDayName).sorted(by: >)
    }
}

extension Backups {
    /// Today's copy made again from the current files (the old one is replaced only once the new one exists).
    @MainActor @discardableResult
    static func runNow(now: Date = Date()) -> Bool {
        let fm = FileManager.default
        let fresh = folder.appendingPathComponent(".new-" + UUID().uuidString, isDirectory: true)
        let today = folder.appendingPathComponent(dayName(now), isDirectory: true)
        do {
            try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
            try DataExport.copyFiles(to: fresh)
            if fm.fileExists(atPath: today.path) {
                _ = try fm.replaceItemAt(today, withItemAt: fresh)
            } else {
                try fm.moveItem(at: fresh, to: today)
            }
            return true
        } catch {
            Log.write("backup failed: \(error)")
            try? fm.removeItem(at: fresh)
            return false
        }
    }
}
