import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private let apps = AppsModel()
    private let perms = PermissionsModel()
    private let browser = BrowserModel(provider: Settings.shared.browserEngine.makeProvider())
    private var engineObserver: AnyCancellable?
    private var lookObserver: AnyCancellable?
    private let downloads = DownloadsModel()
    private let library = Library()
    private let autoQuit = AutoQuitManager()
    private lazy var settingsWindow = SettingsWindowController(settings: settings, apps: apps, autoQuit: autoQuit, library: library,
                                                               tabCloser: tabCloser, ideas: ideas)
    private var favoritesSync: AnyCancellable?

    private var panel: SidebarPanel!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var commandHotKeys: [HotKey] = []
    /// ⌘L opens the address bar, only while the browser is in front.
    private var addressHotKey: HotKey?
    private var addressObserver: NSObjectProtocol?
    private let ideas = IdeasModel()
    private let tabCloser = TabCloser()
    private var checkInTimer: Timer?
    private var backupTimer: Timer?
    private let iconPicker = IconPickerWindow()
    private var widthObserver: AnyCancellable?
    private var resnapWork: DispatchWorkItem?
    private lazy var ideasPanel = IdeasPanelController(model: ideas)
    private lazy var overview = WorkspaceOverviewController(browser: browser, apps: apps)
    private lazy var setupTour = SetupTour(library: library, perms: perms)
    private var setupAutosave: SetupAutosave?
    private lazy var commandBar = CommandBarController(model: CommandBarModel(apps: apps, browser: browser, library: library))
    private var toggleItem: NSMenuItem!
    private var snapItem: NSMenuItem!
    private var axStatusItem: NSMenuItem!
    private(set) var sidebarVisible = true
    private var downloadsBlob: DownloadsBlobController!
    private let edgeGuard = EdgeGuard()
    private var backdrop: Backdrop!
    private var menuAddress: MenuBarAddress!
    private var docks: DockManager!
    private var dockSettings: AnyCancellable?
    private var frameSettings: AnyCancellable?
    private var frameWork: DispatchWorkItem?
    private var containObserver: NSObjectProtocol?
    private var guardSetting: AnyCancellable?
    private var guardTimer: Timer?
    private var swipeMonitor: Any?
    private var swipeDistance: CGFloat = 0
    private var swipeFired = false
    private var launched = false
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashCollector.start()
        MainMenu.install()
        BrowserKeys.install()
        ScreenWatcher.shared.start()
        // Every Accessibility call to another app gives up after 1 s (the default is 6 s): an app
        // that hangs must not freeze the bar. Covers elements that set no timeout of their own.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        // Extensions first: every browser tab's web view is created with them.
        WebExtensionStore.shared.start()
        panel = SidebarPanel(rootView: SidebarView(
            settings: settings, apps: apps, browser: browser, downloads: downloads, perms: perms,
            onHide: { [weak self] in self?.setSidebar(visible: false) },
            onToggleDownloads: { [weak self] in self?.downloadsBlob.toggle() },
            onOpenSettings: { [weak self] in self?.settingsWindow.show() }
        ))
        backdrop = Backdrop(settings: settings, apps: apps, browser: browser)
        docks = DockManager(settings: settings, apps: apps, browser: browser, perms: perms)
        menuAddress = MenuBarAddress()
        menuAddress.screen = { [weak self] in self?.sidebarScreen }
        // ⌘L and a click on the address in the bar: the menu bar field, or DOCKlight as the address bar.
        WebBrowser.shared.focusAddress = { [weak self] in
            guard let self else { return }
            if self.menuAddress.isShown { self.menuAddress.focus() }
            else if self.sidebarVisible, self.browser.provider.isBuiltIn { BrowserNavState.shared.focusRequest += 1 }
            else { self.commandBar.showAddressBar(currentURL: self.browser.activeTabURL) }
        }
        SidebarActions.editAddress = { WebBrowser.shared.focusAddress?() }
        // Extension popups open at the bar's top right, over the page.
        ExtensionUI.anchor = { [weak self] in
            guard let view = self?.panel.contentView else { return nil }
            let top = view.isFlipped ? view.bounds.minY + 40 : view.bounds.maxY - 70
            return (view, NSRect(x: view.bounds.maxX - 30, y: top, width: 20, height: 30))
        }
        SplitManager.shared.attach(browser: browser)
        library.browser = browser
        browser.library = library
        apps.library = library
        SidebarActions.importArc = { [weak self] in self?.importFromArc(announce: true) }
        SidebarActions.importChrome = { [weak self] in self?.importBookmarks(chrome: true) }
        SidebarActions.importSafari = { [weak self] in self?.importBookmarks(chrome: false) }
        SidebarActions.newSpace = { [weak self] in
            guard let self, let title = Prompt.text("New Workspace", message: "Name your workspace. You can link it to an Arc space later.") else { return }
            self.library.addSpace(title: title)
        }
        // Sidebar-first: on first start, take over Arc's spaces, pins, folders and favorites.
        if !library.isSetUp { importFromArc(announce: false) }
        // Debug aid: ARCSIDEBAR_SNAPSHOT_DESIGN=/path renders the Design tab and the icon set.
        if let base = ProcessInfo.processInfo.environment["ARCSIDEBAR_SNAPSHOT_DESIGN"] {
            // ARCSIDEBAR_SETTINGS_TAB=general|browser|autoQuit|data renders that tab instead.
            settingsWindow.show(tab: SettingsView.Tab(rawValue: ProcessInfo.processInfo.environment["ARCSIDEBAR_SETTINGS_TAB"] ?? "") ?? .appearance)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                MainActor.assumeIsolated {
                    if let w = NSApp.windows.first(where: { $0.title.contains("Settings") && $0.isVisible }), let v = w.contentView,
                       let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: r)
                        try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + ".design.png"))
                    }
                    let renderer = ImageRenderer(content: IconSheet().background(Palette.canvas))
                    renderer.scale = 2
                    if let img = renderer.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + ".icons.png"))
                    }
                }
            }
        }
        // Debug aid: ARCSIDEBAR_TEST_CRASH=1 crashes on purpose after 3 s (checks the crash collector).
        if ProcessInfo.processInfo.environment["ARCSIDEBAR_TEST_CRASH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Log.write("test crash now"); raise(SIGSEGV) }
        }
        // Debug aid: ARCSIDEBAR_TEST_SWIPE=1 does what a two-finger swipe does, to the next space and
        // back, a few times, and logs each switch (for checking the space slide without a trackpad).
        if ProcessInfo.processInfo.environment["ARCSIDEBAR_TEST_SWIPE"] != nil {
            for (i, offset) in [1, -1, 1, -1, 1, -1].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(i) * 1.5) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let before = self.browser.activeSpace?.title ?? "-"
                        self.browser.focusAdjacentSpace(offset)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            MainActor.assumeIsolated {
                                Log.write("test swipe \(offset): \(before) -> \(self.browser.activeSpace?.title ?? "-") slide=\(self.browser.spaceSlide)")
                            }
                        }
                    }
                }
            }
        }
        // Debug aid: ARCSIDEBAR_TEST_FOLDER=1 creates a folder in the active space and logs the result.
        if ProcessInfo.processInfo.environment["ARCSIDEBAR_TEST_FOLDER"] != nil, let space = library.activeSpace {
            let before = library.folders(in: space.id).count
            library.newFolder(in: space.id, title: "Test Folder")
            if let folder = library.folders(in: space.id).first(where: { $0.title == "Test Folder" }) {
                library.add(.app("com.apple.finder", title: "Finder"), toSpace: space.id, inFolder: folder.id)
            }
            let inside = library.folders(in: space.id).first { $0.title == "Test Folder" }?.children.map(\.title) ?? []
            Log.write("test folder: \(before) -> \(library.folders(in: space.id).count) in \(space.title), contents: \(inside)")
        }
        apps.migrateSpaceAppsToLibrary()
        // Without Arc data (e.g. a friend's Mac) start with one space to put things in.
        if library.spaces.isEmpty { library.addSpace(title: "Home", emoji: "🏠") }
        // Daily copy of the data, kept 14 days (Settings → Data); checked hourly while running.
        Backups.runIfDue()
        backupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in MainActor.assumeIsolated { Backups.runIfDue() } }
        backupTimer?.tolerance = 300
        PanelFocus.makeKey = { [weak self] in self?.panel.makeKey() }
        // A deleted space's built-in browser tabs move to the space you land in (and any left
        // over from before are taken in now), instead of staying loaded but never shown.
        library.onSpaceDeleted = { old, new in if let new { WebBrowser.shared.moveTabs(fromSpace: old, to: new) } }
        if let home = library.activeSpace?.id {
            WebBrowser.shared.adoptOrphanTabs(validSpaces: Set(library.spaces.map(\.id)), into: home)
        }
        DuplicateActions.apps = apps
        DuplicateActions.browser = browser
        // Built-in browser: the sidebar follows its tabs, ⌘T opens the command bar.
        WebBrowser.shared.onChange = { [weak self] in self?.browser.refresh() }
        WebBrowser.shared.onNewTab = { [weak self] in self?.commandBar.show() }
        WebBrowser.shared.onHint = { [weak self] text in self?.browser.showHint(text) }
        WebBrowser.shared.profileForSpace = { [weak self] id in self?.library.profile(forSpace: id)?.id }
        // The window buttons' notch has the frame's color: the space's color, or the canvas.
        WebBrowser.shared.spaceColor = { [weak self] id in
            guard let self, self.settings.matchArcSpace else { return Palette.NS.canvas }
            return self.library.spaces.first { $0.id == id }?.area?.nsFill(tone: self.settings.barTone) ?? Palette.NS.canvas
        }
        // Every window shows the current space's color and accent, and the chosen theme.
        lookObserver = browser.objectWillChange.merge(with: settings.objectWillChange).sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateLook() } }
        }
        updateLook()
        engineObserver = settings.$browserEngine.dropFirst().sink { [weak self] engine in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if engine != .builtIn { WebBrowser.shared.hide() }
                    self.browser.use(engine.makeProvider())
                    self.updateEdgeGuard()
                }
            }
        }
        apps.openWebsite = { [weak self] url, split in self?.browser.openPinned(url: url, split: split) }
        // Keep the one pin area in sync with Arc's favorites.
        favoritesSync = browser.$snapshot
            .map(\.favorites)
            .removeDuplicates()
            .sink { [weak self] favorites in
                MainActor.assumeIsolated {
                    guard let self, self.browser.status == .ok || !favorites.isEmpty else { return }
                    // Sidebar-first: pins are the sidebar's own; Arc favorites only seed them once.
                    if self.library.isSetUp {
                        self.apps.convertFavoritePins(favorites)
                    } else {
                        self.apps.syncFavorites(favorites)
                    }
                }
            }
        downloadsBlob = DownloadsBlobController(downloads: downloads, anchor: { [weak self] in self?.panel.frame ?? .zero })
        TabDrag.pin = { [weak self] tab in
            self?.apps.pinTab(url: tab.url, title: tab.title)
        }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handleSwipe(event) }
            return event
        }

        WindowManager.screen = { [weak self] in self?.sidebarScreen }
        WindowManager.reservedWidth = { [weak self] in (self?.sidebarVisible ?? true) ? Layout.reservedWidth : 0 }
        WindowManager.rightReservedWidth = { [weak self] in (self?.sidebarVisible ?? true) ? Layout.rightReservedWidth : 0 }

        watchMouseScreen()
        WindowRules.shared.start()
        Freeze.shared.apps = apps
        Badges.shared.start()
        // Debug aid: ARCSIDEBAR_TEST_FREEZE=app:<bundle id> or tab freezes it on the right after a moment.
        if let test = ProcessInfo.processInfo.environment["ARCSIDEBAR_TEST_FREEZE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated {
                    if test.hasPrefix("app:") { Freeze.shared.freezeApp(String(test.dropFirst(4)), side: .right) }
                    else if let tab = WebBrowser.shared.tabs.first { Freeze.shared.freezeTab(tab.id, side: .right) }
                    Log.write("test freeze: target=\(WindowManager.targetAXRect().map { "\($0)" } ?? "-")")
                }
            }
        }
        screenSetting = settings.$barScreen.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.watchMouseScreen()
                self?.moveBarToScreen()
            } }
        }
        setupStatusItem()
        Log.write("launch \(Bundle.main.bundlePath) accessibilityTrusted=\(AXIsProcessTrusted())")
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            MainActor.assumeIsolated { self?.toggleSidebar() }
        }
        // Ideas & wishes: ⌃⌥I opens a small note.
        commandHotKeys.append(HotKey(keyCode: UInt32(kVK_ANSI_I), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            MainActor.assumeIsolated { self?.ideasPanel.toggle() }
        })
        SidebarActions.newIdea = { [weak self] in self?.ideasPanel.show() }
        // Show All Workspaces: ⌃⌥W, side by side to move things between them.
        commandHotKeys.append(HotKey(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            MainActor.assumeIsolated { self?.overview.toggle() }
        })
        SidebarActions.showOverview = { [weak self] in self?.overview.show() }
        // ⌃⌥Y anywhere: the last closed tab or quit app comes back (⌘Y does the same inside proDOCKtivity;
        // a global ⌘Y would take it from Finder's Quick Look and the browsers' History).
        commandHotKeys.append(HotKey(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(controlKey | optionKey)) {
            MainActor.assumeIsolated { if !Reopen.reopenLast() { NSSound.beep() } }
        })
        tabCloser.attach(browser: browser, apps: apps)
        // Auto-Quit asks where an app is: Favorites, pinned in a workspace (or opened there, with open apps
        // per workspace), or just open.
        autoQuit.place = { [weak self] id in
            guard let self else { return .open }
            if self.apps.pinnedIDs.contains(id) { return .favorites }
            if let space = self.library.spaces.first(where: { self.library.containsApp(id, inSpace: $0.id) }) {
                return .workspace(space.id)
            }
            if self.settings.openAppsPerWorkspace, let space = self.apps.openIn[id] { return .workspace(space) }
            return .open
        }
        // Every few days, gently ask what could be better (Settings → General to change).
        checkInTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.ideas.isCheckInDue, !self.commandBar.isShown else { return }
                self.ideasPanel.showCheckIn()
            }
        }
        checkInTimer?.tolerance = 60
        SidebarActions.chooseIcon = { [weak self] id, title in
            guard let self else { return }
            self.iconPicker.show(title: title, current: self.apps.pinIcons[id]) { key in
                DS.Motion.perform(DS.Motion.standard) { self.apps.setIcon(key, for: id) }
            }
        }
        SidebarActions.openDesign = { [weak self] in self?.settingsWindow.show(tab: .appearance) }
        SidebarActions.openSettings = { [weak self] in self?.settingsWindow.show() }
        // Resizing the bar: move it right away, re-snap windows once the drag settles.
        widthObserver = settings.$sidebarWidth.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.sidebarVisible, let screen = self.sidebarScreen else { return }
                    self.panel.setFrame(SidebarPanel.shownFrame(on: screen), display: true)
                    self.updateBackdrop()
                    self.resnapWork?.cancel()
                    let work = DispatchWorkItem {
                        MainActor.assumeIsolated {
                            WindowManager.fillFrontmost(automatic: true)
                            WindowManager.containAll()
                            WebBrowser.shared.followFrame()
                            self.updateEdgeGuard()
                        }
                    }
                    self.resnapWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                }
            }
        }
        SidebarActions.newFolder = { [weak self] spaceID in
            // Let the menu close before showing the name prompt.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let name = Prompt.text("New Folder", message: "Name the folder.", initial: "New Folder") else { return }
                    DS.Motion.perform(DS.Motion.standard) { self.library.newFolder(in: spaceID, title: name) }
                    Log.write("new folder “\(name)” in space \(spaceID)")
                }
            }
        }
        SidebarActions.openIdeas = { [weak self] in self?.ideas.openFile() }
        SidebarActions.exportIdeas = { [weak self] in self?.ideas.export() }
        SidebarActions.emailIdeas = { [weak self] in self?.ideas.email() }
        SidebarActions.openGuide = {
            if let url = Bundle.main.url(forResource: "Setup Guide", withExtension: "html") { NSWorkspace.shared.open(url) }
        }
        addressObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self else { return }
                // The built-in browser has its own address field (⌘L there).
                if !self.browser.provider.isBuiltIn, app?.bundleIdentifier == self.browser.provider.bundleID {
                    if self.addressHotKey == nil {
                        self.addressHotKey = HotKey(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey)) { [weak self] in
                            MainActor.assumeIsolated {
                                guard let self else { return }
                                self.commandBar.showAddressBar(currentURL: self.browser.activeTabURL)
                            }
                        }
                    }
                } else if app?.processIdentifier != getpid() {
                    self.addressHotKey = nil
                }
            }
        }
        // DOCKlight: ⌥Space, and ⌃⌥Space as a fallback. ⌘Space stays Spotlight's.
        for mods in [UInt32(optionKey), UInt32(controlKey | optionKey)] {
            commandHotKeys.append(HotKey(keyCode: UInt32(kVK_Space), modifiers: mods) { [weak self] in
                MainActor.assumeIsolated { self?.commandBar.toggle() }
            })
        }

        NotificationCenter.default.addObserver(forName: ScreenWatcher.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sidebarVisible, let screen = self.sidebarScreen else { return }
                self.panel.show(on: screen, animated: false)
                // A screen plugged in or out changes where the frame is open (see Layout.sharedEdges).
                self.frameChanged()
            }
        }

        // The bar comes back the way you left it: hidden stays hidden until ⌃⌥S.
        if UserDefaults.standard.object(forKey: Self.sidebarVisibleKey) as? Bool == false {
            setSidebar(visible: false)
        } else if let screen = sidebarScreen {
            panel.show(on: screen, animated: true)
        }
        updateBackdrop()
        // Frame mode: switching it, its width or snapping re-lays out the bar, backdrop and windows.
        frameSettings = Publishers.CombineLatest4(settings.$frameMode, settings.$frameWidth, settings.$autoFitWindows,
                                                  settings.$frameUnderMenuBar)
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.frameChanged() } }
            }
        frameOtherScreensSetting = settings.$frameOtherScreens.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateBackdrop(); WebBrowser.shared.moveToConfiguredScreen() } }
        }
        // Docks switched on or off, or resized: bar, docks and windows make room.
        dockSettings = Publishers.CombineLatest4(settings.$websiteDock, settings.$websiteDockWidth,
                                                 settings.$filesDock, settings.$filesDockWidth)
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.frameChanged() } }
            }
        // Frame mode: an app brought forward with its window over the bar or past the frame snaps inside.
        containObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { WindowManager.containFrontmost() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated { WindowManager.containAll() }
        }
        guardSetting = settings.$blockArcSidebarPeek.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateEdgeGuard() } }
        }
        // Follow Arc's window as it moves or resizes.
        WindowManager.tuckWidth = { ArcWindowState.anchoredSidebarWidth() }
        WindowManager.tuckPID = { [weak self] in
            guard let self, self.browser.provider.isArc, self.settings.blockArcSidebarPeek, self.sidebarVisible else { return nil }
            return self.browser.provider.runningApp?.processIdentifier
        }
        guardTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateEdgeGuard() }
        }
        guardTimer?.tolerance = 1
        browser.start()

        // Debug aid: ARCSIDEBAR_WEB_TEST=/path.png opens a page in the built-in browser and saves what it shows.
        if let path = ProcessInfo.processInfo.environment["ARCSIDEBAR_WEB_TEST"], browser.provider.isBuiltIn {
            browser.createTab(input: "example.com")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                MainActor.assumeIsolated {
                    let tab = WebBrowser.shared.activeTab
                    let space = self?.browser.activeSpace
                    Log.write("web test: tab=\(tab?.title ?? "-") \(tab?.url ?? "-") sidebarTabs=\(space?.unpinned.map(\.title) ?? [])")
                    tab?.webView?.takeSnapshot(with: nil) { image, _ in
                        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
        }
        // Debug aid: ARCSIDEBAR_TEST_KEYS=1 sends the browser shortcuts as real key events (browser window
        // in focus, then the bar) with two temporary tabs, logs what happened, and cleans up.
        if ProcessInfo.processInfo.environment["ARCSIDEBAR_TEST_KEYS"] != nil, browser.provider.isBuiltIn {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.testKeys() }
            }
        }
        // Debug aid: ARCSIDEBAR_SNAPSHOT=/path.png renders the sidebar to an image after a few seconds
        // (also while the screen is locked), then the downloads view and DOCKlight next to it.
        if let path = ProcessInfo.processInfo.environment["ARCSIDEBAR_SNAPSHOT"] {
            // ARCSIDEBAR_SNAPSHOT_OVERVIEW=1: also Show All Workspaces, to path + ".overview.png".
            if ProcessInfo.processInfo.environment["ARCSIDEBAR_SNAPSHOT_OVERVIEW"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.overview.show()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            MainActor.assumeIsolated {
                                guard let v = NSApp.windows.first(where: { $0.title == "All Workspaces" })?.contentView,
                                      let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                                v.cacheDisplay(in: v.bounds, to: r)
                                try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".overview.png"))
                            }
                        }
                    }
                }
            }
            // ARCSIDEBAR_SNAPSHOT_UNDO=1: with an Undo toast.
            if ProcessInfo.processInfo.environment["ARCSIDEBAR_SNAPSHOT_UNDO"] != nil {
                browser.showHint("“Work” deleted. Its open tabs moved to “uni”.", action: "Undo", seconds: 30) {}
            }
            // ARCSIDEBAR_SNAPSHOT_UPDATE=1: with the update card for a made-up version.
            if ProcessInfo.processInfo.environment["ARCSIDEBAR_SNAPSHOT_UPDATE"] != nil { Updater.shared.pretend(version: "0.2") }
            // ARCSIDEBAR_SNAPSHOT_SETUP=1: also the setup tour's first page, to path + ".setup.png".
            if ProcessInfo.processInfo.environment["ARCSIDEBAR_SNAPSHOT_SETUP"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.setupTour.show()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            MainActor.assumeIsolated {
                                guard let v = NSApp.windows.first(where: { $0.title == "Set Up proDOCKtivity" })?.contentView,
                                      let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                                v.cacheDisplay(in: v.bounds, to: r)
                                try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".setup.png"))
                            }
                        }
                    }
                }
            }
            // ARCSIDEBAR_SNAPSHOT_ICONS=1: with the icon picker open under the current space.
            if ProcessInfo.processInfo.environment["ARCSIDEBAR_SNAPSHOT_ICONS"] != nil {
                Settings.shared.editingIconSpace = library.activeSpaceID
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let view = self?.panel.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    self?.downloadsBlob.show()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        MainActor.assumeIsolated {
                            guard let blob = NSApp.windows.first(where: { $0 is NSPanel && $0 !== self?.panel && $0.isVisible }),
                                  let v = blob.contentView, let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                            v.cacheDisplay(in: v.bounds, to: r)
                            try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".blob.png"))
                            self?.downloadsBlob.close()
                            self?.debugSnapshotCommandBar(path: path + ".command.png")
                        }
                    }
                }
            }
        }

        launched = true
        if !pendingURLs.isEmpty {
            let urls = pendingURLs
            pendingURLs = []
            application(NSApp, open: urls)
        }

        // setupNA is kept up to date from here on; the setup tour on the very first start (it asks
        // for Accessibility itself), otherwise the system prompt once, as before.
        setupAutosave = SetupAutosave(library: library)
        Updater.shared.start()
        Reopen.openTab = { [weak self] entry in
            guard let self, case .tab(let spaceID, let url, let title) = entry else { return }
            if self.browser.provider.isBuiltIn {
                let space = spaceID.flatMap { id in self.library.spaces.contains { $0.id == id } ? id : nil } ?? self.library.activeSpaceID
                if let space { WebBrowser.shared.newTab(url: url, inSpace: space).title = title } else { self.browser.createTab(input: url) }
                WebBrowser.shared.closedTabsForget(url: url)
            } else {
                self.browser.createTab(input: url)
            }
        }
        SidebarActions.showSetupTour = { [weak self] in self?.setupTour.show() }
        let defaults = UserDefaults.standard
        if setupTour.isDue {
            defaults.set(true, forKey: "didRequestAccessibility")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in MainActor.assumeIsolated { self?.setupTour.show() } }
        } else if !defaults.bool(forKey: "didRequestAccessibility") {
            defaults.set(true, forKey: "didRequestAccessibility")
            if !AXIsProcessTrusted() { perms.promptAccessibility() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        CrashCollector.logQuitRequest()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Tabs are saved a second after each change; a quick quit must not lose the last ones.
        WebBrowser.shared.saveNow()
        library.saveNow()
        CrashCollector.endedNormally()
    }

    /// Links from other apps (when proDOCKtivity is the default browser) open as a tab in the
    /// active space, in whichever browser is chosen under Settings → Browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        // A link that launched the app can arrive before launching is done (no spaces, browser
        // or window placement yet): it waits until then.
        guard launched else { pendingURLs += urls; return }
        for url in urls {
            Log.write("open link from another app: \(url.scheme ?? "?")://\(url.host ?? "")")
            if url.isFileURL {
                browser.createTab(input: url.absoluteString)
            } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                browser.createTab(input: url.absoluteString)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        setSidebar(visible: true)
        return false
    }

    /// The screen chosen in Settings → General (the main one by default).
    private var sidebarScreen: NSScreen? { settings.resolvedBarScreen(mouseScreen: mouseScreen) }
    /// The screen the mouse was last on (for "where the mouse is").
    private var mouseScreen: NSScreen?
    private var mouseScreenTimer: Timer?
    /// The screen the mouse moved to, and since when (it has to rest there a moment).
    private var mouseCandidate: NSScreen?
    private var mouseCandidateSince = Date()
    private var screenSetting: AnyCancellable?
    private var frameOtherScreensSetting: AnyCancellable?

    /// Moves the bar to the screen it belongs on now.
    private func moveBarToScreen() {
        guard sidebarVisible, let screen = sidebarScreen else { return }
        if panel.frame != SidebarPanel.shownFrame(on: screen) {
            panel.show(on: screen, animated: false)
            updateBackdrop()
            updateEdgeGuard()
            WebBrowser.shared.followFrame()
            Log.write("bar moved to screen \(screen.localizedName)")
        }
    }

    /// "Where the mouse is": the bar follows once the mouse has rested on another screen for a moment.
    /// Runs only while Settings → General says "The screen where the mouse is".
    private func watchMouseScreen() {
        mouseScreenTimer?.invalidate()
        mouseScreenTimer = nil
        guard settings.barScreen == "mouse" else { return }
        mouseCandidate = nil
        mouseCandidateSince = Date()
        mouseScreenTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.barScreen == "mouse" else { return }
                let point = NSEvent.mouseLocation
                guard let here = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return }
                if here != self.mouseCandidate { self.mouseCandidate = here; self.mouseCandidateSince = Date(); return }
                if here != self.mouseScreen, Date().timeIntervalSince(self.mouseCandidateSince) > 0.8 {
                    self.mouseScreen = here
                    self.moveBarToScreen()
                }
            }
        }
        mouseScreenTimer?.tolerance = 0.1
    }

    // MARK: Show / hide

    @objc func toggleSidebar() { setSidebar(visible: !sidebarVisible) }

    static let sidebarVisibleKey = "sidebar.visible"

    func setSidebar(visible: Bool) {
        sidebarVisible = visible
        UserDefaults.standard.set(visible, forKey: Self.sidebarVisibleKey)
        if !visible { GettingStarted.shared.mark(.hideBar) }
        browser.isVisible = visible
        Badges.shared.isActive = visible
        if visible, let screen = sidebarScreen {
            panel.show(on: screen, animated: true)
        } else {
            panel.hide(animated: true)
            downloadsBlob.close()
        }
        updateBackdrop()
        updateEdgeGuard()
        toggleItem.title = visible ? "Hide Sidebar" : "Show Sidebar"
    }

    // MARK: Frame mode

    /// The backdrop follows the bar's screen and the area windows snap into.
    private func updateBackdrop() {
        backdrop.update(screen: sidebarScreen, area: WindowManager.fullCocoaRect(),
                        visible: settings.frameMode && sidebarVisible)
        // The other screens get the frame without a bar, if switched on.
        let others = settings.frameMode && settings.frameOtherScreens && sidebarVisible
            ? NSScreen.screens.filter { $0 != sidebarScreen } : []
        for screen in others {
            let name = screen.localizedName
            let extra = otherBackdrops[name] ?? Backdrop(settings: settings, apps: apps, browser: browser)
            otherBackdrops[name] = extra
            extra.update(screen: screen, area: WindowManager.otherScreenCocoaRect(screen), visible: true)
        }
        for (name, extra) in otherBackdrops where !others.contains(where: { $0.localizedName == name }) {
            extra.update(screen: nil, area: nil, visible: false)
        }

        docks.update(screen: sidebarScreen, visible: sidebarVisible)
    }

    private var otherBackdrops: [String: Backdrop] = [:]

    private func frameChanged() {
        if sidebarVisible, let screen = sidebarScreen { panel.show(on: screen, animated: false) }
        updateBackdrop()
        WindowRules.shared.syncWatching()
        frameWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                WindowManager.containAll()
                WebBrowser.shared.followFrame()
                self.updateEdgeGuard()
            }
        }
        frameWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        Log.write("frame mode=\(settings.frameMode) width=\(settings.frameWidth)")
    }

    /// Two-finger horizontal swipe on the sidebar switches Arc spaces, like in Arc.
    private func handleSwipe(_ event: NSEvent) {
        guard event.window === panel else { return }
        if event.phase == .began { swipeDistance = 0; swipeFired = false }
        if event.phase == .ended || event.phase == .cancelled { swipeDistance = 0; swipeFired = false; return }
        guard event.phase == .changed || event.phase == .began,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
        // Measured in the fingers' direction, whatever the natural scrolling setting is.
        swipeDistance += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        if !swipeFired, abs(swipeDistance) > 60 {
            swipeFired = true
            // Like macOS: the content moves with the fingers, so fingers to the left bring in the next space.
            let next = (swipeDistance < 0) != settings.reverseSpaceSwipe
            browser.focusAdjacentSpace(next ? 1 : -1)
        }
    }

    private func testKeys() {
        let web = WebBrowser.shared
        let before = web.activeTab?.id
        let clip = NSPasteboard.general.string(forType: .string)
        let a = web.newTab(url: "https://example.com/?keytest=a")
        let b = web.newTab(url: "https://example.org/?keytest=b")
        func send(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags) {
            guard let w = NSApp.keyWindow, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                                              windowNumber: w.windowNumber, context: nil, characters: chars,
                                                              charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
            NSApp.sendEvent(e)
        }
        func name() -> String { web.activeTab.map { $0.id == a.id ? "A" : $0.id == b.id ? "B" : "other" } ?? "none" }
        var steps: [(String, () -> Void)] = [
            ("key=\(type(of: NSApp.keyWindow as Any))", {}),
            ("⌃Tab", { send("\t", 48, .control) }),
            ("⌃⇧Tab", { send("\t", 48, [.control, .shift]) }),
            ("⌘⌥→", { send("\u{F703}", 124, [.command, .option]) }),
            ("⌘⇧}", { send("}", 30, [.command, .shift]) }),
            ("⌘1", { send("1", 18, .command) }),
            ("⌘9", { send("9", 25, .command) }),
            ("⌘⌥C", { send("c", 8, [.command, .option]) }),
            ("clipboard", {}),
            ("bar focus", { self.panel.makeKey() }),
            ("key=bar ⌃Tab", { send("\t", 48, .control) }),
            ("bar ⌘9", { send("9", 25, .command) }),
            ("bar ⌘W browser close B then ⌘⇧T", { web.close(tabID: web.activeTab?.id ?? ""); }),
            ("bar ⌘⇧T", { send("T", 17, [.command, .shift]) }),
        ]
        var log: [String] = []
        func next() {
            guard !steps.isEmpty else {
                Log.write("key test: " + log.joined(separator: " | "))
                for t in web.tabs where t.url.contains("keytest=") { web.close(tabID: t.id) }
                if let before { web.select(tabID: before) }
                NSPasteboard.general.clearContents()
                if let clip { NSPasteboard.general.setString(clip, forType: .string) }
                return
            }
            let (label, action) = steps.removeFirst()
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    let extra = label == "clipboard" ? (NSPasteboard.general.string(forType: .string) ?? "-") : name()
                    let key = NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil"
                    log.append("\(label) → \(extra) [\(key)]")
                    next()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { next() } }
    }

    /// Debug aid for the snapshot hook: renders the command bar with a sample query.
    private func debugSnapshotCommandBar(path: String) {
        commandBar.show()
        commandBar.debugQuery(ProcessInfo.processInfo.environment["ARCSIDEBAR_QUERY"] ?? "rem")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let win = NSApp.windows.first(where: { $0 is CommandPanel && $0.isVisible }),
                      let v = win.contentView, let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: r)
                try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                self?.commandBar.close()
            }
        }
    }

    /// The current space's color and accent for every window (switched instantly),
    /// and the chosen theme.
    private func updateLook() {
        let space: (area: Area?, accent: Accent?) = library.activeSpace.map { ($0.area, $0.accent) }
            ?? browser.snapshot.activeSpace.map { ($0.area, $0.accent) } ?? (nil, nil)
        let area = settings.matchArcSpace ? space.area : nil
        let accent = space.accent ?? settings.accent
        let look = SpaceLook.shared
        if look.area != area { look.area = area }
        if look.accent != accent { look.accent = accent }
        if look.tone != settings.barTone { look.tone = settings.barTone }
        let appearance = settings.theme.appearance
        if NSApp.appearance?.name != appearance?.name { NSApp.appearance = appearance }
    }

    // MARK: Import

    /// Copies Arc's spaces, pinned tabs, folders and favorites into the sidebar.
    func importFromArc(announce: Bool) {
        guard let tree = ArcSidebarFile().load() else {
            if announce { browser.showHint("Couldn't read Arc's sidebar data.") }
            return
        }
        let favorites = library.importFromArc(tree)
        for space in library.spaces {
            guard let arcID = space.arcSpaceID else { continue }
            apps.migrateSpaceApps(from: arcID, to: space.id)
        }
        apps.convertFavoritePins(browser.snapshot.favorites)
        for fav in favorites where !fav.url.isEmpty && !apps.isTabPinned(url: fav.url) {
            apps.pinTab(url: fav.url, title: fav.title)
        }
        Log.write("imported from Arc: \(library.spaces.count) spaces, \(favorites.count) favorites")
        if announce { browser.showHint("Imported from Arc: \(library.spaces.count) spaces and \(favorites.count) favorites.") }
    }

    func importBookmarks(chrome: Bool) {
        let items = chrome ? BookmarkImport.chrome() : BookmarkImport.safari()
        guard let items, !items.isEmpty else {
            browser.showHint(chrome ? "No Chrome bookmarks found." :
                "Safari bookmarks need Full Disk Access for proDOCKtivity (Privacy & Security).")
            return
        }
        library.importBookmarks(items, spaceTitle: chrome ? "Chrome" : "Safari", emoji: chrome ? "🌐" : "🧭")
        browser.showHint("Imported \(chrome ? "Chrome" : "Safari") bookmarks into a new workspace.")
    }

    /// Arc's sidebar pops out whenever the mouse nears its edge while it's hidden, and Arc
    /// watches the mouse directly, so no overlay can stop that. Instead its sidebar stays shown
    /// and Arc's window is shifted left so the sidebar sits behind ours.
    private func updateEdgeGuard() {
        edgeGuard.hide()
        guard browser.provider.isArc, settings.blockArcSidebarPeek, sidebarVisible, AXIsProcessTrusted(),
              let pid = browser.provider.runningApp?.processIdentifier else { return }
        if browser.showArcSidebarIfHidden() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { WindowManager.fillNow(pid: pid) }
        } else if let width = ArcWindowState.anchoredSidebarWidth(), let area = WindowManager.targetCocoaRect(),
                  let arcFrame = EdgeGuard.mainWindowFrame(of: pid), abs(arcFrame.minX - (area.minX - width)) > 2 {
            // Arc's sidebar is showing but not tucked yet (e.g. Arc was moved): tuck it.
            WindowManager.fillNow(pid: pid)
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image()

        let menu = NSMenu()
        toggleItem = NSMenuItem(title: "Hide Sidebar", action: #selector(toggleSidebar), keyEquivalent: "s")
        toggleItem.keyEquivalentModifierMask = [.control, .option]
        toggleItem.target = self
        menu.addItem(toggleItem)

        let idea = NSMenuItem(title: "New Idea for proDOCKtivity  ⌃⌥I", action: #selector(newIdea), keyEquivalent: "")
        idea.target = self
        menu.addItem(idea)

        let command = NSMenuItem(title: "DOCKlight Search  ⌥Space / ⌃⌥Space", action: #selector(openCommandBar), keyEquivalent: "")
        command.target = self
        menu.addItem(command)

        let all = NSMenuItem(title: "Show All Workspaces  ⌃⌥W", action: #selector(showOverview), keyEquivalent: "")
        all.target = self
        menu.addItem(all)

        let fit = NSMenuItem(title: "Snap Front Window", action: #selector(snapFront), keyEquivalent: "")
        fit.target = self
        menu.addItem(fit)

        snapItem = NSMenuItem(title: "Snap Windows Automatically", action: #selector(toggleAutoFit), keyEquivalent: "")
        snapItem.target = self
        menu.addItem(snapItem)

        menu.addItem(.separator())
        axStatusItem = NSMenuItem(title: "Accessibility", action: #selector(openAX), keyEquivalent: "")
        axStatusItem.target = self
        menu.addItem(axStatusItem)
        let auto = NSMenuItem(title: "Automation Settings…", action: #selector(openAutomation), keyEquivalent: "")
        auto.target = self
        menu.addItem(auto)

        let prefs = NSMenuItem(title: "Settings & Auto-Quit…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit proDOCKtivity", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func openSettings() { settingsWindow.show() }
    @objc private func openCommandBar() { commandBar.show() }
    @objc private func newIdea() { ideasPanel.show() }
    @objc private func showOverview() { overview.show() }
    @objc private func snapFront() { WindowManager.fillFrontmost() }
    @objc private func toggleAutoFit() { settings.autoFitWindows.toggle() }
    @objc private func openAX() { perms.openAccessibilitySettings() }
    @objc private func openAutomation() { perms.openAutomationSettings() }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        snapItem.state = settings.autoFitWindows ? .on : .off
        axStatusItem.title = AXIsProcessTrusted() ? "Accessibility: allowed ✓" : "Accessibility: not allowed – click to fix"
    }
}
