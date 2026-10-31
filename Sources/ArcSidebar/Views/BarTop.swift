import AppKit
import SwiftUI

// The bar's top row: address field, back / forward / reload, extensions.

struct TopBar: View {
    @ObservedObject var apps: AppsModel
    @ObservedObject var browser: BrowserModel
    @ObservedObject private var placement = AddressPlacement.shared

    /// The address is in the menu bar: here only back / forward / reload, never the address twice.
    private var addressInMenuBar: Bool { browser.provider.isBuiltIn && placement.inMenuBar }

    @ObservedObject private var nav = BrowserNavState.shared
    @Environment(\.dsAccent) private var accent

    /// Another app (Claude, Mail …) is in front rather than the browser or the bar itself.
    private var appInFront: Bool {
        guard let id = apps.frontmostID else { return false }
        return id != browser.provider.bundleID && id != Bundle.main.bundleIdentifier
    }

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            // The address in the bar's top corner: type here (or ⌘L), Enter loads. While another app
            // is in front it shows that app, with an outline, instead of the browser's address.
            if appInFront {
                addressPill
            } else if addressInMenuBar {
                Spacer(minLength: 0)
            } else if browser.provider.isBuiltIn {
                BarAddressField(nav: nav)
            } else {
                addressPill
            }
            // Back / forward only when they can be used (built-in browser), reload always.
            HStack(spacing: 0) {
                if !browser.provider.isBuiltIn || nav.canGoBack { navButton("chevron.left", "Back (⌘[)", .back) }
                if !browser.provider.isBuiltIn || nav.canGoForward { navButton("chevron.right", "Forward (⌘])", .forward) }
                navButton("arrow.clockwise", "Reload (⌘R)", .reload)
                if browser.provider.isBuiltIn { ExtensionsMenu(tint: accent.color) }
            }
            .dsAnimation(DS.Motion.quick, value: nav.canGoBack)
            .dsAnimation(DS.Motion.quick, value: nav.canGoForward)
            .disabled(browser.status != .ok)
            .opacity(browser.status == .ok ? 1 : DS.Opacity.disabled)
        }
        .padding(.horizontal, DS.Space.edge)
        .padding(.top, DS.Space.m)
        .padding(.bottom, DS.Space.s)
    }

    /// What's in front: the site (click to type an address in the built-in browser), or the app with
    /// its icon on stripes, so it never reads as a web address.
    private var addressPill: some View {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
            return HStack(spacing: DS.Space.s) {
                if !appInFront, let host = activeHost {
                    FaviconView(host: host).frame(width: DS.Size.iconSmall, height: DS.Size.iconSmall)
                    Text(host).lineLimit(1)
                } else if let icon = frontIcon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: DS.Size.icon, height: DS.Size.icon)
                    Text(frontName).lineLimit(1)
                } else {
                    Image(systemName: "macwindow").textRole(.footnote)
                    Text(frontName).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .textRole(.body)
            .foregroundStyle(Palette.text)
            .padding(.horizontal, DS.Space.rowInset)
            .frame(height: DS.Size.control)
            .background {
                // An app in front: stripes, so it never reads as a web address.
                shape.fill(accent.color.opacity(DS.Opacity.accentTile))
                    .overlay { if appInFront { Hatch().fill(accent.color.opacity(DS.Opacity.hatch)).clipShape(shape) } }
            }
            .contentShape(Rectangle())
            .onTapGesture { if browser.provider.isBuiltIn { SidebarActions.editAddress?() } }
            .help(browser.provider.isBuiltIn ? "Click to type an address (⌘L)" : "What's in front right now")
    }

    private func navButton(_ symbol: String, _ help: String, _ action: NavigationAction) -> some View {
        IconButton(symbol: symbol, help: help, tint: accent.color) { browser.navigate(action) }
            .transition(.opacity)
    }

    private var activeHost: String? {
        guard apps.frontmostID == browser.provider.bundleID, let id = browser.snapshot.activeTabID else { return nil }
        return browser.snapshot.tab(id: id)?.host
    }

    /// The app in front, also when the bar doesn't list it (accessory apps, system dialogs).
    private var frontApp: NSRunningApplication? {
        guard let id = apps.frontmostID else { return nil }
        return apps.running.first(where: { $0.bundleIdentifier == id })
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }

    private var frontIcon: NSImage? { frontApp?.icon ?? apps.frontmostID.flatMap(AppIcons.icon(of:)) }

    private var frontName: String {
        frontApp?.localizedName ?? apps.frontmostID.flatMap(AppIcons.name(of:)) ?? "proDOCKtivity"
    }
}

/// The built-in browser's extensions with a toolbar button (uBlock, Zotero …), behind a puzzle piece.
struct ExtensionsMenu: View {
    var tint: Color = Palette.text2
    @ObservedObject private var store = WebExtensionStore.shared

    var body: some View {
        if !store.actions.isEmpty {
            Menu {
                ForEach(store.actions, id: \.id) { action in
                    Button { store.performAction(action.id) } label: {
                        if let icon = action.icon { Label { Text(action.name) } icon: { Image(nsImage: icon) } } else { Text(action.name) }
                    }
                }
            } label: {
                Image(systemName: "puzzlepiece.extension")
                    .textRole(.body)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: DS.Size.hitTarget, height: DS.Size.hitTarget)
            .foregroundStyle(tint)
            .tint(tint)
            .help("Extensions")
        }
    }
}

/// The built-in browser's address, editable right in the bar: shows the site, the full address
/// while typing; Enter loads it in the current tab, Esc gives up.
struct BarAddressField: View {
    @ObservedObject var nav: BrowserNavState
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dsAccent) private var accent

    var body: some View {
        HStack(spacing: DS.Space.s) {
            if !focused, let host = URL(string: nav.url)?.host {
                FaviconView(host: host).frame(width: DS.Size.iconSmall, height: DS.Size.iconSmall)
            } else {
                Image(systemName: "magnifyingglass").textRole(.footnote, weight: .semibold)
            }
            TextField("", text: $text, prompt: Text("Search or enter address").foregroundColor(Palette.text3))
                .textFieldStyle(.plain)
                .lineLimit(1)
                .focused($focused)
                .onSubmit(submit)
                .onExitCommand { focused = false; WebBrowser.shared.focusPage() }
        }
        .textRole(.body)
        .foregroundStyle(Palette.text)
        .padding(.horizontal, DS.Space.rowInset)
        .frame(height: DS.Size.control)
        // A quiet field on the bar; while typing, a card (the quick-capture look).
        .background {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
            if focused {
                shape.fill(Palette.surface).elevation(.card)
                    .overlay(shape.strokeBorder(accent.color, lineWidth: DS.Line.focus))
            } else {
                shape.fill(accent.color.opacity(DS.Opacity.accentTile))
            }
        }
        .dsAnimation(DS.Motion.quick, value: focused)
        .contentShape(Rectangle())
        .onTapGesture { beginEditing() }
        .help("Type an address or search (⌘L)")
        .onAppear { text = Self.site(nav.url) }
        .onChange(of: nav.url) { _, url in if !focused { text = Self.site(url) } }
        .onChange(of: nav.focusRequest) { _, _ in beginEditing() }
        .onChange(of: focused) { _, now in
            // A panel hands its first field the focus when it becomes key: only a click or ⌘L counts.
            if now, !requested, NSApp.currentEvent?.type != .leftMouseDown { focused = false; return }
            requested = false
            text = now ? nav.url : Self.site(nav.url)
            // The whole address selected, so typing replaces it (like ⌘L in any browser).
            if now { DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) } }
        }
    }

    @State private var requested = false

    private func beginEditing() {
        requested = true
        PanelFocus.makeKey?()
        DispatchQueue.main.async { focused = true }
    }

    private func submit() {
        let input = text.trimmingCharacters(in: .whitespaces)
        focused = false
        // The bar keeps the keyboard otherwise: typing into the page would only beep.
        defer { WebBrowser.shared.focusPage() }
        guard !input.isEmpty, let url = BrowserModel.url(fromInput: input) else { text = Self.site(nav.url); return }
        WebBrowser.shared.load(url: url)
    }

    /// The site only, like Arc: "linkedin.com".
    static func site(_ url: String) -> String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
