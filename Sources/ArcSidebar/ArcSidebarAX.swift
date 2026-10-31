import AppKit
import ApplicationServices

/// Drives Arc's own sidebar through Accessibility for things neither its AppleScript nor its
/// menu bar offer (adding/removing favorites): finds the tab's item in Arc's sidebar, opens
/// its context menu and presses the matching command. Best effort; logs what it finds.
@MainActor
enum ArcSidebarAX {
    /// Opens the context menu of the sidebar item titled `itemTitle` and presses the first item
    /// whose title contains every word of one of the `keywordSets`. Returns false if anything
    /// along the way is missing.
    static func pressContextItem(pid: pid_t, itemTitle: String, keywordSets: [[String]]) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else {
            Log.write("arcAX: no window"); return false
        }
        guard let target = find(in: window, depth: 0, where: { el in
            let names = [string(el, kAXTitleAttribute), string(el, kAXDescriptionAttribute), string(el, kAXValueAttribute)]
            return names.contains { $0 == itemTitle }
        }) else {
            Log.write("arcAX: sidebar item '\(itemTitle)' not found"); return false
        }
        let err = AXUIElementPerformAction(target, kAXShowMenuAction as CFString)
        guard err == .success else { Log.write("arcAX: show menu failed \(err.rawValue)"); return false }

        // The context menu shows up as an AXMenu somewhere under the app.
        var menuItem: AXUIElement?
        var seen: [String] = []
        for _ in 0..<10 where menuItem == nil {
            usleep(50_000)
            menuItem = find(in: app, depth: 0, maxDepth: 6, where: { el in
                guard string(el, kAXRoleAttribute) == kAXMenuItemRole, let t = string(el, kAXTitleAttribute) else { return false }
                if !seen.contains(t) { seen.append(t) }
                return keywordSets.contains { set in set.allSatisfy { t.localizedCaseInsensitiveContains($0) } }
            })
        }
        guard let menuItem else {
            Log.write("arcAX: no menu item \(keywordSets) among \(seen.prefix(40))")
            WindowManager.sendKey(53 /* esc */, flags: [], to: pid)
            return false
        }
        let pressed = AXUIElementPerformAction(menuItem, kAXPressAction as CFString) == .success
        Log.write("arcAX: pressed '\(string(menuItem, kAXTitleAttribute) ?? "?")' = \(pressed)")
        return pressed
    }

    private static func find(in el: AXUIElement, depth: Int, maxDepth: Int = 25,
                             where match: (AXUIElement) -> Bool) -> AXUIElement? {
        // Never look inside web pages; only Arc's own sidebar and chrome.
        if string(el, kAXRoleAttribute) == "AXWebArea" { return nil }
        if match(el) { return el }
        guard depth < maxDepth else { return nil }
        for child in children(el) {
            if let hit = find(in: child, depth: depth + 1, maxDepth: maxDepth, where: match) { return hit }
        }
        return nil
    }

    private static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    private static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? { value(el, attr) as? String }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        (value(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
