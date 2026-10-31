import AppKit
import SwiftUI

/// True while ⌥ is held; ⌥-click opens the item in split screen.
@MainActor var optionHeld: Bool { NSEvent.modifierFlags.contains(.option) }

struct SidebarView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var apps: AppsModel
    @ObservedObject var browser: BrowserModel
    @ObservedObject var downloads: DownloadsModel
    @ObservedObject var perms: PermissionsModel
    let onHide: () -> Void
    let onToggleDownloads: () -> Void
    let onOpenSettings: () -> Void
    @ObservedObject private var chrome = BarChrome.shared

    var body: some View {
        if let insets = chrome.framed {
            // Frame mode: no card of its own; the bar sits on the frame's color, like Arc.
            column
                .padding(insets)
                .background(BarBackground())
                .overlay(alignment: .trailing) { ResizeHandle(settings: settings) }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: chrome.roundTop ? Layout.frameCornerRadius : 0, style: .continuous))
        } else {
            card
        }
    }

    private var card: some View {
        column
        .background(BarBackground())
        .overlay(alignment: .trailing) { ResizeHandle(settings: settings) }
        .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous))
        .overlay(BarOutline())
    }

    private var column: some View {
        VStack(spacing: 0) {
            TopBar(apps: apps, browser: browser)
            content
            UpdateCard(updater: Updater.shared)
                .padding(.horizontal, DS.Space.edge)
            if let hint = browser.hint {
                HintToast(text: hint, action: browser.hintAction) { browser.hint = nil; browser.hintAction = nil }
                    .padding(.horizontal, DS.Space.edge)
                    .transition(.appear)
            }
            BottomBar(settings: settings, apps: apps, browser: browser, downloads: downloads,
                      onToggleDownloads: onToggleDownloads, onOpenSettings: onOpenSettings, onHide: onHide)
        }
        .dsAnimation(DS.Motion.standard, value: apps.pinnedIDs)
        .dsAnimation(DS.Motion.standard, value: browser.hint)
        .dsAnimation(DS.Motion.standard, value: apps.running.map(\.processIdentifier))
    }

    private var content: some View {
            ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                    GettingStartedCard(favorites: apps.pinnedIDs.count, spaces: browser.library?.spaces.count ?? 1)
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        SectionHeader(title: "Favorites")
                            .help("Your most-used apps and websites. Drag apps or tabs here; right-click one for more.")
                        PinnedAppsGrid(apps: apps, browser: browser)
                    }
                    SplitViewsSection(splits: SplitManager.shared, apps: apps, browser: browser)
                    if !perms.accessibility {
                        PermissionCard(
                            symbol: "macwindow.on.rectangle",
                            title: "Snap windows next to the bar",
                            message: "Allow Accessibility access so apps you open from here fill the space beside the bar. Everything else works without it.",
                            buttonTitle: "Open Accessibility Settings…",
                            action: perms.openAccessibilitySettings
                        )
                    }
                    if browser.activeSpace == nil {
                        AppsSection(apps: apps, browser: browser)
                    }
                    BrowserSection(browser: browser, apps: apps, perms: perms, mode: settings.websiteDock ? .apps : .all)
                }
                .padding(.horizontal, DS.Space.edge)
                .padding(.bottom, DS.Space.l)
                .dsAnimation(DS.Motion.standard, value: browser.snapshot.activeSpaceID)
            }
    }
}

/// A short message at the bottom of the bar (a toast); goes away by itself or with a click.
struct HintToast: View {
    let text: String
    var action: (title: String, run: () -> Void)?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Image(systemName: "info.circle")
                    .textRole(.body)
                    .foregroundStyle(Palette.text2)
                Text(text)
                    .textRole(.footnote)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "xmark")
                    .textRole(.caption, weight: .semibold)
                    .foregroundStyle(Palette.text3)
            }
            // The button on a line of its own, so the text keeps the whole width of a narrow bar.
            if let action {
                Button { action.run(); dismiss() } label: { Text(action.title).frame(maxWidth: .infinity) }
                    .buttonStyle(.primarySmall)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous).strokeBorder(Palette.border, lineWidth: DS.Line.hairline))
        .elevation(.floating)
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: action == nil ? .combine : .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Actions the app delegate provides to the views (import, new space).
@MainActor enum SidebarActions {
    /// Edit the built-in browser's address (click on the address at the top of the bar).
    static var editAddress: (() -> Void)?
    static var importArc: (() -> Void)?
    static var importChrome: (() -> Void)?
    static var importSafari: (() -> Void)?
    static var newSpace: (() -> Void)?
    /// Every workspace side by side (Show All Workspaces).
    static var showOverview: (() -> Void)?
    static var showSetupTour: (() -> Void)?
    static var newIdea: (() -> Void)?
    /// Opens the icon set for a pin (id, title).
    static var chooseIcon: ((String, String) -> Void)?
    static var openDesign: (() -> Void)?
    static var openSettings: (() -> Void)?
    /// Asks for a name and adds a folder to the space.
    static var newFolder: ((String) -> Void)?
    static var openIdeas: (() -> Void)?
    static var exportIdeas: (() -> Void)?
    static var emailIdeas: (() -> Void)?
    static var openGuide: (() -> Void)?
}

/// Drag the bar's right edge to make it narrower or wider.
struct ResizeHandle: View {
    @ObservedObject var settings: Settings
    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering || startWidth != nil ? Palette.border : Palette.clearHit)
            .frame(width: hovering || startWidth != nil ? DS.Size.resizeLine : DS.Size.resizeGrip)
            .frame(maxHeight: .infinity)
            .padding(.vertical, DS.Space.xxxl)
            .contentShape(Rectangle().inset(by: -DS.Size.resizeLine))
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? settings.sidebarWidth
                        if startWidth == nil { startWidth = start }
                        let width = min(max(start + value.translation.width, Layout.widthRange.lowerBound), Layout.widthRange.upperBound)
                        settings.sidebarWidth = width.rounded()
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .help("Drag to resize the bar")
            .dsAnimation(DS.Motion.quick, value: hovering)
    }
}

/// The websites of the active space in a bar of their own, next to the main bar.
struct WebsiteDockView: View {
    @ObservedObject var apps: AppsModel
    @ObservedObject var browser: BrowserModel
    @ObservedObject var perms: PermissionsModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            BrowserSection(browser: browser, apps: apps, perms: perms, mode: .websites)
                .padding(.horizontal, DS.Space.edge)
                .padding(.vertical, DS.Space.m)
        }
    }
}

/// A new version is out (bottom of the bar): Update, Later, or read what's new.
struct UpdateCard: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if let release = updater.available {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "arrow.down.circle").textRole(.body).foregroundStyle(Palette.text2)
                    Text("Version \(release.version) is out").textRole(.bodyStrong).foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                switch updater.state {
                case .downloading:
                    HStack(spacing: DS.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Updating… proDOCKtivity restarts by itself.").textRole(.footnote).foregroundStyle(Palette.text2)
                    }
                case .failed(let message):
                    Text(message).textRole(.footnote).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DS.Space.xs) {
                        Button("Release Page") { NSWorkspace.shared.open(release.page) }.buttonStyle(.primarySmall).fixedSize()
                        Spacer(minLength: 0)
                        Button("Later") { updater.later() }.buttonStyle(.ghostSmall).fixedSize()
                    }
                case .idle:
                    // Fits the narrowest bar: Update on its own line, the quiet choices under it.
                    Button { updater.install() } label: { Text("Update").frame(maxWidth: .infinity) }
                        .buttonStyle(.primarySmall)
                    HStack(spacing: DS.Space.xs) {
                        Button("What's New") { NSWorkspace.shared.open(release.page) }.buttonStyle(.ghostSmall).fixedSize()
                        Spacer(minLength: 0)
                        Button("Later") { updater.later() }.buttonStyle(.ghostSmall).fixedSize()
                    }
                }
            }
            .card(padding: DS.Space.m)
            .padding(.bottom, DS.Space.xs)
            .transition(.appear)
        }
    }
}
