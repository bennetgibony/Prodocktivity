import AppKit
import WebKit

/// Web extensions for the built-in browser (WebKit's WKWebExtension, macOS 15.4+): Safari web
/// extensions (inside apps, e.g. Zotero.app), and Chrome / Firefox style extensions (a folder, .zip,
/// .xpi or .crx). The list lives in Application Support; unpacked extensions are copied there too.
@MainActor
final class WebExtensionStore: ObservableObject {
    static let shared = WebExtensionStore()

    struct Entry: Codable, Identifiable, Equatable {
        enum Kind: String, Codable { case folder, appExtension }
        var id: String
        var name: String
        var version: String
        var kind: Kind
        /// Folder (copied into our Extensions folder) or the .appex inside an app.
        var path: String
        var enabled: Bool
        /// Where it came from, e.g. a Chrome profile folder or an app, so it isn't suggested twice.
        var source: String?
    }

    /// Something on this Mac that can be added with one click.
    struct Suggestion: Identifiable {
        let id: String  // the source path
        let name: String
        let from: String
        let url: URL
    }

    @Published private(set) var entries: [Entry] = []
    /// Why an extension couldn't be loaded, by entry id.
    @Published private(set) var problems: [String: String] = [:]
    /// Loaded extensions with a toolbar action, for the bar's extensions menu (id, name, icon).
    @Published private(set) var actions: [(id: String, name: String, icon: NSImage?)] = []
    @Published private(set) var busy: String?
    /// The last add or download that failed, shown in place with Retry instead of an alert.
    @Published private(set) var failure: Failure?

    struct Failure: Equatable {
        enum Retry: Equatable { case install(URL, source: String?), uBlock }
        let message: String
        let retry: Retry
    }

    static var isSupported: Bool { if #available(macOS 15.4, *) { return true } else { return false } }

    private var hostBox: AnyObject?
    @available(macOS 15.4, *) var host: ExtensionHost {
        if let host = hostBox as? ExtensionHost { return host }
        let host = ExtensionHost(store: self)
        hostBox = host
        return host
    }

    nonisolated static var directory: URL {
        let dir = AppPaths.directory.appendingPathComponent("Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var listURL: URL { directory.deletingLastPathComponent().appendingPathComponent("extensions.json") }

    private init() {
        if let list = AppPaths.load([Entry].self, from: Self.listURL) { entries = list }
    }

    /// Before the first web view: the controller exists, enabled extensions load.
    func start() {
        guard #available(macOS 15.4, *) else { return }
        _ = host
        for entry in entries where entry.enabled { load(entry) }
    }

    /// An extension's keyboard shortcut was typed.
    static func performCommand(for event: NSEvent) -> Bool {
        guard #available(macOS 15.4, *), shared.hostBox != nil else { return false }
        return shared.host.performCommand(for: event)
    }

    /// Extension entries for a page's right-click menu.
    func contextMenuItems(for webView: WKWebView) -> [NSMenuItem] {
        guard #available(macOS 15.4, *), hostBox != nil else { return [] }
        return host.contextMenuItems(for: webView)
    }

    /// Adds the extension controller to a browser tab's configuration.
    func attach(to config: WKWebViewConfiguration) {
        guard #available(macOS 15.4, *) else { return }
        config.webExtensionController = host.controller
    }

    // MARK: Adding and removing

    /// A folder, .zip / .xpi / .crx, a Safari web extension (.appex) or an app containing one.
    func install(from url: URL, source: String? = nil) {
        Task { @MainActor in await installNow(from: url, source: source) }
    }

    /// Adds the extension and returns once it's done (the file at `url` can be removed then).
    func installNow(from url: URL, source: String? = nil) async {
        guard #available(macOS 15.4, *) else { return }
        busy = url.lastPathComponent
        failure = nil
        defer { busy = nil }
        // Our unpacked copy, removed again if the extension can't be added.
        var unpackedCopy: URL?
        do {
            // Unpacking can take a while (uBlock has many filter lists): off the main thread.
            let (kind, path) = try await Task.detached(priority: .userInitiated) { try Self.prepare(url) }.value
            unpackedCopy = Self.ownCopy(path)
            let ext = try await Self.makeExtension(kind: kind, path: path)
            if let problem = ext.errors.first, ext.manifest.isEmpty { throw problem }
            var entry = Entry(id: UUID().uuidString, name: ext.displayName ?? url.deletingPathExtension().lastPathComponent,
                              version: ext.displayVersion ?? ext.version ?? "", kind: kind, path: path.path,
                              enabled: true, source: source ?? url.path)
            if entry.name.isEmpty { entry.name = "Extension" }
            entries.append(entry)
            save()
            host.load(entry, extension: ext)
            Log.write("extension added: \(entry.name) \(entry.version)")
        } catch {
            if let copy = unpackedCopy { try? FileManager.default.removeItem(at: copy) }
            Log.write("extension add failed: \(url.lastPathComponent): \(error)")
            // The downloaded uBlock zip is gone afterwards: retrying downloads it again.
            failure = Failure(message: "Couldn't add “\(url.lastPathComponent)”: \(error.localizedDescription)",
                              retry: source == "github:uBOL-home" ? .uBlock : .install(url, source: source))
        }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].enabled = on
        save()
        guard #available(macOS 15.4, *) else { return }
        if on { load(entries[i]) } else { host.unload(id) }
    }

    func remove(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: i)
        save()
        problems[id] = nil
        if #available(macOS 15.4, *) { host.unload(id) }
        // Only our own copies are deleted, never an app's extension.
        if entry.kind == .folder, let copy = Self.ownCopy(URL(fileURLWithPath: entry.path)) {
            try? FileManager.default.removeItem(at: copy)
        }
    }

    /// The official uBlock Origin Lite build for Safari, from its GitHub releases.
    func getUBlockOriginLite() {
        busy = "uBlock Origin Lite"
        failure = nil
        Task { @MainActor in
            do {
                let api = URL(string: "https://api.github.com/repos/uBlockOrigin/uBOL-home/releases/latest")!
                let (data, _) = try await URLSession.shared.data(from: api)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let assets = json["assets"] as? [[String: Any]],
                      let link = assets.compactMap({ $0["browser_download_url"] as? String }).first(where: { $0.hasSuffix(".safari.zip") }),
                      let url = URL(string: link) else { throw ExtensionError("No Safari build in the latest release.") }
                let (file, _) = try await URLSession.shared.download(from: url)
                let zip = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: zip)
                try FileManager.default.moveItem(at: file, to: zip)
                busy = nil
                // Installing reads the zip: it's removed only after that's done.
                await installNow(from: zip, source: "github:uBOL-home")
                try? FileManager.default.removeItem(at: zip)
            } catch {
                busy = nil
                failure = Failure(message: "Couldn't download uBlock Origin Lite: \(error.localizedDescription) Check the internet connection, then retry.",
                                  retry: .uBlock)
            }
        }
    }

    func retry() {
        guard let failure else { return }
        self.failure = nil
        switch failure.retry {
        case .install(let url, let source): install(from: url, source: source)
        case .uBlock: getUBlockOriginLite()
        }
    }

    func dismissFailure() { failure = nil }

    var hasUBlock: Bool { entries.contains { $0.source == "github:uBOL-home" || $0.name.localizedCaseInsensitiveContains("uBlock") } }

    /// Turns what was picked into something WebKit can load: our own unpacked copy, or the .appex.
    nonisolated static func prepare(_ url: URL) throws -> (Entry.Kind, URL) {
        let fm = FileManager.default
        let ext = url.pathExtension.lowercased()
        if ext == "appex" { return (.appExtension, url) }
        if ext == "app" {
            let plugins = url.appendingPathComponent("Contents/PlugIns")
            let found = (try? fm.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil))?.first { Self.isSafariWebExtension($0) }
            guard let found else { throw ExtensionError("This app has no Safari web extension inside.") }
            return (.appExtension, found)
        }
        let target = Self.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            guard fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else {
                throw ExtensionError("There's no manifest.json in this folder.")
            }
            try fm.copyItem(at: url, to: target)
            return (.folder, target)
        }
        var zip = url
        if ext == "crx" { zip = try Self.zipFromCRX(url) }
        guard ["zip", "xpi", "crx"].contains(ext) else { throw ExtensionError("Pick a folder, a .zip, .xpi or .crx file, or an app.") }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, target.path]
        try unzip.run()
        unzip.waitUntilExit()
        if ext == "crx" { try? fm.removeItem(at: zip) }
        guard unzip.terminationStatus == 0 else { try? fm.removeItem(at: target); throw ExtensionError("The file couldn't be unpacked.") }
        if fm.fileExists(atPath: target.appendingPathComponent("manifest.json").path) { return (.folder, target) }
        // Some archives have one folder at the top.
        if let inner = try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil),
           let only = inner.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }) {
            return (.folder, only)
        }
        try? fm.removeItem(at: target)
        throw ExtensionError("There's no manifest.json in this file, so it isn't a web extension.")
    }

    /// The folder we unpacked an extension into (the extension itself can be a folder inside
    /// it), or nil if `path` isn't one of our copies.
    nonisolated static func ownCopy(_ path: URL) -> URL? {
        let base = directory.standardizedFileURL.pathComponents
        let parts = path.standardizedFileURL.pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return nil }
        return directory.appendingPathComponent(parts[base.count], isDirectory: true)
    }

    /// A .crx is a zip with a small header in front.
    nonisolated static func zipFromCRX(_ url: URL) throws -> URL {
        let data = try Data(contentsOf: url)
        guard data.count > 16, data.prefix(4) == Data("Cr24".utf8) else { throw ExtensionError("Not a Chrome extension file.") }
        func u32(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24 }
        let version = u32(4)
        guard version == 2 || version == 3 else { throw ExtensionError("Unknown Chrome extension format (version \(version)).") }
        // The header sizes come from the file: a damaged one must not point past its end.
        let start = version == 3 ? 12 + u32(8) : 16 + u32(8) + u32(12)
        guard start < data.count else { throw ExtensionError("The Chrome extension file is damaged.") }
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try data.subdata(in: start..<data.count).write(to: zip)
        return zip
    }

    nonisolated private static func isSafariWebExtension(_ appex: URL) -> Bool {
        guard appex.pathExtension == "appex", let info = Bundle(url: appex)?.infoDictionary,
              let ext = info["NSExtension"] as? [String: Any] else { return false }
        return ext["NSExtensionPointIdentifier"] as? String == "com.apple.Safari.web-extension"
    }

    @available(macOS 15.4, *)
    fileprivate static func makeExtension(kind: Entry.Kind, path: URL) async throws -> WKWebExtension {
        switch kind {
        case .appExtension:
            guard let bundle = Bundle(url: path) else { throw ExtensionError("The extension is gone (was its app removed?).") }
            return try await WKWebExtension(appExtensionBundle: bundle)
        case .folder:
            return try await WKWebExtension(resourceBaseURL: path)
        }
    }

    @available(macOS 15.4, *)
    private func load(_ entry: Entry) {
        Task { @MainActor in
            do {
                let ext = try await Self.makeExtension(kind: entry.kind, path: URL(fileURLWithPath: entry.path))
                host.load(entry, extension: ext)
            } catch {
                problems[entry.id] = error.localizedDescription
                Log.write("extension load failed: \(entry.name): \(error)")
            }
        }
    }

    fileprivate func setProblem(_ id: String, _ text: String?) { problems[id] = text }
    fileprivate func setActions(_ list: [(id: String, name: String, icon: NSImage?)]) { actions = list }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: Self.listURL, options: .atomic) }
    }

    /// The toolbar button of an extension was picked in the bar.
    func performAction(_ id: String) {
        guard #available(macOS 15.4, *) else { return }
        host.performAction(id)
    }

    // MARK: Found on this Mac

    /// Extensions installed in Chrome, Arc, Brave or Edge, and Safari web extensions inside apps.
    func suggestions() -> [Suggestion] {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let browsers: [(String, String)] = [("Google/Chrome", "Chrome"), ("Arc/User Data", "Arc"),
                                            ("BraveSoftware/Brave-Browser", "Brave"), ("Microsoft Edge", "Edge")]
        let taken = Set(entries.compactMap(\.source))
        var out: [Suggestion] = []
        var names = Set<String>()
        for (dir, browser) in browsers {
            let base = support.appendingPathComponent(dir)
            for profile in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
                let exts = profile.appendingPathComponent("Extensions")
                for id in (try? fm.contentsOfDirectory(at: exts, includingPropertiesForKeys: nil)) ?? [] {
                    // Apple's iCloud Passwords helper only talks to the browsers macOS allows.
                    guard !Self.unsupportedChromeIDs.contains(id.lastPathComponent) else { continue }
                    let versions = ((try? fm.contentsOfDirectory(at: id, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
                    guard let folder = versions.last, let name = Self.manifestName(folder), !names.contains(name),
                          !taken.contains(folder.path) else { continue }
                    names.insert(name)
                    out.append(Suggestion(id: folder.path, name: name, from: browser, url: folder))
                }
            }
        }
        for appsDir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            for app in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: appsDir), includingPropertiesForKeys: nil)) ?? []
            where app.pathExtension == "app" {
                let plugins = app.appendingPathComponent("Contents/PlugIns")
                for appex in (try? fm.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? []
                where Self.isSafariWebExtension(appex) && !taken.contains(appex.path) {
                    let name = Self.manifestName(appex.appendingPathComponent("Contents/Resources")) ?? app.deletingPathExtension().lastPathComponent
                    // The Safari version of an extension wins over a copy from another browser.
                    out.removeAll { $0.name == name }
                    names.insert(name)
                    out.append(Suggestion(id: appex.path, name: name, from: app.deletingPathExtension().lastPathComponent + " (Safari version)", url: appex))
                }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// iCloud Passwords (Chrome / Edge builds).
    static let unsupportedChromeIDs: Set<String> = ["pejdijmoenmkgeppbflobdenhhabjlaj", "mfbcdcnpokpoajjciilocoachedjkima"]

    /// The extension's name from its manifest, with "__MSG_…__" looked up in its translations.
    private static func manifestName(_ folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var name = manifest["name"] as? String else { return nil }
        if name.hasPrefix("__MSG_"), name.hasSuffix("__") {
            let key = String(name.dropFirst(6).dropLast(2)).lowercased()
            let locale = manifest["default_locale"] as? String ?? "en"
            for loc in [locale, "en", "en_US"] {
                let file = folder.appendingPathComponent("_locales/\(loc)/messages.json")
                if let d = try? Data(contentsOf: file), let messages = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let entry = messages.first(where: { $0.key.lowercased() == key })?.value as? [String: Any],
                   let message = entry["message"] as? String {
                    name = message
                    break
                }
            }
        }
        // Chrome's own built-in helpers have no real name.
        return name.hasPrefix("__MSG_") || name.isEmpty ? nil : name
    }
}

struct ExtensionError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

// MARK: - WebKit side

/// The extension controller, and the browser's tabs and window as WebKit's extensions see them.
@available(macOS 15.4, *)
@MainActor
final class ExtensionHost: NSObject, WKWebExtensionControllerDelegate {
    let controller: WKWebExtensionController
    private unowned let store: WebExtensionStore
    private var contexts: [String: WKWebExtensionContext] = [:]
    private var tabs: [String: ExtensionTab] = [:]
    private var activeTabID: String?
    private(set) lazy var window = ExtensionWindow(host: self)

    init(store: WebExtensionStore) {
        self.store = store
        // The extensions' own pages (popup, background) identify as Safari like the tabs do:
        // Bitwarden and others only use their Safari code path when they see "Safari/" there.
        let configuration = WKWebExtensionController.Configuration.default()
        configuration.webViewConfiguration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        controller.didOpenWindow(window)
        controller.didFocusWindow(window)
    }

    func load(_ entry: WebExtensionStore.Entry, extension ext: WKWebExtension) {
        unload(entry.id)
        let context = WKWebExtensionContext(for: ext)
        // A stable address, so the extension keeps its settings and storage between launches.
        context.uniqueIdentifier = entry.id
        context.isInspectable = true
        // You added it yourself: it gets what it asks for.
        for permission in ext.requestedPermissions.union(ext.optionalPermissions) {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        // Bitwarden keeps asking its desktop app over native messaging (Touch ID prompts, and
        // WebKit's lookup of the app on the main thread cost ~23% CPU while idle). Without that
        // permission it doesn't try. Other extensions (Zotero) keep theirs.
        if entry.name.localizedCaseInsensitiveContains("bitwarden") {
            context.setPermissionStatus(.deniedExplicitly, for: .nativeMessaging)
        }
        for pattern in ext.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        do {
            try controller.load(context)
            contexts[entry.id] = context
            store.setProblem(entry.id, nil)
            Log.write("extension loaded: \(entry.name) \(entry.version) warnings=\(ext.errors.map(\.localizedDescription))")
            syncTabs()
        } catch {
            store.setProblem(entry.id, error.localizedDescription)
            Log.write("extension context failed: \(entry.name): \(error)")
        }
        publishActions()
    }

    func unload(_ id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
        publishActions()
    }

    private func publishActions() {
        let list = store.entries.compactMap { entry -> (id: String, name: String, icon: NSImage?)? in
            guard let context = contexts[entry.id], context.webExtension.manifest["action"] != nil
                    || context.webExtension.manifest["browser_action"] != nil else { return nil }
            return (entry.id, entry.name, context.webExtension.actionIcon(for: CGSize(width: 16, height: 16))
                    ?? context.webExtension.icon(for: CGSize(width: 16, height: 16)))
        }
        store.setActions(list)
    }

    /// The extension's toolbar button: its popup opens next to the bar, or it acts on the page.
    func performAction(_ id: String) {
        guard let context = contexts[id] else { return }
        // A private tab isn't known to extensions: the button then acts on a normal tab of the space.
        let browser = WebBrowser.shared
        let tab = browser.activeTab.flatMap { tabs[$0.id] } ?? windowTabs.first
        Log.write("extension button: \(context.webExtension.displayName ?? id), tab \(tab?.tab?.url ?? "none")")
        if let tab { context.userGesturePerformed(in: tab) }
        context.performAction(for: tab)
    }

    /// An extension's keyboard shortcut (e.g. Bitwarden's ⌘⇧L fill) was typed: runs its command.
    func performCommand(for event: NSEvent) -> Bool {
        for context in contexts.values where context.performCommand(for: event) { return true }
        return false
    }

    /// The extensions' entries for the page's right-click menu (e.g. Bitwarden's "Auto-fill").
    func contextMenuItems(for webView: WKWebView) -> [NSMenuItem] {
        guard let tab = tabs.values.first(where: { $0.tab?.webView === webView }) else { return [] }
        return contexts.values.flatMap { $0.menuItems(for: tab) }
    }

    // MARK: Tabs

    /// Tells WebKit about opened, closed and switched tabs (called whenever the browser changes).
    func syncTabs() {
        let browser = WebBrowser.shared
        let openTabs = browser.tabs.filter { !$0.isIncognito }
        let live = Set(openTabs.map(\.id))
        for (id, tab) in tabs where !live.contains(id) {
            tabs[id] = nil
            controller.didCloseTab(tab, windowIsClosing: false)
        }
        for webTab in openTabs where tabs[webTab.id] == nil {
            let tab = ExtensionTab(tab: webTab, host: self)
            tabs[webTab.id] = tab
            controller.didOpenTab(tab)
        }
        let active = browser.activeTab?.id
        if active != activeTabID, let active, let tab = tabs[active] {
            controller.didActivateTab(tab, previousActiveTab: activeTabID.flatMap { tabs[$0] })
            controller.didSelectTabs([tab])
        }
        activeTabID = active
    }

    func tabChanged(_ webTab: WebTab) {
        guard let tab = tabs[webTab.id] else { return }
        controller.didChangeTabProperties([.URL, .title, .loading], for: tab)
    }

    func tab(for id: String) -> ExtensionTab? { tabs[id] }

    /// Tabs of the space you're in (the extensions' one window).
    var windowTabs: [ExtensionTab] {
        let space = WebBrowser.shared.activeSpaceID
        return WebBrowser.shared.tabs.filter { $0.spaceID == space }.compactMap { tabs[$0.id] }
    }

    // MARK: Delegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let webTab = WebBrowser.shared.newTab(url: configuration.url?.absoluteString ?? "about:blank", show: configuration.shouldBeActive)
        syncTabs()
        completionHandler(tabs[webTab.id], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if let url = extensionContext.optionsPageURL { WebBrowser.shared.newTab(url: url.absoluteString); syncTabs() }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        completionHandler(urls, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        completionHandler(matchPatterns, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        publishActions()
    }

    /// The popup (e.g. uBlock's on/off switch) opens next to the bar, over the page.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover, let (view, rect) = ExtensionUI.anchor?() else {
            Log.write("extension popup: nowhere to show it")
            completionHandler(ExtensionError("Nowhere to show the popup.")); return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.behavior = .transient
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
        Log.write("extension popup: \(context.webExtension.displayName ?? "?") shown=\(popover.isShown) viewInWindow=\(view.window != nil) windowVisible=\(view.window?.isVisible ?? false)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Log.write("extension popup: \(context.webExtension.displayName ?? "?") after 1.5 s shown=\(popover.isShown) size=\(popover.contentSize)")
        }
        completionHandler(nil)
    }
}

/// Where extension popups are shown (the bar's top right corner).
@MainActor enum ExtensionUI {
    static var anchor: (() -> (NSView, NSRect)?)?
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: WebTab?
    private unowned let host: ExtensionHost

    init(tab: WebTab, host: ExtensionHost) {
        self.tab = tab
        self.host = host
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { host.window }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { host.windowTabs.firstIndex { $0 === self } ?? NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab?.webView }
    func title(for context: WKWebExtensionContext) -> String? { tab?.title }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.webView?.url ?? tab.flatMap { URL(string: $0.url) } }
    func isSelected(for context: WKWebExtensionContext) -> Bool { tab != nil && tab?.id == WebBrowser.shared.activeTab?.id }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.webView?.isLoading ?? false) }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(tab?.webView?.pageZoom ?? 1) }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab { WebBrowser.shared.select(tabID: tab.id) }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab { WebBrowser.shared.close(tabID: tab.id) }
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.loadedWebView(browser: WebBrowser.shared).load(URLRequest(url: url))
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { tab?.webView?.reloadFromOrigin() } else { tab?.webView?.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.webView?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.webView?.goForward()
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    private unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { host.windowTabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        WebBrowser.shared.activeTab.flatMap { host.tab(for: $0.id) }
    }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { WebBrowser.shared.mainWindowFrame ?? .zero }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { NSScreen.main?.frame ?? .zero }
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        WebBrowser.shared.show()
        completionHandler(nil)
    }
}
