import AppKit
import ApplicationServices

/// One command in another app's menu bar, e.g. ["Spaces", "New Space…"].
struct MenuEntry: Identifiable, Hashable {
    let path: [String]
    let enabled: Bool
    var id: String { path.joined(separator: " › ") }
    var title: String { path.last ?? "" }
}

/// Reads and presses other apps' menu bar items through the Accessibility API.
/// Used to drive Arc features that its AppleScript dictionary doesn't expose.
@MainActor
enum MenuBar {
    /// All items (two levels deep below each top-level menu), optionally limited to one menu.
    static func entries(pid: pid_t, menu: String? = nil) -> [MenuEntry] {
        guard AXIsProcessTrusted(), let bar = element(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) else { return [] }
        var result: [MenuEntry] = []
        for top in children(bar) {
            guard let title = string(top, kAXTitleAttribute), !title.isEmpty, title != "Apple" else { continue }
            if let menu, title != menu { continue }
            collect(top, path: [title], depth: 0, into: &result)
        }
        return result
    }

    private static func collect(_ el: AXUIElement, path: [String], depth: Int, into result: inout [MenuEntry]) {
        // A menu bar item / menu item holds an AXMenu whose children are AXMenuItems.
        for menu in children(el) where string(menu, kAXRoleAttribute) == kAXMenuRole {
            for item in children(menu) {
                guard let title = string(item, kAXTitleAttribute), !title.isEmpty else { continue }
                let p = path + [title]
                let hasSubmenu = children(item).contains { string($0, kAXRoleAttribute) == kAXMenuRole }
                if hasSubmenu, depth < 1 {
                    collect(item, path: p, depth: depth + 1, into: &result)
                } else if !hasSubmenu {
                    let enabled = (value(item, kAXEnabledAttribute) as? Bool) ?? true
                    result.append(MenuEntry(path: p, enabled: enabled))
                }
            }
        }
    }

    /// Presses the item at `path`. Returns false if it wasn't found.
    @discardableResult
    static func press(pid: pid_t, path: [String]) -> Bool {
        guard AXIsProcessTrusted(), var current = element(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) else { return false }
        for (i, title) in path.enumerated() {
            let candidates = i == 0 ? children(current)
                : children(current).filter { string($0, kAXRoleAttribute) == kAXMenuRole }.flatMap(children)
            guard let next = candidates.first(where: { string($0, kAXTitleAttribute) == title }) else {
                Log.write("menu: '\(title)' not found in \(path)")
                return false
            }
            current = next
        }
        let err = AXUIElementPerformAction(current, kAXPressAction as CFString)
        Log.write("menu: pressed \(path) result=\(err.rawValue)")
        return err == .success
    }

    /// First enabled entry whose title contains all `keywords` (case-insensitive).
    static func find(pid: pid_t, keywords: [String], in menu: String? = nil) -> MenuEntry? {
        entries(pid: pid, menu: menu).first { entry in
            entry.enabled && keywords.allSatisfy { entry.title.localizedCaseInsensitiveContains($0) }
        }
    }

    // MARK: AX helpers

    private static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    private static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        value(el, attr) as? String
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        (value(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
