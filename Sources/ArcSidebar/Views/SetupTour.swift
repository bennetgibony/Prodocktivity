import AppKit
import SwiftUI

/// The setup tour: set proDOCKtivity up in about a minute, then never again. Three ways in: a quick
/// premade setup, a few questions step by step, or a setup file (setupWA / setupNA). Shown once on the
/// first start; again from the ⋯ menu or Settings › General.
@MainActor
final class SetupTour: NSObject, NSWindowDelegate {
    static let doneKey = "setup.done"

    private let library: Library
    private let perms: PermissionsModel
    private var window: NSWindow?

    init(library: Library, perms: PermissionsModel) {
        self.library = library
        self.perms = perms
    }

    /// First start only: nothing set up yet (one empty workspace) and the tour not done or skipped.
    var isDue: Bool {
        guard !UserDefaults.standard.bool(forKey: Self.doneKey) else { return false }
        let fresh = library.spaces.count <= 1 && (library.spaces.first?.pinned.isEmpty ?? true)
        if !fresh { UserDefaults.standard.set(true, forKey: Self.doneKey) }
        return fresh
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: DS.Size.setupTour),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Set Up proDOCKtivity"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SetupTourView(library: library, perms: perms) { [weak self] in self?.finish() }
            .accent(Settings.shared.accent))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
        Log.write("setup tour: shown")
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing counts as "later": it doesn't come back by itself.
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window = nil
    }

    // MARK: Premade setup

    /// Settings most people want, and three workspaces if there aren't any yet. A premade file in the
    /// app (Resources/Premade.pdsetup) wins, so a set-up proDOCKtivity can be handed out as it is.
    static func applyPremade(library: Library) -> Bool {
        if let url = Bundle.main.url(forResource: "Premade", withExtension: SetupFile.fileExtension),
           let data = try? Data(contentsOf: url), let contents = try? SetupFile.read(data) {
            SetupFile.apply(contents, library: library)
            return true // settings changed under the running app: restart
        }
        let s = Settings.shared
        s.browserEngine = .builtIn
        s.autoFitWindows = true
        s.frameMode = true
        s.matchArcSpace = true
        s.openAppsPerWorkspace = false
        if library.spaces.count <= 1, library.spaces.first?.pinned.isEmpty ?? true {
            var spaces = [LibrarySpace(title: "Uni", emoji: "🎓"), LibrarySpace(title: "Work", emoji: "💼"),
                          LibrarySpace(title: "Free time", emoji: "🌴")]
            if let home = library.spaces.first { spaces[0].id = home.id; spaces[0].profileID = home.profileID }
            library.replaceAll(spaces: spaces, profiles: [])
        }
        return false
    }
}

private struct SetupTourView: View {
    let library: Library
    @ObservedObject var perms: PermissionsModel
    let finish: () -> Void

    enum Page { case start, browser, workspaces, behaviour, permissions, done }
    @State private var page: Page = .start
    /// A setup file was applied: settings are read again at the end (restart).
    @State private var needsRestart = false
    @State private var problem: String?
    @State private var names = ["Uni", "Work", "Free time"]
    @ObservedObject private var settings = Settings.shared

    private let manualPages: [Page] = [.browser, .workspaces, .behaviour, .permissions, .done]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            content
            Spacer(minLength: 0)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").textRole(.footnote).foregroundStyle(Palette.danger)
            }
            footer
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.top, DS.Space.xxxl)
        .padding(.bottom, DS.Space.xl)
        .frame(width: DS.Size.setupTour.width, height: DS.Size.setupTour.height, alignment: .topLeading)
        .background(Palette.canvas)
        .dsAnimation(DS.Motion.standard, value: page)
    }

    // MARK: Pages

    @ViewBuilder private var content: some View {
        switch page {
        case .start:
            header("Set up proDOCKtivity", "About a minute, and you won't need to touch it again. Everything can be changed later in Settings.")
            VStack(spacing: DS.Space.s) {
                choice("bolt.fill", "Quick setup", "Recommended settings and three workspaces: Uni, Work, Free time. One click.", recommended: true) {
                    needsRestart = SetupTour.applyPremade(library: library)
                    page = .permissions
                }
                choice("list.bullet", "Step by step", "Four short questions: browser, workspaces, how windows behave, permissions.") {
                    page = .browser
                }
                choice("doc.badge.arrow.up", "From a setup file", "A setupWA (with apps) or setupNA (without apps) file, from another Mac or a friend.") {
                    loadFile()
                }
            }
        case .browser:
            header("Which browser?", "Websites in the bar open here.")
            Picker("", selection: $settings.browserEngine) {
                Text("Built-in (recommended): fast, separate logins per workspace").tag(BrowserEngine.builtIn)
                Text("Arc").tag(BrowserEngine.arc)
                Text("Google Chrome: for Chrome extensions").tag(BrowserEngine.chrome)
            }
            .pickerStyle(.radioGroup).labelsHidden()
        case .workspaces:
            header("Your workspaces", "One per part of your life. Leave a field empty to skip it. Or bring over what you have:")
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(names.indices, id: \.self) { i in
                    TextField("Workspace \(i + 1)", text: $names[i]).textFieldStyle(.roundedBorder).frame(width: DS.Size.popover)
                }
            }
            HStack(spacing: DS.Space.s) {
                Button("From Arc") { SidebarActions.importArc?(); names = [] ; page = .behaviour }
                Button("Chrome bookmarks") { SidebarActions.importChrome?(); names = []; page = .behaviour }
                Button("Safari bookmarks") { SidebarActions.importSafari?(); names = []; page = .behaviour }
            }
            .buttonStyle(.secondary)
        case .behaviour:
            header("How should it behave?", "The usual choice is already ticked.")
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Toggle("Snap windows next to the bar", isOn: $settings.autoFitWindows)
                Toggle("Frame: everything in one window, in the workspace's color", isOn: $settings.frameMode)
                Picker("Open apps", selection: $settings.openAppsPerWorkspace) {
                    Text("Show in every workspace").tag(false)
                    Text("Only in the workspace they were opened in").tag(true)
                }
                .pickerStyle(.radioGroup)
            }
            .toggleStyle(DSSwitchStyle())
        case .permissions:
            header("Two permissions", "Both are optional; everything else works without them.")
            VStack(alignment: .leading, spacing: DS.Space.m) {
                permission(done: perms.accessibility, title: "Snap windows next to the bar",
                           detail: "macOS asks for Accessibility. Turn proDOCKtivity on in the list that opens.",
                           button: "Allow…") { perms.openAccessibilitySettings() }
                permission(done: false, title: "Open links from other apps here",
                           detail: "Makes proDOCKtivity your default browser (macOS asks to confirm).",
                           button: "Make Default…") {
                    for scheme in ["http", "https"] {
                        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { _ in }
                    }
                }
            }
        case .done:
            header("All set", needsRestart ? "proDOCKtivity restarts once to load your setup." : "Four shortcuts worth knowing:")
            VStack(alignment: .leading, spacing: DS.Space.s) {
                shortcut("⌃⌥S", "Show or hide the bar")
                shortcut("⌥Space / ⌃⌥Space", "DOCKlight: search apps, tabs, files and the web")
                shortcut("⌃⌥W", "All workspaces side by side, to tidy up")
                shortcut("⌘Y", "Bring back what you just closed (⌃⌥Y from other apps)")
            }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if page == .start {
                Button("Skip for Now", action: finish).buttonStyle(.ghostSmall)
            } else if page != .done {
                Button("Back") { back() }.buttonStyle(.ghostSmall)
            }
            Spacer()
            if page != .start {
                if let index = manualPages.firstIndex(of: page), page != .done {
                    Text("\(index + 1) of \(manualPages.count - 1)").textRole(.footnote).foregroundStyle(Palette.text3)
                }
                Button(page == .done ? (needsRestart ? "Restart" : "Done") : "Continue") { next() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Steps

    private func next() {
        problem = nil
        switch page {
        case .workspaces: makeWorkspaces()
        case .done:
            finish()
            if needsRestart { SetupFile.relaunch() }
            return
        default: break
        }
        if let i = manualPages.firstIndex(of: page), i + 1 < manualPages.count { page = manualPages[i + 1] }
    }

    private func back() {
        if let i = manualPages.firstIndex(of: page), i > 0, page != .permissions || !needsRestart { page = manualPages[i - 1] } else { page = .start }
    }

    /// The typed names become the workspaces (only while nothing is set up yet, so nothing is lost).
    private func makeWorkspaces() {
        let titles = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !titles.isEmpty, library.spaces.count <= 1, library.spaces.first?.pinned.isEmpty ?? true else { return }
        var spaces = titles.map { LibrarySpace(title: $0) }
        if let home = library.spaces.first { spaces[0].id = home.id; spaces[0].profileID = home.profileID }
        library.replaceAll(spaces: spaces, profiles: [])
    }

    private func loadFile() {
        guard let result = SetupFile.openWithPanel() else { return }
        switch result {
        case .success(let contents):
            SetupFile.apply(contents, library: library)
            needsRestart = true
            page = .permissions
        case .failure(let error):
            problem = error.localizedDescription
        }
    }

    // MARK: Pieces

    private func header(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title).textRole(.title2).foregroundStyle(Palette.text)
            Text(text).textRole(.body).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choice(_ symbol: String, _ title: String, _ text: String, recommended: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                Image(systemName: symbol).textRole(.title3).frame(width: DS.Size.settingsIcon)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    HStack(spacing: DS.Space.s) {
                        Text(title).textRole(.headline).foregroundStyle(Palette.text)
                        if recommended { Text("Recommended").textRole(.caption).foregroundStyle(Palette.text2) }
                    }
                    Text(text).textRole(.footnote).foregroundStyle(Palette.text2).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(Palette.text3)
            }
            .card(padding: DS.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }

    private func permission(done: Bool, title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Palette.success : Palette.text3)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).textRole(.headline).foregroundStyle(Palette.text)
                Text(detail).textRole(.footnote).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !done { Button(button, action: action).buttonStyle(.secondary) }
        }
    }

    private func shortcut(_ keys: String, _ text: String) -> some View {
        HStack(spacing: DS.Space.m) {
            Text(keys).textRole(.mono).foregroundStyle(Palette.text).frame(width: DS.Size.settingsValue * 2, alignment: .leading)
            Text(text).textRole(.body).foregroundStyle(Palette.text2)
        }
    }
}
