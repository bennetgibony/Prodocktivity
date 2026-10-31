import AppKit
import Darwin

/// Keeps a record of every way a session ends badly, in AppPaths.directory/Crashes (Settings → Data):
/// - a crash: the signal or exception and the call stack, written the moment it happens;
/// - a session that ended without quitting (killed, force quit, power loss), found at the next start;
/// - macOS's own crash reports for the app, copied over at the next start;
/// - who asked the app to quit (an app sending Quit, the installer), in the log.
/// Nothing leaves the Mac.
enum CrashCollector {
    static var folder: URL { AppPaths.directory.appendingPathComponent("Crashes", isDirectory: true) }
    static let keep = 30

    private static var marker: URL { folder.appendingPathComponent(".running") }
    private static var pending: URL { folder.appendingPathComponent(".signal") }
    private static var lastSystemCheck: URL { folder.appendingPathComponent(".system-reports-checked") }

    // Set up before a crash can happen, used from the signal handler (no allocation there).
    nonisolated(unsafe) private static var signalFD: Int32 = -1
    nonisolated(unsafe) private static var markerPath: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static var frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
    nonisolated(unsafe) private static var digits = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)

    static let crashSignals: [Int32] = [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP]

    /// Call first thing at launch.
    static func start(now: Date = Date()) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reviewLastSession(now: now)
        copySystemReports()
        prune()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        try? "pid \(getpid())\nstarted \(stamp(now))\nversion \(version)\n".write(to: marker, atomically: true, encoding: .utf8)
        markerPath = strdup(marker.path)
        signalFD = open(pending.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)

        NSSetUncaughtExceptionHandler { exception in
            let text = "Exception: \(exception.name.rawValue)\nReason: \(exception.reason ?? "-")\n\n"
                + exception.callStackSymbols.joined(separator: "\n") + "\n"
            CrashCollector.save("exception", text: text)
        }
        for sig in crashSignals {
            signal(sig) { sig in
                // Only async-signal-safe calls in here: write, backtrace_symbols_fd, signal, raise.
                let fd = CrashCollector.signalFD
                if fd >= 0 {
                    CrashCollector.writeSafe(fd, "Signal ")
                    CrashCollector.writeNumber(fd, Int(sig))
                    CrashCollector.writeSafe(fd, "\n\n")
                    let count = backtrace(CrashCollector.frames, 64)
                    backtrace_symbols_fd(CrashCollector.frames, count, fd)
                }
                signal(sig, SIG_DFL)
                raise(sig)
            }
        }
        // Quit by `kill` or the installer (not a crash): end like a normal quit, without a record.
        signal(SIGTERM) { _ in
            if let path = CrashCollector.markerPath { unlink(path) }
            signal(SIGTERM, SIG_DFL)
            raise(SIGTERM)
        }
    }

    /// A normal quit: the next start finds no marker, so nothing is recorded.
    static func endedNormally() {
        try? FileManager.default.removeItem(at: marker)
        if signalFD >= 0 { close(signalFD); signalFD = -1 }
        try? FileManager.default.removeItem(at: pending)
    }

    /// Logs which app asked proDOCKtivity to quit (from the Quit Apple Event), or that it was the user.
    @MainActor static func logQuitRequest() {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication else {
            Log.write("quit: by the user (menu or ⌘Q)")
            return
        }
        let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value ?? 0
        let sender = NSRunningApplication(processIdentifier: pid_t(pid))
        Log.write("quit: asked by \(sender?.localizedName ?? "another program") (\(sender?.bundleIdentifier ?? "pid \(pid)"))")
    }

    /// Records from earlier sessions, newest first.
    static var reports: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: At the next start

    static func reviewLastSession(now: Date = Date()) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: marker.path) else { return }
        let started = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        let signalText = (try? String(contentsOf: pending, encoding: .utf8)) ?? ""
        if !signalText.isEmpty {
            save("crash", text: "The last session crashed.\n\n" + started + "\n" + signalText, at: now)
            Log.write("last session crashed (\(signalText.split(separator: "\n").first ?? "")); details in Crashes")
        } else {
            save("ended-unexpectedly", text: "The last session ended without quitting: force quit, killed, a hang the system ended, or the Mac lost power. No crash was caught.\n\n" + started, at: now)
            Log.write("last session ended unexpectedly; noted in Crashes")
        }
        try? fm.removeItem(at: pending)
        try? fm.removeItem(at: marker)
    }

    /// Copies macOS's crash reports for this app (ArcSidebar-….ips) that are new since the last look.
    static func copySystemReports(from roots: [URL] = defaultReportFolders) {
        let fm = FileManager.default
        let since = (try? fm.attributesOfItem(atPath: lastSystemCheck.path)[.modificationDate] as? Date) ?? .distantPast
        for root in roots {
            for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix("ArcSidebar") && name.hasSuffix(".ips") {
                let url = root.appendingPathComponent(name)
                guard let date = try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, date > since else { continue }
                let target = folder.appendingPathComponent("macos-" + name)
                if !fm.fileExists(atPath: target.path) {
                    try? fm.copyItem(at: url, to: target)
                    Log.write("copied macOS crash report \(name) to Crashes")
                }
            }
        }
        if fm.fileExists(atPath: lastSystemCheck.path) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: lastSystemCheck.path)
        } else {
            fm.createFile(atPath: lastSystemCheck.path, contents: nil)
        }
    }

    static var defaultReportFolders: [URL] {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        return [logs, logs.appendingPathComponent("Retired")]
    }

    /// Keeps the newest `keep` records.
    static func prune() {
        for old in reports.dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }

    // MARK: Helpers

    static func save(_ kind: String, text: String, at date: Date = Date()) {
        let url = folder.appendingPathComponent("\(stamp(date))-\(kind).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Sorts like the date: 2026-10-30_10-54-55.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: date)
    }

    private static func writeSafe(_ fd: Int32, _ s: StaticString) {
        _ = write(fd, s.utf8Start, s.utf8CodeUnitCount)
    }

    /// Signal numbers are small; written into the preallocated buffer (no allocation in a handler).
    private static func writeNumber(_ fd: Int32, _ n: Int) {
        var i = 4, v = max(n, 0)
        repeat { i -= 1; digits[i] = UInt8(48 + v % 10); v /= 10 } while v > 0 && i > 0
        _ = write(fd, digits + i, 4 - i)
    }
}
