import AppKit

/// ⌘Y brings back what was closed last, newest first: a tab (⌘W, the × on a row, also in Arc/Chrome),
/// an app that quit, or a deleted workspace/profile. ⌘Y while the bar or the built-in browser has the
/// focus, ⌃⌥Y anywhere. ⌘Z is always the normal Undo.
@MainActor
enum Reopen {
    enum Entry: Equatable {
        case tab(spaceID: String?, url: String, title: String)
        case app(String)
        /// Something deleted that can come back (a workspace, a profile); the action is kept below.
        case undo(String)
    }

    private static var undoActions: [String: () -> Void] = [:]

    /// Registers how to bring back something just deleted; ⌘Y (or the toast's Undo) runs it.
    @discardableResult
    static func undoable(_ action: @escaping () -> Void) -> String {
        let id = UUID().uuidString
        undoActions[id] = action
        closed(.undo(id))
        return id
    }

    /// Runs an undo now (the toast's Undo button); false if it already ran.
    @discardableResult
    static func undo(_ id: String) -> Bool {
        guard let action = undoActions.removeValue(forKey: id) else { return false }
        forget(.undo(id))
        action()
        return true
    }

    static let kept = 25
    private(set) static var entries: [Entry] = []
    /// Opens a closed tab again (set by the app delegate: built-in browser or Arc/Chrome).
    static var openTab: ((Entry) -> Void)?

    static func closed(_ entry: Entry) {
        if case .tab(_, let url, _) = entry, url.isEmpty || url == "about:blank" { return }
        entries.removeAll { $0 == entry }
        entries.append(entry)
        if entries.count > kept {
            for case .undo(let id) in entries.prefix(entries.count - kept) { undoActions[id] = nil }
            entries.removeFirst(entries.count - kept)
        }
    }

    /// Something came back another way (⌘⇧T): not offered again.
    static func forget(_ entry: Entry) { entries.removeAll { $0 == entry } }

    /// Reopens the newest entry; false when there's nothing to bring back.
    @discardableResult
    static func reopenLast() -> Bool {
        guard let last = entries.popLast() else { return false }
        switch last {
        case .tab: openTab?(last)
        case .undo(let id):
            guard let action = undoActions.removeValue(forKey: id) else { return reopenLast() }
            action()
        case .app(let id):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return reopenLast() }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
        Log.write("reopen: \(last)")
        return true
    }
}
