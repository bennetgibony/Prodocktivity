import AppKit

/// The app's main menu. proDOCKtivity runs without a Dock icon, so this menu is never shown,
/// but macOS still sends every ⌘-shortcut through it: without it ⌘C, ⌘V, ⌘A, ⌘Z … do nothing
/// in the browser and in text fields (DOCKlight). Edit items go to whatever has the focus
/// (page, text field); browser items go to the browser window in front (`BrowserWindow`).
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let app = submenu(in: main, "proDOCKtivity")
        app.addItem(withTitle: "Settings…", action: #selector(MenuActions.openSettings(_:)), keyEquivalent: ",").target = MenuActions.shared
        app.addItem(withTitle: "Hide proDOCKtivity", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")

        let file = submenu(in: main, "File")
        file.addItem(withTitle: "New Tab", action: #selector(BrowserWindow.newTab(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "New Incognito Tab", action: #selector(BrowserWindow.newIncognitoTab(_:)), keyEquivalent: "N")
        file.addItem(withTitle: "Open Location…", action: #selector(BrowserWindow.openLocation(_:)), keyEquivalent: "l")
        file.addItem(withTitle: "Close Tab", action: #selector(BrowserWindow.closeTab(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Reopen Closed Tab", action: #selector(BrowserWindow.reopenClosedTab(_:)), keyEquivalent: "T")

        let edit = submenu(in: main, "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Copy Page Address", action: #selector(BrowserWindow.copyPageAddress(_:)), keyEquivalent: "c")
            .keyEquivalentModifierMask = [.command, .option]
        // ⌘V pastes without formatting, ⇧⌘V with (macOS
        // ships it the other way round), set here so it doesn't depend on the system setting.
        edit.addItem(withTitle: "Paste and Match Style", action: #selector(MenuActions.pastePlain(_:)), keyEquivalent: "v")
            .target = MenuActions.shared
        let paste = edit.addItem(withTitle: "Paste", action: #selector(MenuActions.pasteFormatted(_:)), keyEquivalent: "v")
        paste.keyEquivalentModifierMask = [.command, .shift]
        paste.target = MenuActions.shared
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "").submenu = find
        findItem(find, "Find…", .showFindInterface, "f")
        findItem(find, "Find Next", .nextMatch, "g")
        findItem(find, "Find Previous", .previousMatch, "G")
        findItem(find, "Use Selection for Find", .setSearchString, "e")

        let view = submenu(in: main, "View")
        view.addItem(withTitle: "Reload Page", action: #selector(BrowserWindow.reloadPage(_:)), keyEquivalent: "r")
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: #selector(BrowserWindow.actualSize(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom In", action: #selector(BrowserWindow.zoomIn(_:)), keyEquivalent: "+")
        // ⌘= is the same key as ⌘+ without shift.
        let zoomIn = view.addItem(withTitle: "Zoom In", action: #selector(BrowserWindow.zoomIn(_:)), keyEquivalent: "=")
        zoomIn.isHidden = true
        view.addItem(withTitle: "Zoom Out", action: #selector(BrowserWindow.zoomOut(_:)), keyEquivalent: "-")

        let history = submenu(in: main, "History")
        history.addItem(withTitle: "Back", action: #selector(BrowserWindow.goBackPage(_:)), keyEquivalent: "[")
        history.addItem(withTitle: "Forward", action: #selector(BrowserWindow.goForwardPage(_:)), keyEquivalent: "]")

        let window = submenu(in: main, "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(.separator())
        window.addItem(withTitle: "Next Tab", action: #selector(BrowserWindow.nextTab(_:)), keyEquivalent: "\t")
            .keyEquivalentModifierMask = .control
        window.addItem(withTitle: "Previous Tab", action: #selector(BrowserWindow.previousTab(_:)), keyEquivalent: "\t")
            .keyEquivalentModifierMask = [.control, .shift]
        window.addItem(withTitle: "Next Tab", action: #selector(BrowserWindow.nextTab(_:)), keyEquivalent: "}").isHidden = true
        window.addItem(withTitle: "Previous Tab", action: #selector(BrowserWindow.previousTab(_:)), keyEquivalent: "{").isHidden = true
        for n in 1...9 {
            let item = window.addItem(withTitle: n == 9 ? "Last Tab" : "Tab \(n)", action: #selector(BrowserWindow.selectTabNumber(_:)),
                                      keyEquivalent: "\(n)")
            item.tag = n
            item.isHidden = true
        }
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private static func submenu(in main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }

    private static func findItem(_ menu: NSMenu, _ title: String, _ action: NSTextFinder.Action, _ key: String) {
        let item = menu.addItem(withTitle: title, action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: key)
        item.tag = action.rawValue
    }
}

/// Targets for app-wide menu items.
@MainActor final class MenuActions: NSObject {
    static let shared = MenuActions()
    @objc func openSettings(_ sender: Any?) { SidebarActions.openSettings?() }
    @objc func pastePlain(_ sender: Any?) { Paste.perform(plain: true) }
    @objc func pasteFormatted(_ sender: Any?) { Paste.perform(plain: false) }
}

/// ⌘V without formatting, ⇧⌘V with it, sent to whatever has the focus. Where only plain text
/// goes in (most fields), both do the same.
@MainActor enum Paste {
    static let plainAction = #selector(NSTextView.pasteAsPlainText(_:))
    static let formattedAction = #selector(NSText.paste(_:))

    /// The action for the chosen kind: plain if the focus takes it, else the normal paste.
    static func action(plain: Bool, accepts: (Selector) -> Bool) -> Selector {
        plain && accepts(plainAction) ? plainAction : formattedAction
    }

    @discardableResult
    static func perform(plain: Bool, to responder: NSResponder? = nil) -> Bool {
        let action = action(plain: plain) { NSApp.target(forAction: $0, to: responder, from: nil) != nil }
        return NSApp.sendAction(action, to: responder, from: nil)
    }
}

/// Edit shortcuts for our panels (DOCKlight, the bar) while another app is in front: there the
/// main menu isn't asked, so ⌘A, ⌘C, ⌘V, ⇧⌘V, ⌘X, ⌘Z and ⌘⇧Z go straight to the focused text field.
@MainActor
enum EditKeys {
    static func perform(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let action: Selector?
        switch (key, flags) {
        case ("a", .command): action = #selector(NSText.selectAll(_:))
        case ("c", .command): action = #selector(NSText.copy(_:))
        case ("v", .command): return Paste.perform(plain: true, to: window.firstResponder)
        case ("v", [.command, .shift]): return Paste.perform(plain: false, to: window.firstResponder)
        case ("x", .command): action = #selector(NSText.cut(_:))
        case ("z", .command): action = Selector(("undo:"))
        case ("z", [.command, .shift]): action = Selector(("redo:"))
        default: action = nil
        }
        guard let action, let responder = window.firstResponder else { return false }
        return NSApp.sendAction(action, to: responder, from: nil)
    }
}

/// The built-in browser's shortcuts, caught before any window or web page sees them. Menu key
/// equivalents alone fall short: they only reach the browser while its window has the focus
/// (not after a click into the bar), and the page swallows ⌃Tab. Matched by the typed character,
/// so they work with German and other keyboard layouts too.
@MainActor
enum BrowserKeys {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    private static func handle(_ event: NSEvent) -> Bool {
        // ⌘Y in the bar or the browser: reopen what was closed last (⌘Z stays the normal Undo).
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "y",
           NSApp.keyWindow is SidebarPanel || NSApp.keyWindow is BrowserWindow {
            if !Reopen.reopenLast() { NSSound.beep() }
            return true
        }
        guard Settings.shared.browserEngine == .builtIn else { return false }
        let window = NSApp.keyWindow
        let browserWindow = window as? BrowserWindow
        let inBar = window is SidebarPanel
        guard browserWindow != nil || inBar else { return false }
        let browser = WebBrowser.shared
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch (flags, event.keyCode) {
        case (.control, 48): browser.selectAdjacentTab(1); return true                  // ⌃Tab
        case ([.control, .shift], 48): browser.selectAdjacentTab(-1); return true      // ⌃⇧Tab
        case ([.command, .option], 124): browser.selectAdjacentTab(1); return true     // ⌘⌥→
        case ([.command, .option], 123): browser.selectAdjacentTab(-1); return true    // ⌘⌥←
        default: break
        }
        switch (flags, key) {
        case ([.command, .shift], "}"), ([.command, .shift], "]"):
            browser.selectAdjacentTab(1); return true
        case ([.command, .shift], "{"), ([.command, .shift], "["):
            browser.selectAdjacentTab(-1); return true
        case ([.command, .shift], "n"):
            browser.newIncognitoTab(); return true
        case ([.command, .shift], "t"):
            browser.reopenClosedTab(); return true
        case ([.command, .option], "c"):   // ⌘⌥C (⌘⇧C is often taken, e.g. by clipboard managers like Maccy)
            browser.copyAddress(of: browserWindow); return true
        case (.command, _) where key.count == 1 && ("1"..."9").contains(key):
            browser.selectTab(number: Int(key) ?? 1); return true
        default:
            break
        }
        if WebExtensionStore.performCommand(for: event) { return true }
        // From the bar: the rest of the browser's shortcuts act on the current tab.
        guard inBar else { return false }
        switch (flags, key) {
        case (.command, "t"): browser.onNewTab?(); return true
        case (.command, "w"):
            guard let tab = browser.activeTab else { return false }
            browser.close(tabID: tab.id); return true
        case (.command, "l"): browser.focusAddress?(); return true
        case (.command, "r"): browser.navigate(.reload); return true
        case (.command, "["): browser.navigate(.back); return true
        case (.command, "]"): browser.navigate(.forward); return true
        default: return false
        }
    }
}
