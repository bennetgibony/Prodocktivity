import AppKit
@preconcurrency import ApplicationServices
import SwiftUI

enum FreezeSide: String {
    case left, right
    var other: FreezeSide { self == .left ? .right : .left }
    var label: String { self == .left ? "Left" : "Right" }
}

/// Freeze: one app or built-in browser tab stays on one half of the screen; everything
/// opened after it goes to the other half, until it's released.
@MainActor
final class Freeze: ObservableObject {
    static let shared = Freeze()

    enum Item: Equatable {
        case app(String)
        /// A built-in browser tab (WebTab id).
        case tab(String)
    }

    @Published private(set) var item: Item?
    @Published private(set) var side: FreezeSide = .right

    weak var apps: AppsModel?

    private init() {
        WindowManager.freezeSide = { [weak self] in self?.item == nil ? nil : self?.side }
        WindowManager.frozenAppID = { [weak self] in
            if case .app(let id) = self?.item { return id }
            return nil
        }
        WebBrowser.shared.onFrozenTabGone = { [weak self] in self?.release() }
        // The frozen app quit: the freeze ends with it (otherwise every window keeps going to
        // half the screen, with nothing left to release it from).
        quitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let id, self.isFrozen(app: id) else { return }
                Log.write("freeze: \(id) quit")
                self.release()
                WindowManager.fillFrontmost(automatic: true)
            }
        }
    }

    private var quitObserver: NSObjectProtocol?

    var isActive: Bool { item != nil }
    func isFrozen(app id: String) -> Bool { item == .app(id) }
    func isFrozen(tab id: String?) -> Bool { id != nil && item == .tab(id!) }

    /// The frozen half (AX coordinates).
    var frozenRect: CGRect? { WindowManager.halfRect(side) }

    func freezeApp(_ id: String, side: FreezeSide) {
        release()
        item = .app(id)
        self.side = side
        started()
        // Opening places it on its half (see WindowRules.placeOpenedApp).
        apps?.open(id)
        Log.write("freeze app \(id) on the \(side.rawValue)")
    }

    /// Freezes the built-in browser tab `tabID`.
    func freezeTab(_ tabID: String, side: FreezeSide) {
        release()
        guard let rect = WindowManager.halfRect(side) else { return }
        item = .tab(tabID)
        self.side = side
        WebBrowser.shared.freeze(tabID: tabID, frame: WindowManager.cocoaRect(fromAX: rect))
        started()
        Log.write("freeze tab on the \(side.rawValue)")
    }

    /// Opens a website first (it may not have a tab yet), then freezes the tab it ends up in.
    func freezeSite(side: FreezeSide, open: () -> Void) {
        open()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                if let tab = WebBrowser.shared.activeTab { Freeze.shared.freezeTab(tab.id, side: side) }
            }
        }
    }

    func release() {
        guard let old = item else { return }
        item = nil
        if case .tab = old { WebBrowser.shared.unfreeze() }
        WindowRules.shared.watchAllApps = false
        Log.write("freeze released")
    }

    private func started() {
        // New windows of every app go to the other half from now on.
        WindowRules.shared.watchAllApps = true
        // The built-in browser's main window moves over right away.
        WebBrowser.shared.moveMainWindowToTarget()
    }

    /// While frozen, a new window of any app goes to the free half (unless its app never snaps).
    func placeNewWindow(pid: pid_t, bundleID: String, window: AXUIElement) -> Bool {
        guard isActive, let rect = WindowManager.halfRect(side.other) else { return false }
        if WindowRules.shared.rule(for: bundleID).placement == .none { return true }
        WindowManager.place(window: window, rect: rect)
        Log.write("freeze: new \(bundleID) window -> \(side.other.rawValue) half")
        return true
    }
}

/// ⌃-click in the bar: what's clicked opens frozen on the left half (or is released if it's
/// frozen already), instead of macOS's usual right-click menu (right-click still shows it).
/// The bar turns the click into a plain one and arms this; the open call that follows uses it up.
@MainActor
enum FreezeClick {
    private static var armedAt: Date?
    static func arm() { armedAt = Date() }
    static func disarm() { armedAt = nil }
    /// True once, right after a ⌃-click.
    static func consume() -> Bool {
        defer { armedAt = nil }
        guard let armedAt else { return false }
        return Date().timeIntervalSince(armedAt) < 1
    }
}

/// "Freeze on the Left/Right" or "Release Freeze" for a right-click menu.
struct FreezeMenu: View {
    enum Subject {
        case app(String)
        /// A website: its live tab id if known, and how to open it.
        case site(tabID: String?, open: () -> Void)
    }

    let subject: Subject
    @ObservedObject private var freeze = Freeze.shared

    private var frozen: Bool {
        switch subject {
        case .app(let id): return freeze.isFrozen(app: id)
        case .site(let tabID, _): return freeze.isFrozen(tab: tabID)
        }
    }

    var body: some View {
        if frozen {
            Button("Release Freeze") { freeze.release() }
        } else {
            ForEach([FreezeSide.left, .right], id: \.rawValue) { side in
                Button("Freeze on the \(side.label)") { apply(side) }
            }
        }
    }

    private func apply(_ side: FreezeSide) {
        switch subject {
        case .app(let id): freeze.freezeApp(id, side: side)
        case .site(let tabID, let open):
            if let tabID, WebBrowser.shared.tabs.contains(where: { $0.id == tabID }) {
                freeze.freezeTab(tabID, side: side)
            } else {
                freeze.freezeSite(side: side, open: open)
            }
        }
    }
}

/// Small snowflake shown on a frozen row or tile.
struct FrozenBadge: View {
    var body: some View {
        Image(systemName: "snowflake")
            .textRole(.caption, weight: .semibold)
            .foregroundStyle(Palette.text2)
            .frame(width: DS.Size.badge + DS.Space.xs, height: DS.Size.badge + DS.Space.xs)
            .background(Circle().fill(Palette.surface))
            .overlay(Circle().strokeBorder(Palette.border, lineWidth: DS.Line.hairline))
            .help("Frozen on one half: ⌃-click or right-click → Release Freeze")
    }
}
