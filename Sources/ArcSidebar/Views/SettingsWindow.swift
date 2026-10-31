import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var tabs: NSTabViewController?
    private let settings: Settings
    private let apps: AppsModel
    private let autoQuit: AutoQuitManager
    private let library: Library
    private let tabCloser: TabCloser
    private let ideas: IdeasModel

    init(settings: Settings, apps: AppsModel, autoQuit: AutoQuitManager, library: Library, tabCloser: TabCloser, ideas: IdeasModel) {
        self.settings = settings
        self.apps = apps
        self.autoQuit = autoQuit
        self.library = library
        self.tabCloser = tabCloser
        self.ideas = ideas
    }

    /// Shows Settings where you left it (size, place and pane are kept across launches), or on `tab`.
    func show(tab: SettingsView.Tab? = nil) {
        if window == nil { build() }
        if let tab, let tabs, let i = SettingsView.Tab.allCases.firstIndex(of: tab) { tabs.selectedTabViewItemIndex = i }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Toolbar tabs, one hosted SwiftUI form per pane.
    private func build() {
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        tabs.canPropagateSelectedChildViewControllerTitle = false
        for tab in SettingsView.Tab.allCases {
            let view = SettingsView(settings: settings, apps: apps, autoQuit: autoQuit, library: library,
                                    tabCloser: tabCloser, ideas: ideas, tab: tab)
            let host = NSHostingController(rootView: view.designRoot())
            // The window keeps its own size; panes scroll instead of resizing it.
            host.sizingOptions = []
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            tabs.addTabViewItem(item)
        }
        if let saved = UserDefaults.standard.string(forKey: SettingsTabs.key).flatMap(SettingsView.Tab.init(rawValue:)),
           let i = SettingsView.Tab.allCases.firstIndex(of: saved) {
            tabs.selectedTabViewItemIndex = i
        }
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.toolbarStyle = .preference
        w.title = "proDOCKtivity Settings"
        w.isReleasedWhenClosed = false
        w.contentMinSize = DS.Size.settingsMin
        w.setContentSize(DS.Size.settingsDefault)
        if !w.setFrameUsingName(SettingsTabs.frameName) { w.center() }
        w.setFrameAutosaveName(SettingsTabs.frameName)
        self.tabs = tabs
        window = w
    }
}

/// Remembers the pane last shown.
private final class SettingsTabs: NSTabViewController {
    static let key = "settings.tab"
    static let frameName = "proDOCKtivity.settings"

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String { UserDefaults.standard.set(id, forKey: Self.key) }
    }
}

struct SettingsView: View {
    /// One pane per subject, in the order you'd set things up.
    enum Tab: String, CaseIterable, Hashable {
        case general, appearance, workspaces, bar, windows, browser, autoQuit, shortcuts, data

        var title: String {
            switch self {
            case .general: "General"
            case .appearance: "Appearance"
            case .workspaces: "Workspaces"
            case .bar: "Bar & Docks"
            case .windows: "Windows"
            case .browser: "Browser"
            case .autoQuit: "Auto-Quit"
            case .shortcuts: "Shortcuts"
            case .data: "Data"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintbrush"
            case .workspaces: "square.stack.3d.up"
            case .bar: "sidebar.left"
            case .windows: "macwindow.on.rectangle"
            case .browser: "globe"
            case .autoQuit: "timer"
            case .shortcuts: "keyboard"
            case .data: "externaldrive"
            }
        }
    }

    @ObservedObject var settings: Settings
    @ObservedObject var apps: AppsModel
    @ObservedObject var autoQuit: AutoQuitManager
    @ObservedObject var library: Library
    @ObservedObject var tabCloser: TabCloser
    @ObservedObject var ideas: IdeasModel
    let tab: Tab

    var body: some View {
        Group {
            switch tab {
            case .general: general
            case .appearance: AppearancePane(settings: settings)
            case .workspaces: WorkspacesPane(settings: settings, library: library)
            case .bar: BarPane(settings: settings, apps: apps)
            case .windows: WindowsPane(settings: settings, apps: apps)
            case .browser: browserPane
            case .autoQuit: autoQuitPane
            case .shortcuts: ShortcutsPane()
            case .data: DataPane(library: library)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.dsSwitch)
        .textRole(.body)
        .frame(minWidth: DS.Size.settingsMin.width, minHeight: DS.Size.settingsMin.height)
    }

    /// Where the bar shows, updates, feedback and help.
    private var general: some View {
        Form {
            Section {
                Picker("Show the bar on", selection: $settings.barScreen) {
                    Text("Main screen (with the menu bar)").tag("main")
                    Text("The screen where the mouse is").tag("mouse")
                    ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { name in
                        Text(name).tag("display:" + name)
                    }
                    // Keep a chosen screen selectable while it's unplugged.
                    if settings.barScreen.hasPrefix("display:"),
                       !NSScreen.screens.contains(where: { "display:" + $0.localizedName == settings.barScreen }) {
                        Text(settings.barScreen.dropFirst(8) + " (not connected)").tag(settings.barScreen)
                    }
                }
                LabeledContent("Show / hide the bar", value: "⌃⌥S")
            } header: {
                Text("The bar")
            } footer: {
                Text("Its look and contents: Appearance and Bar & Docks. Its workspaces: Workspaces.")
                    .settingsFooter()
            }

            Section {
                LabeledContent("Version", value: Updater.currentVersion)
                if Updater.isEnabled {
                    Button("Check for Updates Now") { Updater.shared.check(manually: true) }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(Updater.isEnabled
                     ? "proDOCKtivity looks for a new version every few hours. When there is one, a card at the bottom of the bar offers to update; it restarts by itself."
                     : "This copy doesn't update by itself (a copy built on this Mac, or no update source set).")
                    .settingsFooter()
            }

            Section("Feedback") {
                Picker("Ask me for feedback", selection: $ideas.askEveryDays) {
                    Text("Every day").tag(1)
                    Text("Every 3 days").tag(3)
                    Text("Every week").tag(7)
                    Text("Never").tag(0)
                }
                .pickerStyle(.radioGroup)
                LabeledContent("Write down an idea", value: "⌃⌥I")
            }

            Section("Help") {
                HStack {
                    Button("Setup Tour…") { SidebarActions.showSetupTour?() }
                    Button("Setup Guide") { SidebarActions.openGuide?() }
                }
            }
        }
        .formStyle(.grouped)
    }

    @State private var defaultBrowserCheck = 0

    private var defaultBrowserURL: URL? {
        _ = defaultBrowserCheck
        return NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
    }
    private var isDefaultBrowser: Bool { defaultBrowserURL.flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier }
    private var defaultBrowserName: String {
        defaultBrowserURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "–"
    }

    /// Which browser shows websites, plus the options that only apply to it.
    private var browserPane: some View {
        Form {
            Section {
                Picker("Open websites in", selection: $settings.browserEngine) {
                    ForEach(BrowserEngine.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Picker("Search with", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                }
                if settings.browserEngine == .builtIn {
                    Picker("Browser window on", selection: $settings.browserScreen) {
                        Text("Beside the bar (same screen)").tag("bar")
                        if NSScreen.screens.count > 1 { Text("The other screen").tag("other") }
                        if NSScreen.screens.count > 1 {
                            ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { name in
                                Text(name).tag("display:" + name)
                            }
                        }
                        if settings.browserScreen.hasPrefix("display:"),
                           !NSScreen.screens.contains(where: { "display:" + $0.localizedName == settings.browserScreen }) {
                            Text(settings.browserScreen.dropFirst(8) + " (not connected)").tag(settings.browserScreen)
                        }
                    }
                    .onChange(of: settings.browserScreen) { _ in WebBrowser.shared.moveToConfiguredScreen() }
                    .help("With a second monitor: keep the bar on one screen and let the browser fill the other. If that screen isn't connected, the browser sits beside the bar as usual.")
                    Toggle("Address in the menu bar instead of the bar", isOn: $settings.menuBarAddress)
                        .help("Normally the address sits in the bar's top corner. With this on, while the frame reaches up behind the menu bar, it sits right after the menus instead. ⌘L jumps into it.")
                }
            } footer: {
                Text("Built-in: pins and tabs open in proDOCKtivity's own window, and every space keeps its own logins. Chrome: for extensions such as Claude in Chrome. Arc: as before.")
                    .settingsFooter()
            }

            Section {
                LabeledContent("Links from other apps open in", value: defaultBrowserName)
                if !isDefaultBrowser {
                    Button("Make proDOCKtivity the Default Browser") {
                        for scheme in ["http", "https"] {
                            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { _ in
                                DispatchQueue.main.async { MainActor.assumeIsolated { defaultBrowserCheck += 1 } }
                            }
                        }
                    }
                }
            } footer: {
                Text("Then links you click in Mail, Slack, WhatsApp and other apps open as a tab in the active workspace, in the browser chosen above. macOS asks you to confirm once.")
                    .settingsFooter()
            }

            if settings.browserEngine == .builtIn { ExtensionsSection() }

            if settings.browserEngine != .builtIn {
                let name = settings.browserEngine == .arc ? "Arc" : "Chrome"
                Section {
                    Picker("Sync tabs with \(name)", selection: $settings.arcSync) {
                        ForEach(Settings.ArcSync.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    if settings.browserEngine == .arc {
                        Toggle("Tuck Arc's own sidebar behind this bar", isOn: $settings.blockArcSidebarPeek)
                    }
                } footer: {
                    Text("Light: tabs update while \(name) is in front and when you click. Off: no tab list, \(name) is only asked when you open something.")
                        .settingsFooter()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var autoQuitPane: some View {
        QuitterPane(apps: apps, autoQuit: autoQuit, tabCloser: tabCloser, library: library)
    }

    static func duration(_ minutes: Int) -> String {
        Formats.duration(minutes: minutes)
    }
}

/// The quitter (like the Quitter app): a general rule for open apps and tabs, its own rule for
/// Favorites and for each workspace, plus exceptions for single apps and websites.
private struct QuitterPane: View {
    @ObservedObject var apps: AppsModel
    @ObservedObject var autoQuit: AutoQuitManager
    @ObservedObject var tabCloser: TabCloser
    @ObservedObject var library: Library
    @ObservedObject private var settings = Settings.shared
    @State private var addingApp = false
    @State private var newSite = ""

    var body: some View {
        Form {
            Section {
                Toggle("Hide or quit apps I haven't used for a while", isOn: $autoQuit.enabled)
                Toggle("Close tabs I haven't looked at for a while", isOn: $tabCloser.enabled)
            } footer: {
                Text("Counts from the last time you used an app or looked at a tab. The app in front, Finder, apps in a call or playing something, and the tab you're on are never touched; quitting asks politely, so unsaved work still prompts. Pinned websites in a workspace are never closed. ⌘Y brings back what was closed.")
                    .settingsFooter()
            }

            Section {
                LabeledContent("Apps") {
                    HStack(spacing: DS.Space.s) {
                        Picker("", selection: actionBinding) {
                            Text("Hide").tag(AutoQuitRule.Action.hide)
                            Text("Quit").tag(AutoQuitRule.Action.quit)
                        }
                        .labelsHidden().frame(width: DS.Size.settingsPickerSmall)
                        Picker("", selection: $autoQuit.defaultRule.minutes) {
                            ForEach(AutoQuitManager.minuteChoices, id: \.self) { Text("after " + SettingsView.duration($0)).tag($0) }
                        }
                        .labelsHidden().frame(width: DS.Size.settingsPickerSmall)
                    }
                }
                .disabled(!autoQuit.enabled)
                Picker("Tabs", selection: $tabCloser.minutes) {
                    ForEach(TabCloser.choices, id: \.self) { Text("close after " + TabCloser.label($0)).tag($0) }
                }
                .disabled(!tabCloser.enabled)
            } header: {
                Text("Open apps and tabs")
            } footer: {
                Text("Apps that aren't pinned anywhere and tabs that are just open. Favorites and workspaces follow this unless they have their own rule below.")
                    .settingsFooter()
            }

            Section {
                AreaAppRule(title: "Apps", rule: $autoQuit.favoritesRule, general: autoQuit.defaultRule)
                    .disabled(!autoQuit.enabled)
                Picker("Websites", selection: $tabCloser.favoritesMinutes) {
                    Text("Never close").tag(0)
                    ForEach(TabCloser.choices, id: \.self) { m in Text("close after " + TabCloser.label(m)).tag(m) }
                }
                .disabled(!tabCloser.enabled)
            } header: {
                Text("Favorites")
            } footer: {
                Text("The icons at the top of the bar. A website's tab closes; the Favorite stays.")
                    .settingsFooter()
            }

            ForEach(Array(library.spaces.enumerated()), id: \.element.id) { index, space in
                Section {
                    AreaAppRule(title: "Apps", rule: spaceAppRule(space), general: autoQuit.defaultRule)
                        .disabled(!autoQuit.enabled)
                    spaceTabRule(space)
                        .disabled(!tabCloser.enabled)
                } header: {
                    Text("Workspace " + (space.emoji.map { $0 + " " } ?? "") + space.title)
                } footer: {
                    if index == library.spaces.count - 1 {
                        Text(settings.openAppsPerWorkspace
                             ? "Apps pinned in the workspace or opened in it, and the tabs open in it."
                             : "Apps pinned in the workspace, and the tabs open in it.")
                            .settingsFooter()
                    }
                }
            }

            Section {
                if exceptionIDs.isEmpty {
                    Text("None yet. Add apps that should stay open, or need a different time wherever they are.")
                        .textRole(.footnote).foregroundStyle(Palette.text2)
                }
                ForEach(exceptionIDs, id: \.self) { id in
                    AppRuleRow(id: id, name: apps.displayName(for: id), icon: icon(for: id), autoQuit: autoQuit)
                }
                Button("Add App Exception…") { addingApp = true }
                    .popover(isPresented: $addingApp, arrowEdge: .bottom) {
                        AppPicker(exclude: Set(exceptionIDs).union(AutoQuitManager.protected)) { id in
                            autoQuit.setOverride(AutoQuitRule(action: .off, minutes: autoQuit.defaultRule.minutes), for: id)
                            addingApp = false
                        }
                    }
            } header: {
                Text("Exceptions for apps")
            } footer: {
                Text("An app here follows its own rule, wherever it is.")
                    .settingsFooter()
            }
            .disabled(!autoQuit.enabled)

            Section {
                ForEach(tabCloser.siteRules.keys.sorted(), id: \.self) { host in
                    HStack {
                        FaviconView(host: host).frame(width: DS.Size.icon, height: DS.Size.icon)
                        Text(host)
                        Spacer()
                        Picker("", selection: siteBinding(host)) {
                            Text("Never close").tag(0)
                            ForEach(TabCloser.choices, id: \.self) { m in Text("after " + TabCloser.label(m)).tag(m) }
                        }
                        .labelsHidden().frame(width: DS.Size.settingsPicker)
                        Button { tabCloser.siteRules[host] = nil } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(Palette.text2).help("Remove exception")
                    }
                }
                HStack {
                    TextField("Add website", text: $newSite, prompt: Text("e.g. gmail.com")).onSubmit(addSite)
                    Button("Add", action: addSite).disabled(TabCloser.host(newSite) == nil)
                    if !openHosts.isEmpty {
                        Menu("Open Tabs") {
                            ForEach(openHosts, id: \.self) { host in Button(host) { tabCloser.siteRules[host] = 0 } }
                        }
                        .fixedSize()
                    }
                }
            } header: {
                Text("Exceptions for websites")
            } footer: {
                Text("A website here is never closed (or after its own time), wherever it's open. Covers its subdomains too.")
                    .settingsFooter()
            }
            .disabled(!tabCloser.enabled)
        }
        .formStyle(.grouped)
    }

    private var actionBinding: Binding<AutoQuitRule.Action> {
        Binding(get: { autoQuit.defaultRule.action == .quit ? .quit : .hide }, set: { autoQuit.defaultRule.action = $0 })
    }

    private var exceptionIDs: [String] {
        autoQuit.overrides.keys.sorted { apps.displayName(for: $0).localizedCaseInsensitiveCompare(apps.displayName(for: $1)) == .orderedAscending }
    }

    private func icon(for id: String) -> NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
    }

    /// Sites of the tabs open right now, for quick adding.
    private var openHosts: [String] {
        let hosts = WebBrowser.shared.tabs.compactMap { TabCloser.host($0.url) }.filter { !$0.isEmpty && tabCloser.siteRules[$0] == nil }
        return Array(Set(hosts)).sorted()
    }

    private func addSite() {
        guard let host = TabCloser.host(newSite) else { return }
        tabCloser.siteRules[host] = 0
        newSite = ""
    }

    private func siteBinding(_ host: String) -> Binding<Int> {
        Binding(get: { tabCloser.siteRules[host] ?? 0 }, set: { tabCloser.siteRules[host] = $0 })
    }

    private func spaceAppRule(_ space: LibrarySpace) -> Binding<AutoQuitRule?> {
        Binding(get: { autoQuit.spaceRules[space.id] }, set: { autoQuit.spaceRules[space.id] = $0 })
    }

    private func spaceTabRule(_ space: LibrarySpace) -> some View {
        let binding = Binding<Int>(
            get: { tabCloser.spaceRules[space.id] ?? -1 },
            set: { tabCloser.spaceRules[space.id] = $0 < 0 ? nil : $0 }
        )
        return Picker("Tabs", selection: binding) {
            Text("Like open tabs (" + TabCloser.label(tabCloser.minutes) + ")").tag(-1)
            Text("Never close").tag(0)
            ForEach(TabCloser.choices, id: \.self) { m in Text("close after " + TabCloser.label(m)).tag(m) }
        }
    }
}

/// The apps rule of Favorites or a workspace: like open apps (nil), keep open, or hide/quit after a time.
private struct AreaAppRule: View {
    enum Choice: Hashable { case general, keep, hide, quit }
    let title: String
    @Binding var rule: AutoQuitRule?
    let general: AutoQuitRule

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: DS.Space.s) {
                Picker("", selection: choice) {
                    Text("Like open apps (" + Self.describe(general) + ")").tag(Choice.general)
                    Text("Keep open").tag(Choice.keep)
                    Text("Hide").tag(Choice.hide)
                    Text("Quit").tag(Choice.quit)
                }
                .labelsHidden().fixedSize()
                if let r = rule, r.action != .off {
                    Picker("", selection: Binding(get: { r.minutes }, set: { rule?.minutes = $0 })) {
                        ForEach(AutoQuitManager.minuteChoices, id: \.self) { Text("after " + SettingsView.duration($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: DS.Size.settingsPickerSmall)
                }
            }
        }
    }

    static func describe(_ rule: AutoQuitRule) -> String {
        rule.action == .off ? "keep open" : rule.action.label.lowercased() + " after " + SettingsView.duration(rule.minutes)
    }

    private var choice: Binding<Choice> {
        Binding(
            get: {
                switch rule?.action {
                case nil: .general
                case .off?: .keep
                case .hide?: .hide
                case .quit?: .quit
                }
            },
            set: { c in
                let minutes = rule?.minutes ?? general.minutes
                switch c {
                case .general: rule = nil
                case .keep: rule = AutoQuitRule(action: .off, minutes: minutes)
                case .hide: rule = AutoQuitRule(action: .hide, minutes: minutes)
                case .quit: rule = AutoQuitRule(action: .quit, minutes: minutes)
                }
            }
        )
    }
}

/// Searchable list of all installed apps.
private struct AppPicker: View {
    let exclude: Set<String>
    let onPick: (String) -> Void
    @State private var query = ""
    @State private var all: [InstalledApps.App] = []

    var body: some View {
        VStack(spacing: DS.Space.s) {
            TextField("Search apps", text: $query).textFieldStyle(.roundedBorder)
            List(filtered) { app in
                Button { onPick(app.id) } label: {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: DS.Size.icon, height: DS.Size.icon)
                        Text(app.name)
                        Spacer()
                        if NSRunningApplication.runningApplications(withBundleIdentifier: app.id).isEmpty == false {
                            Text("open").textRole(.footnote).foregroundStyle(Palette.text2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Space.m)
        .frame(width: DS.Size.popoverWide, height: DS.Size.appPickerHeight)
        .onAppear {
            all = InstalledApps.scan().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private var filtered: [InstalledApps.App] {
        all.filter { !exclude.contains($0.id) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }
}

private struct AppRuleRow: View {
    let id: String
    let name: String
    let icon: NSImage
    @ObservedObject var autoQuit: AutoQuitManager

    var body: some View {
        HStack {
            Image(nsImage: icon).resizable().frame(width: DS.Size.icon, height: DS.Size.icon)
            Text(name)
            Spacer()
            Picker("", selection: actionBinding) {
                ForEach(AutoQuitRule.Action.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: DS.Size.settingsPickerSmall)
            if let rule = autoQuit.overrides[id], rule.action != .off {
                Picker("", selection: minutesBinding) {
                    ForEach(AutoQuitManager.minuteChoices, id: \.self) { Text("after " + SettingsView.duration($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: DS.Size.settingsPickerSmall)
            }
            Button { autoQuit.setOverride(nil, for: id) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).foregroundStyle(Palette.text2).help("Remove exception")
        }
    }

    private var actionBinding: Binding<AutoQuitRule.Action> {
        Binding(
            get: { autoQuit.overrides[id]?.action ?? .off },
            set: { action in
                let minutes = autoQuit.overrides[id]?.minutes ?? autoQuit.defaultRule.minutes
                autoQuit.setOverride(AutoQuitRule(action: action, minutes: minutes), for: id)
            }
        )
    }

    private var minutesBinding: Binding<Int> {
        Binding(
            get: { autoQuit.overrides[id]?.minutes ?? autoQuit.defaultRule.minutes },
            set: { autoQuit.overrides[id]?.minutes = $0 }
        )
    }
}

/// Appearance: theme, accent, text size, reading font, density, and the bar's color. Everything applies at once.
private struct AppearancePane: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section("Look") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(Theme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Accent") {
                    SwatchGrid(items: Accent.allCases, columns: 4, selected: settings.accent, color: \.color, name: \.name) {
                        settings.accent = $0
                    }
                    .fixedSize()
                }
                .help("For new workspaces, and wherever no workspace is open. Each workspace can have its own (Workspaces tab).")
            }

            Section("Text") {
                textSize
                Picker("Reading font", selection: $settings.readingFont) {
                    ForEach(ReadingFont.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("For running text, like your ideas notes. Labels stay in the system font.")
                Picker("Density", selection: $settings.density) {
                    ForEach(Density.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Bar takes the current workspace's color", isOn: $settings.matchArcSpace)
                    .help("Off: the bar and the frame stay in the neutral warm background.")
                colorTone
                    .disabled(!settings.matchArcSpace)
            } header: {
                Text("Color of the bar and frame")
            } footer: {
                Text("Each workspace's color and accent: Workspaces tab.")
                    .settingsFooter()
            }

            Section {
                Button("Reset Appearance to Defaults") {
                    settings.theme = .system
                    settings.textScale = 1
                    settings.readingFont = .sans
                    settings.density = .standard
                    settings.accent = .indigo
                    settings.sidebarWidth = 240
                    settings.tileSize = 48
                    settings.barTone = 0
                }
            }
        }
        .formStyle(.grouped)
    }

    /// A slider with one stop per step, the step's name beside it; the bar resizes as you drag.
    private var textSize: some View {
        let steps = TextScale.steps
        let index = Binding<Double>(
            get: { Double(steps.firstIndex { $0.value == TextScale.snapped(settings.textScale) } ?? 1) },
            set: { settings.textScale = steps[min(max(Int($0.rounded()), 0), steps.count - 1)].value }
        )
        return LabeledContent("Text size") {
            HStack(spacing: DS.Space.s) {
                Slider(value: index, in: 0...Double(steps.count - 1), step: 1)
                    .frame(width: DS.Size.settingsSlider)
                    .accessibilityValue(steps[Int(index.wrappedValue)].label)
                Text(steps[Int(index.wrappedValue)].label)
                    .textRole(.footnote).foregroundStyle(Palette.text2)
                    .frame(width: DS.Size.settingsValue, alignment: .leading)
            }
        }
    }

    /// Approximate value, live preview on the bar and frame; the middle is the offered tone.
    private var colorTone: some View {
        LabeledContent("Color tone") {
            HStack(spacing: DS.Space.s) {
                Text("Darker").textRole(.footnote).foregroundStyle(Palette.text2)
                Slider(value: $settings.barTone, in: -1...1, step: DS.Tone.step)
                    .frame(width: DS.Size.settingsSlider)
                    .accessibilityValue(Self.toneLabel(settings.barTone))
                Text("Lighter").textRole(.footnote).foregroundStyle(Palette.text2)
                Text(Self.toneLabel(settings.barTone))
                    .textRole(.footnote).monospacedDigit().foregroundStyle(Palette.text2)
                    .frame(width: DS.Size.settingsValue, alignment: .trailing)
            }
        }
        .help("How much lighter or darker than the offered colors the bar and frame are, in every workspace. The middle is the color as offered.")
    }

    static func toneLabel(_ tone: Double) -> String {
        let percent = Int((abs(tone) * 100).rounded())
        return percent == 0 ? "As offered" : "\(percent) % " + (tone > 0 ? "lighter" : "darker")
    }

}

/// Workspaces: each one's icon, color and accent, which open apps they list, and swiping between them.
private struct WorkspacesPane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var library: Library

    var body: some View {
        Form {
            Section {
                ForEach(library.spaces) { space in
                    spaceRow(space)
                }
                Button("New Workspace…") { SidebarActions.newSpace?() }
            } header: {
                Text("Workspaces")
            } footer: {
                Text("Each workspace has an icon, a color (the bar and the frame) and an accent (its Favorites squares, folders, focus, switches). New workspaces get the next unused color. Rename or delete one: right-click its icon at the bottom of the bar (⌘Y brings a deleted one back).")
                    .settingsFooter()
            }

            Section {
                Picker("Open apps", selection: $settings.openAppsPerWorkspace) {
                    Text("In every workspace").tag(false)
                    Text("Only in the workspace they were opened in").tag(true)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Open apps")
            } footer: {
                Text("With “only in the workspace”, an app belongs to the workspace that was open when you started it, and the workspace lists its open apps and tabs together. Drag an app onto another workspace's icon to move it there. Windows aren't hidden when you switch.")
                    .settingsFooter()
            }

            Section {
                Toggle("Reverse swipe direction between workspaces", isOn: $settings.reverseSpaceSwipe)
                    .help("The bar always slides the way your fingers swipe. Normally two fingers to the left bring the next workspace (it slides in from the right). Turn this on for the other way round: two fingers to the right bring the next workspace (it slides in from the left).")
                LabeledContent("Show All Workspaces", value: "⌃⌥W")
            } header: {
                Text("Switching")
            } footer: {
                Text("Swipe with two fingers on the bar, click a workspace icon at the bottom, or open Show All Workspaces to see them side by side and drag things between them.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
    }

    /// A space's name with its color and accent pickers (menus with swatches).
    private func spaceRow(_ space: LibrarySpace) -> some View {
        HStack(spacing: DS.Space.s) {
            Circle().fill((space.area ?? .slate).base).frame(width: DS.Size.dot, height: DS.Size.dot)
            Text(space.title).lineLimit(1)
            Spacer()
            let area = space.area ?? .slate
            let accent = space.accent ?? settings.accent
            SpaceIconButton(space: space, library: library)
            SwatchButton(name: area.name, color: area.base, help: "Color of “\(space.title)”") { close in
                SwatchGrid(items: Area.allCases, columns: 6, selected: area, color: \.base, name: \.name) { a in
                    library.updateSpace(space.id) { $0.area = a }
                    close()
                }
            }
            SwatchButton(name: accent.name, color: accent.color, help: "Accent of “\(space.title)”") { close in
                SwatchGrid(items: Accent.allCases, columns: 4, selected: accent, color: \.color, name: \.name) { a in
                    library.updateSpace(space.id) { $0.accent = a }
                    close()
                }
            }
        }
    }
}

/// The bar and the docks: width, the Favorites tiles and their icons, the website and files docks,
/// and apps kept out of the bar.
private struct BarPane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var apps: AppsModel
    @State private var picking: String?

    var body: some View {
        Form {
            Section("Bar") {
                slider("Width", value: $settings.sidebarWidth, in: Layout.widthRange, step: 5, unit: "pt",
                       hint: "You can also drag the bar's right edge.")
            }

            Section("Favorites") {
                slider("Size", value: $settings.tileSize, in: 36...76, step: 2, unit: "pt", hint: "Size of the tiles at the top.")
                pinboardPreview
            }

            Section {
                ForEach(apps.pinnedEntries(favorites: []), id: \.id) { entry in
                    iconRow(entry)
                }
            } header: {
                Text("Icons for your Favorites")
            } footer: {
                Text("Pick an icon from the set for any Favorite. Pins in workspaces: right-click → Change Icon…")
                    .settingsFooter()
            }

            Section {
                Toggle("Websites in a dock of their own", isOn: $settings.websiteDock)
                if settings.websiteDock {
                    slider("Website dock width", value: $settings.websiteDockWidth, in: Layout.dockWidthRange, step: 5, unit: "pt", hint: nil)
                }
                Picker("Files dock", selection: $settings.filesDock) {
                    ForEach(Settings.FilesDock.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if settings.filesDock != .off {
                    slider("Files dock width", value: $settings.filesDockWidth, in: Layout.dockWidthRange, step: 5, unit: "pt",
                           hint: "Add folders with + in the dock; right-click a folder to choose whether it starts open.")
                }
            } header: {
                Text("Docks")
            } footer: {
                Text("One bar, or the bar for apps and Favorites plus a website dock next to it. The files dock shows the folders you pick, like a small Finder.")
                    .settingsFooter()
            }

            Section {
                if apps.hiddenFromTabs.isEmpty {
                    Text("None. Right-click an app in the bar → “Hide from Tab List” to keep it only in the menu bar.")
                        .textRole(.footnote).foregroundStyle(Palette.text2)
                }
                ForEach(apps.hiddenFromTabs.sorted(), id: \.self) { id in
                    HStack {
                        Text(apps.displayName(for: id))
                        Spacer()
                        Button("Show again") { apps.setHiddenFromTabs(id, false) }
                    }
                }
            } header: {
                Text("Apps hidden from the bar")
            }
        }
        .formStyle(.grouped)
    }

    private var pinboardPreview: some View {
        HStack(spacing: DS.Space.s) {
            ForEach(["mail", "study", "ai"], id: \.self) { key in
                RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .fill(Palette.sunken)
                    .frame(width: settings.tileSize * DS.Size.tileAspect, height: settings.tileSize)
                    .overlay(SuiteIconView(icon: SuiteIcon.find(key)!, size: (settings.tileSize * DS.Size.tileIconRatio).rounded()))
            }
        }
        .dsAnimation(DS.Motion.standard, value: settings.tileSize)
    }

    @ViewBuilder private func iconRow(_ entry: PinnedEntry) -> some View {
        let s = DS.Size.settingsIcon
        let (title, original): (String, AnyView) = {
            switch entry {
            case .app(let a): return (a.name, AnyView(Image(nsImage: a.icon).resizable().frame(width: s, height: s)))
            case .tab(let t): return (t.title, AnyView(FaviconView(url: t.url).frame(width: DS.Size.icon, height: DS.Size.icon)))
            case .favorite(let f): return (f.title, AnyView(FaviconView(url: f.url).frame(width: DS.Size.icon, height: DS.Size.icon)))
            }
        }()
        HStack(spacing: DS.Space.s) {
            Group {
                if let icon = SuiteIcon.find(apps.pinIcons[entry.id]) { SuiteIconView(icon: icon, size: s) } else { original }
            }
            .frame(width: s, height: s)
            Text(title).lineLimit(1)
            Spacer()
            Button(apps.pinIcons[entry.id] == nil ? "Choose Icon…" : "Change…") { picking = entry.id }
                .popover(isPresented: Binding(get: { picking == entry.id }, set: { if !$0 { picking = nil } })) {
                    IconPicker(current: apps.pinIcons[entry.id]) { key in
                        apps.setIcon(key, for: entry.id)
                        picking = nil
                    }
                }
        }
    }

}

/// Windows: snapping beside the bar, the frame around everything, split screen.
private struct WindowsPane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var apps: AppsModel
    @ObservedObject private var rules = WindowRules.shared
    @State private var addingApp = false

    var body: some View {
        Form {
            Section {
                Toggle("Snap windows next to the bar", isOn: $settings.autoFitWindows)
                    .help("Windows you open from the bar fill the space beside it, on the bar's screen.")
            } footer: {
                Text("Needs Accessibility (System Settings → Privacy & Security). Single apps can go elsewhere: see below.")
                    .settingsFooter()
            }

            Section {
                Toggle("Frame around everything", isOn: $settings.frameMode)
                    .help("A backdrop in the workspace's color behind everything; windows snap inside a thin frame next to the bar. Apps set to “Don't snap”, full-screen and fixed-size windows stay free.")
                if settings.frameMode {
                    slider("Frame width", value: $settings.frameWidth, in: Layout.frameWidthRange, step: 1, unit: "pt",
                           hint: "The frame takes the workspace's color, like the bar.")
                    Picker("At the top", selection: $settings.frameUnderMenuBar) {
                        Text("Stop below the menu bar").tag(false)
                        Text("Reach up behind the menu bar").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    if NSScreen.screens.count > 1 {
                        Toggle("Frame on the other screens too", isOn: $settings.frameOtherScreens)
                            .help("The workspace's color as a thin frame around the second screen as well. The browser window, if set to open there (Browser tab), fills the inside. No bar on that screen.")
                    }
                }
            } header: {
                Text("Frame")
            } footer: {
                Text("All windows inside one proDOCKtivity window, in the workspace's color.")
                    .settingsFooter()
            }

            Section {
                ForEach(ruleIDs, id: \.self) { id in
                    HStack(spacing: DS.Space.s) {
                        Image(nsImage: Self.icon(for: id)).resizable().frame(width: DS.Size.icon, height: DS.Size.icon)
                        Text(apps.displayName(for: id)).lineLimit(1)
                        Spacer()
                        let rule = rules.rule(for: id)
                        if rule.placement != .fill && rule.placement != .none {
                            Toggle("Only extra windows", isOn: Binding(get: { rule.extraOnly }, set: { rules.setExtraOnly($0, for: id) }))
                                .toggleStyle(.checkbox)
                                .help("The app's first window snaps as usual; only further windows (like a new email) go here.")
                        }
                        Picker("", selection: Binding(get: { rule.placement }, set: { rules.setPlacement($0, for: id) })) {
                            ForEach(WindowPlacement.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        if rules.custom[id] != nil {
                            Button { rules.removeRule(for: id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(Palette.text2)
                                .help(WindowRules.defaults[id] == nil ? "Remove rule" : "Back to the default")
                        }
                    }
                }
                Button("Add App…") { addingApp = true }
                    .popover(isPresented: $addingApp, arrowEdge: .bottom) {
                        AppPicker(exclude: Set(ruleIDs)) { id in
                            rules.setPlacement(.none, for: id)
                            addingApp = false
                        }
                    }
            } header: {
                Text("Where each app's windows go")
            } footer: {
                Text("Every other app fills the space next to the bar. “Don't snap” leaves an app's windows where they are.")
                    .settingsFooter()
            }

            Section {
                LabeledContent("Two things side by side", value: "⌥-click an app or tab")
                LabeledContent("Keep one on the left half (freeze)", value: "⌃-click")
            } header: {
                Text("Split screen")
            } footer: {
                Text("The one in front goes left, the one you ⌥-clicked right. Clicking something else ends the split: only that shows. To keep one thing on a half while you switch the other, ⌃-click it (frozen on the left; ⌃-click again to release), or right-click → Freeze on the Left / Right.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
    }

    /// Apps with a rule: the built-in ones (Finder, Terminal, Mail) and your own, by name.
    private var ruleIDs: [String] {
        Set(WindowRules.defaults.keys).union(rules.custom.keys)
            .sorted { apps.displayName(for: $0).localizedCaseInsensitiveCompare(apps.displayName(for: $1)) == .orderedAscending }
    }

    private static func icon(for id: String) -> NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
    }
}

/// A labeled slider with its value, and a hint below (Appearance, Bar & Docks, Windows).
@MainActor
private func slider(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, unit: String, hint: String?) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.xs) {
        HStack {
            Text(label)
            Spacer()
            Text("\(value.wrappedValue, specifier: step < 1 ? "%.1f" : "%.0f") \(unit)").monospacedDigit().foregroundStyle(Palette.text2)
        }
        Slider(value: value, in: range, step: step)
        if let hint { Text(hint).textRole(.footnote).foregroundStyle(Palette.text2) }
    }
}

/// Every shortcut in one place (read only).
private struct ShortcutsPane: View {
    private static let groups: [(String, [(String, String)])] = [
        ("Anywhere", [
            ("Show or hide the bar", "⌃⌥S"),
            ("DOCKlight (search apps, tabs, files, the web)", "⌥Space  or  ⌃⌥Space"),
            ("Show All Workspaces", "⌃⌥W"),
            ("Bring back what was closed last", "⌃⌥Y"),
            ("Write down an idea", "⌃⌥I"),
        ]),
        ("In the bar and the browser", [
            ("Bring back what was closed last (tab, app, workspace)", "⌘Y"),
            ("Undo", "⌘Z"),
            ("Paste without formatting / with formatting", "⌘V  /  ⇧⌘V"),
            ("Settings", "⌘,"),
            ("Two things side by side", "⌥-click"),
            ("Freeze one thing on the left half / release it", "⌃-click"),
        ]),
        ("Built-in browser", [
            ("Type an address or search", "⌘L"),
            ("New tab (opens DOCKlight)", "⌘T"),
            ("Close tab", "⌘W"),
            ("Reopen the last closed tab", "⇧⌘T"),
            ("Back / forward / reload", "⌘[  ⌘]  ⌘R"),
            ("Next / previous tab", "⌃Tab  ⌃⇧Tab"),
            ("Jump to a tab", "⌘1 … ⌘9"),
            ("Bigger / smaller / actual size", "⌘+  ⌘−  ⌘0"),
            ("Find on the page", "⌘F"),
            ("Copy the page's address", "⌥⌘C"),
            ("New private tab", "⇧⌘N"),
        ]),
    ]

    var body: some View {
        Form {
            ForEach(Self.groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1, id: \.0) { row in
                        LabeledContent(row.0) {
                            Text(row.1).foregroundStyle(Palette.text2).textSelection(.enabled)
                        }
                    }
                }
            }
            Section {
            } footer: {
                Text("Spotlight keeps ⌘Space. In DOCKlight, start with & to search the web or / to search your files.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
    }
}

private extension View {
    /// Group footers read from the left, like the rows above them.
    func settingsFooter() -> some View {
        textRole(.footnote).foregroundStyle(Palette.text2).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A space's icon in Settings; opens the icon picker in a popover.
private struct SpaceIconButton: View {
    let space: LibrarySpace
    let library: Library
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: DS.Space.s) {
                switch space.iconChoice {
                case .emoji(let e): Text(e)
                case .symbol(let s): Image(systemName: s).foregroundStyle((space.area ?? .slate).base)
                case .none: Text("Icon")
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: DS.Size.chevron))
                    .foregroundStyle(Palette.text3)
            }
        }
        .buttonStyle(.secondary)
        .help("Icon of “\(space.title)”")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SpaceIconPicker(current: space.iconChoice) { choice in
                library.updateSpace(space.id) { $0.setIcon(choice) }
                open = false
            }
            .padding(DS.Space.l)
            .frame(width: DS.Size.popover)
        }
    }
}

/// Pop-up look (secondary button showing the current value) that opens the fixed swatch grid.
private struct SwatchButton<Grid: View>: View {
    let name: String
    let color: Color
    let help: String
    @ViewBuilder let grid: (_ close: @escaping () -> Void) -> Grid
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: DS.Space.s) {
                Circle().fill(color).frame(width: DS.Size.dot, height: DS.Size.dot)
                Text(name)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: DS.Size.chevron))
                    .foregroundStyle(Palette.text3)
            }
        }
        .buttonStyle(.secondary)
        .help(help)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            grid { open = false }.padding(DS.Space.l)
        }
    }
}

/// Settings → Data: where data lives, what leaves the Mac, backups and export.
private struct DataPane: View {
    @ObservedObject var library: Library
    @State private var days = Backups.days
    @State private var problem: String?
    @State private var crashes = CrashCollector.reports.count

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    Text((AppPaths.directory.path as NSString).abbreviatingWithTildeInPath)
                        .textRole(.footnote).foregroundStyle(Palette.text2)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.directory]) }
            } header: {
                Text("Where your data lives")
            } footer: {
                Text("Workspaces, pins, open tabs, extensions and your ideas are saved on this Mac only. There is no account and no sync.")
                    .settingsFooter()
            }

            Section("What leaves this Mac") {
                Label("Websites you open get what any browser sends them; searches go to the search engine you chose under Browser.", systemImage: "globe")
                Label("Site icons come from Google's icon service, which sees the names of the sites in your bar. When Google has none, the icon is fetched from the site itself, once.", systemImage: "photo")
                Label("Your ideas are only sent when you choose Email in the Ideas menu, from your own mail app.", systemImage: "envelope")
                Label("Every few hours the app asks GitHub whether a newer version exists; GitHub sees your IP address, nothing else is sent.", systemImage: "arrow.triangle.2.circlepath")
                Label("Nothing goes to any analytics or AI service.", systemImage: "lock")
            }
            .foregroundStyle(Palette.text)

            Section {
                LabeledContent("Last copy", value: days.first.flatMap(Self.day) ?? "None yet")
                HStack {
                    Button("Back Up Now") {
                        if Backups.runNow() { problem = nil } else { problem = "Couldn't make a copy. See the log for details, then try again." }
                        days = Backups.days
                    }
                    Button("Show Backups") {
                        try? FileManager.default.createDirectory(at: Backups.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([Backups.folder])
                    }
                }
            } header: {
                Text("Backups")
            } footer: {
                Text("A copy of your data is made once a day and kept for \(Backups.keepDays) days, in the Backups folder inside the folder above.")
                    .settingsFooter()
            }

            Section {
                LabeledContent("Saved", value: crashes == 0 ? "None" : "\(crashes)")
                Button("Show Crash Reports") {
                    try? FileManager.default.createDirectory(at: CrashCollector.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([CrashCollector.reports.first ?? CrashCollector.folder])
                }
            } header: {
                Text("Crash reports")
            } footer: {
                Text("If proDOCKtivity crashes or ends without quitting, what happened is saved here as a text file (the newest \(CrashCollector.keep)), with macOS's own report when there is one. Who asked the app to quit is in the log. Nothing is sent anywhere.")
                    .settingsFooter()
            }

            Section {
                Button("Save Setup File with Apps (setupWA)…") { problem = SetupFile.saveWithPanel(.withApps, library: library) }
                Button("Save Setup File without Apps (setupNA)…") { problem = SetupFile.saveWithPanel(.noApps, library: library) }
                Button("Load Setup File…") {
                    switch SetupFile.openWithPanel() {
                    case .success(let contents)?:
                        if Prompt.confirm("Replace your workspaces and settings?",
                                          message: "The setup file's workspaces replace yours (a backup of today stays under Backups). proDOCKtivity restarts.",
                                          destructive: "Replace") {
                            Backups.runNow()
                            SetupFile.apply(contents, library: library)
                            SetupFile.relaunch()
                        }
                    case .failure(let error)?: problem = error.localizedDescription
                    case nil: break
                    }
                }
                HStack {
                    Button("Setup Tour…") { SidebarActions.showSetupTour?() }
                    Button("Show setupNA in Finder") { NSWorkspace.shared.activateFileViewerSelecting([SetupFile.automaticNA]) }
                }
            } header: {
                Text("Setup file")
            } footer: {
                Text("A setup file sets up proDOCKtivity on another Mac in one go. setupNA (your settings, workspaces and websites, no apps) is saved by itself after every change; setupWA also holds your apps and their rules. Logins, open tabs and ideas are never in it.")
                    .settingsFooter()
            }

            Section {
                Button("Export All Data…") { problem = DataExport.exportWithPanel(spaces: library.spaces) }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .textRole(.footnote).foregroundStyle(Palette.danger)
                }
            } header: {
                Text("Export")
            } footer: {
                Text("A new folder with your data as JSON, your settings as a property list and all pins as a CSV table.")
                    .settingsFooter()
            }
        }
        .onAppear {
            days = Backups.days
            crashes = CrashCollector.reports.count
        }
    }

    private static func day(_ name: String) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: name).map { Formats.relativeDay($0) }
    }
}

/// Settings → Browser → Extensions: add, switch on/off and remove web extensions.
private struct ExtensionsSection: View {
    @ObservedObject private var store = WebExtensionStore.shared
    @State private var found: [WebExtensionStore.Suggestion] = []

    var body: some View {
        Section {
            if !WebExtensionStore.isSupported {
                Text("Extensions need macOS 15.4 or newer.").foregroundStyle(Palette.text2)
            } else {
                ForEach(store.entries) { entry in
                    HStack(spacing: DS.Space.s) {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text(entry.name)
                            Text(store.problems[entry.id].map { "Not working: \($0)" } ?? (entry.kind == .appExtension ? "Safari version · \(entry.version)" : entry.version))
                                .textRole(.footnote)
                                .foregroundStyle(store.problems[entry.id] == nil ? Palette.text2 : Palette.danger)
                                .lineLimit(2)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { entry.enabled }, set: { store.setEnabled(entry.id, $0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Button { store.remove(entry.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove")
                    }
                }
                HStack {
                    Button("Add from File…", action: pickFile)
                    Menu("Found on this Mac") {
                        if found.isEmpty { Text("Nothing new found") }
                        ForEach(found) { item in
                            Button("\(item.name) — from \(item.from)") { store.install(from: item.url, source: item.id) }
                        }
                    }
                    .fixedSize()
                    if !store.hasUBlock {
                        Button("Get uBlock Origin Lite") { store.getUBlockOriginLite() }
                            .help("Downloads the official Safari build from github.com/uBlockOrigin/uBOL-home.")
                    }
                    if let busy = store.busy {
                        ProgressView().controlSize(.small)
                        Text(busy).textRole(.footnote).foregroundStyle(Palette.text2)
                    }
                }
                .onAppear { found = store.suggestions() }
                .onChange(of: store.entries) { _, _ in found = store.suggestions() }
                if let failure = store.failure {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                        Label(failure.message, systemImage: "exclamationmark.triangle")
                            .textRole(.footnote).foregroundStyle(Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Retry") { store.retry() }
                        Button { store.dismissFailure() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss")
                    }
                }
            }
        } header: {
            Text("Extensions")
        } footer: {
            Text("Safari web extensions (inside apps like Zotero) and Chrome or Firefox extensions (a folder, .zip, .xpi or .crx). Their buttons are in the bar behind the puzzle piece. Apple's iCloud Passwords extension can't work here: macOS only lets Safari, Chrome, Edge and Firefox talk to the Passwords app. Copy from the Passwords app and paste with ⌘V instead.")
                .settingsFooter()
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Pick an extension folder, a .zip, .xpi or .crx file, or an app with a Safari extension."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.install(from: url)
    }
}
