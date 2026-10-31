import AppKit
@preconcurrency import ApplicationServices
import Combine

/// The built-in browser's address in the menu bar, right after the front app's menus (it floats
/// over the empty menu bar), while the frame reaches up behind the menu bar and there's room.
/// Shows the current site; click or ⌘L to type, Enter loads.
@MainActor
final class MenuBarAddress: NSObject, NSTextFieldDelegate {
    private let panel: NSPanel
    private let field = AddressField()
    private let pill = NSView()
    private var observers: [NSObjectProtocol] = []
    private var settingsSink: AnyCancellable?
    private var timer: Timer?
    /// Where the menus of the app owning the menu bar end (screen x), measured off the main thread.
    private var menusEnd: CGFloat?
    /// The screen the bar is on.
    var screen: () -> NSScreen? = { NSScreen.screens.first }

    private static let preferredWidth: CGFloat = 340
    private static let minimumWidth: CGFloat = 180
    nonisolated private static let axQueue = DispatchQueue(label: "ArcSidebar.menuAddress", qos: .userInitiated)

    override init() {
        panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        field.delegate = self
        field.target = self
        field.action = #selector(submit(_:))
        field.onFocus = { [weak self] in
            guard let self, !self.editing else { return }
            self.editing = true
            self.field.stringValue = self.shownURL
        }
        // Quiet like the menu titles; a soft box only while typing.
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 6
        field.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        pill.addSubview(field)
        panel.contentView = pill

        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.remeasure() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: ScreenWatcher.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.remeasure() }
        })
        let s = Settings.shared
        settingsSink = Publishers.CombineLatest4(s.$menuBarAddress, s.$browserEngine, s.$frameUnderMenuBar, s.$frameMode)
            .dropFirst().sink { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.remeasure() } }
            }
        remeasure()
    }

    /// The address follows the current tab once a second, only while it's switched on.
    private func updateTimer() {
        if enabled, timer == nil {
            let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.refreshText() }
            }
            t.tolerance = 0.3
            timer = t
        } else if !enabled {
            timer?.invalidate()
            timer = nil
        }
    }

    private var enabled: Bool { Settings.shared.menuBarAddress && Settings.shared.browserEngine == .builtIn }

    /// Measures the menus again (an app's menus appear a moment after it's activated).
    func remeasure() {
        updateTimer()
        guard enabled else { layout(); return }
        let pid = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier
        for delay in [0.05, 0.6] {
            Self.axQueue.asyncAfter(deadline: .now() + delay) {
                let end = pid.flatMap(Self.menusEnd(pid:))
                DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
                    self?.menusEnd = end
                    self?.layout()
                } }
            }
        }
    }

    /// Right edge of the last menu title of `pid` (e.g. "Help"), in screen coordinates.
    nonisolated private static func menusEnd(pid: pid_t) -> CGFloat? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
              let items = kids as? [AXUIElement] else { return nil }
        var maxX: CGFloat = 0
        for item in items {
            var pos: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &pos) == .success,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success,
                  let pos, let size,
                  CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { continue }
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(pos as! AXValue, .cgPoint, &p)
            AXValueGetValue(size as! AXValue, .cgSize, &s)
            maxX = max(maxX, p.x + s.width)
        }
        return maxX > 0 ? maxX : nil
    }

    /// Free stretch of the menu bar between the menus and the notch or the status icons (Cocoa coordinates).
    private func freeSlot(on screen: NSScreen) -> CGRect? {
        // The menus were measured on one screen's menu bar; every menu bar shows them at the same
        // distance from its left edge.
        guard let menusEnd, let measured = NSScreen.screens.first(where: { $0.frame.minX < menusEnd && menusEnd <= $0.frame.maxX })
        else { return nil }
        let notch = screen.auxiliaryTopLeftArea.flatMap { $0.width < screen.frame.width ? $0.maxX : nil }
        return Self.slot(screen: screen.frame, visibleMaxY: screen.visibleFrame.maxY, menusWidth: menusEnd - measured.frame.minX,
                         notchLeftEnd: notch, statusIconsMinX: Self.statusIconsMinX(screen: screen))
    }

    /// The field's place on a menu bar: after the menus (`menusWidth` from the screen's left
    /// edge), before the notch and the status icons; nil when the menu bar is hidden or too full.
    static func slot(screen f: CGRect, visibleMaxY: CGFloat, menusWidth: CGFloat,
                     notchLeftEnd: CGFloat?, statusIconsMinX: CGFloat?) -> CGRect? {
        let barHeight = f.maxY - visibleMaxY
        guard barHeight > 10 else { return nil }  // menu bar hidden
        let start = f.minX + menusWidth + 14
        var end = f.maxX - 16
        if let notchLeftEnd { end = min(end, notchLeftEnd - 10) }
        if let statusIconsMinX { end = min(end, statusIconsMinX - 14) }
        let width = min(preferredWidth, end - start)
        guard width >= minimumWidth else { return nil }
        let h = min(24, barHeight - 6)
        return CGRect(x: start, y: f.maxY - barHeight + (barHeight - h) / 2, width: width, height: h)
    }

    /// Left edge of the status icons (battery, Wi-Fi, clock…) on `screen`'s menu bar.
    private static func statusIconsMinX(screen: NSScreen) -> CGFloat? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return nil }
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        let topY = primary.frame.maxY - screen.frame.maxY  // CG y of this screen's top
        let xs: [CGFloat] = list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == statusLayer,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], width < 400,
                  abs(y - topY) < 4, x >= screen.frame.minX, x < screen.frame.maxX else { return nil }
            return x
        }
        return xs.min()
    }

    /// Floats the field after the menus. With no room (or the frame below the menu bar), the
    /// address is in the bar instead (`AddressPlacement`), never in two places.
    private func layout() {
        let inline = Settings.shared.frameMode && Settings.shared.frameUnderMenuBar
        guard enabled, inline, let screen = screen(), let slot = freeSlot(on: screen) else {
            if !editing { panel.orderOut(nil) }
            AddressPlacement.shared.set(inMenuBar: false)
            return
        }
        place(slot)
        AddressPlacement.shared.set(inMenuBar: true)
        refreshText(force: true)
    }

    private func place(_ frame: CGRect) {
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        // The field at its natural height, centered vertically.
        let h = field.intrinsicContentSize.height
        field.frame = NSRect(x: 6, y: ((frame.height - h) / 2).rounded(), width: frame.width - 12, height: h)
        if !panel.isVisible { panel.orderFrontRegardless() }
        // Not in edit mode until clicked (a panel otherwise hands its field the focus right away).
        if !editing, !panel.isKeyWindow { panel.makeFirstResponder(nil) }
    }

    private var shownURL = ""
    private var editing = false { didSet { pill.layer?.backgroundColor = (editing ? MenuBarStyle.editingFill : .clear).cgColor } }

    private func refreshText(force: Bool = false) {
        guard enabled || force else { return }
        let url = WebBrowser.shared.activeTab?.url ?? ""
        guard force || url != shownURL else { return }
        shownURL = url
        // (A field is "first responder" in its panel even when nobody types: only real edits count.)
        if !editing { field.stringValue = Self.site(url) }
    }

    /// The site only, like Arc: "career.quantum-systems.com".
    static func site(_ url: String) -> String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// ⌘L: jump into the field, showing the full address.
    func focus() {
        panel.makeKey()
        panel.makeFirstResponder(field)
        editing = true
        field.stringValue = shownURL
        field.currentEditor()?.selectAll(nil)
    }

    var isShown: Bool { AddressPlacement.shared.inMenuBar && panel.isVisible }

    @objc private func submit(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let url = BrowserModel.url(fromInput: text) else { return }
        WebBrowser.shared.load(url: url)
        shownURL = ""
        sender.window?.makeFirstResponder(nil)
        editing = false
        refreshText()
        Log.write("menu bar address: load \(URL(string: url)?.host ?? "?")")
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            control.window?.makeFirstResponder(nil)
            editing = false
            refreshText(force: true)
            return true
        }
        return false
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        // Show the full address while editing.
        editing = true
        (obj.object as? NSTextField)?.stringValue = shownURL
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        editing = false
        refreshText(force: true)
        layout()
    }
}

/// A borderless panel that can still take typing.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Address field that fits the menu bar (the panel draws the rounded pill around it).
private final class AddressField: NSTextField {
    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        // Same font and color as the menu titles next to it.
        font = .menuBarFont(ofSize: 0)
        textColor = MenuBarStyle.textColor
        placeholderString = "Search or enter address"
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        alignment = .left
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var onFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        onFocus?()
        super.mouseDown(with: event)
    }
}

/// Where the browser's address is shown right now: in the menu bar, or at the top of the bar.
@MainActor final class AddressPlacement: ObservableObject {
    static let shared = AddressPlacement()
    @Published private(set) var inMenuBar = false
    func set(inMenuBar value: Bool) { if inMenuBar != value { inMenuBar = value } }
}
