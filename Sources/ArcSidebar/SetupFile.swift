import AppKit
import Combine

/// A setup file: proDOCKtivity's settings and workspaces in one JSON file, to set up another Mac (or
/// this one again) in one go. Two kinds:
/// - setupNA (no apps): settings, workspaces and their websites. Works on any Mac. Saved by itself after
///   every change (AppPaths.directory/Setup/setupNA.pdsetup).
/// - setupWA (with apps): also the apps in workspaces and on the Pinwall and the per-app rules (auto-quit,
///   window snapping, open as website, hidden apps, files dock folders). Saved when asked (Settings › Data).
/// Logins, open tabs, ideas and window positions are never part of it.
enum SetupFile {
    static let format = "proDOCKtivity-setup"
    static let fileExtension = "pdsetup"

    enum Kind: String { case withApps, noApps
        var fileName: String { self == .withApps ? "setupWA" : "setupNA" }
    }

    /// Preferences in both kinds.
    static let generalKeys = [
        "appearance.accent", "appearance.density", "appearance.readingFont", "appearance.textScale", "appearance.theme",
        "arcSync", "autoFitWindows", "barScreen", "blockArcSidebarPeek", "browserEngine", "browserScreen",
        "design.barTone", "design.frameUnderMenuBar", "design.frameWidth", "design.sidebarWidth", "design.tileSize",
        "dock.files", "dock.filesWidth", "dock.websites", "dock.websitesWidth", "frameMode", "frameOtherScreens",
        "ideas.askEveryDays", "matchArcSpace", "menuBarAddress.v2", "openApps.perWorkspace", "reverseSpaceSwipe",
        "searchEngine", "tabs.autoClose", "tabs.autoCloseMinutes", "tabs.siteRules", "tabs.spaceRules",
        "tabs.favoritesMinutes", "autoQuit.enabled", "autoQuit.default", "autoQuit.favorites", "autoQuit.spaceRules", "siteZoom", "pinIcons",
    ]
    /// Preferences about this Mac's apps and folders (setupWA only).
    static let appKeys = ["autoQuit.overrides", "hiddenFromTabs", "openAsWebsite", "windowRules", "keptDuplicates", "dock.folders"]

    /// Pinwall entries that are websites ("tab␟…", "fav␟…"); the others are apps.
    static func isWebsitePin(_ entry: String) -> Bool { entry.contains("\u{1F}") }

    // MARK: Making

    /// The file's contents. `created` is left out when `stamped` is false (to compare two versions).
    static func make(_ kind: Kind, defaults: UserDefaults = .standard, spaces: [LibrarySpace], profiles: [BrowserProfile],
                     stamped: Bool = true) -> Data? {
        var settings: [String: Any] = [:]
        for key in generalKeys + (kind == .withApps ? appKeys : []) {
            if let value = defaults.object(forKey: key), JSONSerialization.isValidJSONObject([value]) { settings[key] = value }
        }
        let pins = defaults.stringArray(forKey: "pinnedBundleIDs") ?? []
        settings["pinnedBundleIDs"] = kind == .withApps ? pins : pins.filter(isWebsitePin)

        let workspaces = kind == .withApps ? spaces : spaces.map(withoutApps)
        guard let spacesJSON = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(workspaces)),
              let profilesJSON = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(profiles)) else { return nil }
        var root: [String: Any] = [
            "format": format, "version": 1, "kind": kind.rawValue,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "settings": settings, "workspaces": spacesJSON, "profiles": profilesJSON,
        ]
        if stamped { root["created"] = ISO8601DateFormatter().string(from: Date()) }
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// A workspace with its apps taken out (folders keep their websites).
    static func withoutApps(_ space: LibrarySpace) -> LibrarySpace {
        func strip(_ items: [LibraryItem]) -> [LibraryItem] {
            items.compactMap { item in
                guard item.kind != .app else { return nil }
                var copy = item
                copy.children = strip(item.children)
                copy.arcTabID = nil
                return copy
            }
        }
        var copy = space
        copy.pinned = strip(space.pinned)
        return copy
    }

    // MARK: Reading

    struct Contents {
        var kind: Kind
        var settings: [String: Any]
        var workspaces: [LibrarySpace]
        var profiles: [BrowserProfile]
    }

    enum Problem: LocalizedError {
        case notASetupFile, newerFormat
        var errorDescription: String? {
            switch self {
            case .notASetupFile: "This isn't a proDOCKtivity setup file."
            case .newerFormat: "This setup file was made by a newer proDOCKtivity. Update the app first."
            }
        }
    }

    static func read(_ data: Data) throws -> Contents {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["format"] as? String == format
        else { throw Problem.notASetupFile }
        guard (root["version"] as? Int ?? 1) <= 1 else { throw Problem.newerFormat }
        func decode<T: Decodable>(_ key: String, as: T.Type) -> T? {
            guard let value = root[key], let json = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return try? JSONDecoder().decode(T.self, from: json)
        }
        return Contents(kind: Kind(rawValue: root["kind"] as? String ?? "") ?? .noApps,
                        settings: root["settings"] as? [String: Any] ?? [:],
                        workspaces: decode("workspaces", as: [LibrarySpace].self) ?? [],
                        profiles: decode("profiles", as: [BrowserProfile].self) ?? [])
    }

    // MARK: Applying

    /// Writes the settings and replaces the workspaces. A setupNA keeps this Mac's apps: its app
    /// settings stay, the Pinwall keeps its apps (the file's websites come after them).
    @MainActor
    static func apply(_ contents: Contents, defaults: UserDefaults = .standard, library: Library) {
        for (key, value) in contents.settings where generalKeys.contains(key) || appKeys.contains(key) {
            if contents.kind == .noApps, appKeys.contains(key) { continue }
            defaults.set(value, forKey: key)
        }
        if let pins = contents.settings["pinnedBundleIDs"] as? [String] {
            let keepApps = contents.kind == .noApps ? (defaults.stringArray(forKey: "pinnedBundleIDs") ?? []).filter { !isWebsitePin($0) } : []
            defaults.set(keepApps + pins.filter { !keepApps.contains($0) }, forKey: "pinnedBundleIDs")
        }
        defaults.set(true, forKey: SetupTour.doneKey)
        library.replaceAll(spaces: contents.workspaces, profiles: contents.profiles)
        Log.write("setup: applied \(contents.kind.rawValue) with \(contents.workspaces.count) workspaces")
    }

    // MARK: Files

    static var folder: URL { AppPaths.directory.appendingPathComponent("Setup", isDirectory: true) }
    static var automaticNA: URL { folder.appendingPathComponent("setupNA.\(fileExtension)") }

    /// Asks where to save a setup file of `kind` (Desktop, named setupWA / setupNA) and writes it.
    @MainActor static func saveWithPanel(_ kind: Kind, library: Library) -> String? {
        NSApp.activate()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = kind.fileName + "." + fileExtension
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let data = make(kind, spaces: library.spaces, profiles: library.profiles) else { return "Couldn't make the setup file." }
        do {
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return nil
        } catch {
            return "Couldn't save “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    /// Asks for a setup file and reads it (nil when cancelled).
    @MainActor static func openWithPanel() -> Result<Contents, Error>? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a setup file (setupWA or setupNA)."
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Result { try read(Data(contentsOf: url)) }
    }

    /// Starts proDOCKtivity again (settings are read at launch).
    @MainActor static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// Keeps setupNA up to date: a few seconds after any change to settings or workspaces, the file is
/// written again (only when its contents actually changed).
@MainActor
final class SetupAutosave {
    private let library: Library
    private var pending: DispatchWorkItem?
    private var subscriptions: Set<AnyCancellable> = []

    init(library: Library) {
        self.library = library
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .merge(with: library.$spaces.map { _ in Notification(name: .init("library")) }.eraseToAnyPublisher(),
                   library.$profiles.map { _ in Notification(name: .init("profiles")) }.eraseToAnyPublisher())
            .sink { [weak self] _ in self?.schedule() }
            .store(in: &subscriptions)
        schedule()
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.write() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func write() {
        let url = SetupFile.automaticNA
        guard let fresh = SetupFile.make(.noApps, spaces: library.spaces, profiles: library.profiles, stamped: false) else { return }
        // Compare without the time stamp, so an unchanged setup isn't rewritten.
        if let old = try? Data(contentsOf: url), let oldRoot = try? JSONSerialization.jsonObject(with: old) as? [String: Any] {
            var unstamped = oldRoot
            unstamped["created"] = nil
            if let same = try? JSONSerialization.data(withJSONObject: unstamped, options: [.prettyPrinted, .sortedKeys]), same == fresh { return }
        }
        guard let data = SetupFile.make(.noApps, spaces: library.spaces, profiles: library.profiles) else { return }
        try? FileManager.default.createDirectory(at: SetupFile.folder, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
