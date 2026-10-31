import AppKit
import IOKit.pwr_mgt

/// What happens to an app after it hasn't been used for a while (like the Quitter app).
struct AutoQuitRule: Codable, Equatable {
    enum Action: String, Codable, CaseIterable, Identifiable {
        case off, hide, quit
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Keep open"
            case .hide: return "Hide"
            case .quit: return "Quit"
            }
        }
    }
    var action: Action
    var minutes: Int
}

@MainActor
final class AutoQuitManager: ObservableObject {
    /// Where an app sits in the bar, which decides its rule.
    enum Place: Equatable {
        case favorites
        /// Pinned in that workspace (or, with "open apps per workspace", opened there).
        case workspace(String)
        /// Open, not pinned anywhere.
        case open
    }

    static let minuteChoices = [1, 2, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 480]
    /// Never auto-quit these, whatever the rules say.
    static let protected: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.systemuiserver"]

    @Published var enabled: Bool { didSet { save() } }
    @Published var defaultRule: AutoQuitRule { didSet { save() } }
    /// Per-app overrides by bundle id; missing = use the default rule.
    @Published var overrides: [String: AutoQuitRule] { didSet { save() } }
    /// Apps in Favorites; nil = like open apps (the default rule).
    @Published var favoritesRule: AutoQuitRule? { didSet { save() } }
    /// Apps of a workspace, by workspace id; missing = like open apps.
    @Published var spaceRules: [String: AutoQuitRule] { didSet { save() } }
    /// Where an app is (set by the app delegate from the bar's contents); nil = everything is open.
    var place: ((String) -> Place)?

    private var lastActive: [String: Date] = [:]
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "autoQuit.enabled")
        defaultRule = Self.decode(defaults.data(forKey: "autoQuit.default")) ?? AutoQuitRule(action: .hide, minutes: 30)
        overrides = Self.decode(defaults.data(forKey: "autoQuit.overrides")) ?? [:]
        favoritesRule = Self.decode(defaults.data(forKey: "autoQuit.favorites"))
        spaceRules = Self.decode(defaults.data(forKey: "autoQuit.spaceRules")) ?? [:]

        let now = Date()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier { lastActive[id] = now }
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let id = app?.bundleIdentifier { self?.lastActive[id] = Date() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 3
    }

    /// An app's own exception wins; then the rule of where it is (Favorites, its workspace), then the general one.
    func rule(for id: String) -> AutoQuitRule { overrides[id] ?? rule(in: place?(id) ?? .open) }

    func rule(in place: Place) -> AutoQuitRule {
        switch place {
        case .favorites: favoritesRule ?? defaultRule
        case .workspace(let space): spaceRules[space] ?? defaultRule
        case .open: defaultRule
        }
    }

    func setOverride(_ rule: AutoQuitRule?, for id: String) {
        overrides[id] = rule
    }

    /// Minutes until the app gets hidden/quit, or nil if it won't.
    func minutesLeft(for id: String) -> Int? {
        guard enabled, !Self.protected.contains(id) else { return nil }
        let r = rule(for: id)
        guard r.action != .off, let last = lastActive[id] else { return nil }
        return max(0, r.minutes - Int(Date().timeIntervalSince(last) / 60))
    }

    /// For tests: when an app was last in front.
    func setLastActive(_ id: String, _ date: Date) { lastActive[id] = date }

    private func tick() {
        guard enabled else { return }
        let now = Date()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let holders = BusyApps.holders()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != front, id != Bundle.main.bundleIdentifier,
                  !Self.protected.contains(id) else { continue }
            // In a call, playing music or video, exporting, downloading: in use, even from behind.
            if BusyApps.isBusy(pid: app.processIdentifier, bundlePath: app.bundleURL?.path, holders: holders) {
                lastActive[id] = now
                continue
            }
            let r = rule(for: id)
            if lastActive[id] == nil { lastActive[id] = now }
            switch Self.decision(rule: r, lastActive: lastActive[id] ?? now, now: now, isHidden: app.isHidden) {
            case .hide:
                app.hide()
                Log.write("auto-quit: hid \(id) after \(r.minutes) min")
            case .quit:
                // terminate() asks politely; apps with unsaved changes can still ask to save.
                app.terminate()
                lastActive[id] = now
                Log.write("auto-quit: quit \(id) after \(r.minutes) min")
            case .off:
                break
            }
        }
    }

    /// What to do with an app now: hide or quit it once it hasn't been used for the rule's
    /// minutes (an app already hidden isn't hidden again), otherwise nothing (`.off`).
    nonisolated static func decision(rule: AutoQuitRule, lastActive: Date, now: Date, isHidden: Bool) -> AutoQuitRule.Action {
        guard rule.action != .off, now.timeIntervalSince(lastActive) >= Double(rule.minutes * 60) else { return .off }
        if rule.action == .hide && isHidden { return .off }
        return rule.action
    }

    private func save() {
        defaults.set(enabled, forKey: "autoQuit.enabled")
        defaults.set(try? JSONEncoder().encode(defaultRule), forKey: "autoQuit.default")
        defaults.set(try? JSONEncoder().encode(overrides), forKey: "autoQuit.overrides")
        if let favoritesRule { defaults.set(try? JSONEncoder().encode(favoritesRule), forKey: "autoQuit.favorites") }
        else { defaults.removeObject(forKey: "autoQuit.favorites") }
        defaults.set(try? JSONEncoder().encode(spaceRules), forKey: "autoQuit.spaceRules")
    }

    private static func decode<T: Decodable>(_ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

/// Apps that are doing something right now without being in front (a call, music or video,
/// an export or download): macOS knows them by the power assertions they hold to keep the
/// Mac awake, directly or through a helper (audio is played on an app's behalf).
enum BusyApps {
    struct Holder: Equatable { let pid: pid_t; let path: String }

    private static let busyTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "PreventSystemSleep",
        "NoIdleSleepAssertion", "NoDisplaySleepAssertion",
    ]

    /// Processes holding (or helped by) a keep-awake assertion right now.
    static func holders() -> [Holder] {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let byPID = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var pids = Set<pid_t>()
        for (pid, list) in byPID {
            for a in list where busyTypes.contains(a["AssertType"] as? String ?? "") {
                // Audio assertions belong to coreaudiod, made on behalf of the playing process.
                pids.insert((a["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value ?? pid.int32Value)
            }
        }
        return pids.compactMap { pid in path(of: pid).map { Holder(pid: pid, path: $0) } }
    }

    /// Whether the app (or a helper inside its bundle, e.g. an Electron helper) is among them.
    static func isBusy(pid: pid_t, bundlePath: String?, holders: [Holder]) -> Bool {
        holders.contains { h in
            h.pid == pid || (bundlePath.map { h.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } ?? false)
        }
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
