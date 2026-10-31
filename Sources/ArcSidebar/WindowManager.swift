import AppKit
@preconcurrency import ApplicationServices

/// Moves and resizes other apps' windows (via the Accessibility API) so they fill
/// the screen area to the right of the sidebar.
@MainActor
enum WindowManager {
    /// Screen the sidebar lives on; set by the app delegate.
    static var screen: () -> NSScreen? = { NSScreen.screens.first }
    /// Width currently claimed by the sidebar (0 while hidden).
    static var reservedWidth: () -> CGFloat = { Layout.reservedWidth }
    /// Width claimed at the right screen edge (the files dock there), 0 while hidden.
    static var rightReservedWidth: () -> CGFloat = { Layout.rightReservedWidth }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Browser whose own sidebar gets tucked behind ours: its window is shifted left by the
    /// width of its sidebar, so the page starts at our edge (set by the app delegate).
    static var tuckPID: () -> pid_t? = { nil }
    /// Width of the browser's own sidebar when it's shown, if known (from its saved state).
    static var tuckWidth: () -> CGFloat? = { nil }

    /// The frozen half, if something is frozen (set by Freeze); windows then fill the other half.
    static var freezeSide: () -> FreezeSide? = { nil }

    /// Where windows snap: the area next to the bar, or its free half while something is frozen.
    static func targetCocoaRect() -> CGRect? {
        guard let full = fullCocoaRect() else { return nil }
        guard let frozen = freezeSide() else { return full }
        return half(of: full, frozen.other)
    }

    private static func half(of full: CGRect, _ side: FreezeSide) -> CGRect {
        let halves = Geometry.halves(of: full, gap: Layout.windowGap)
        return side == .left ? halves.left : halves.right
    }

    /// One half of the area next to the bar (AX coordinates).
    static func halfRect(_ side: FreezeSide) -> CGRect? {
        guard let full = fullAXRect() else { return nil }
        return half(of: full, side)
    }

    /// The whole area next to the bar in AX coordinates.
    static func fullAXRect() -> CGRect? {
        guard let r = fullCocoaRect(), let primary = NSScreen.screens.first else { return nil }
        return CGRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// The whole area next to the bar in Cocoa coordinates (origin bottom-left of the primary screen).
    static func fullCocoaRect() -> CGRect? {
        guard let screen = screen() else { return nil }
        return Geometry.area(visibleFrame: screen.visibleFrame, left: reservedWidth(), rightDock: rightReservedWidth(),
                             gap: Layout.windowGap, openEdges: Layout.sharedEdges(of: screen))
    }

    /// The area inside the frame on a screen other than the bar's (Settings → Windows → frame on the other screens too).
    static func otherScreenCocoaRect(_ screen: NSScreen) -> CGRect {
        Geometry.framedArea(visibleFrame: screen.visibleFrame, gap: Layout.windowGap, openEdges: Layout.sharedEdges(of: screen))
    }

    /// Same rect converted to AX coordinates (origin top-left of the primary screen).
    static func targetAXRect() -> CGRect? {
        guard let r = targetCocoaRect(), let primary = NSScreen.screens.first else { return nil }
        return CGRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// Fit the focused window of `pid` once it has had a moment to activate, if enabled.
    static func fillIfEnabled(pid: pid_t) {
        guard Settings.shared.autoFitWindows, isTrusted else {
            Log.write("snap skipped pid=\(pid) autoFit=\(Settings.shared.autoFitWindows) trusted=\(isTrusted)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                guard let target = targetAXRect() else { return }
                fill(pid: pid, target: target, attempt: 0)
            }
        }
    }

    /// Fills `pid`'s window right away, regardless of the auto-snap setting.
    static func fillNow(pid: pid_t) {
        guard isTrusted, let target = targetAXRect() else { return }
        fill(pid: pid, target: target, attempt: 0)
    }

    /// `automatic`: a re-snap the user didn't ask for, so apps set to "Don't snap" (Finder, Terminal) stay put.
    static func fillFrontmost(automatic: Bool = false) {
        guard isTrusted, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid(), let target = targetAXRect() else { return }
        if automatic, let id = app.bundleIdentifier, WindowRules.shared.rule(for: id).placement == .none { return }
        fill(pid: app.processIdentifier, target: target, attempt: 0)
    }

    /// Fills `pid`'s window into a given rect (AX coordinates).
    static func fillNow(pid: pid_t, rect: CGRect) {
        guard isTrusted else { return }
        fill(pid: pid, target: rect, attempt: 0)
    }

    /// Left and right halves of the area next to the sidebar (AX coordinates).
    static func splitRects() -> (left: CGRect, right: CGRect)? {
        guard let full = fullAXRect() else { return nil }
        return Geometry.halves(of: full, gap: Layout.windowGap)
    }

    /// AX rect (origin top-left) → Cocoa rect (origin bottom-left).
    static func cocoaRect(fromAX r: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
    }

    /// Split screen: `left`'s focused window takes the left half of the area next to the
    /// sidebar, `right`'s the right half. Runs regardless of the auto-snap setting.
    static func split(left: pid_t, right: pid_t) {
        guard isTrusted, let full = targetAXRect() else {
            Log.write("split skipped trusted=\(isTrusted)")
            return
        }
        let (leftRect, rightRect) = Geometry.halves(of: full, gap: Layout.windowGap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                fill(pid: left, target: leftRect, attempt: 0)
                fill(pid: right, target: rightRect, attempt: 0)
            }
        }
    }

    // MARK: Frame mode

    /// Whether windows are kept inside the frame (frame mode with snapping on and the bar shown).
    static var isContaining: Bool { Settings.shared.frameMode && Settings.shared.autoFitWindows && reservedWidth() > 0 && isTrusted }

    /// Frame mode for this app's own windows (the built-in browser), which need no Accessibility.
    static var framesOwnWindows: Bool { Settings.shared.frameMode && Settings.shared.autoFitWindows && reservedWidth() > 0 }

    /// Bundle id of the frozen app, if an app is frozen (set by Freeze); it keeps its half.
    static var frozenAppID: () -> String? = { nil }

    /// Apps whose windows are left alone by frame mode: "Don't snap" apps, the frozen app,
    /// the tucked browser (its window reaches behind the bar on purpose) and this app.
    private static func containable(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular, app.processIdentifier != getpid(),
              app.processIdentifier != tuckPID(), let id = app.bundleIdentifier else { return false }
        return WindowRules.shared.rule(for: id).placement != .none && id != frozenAppID()
    }

    /// Frame mode: moves `pid`'s focused window inside the frame if it sticks out (over the bar,
    /// past the frame). Windows already inside, even small ones, stay as they are.
    static func containFrontmost() {
        guard isContaining, let app = NSWorkspace.shared.frontmostApplication, containable(app),
              let target = targetAXRect(), let screen = screen() else { return }
        let pid = app.processIdentifier
        let screenAX = axRect(fromCocoa: screen.frame)
        axQueue.asyncAfter(deadline: .now() + 0.2) {
            let el = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(el, 0.5)
            if let w = focusedWindow(of: el) { contain(w, in: target, screen: screenAX, pid: pid) }
        }
    }

    /// Frame mode: moves every app's windows on the bar's screen inside the frame (when frame
    /// mode is switched on, at launch, and when the frame or bar changes size).
    static func containAll() {
        guard isContaining, let target = targetAXRect(), let screen = screen() else { return }
        let screenAX = axRect(fromCocoa: screen.frame)
        let pids = NSWorkspace.shared.runningApplications.filter(containable).map(\.processIdentifier)
        axQueue.async {
            for pid in pids {
                let el = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(el, 0.3)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &value) == .success,
                      let windows = value as? [AXUIElement] else { continue }
                for w in windows where isStandard(w) && bool(w, "AXMinimized") != true {
                    contain(w, in: target, screen: screenAX, pid: pid)
                }
            }
        }
    }

    /// Full-screen and fixed-size windows are allowed to break out of the frame.
    nonisolated private static func contain(_ w: AXUIElement, in target: CGRect, screen: CGRect, pid: pid_t) {
        guard bool(w, "AXFullScreen") != true, let f = frame(of: w), f.intersects(screen),
              !approximatelyEqual(f, target) else { return }
        // Inside and clearly smaller stays; a window that nearly fills the frame (e.g. snapped
        // before the frame or the bar changed size) snaps to it exactly.
        let nearlyFills = abs(f.minX - target.minX) < 40 && abs(f.maxX - target.maxX) < 40
            && abs(f.minY - target.minY) < 40 && abs(f.maxY - target.maxY) < 40
        guard nearlyFills || !target.insetBy(dx: -2, dy: -2).contains(f) else { return }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(w, kAXSizeAttribute as CFString, &settable) == .success, settable.boolValue else { return }
        setFrame(w, target)
        Log.write("frame: pid=\(pid) window \(f) -> \(target)")
    }

    /// Cocoa rect (origin bottom-left) → AX rect (origin top-left).
    static func axRect(fromCocoa r: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
    }

    /// Posts a key press to an app (used for Arc's ⌘T). Needs Accessibility access.
    static func sendKey(_ key: CGKeyCode, flags: CGEventFlags, to pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.postToPid(pid)
        }
    }

    /// Accessibility calls run here, never on the main thread: an app that is still launching
    /// can take seconds to answer, which used to freeze the sidebar (and every click) meanwhile.
    nonisolated private static let axQueue = DispatchQueue(label: "ArcSidebar.windows", qos: .userInitiated)

    private static func fill(pid: pid_t, target: CGRect, attempt: Int) {
        // Our own window (the built-in browser) is moved directly: setting it through
        // Accessibility from the background queue crashes AppKit (it must be the main thread).
        if pid == getpid() {
            WebBrowser.shared.place(in: cocoaRect(fromAX: target))
            return
        }
        let tuckOffset: CGFloat?? = pid == tuckPID() ? .some(tuckWidth()) : .none
        axQueue.async { fillInBackground(pid: pid, target: target, attempt: attempt, tuckOffset: tuckOffset) }
    }

    /// `tuckOffset` is nil for normal apps, and the known sidebar width (or nil if unknown) for the tucked browser.
    nonisolated private static func fillInBackground(pid: pid_t, target: CGRect, attempt: Int, tuckOffset: CGFloat??) {
        let appElement = AXUIElementCreateApplication(pid)
        // Don't wait long for a busy app; the retry below asks again.
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        guard let window = focusedWindow(of: appElement) else {
            // The app may still be launching or opening its window; retry for ~2s.
            Log.write("snap pid=\(pid) attempt=\(attempt): no standard window found")
            if attempt < 10 {
                axQueue.asyncAfter(deadline: .now() + 0.2) {
                    fillInBackground(pid: pid, target: target, attempt: attempt + 1, tuckOffset: tuckOffset)
                }
            }
            return
        }
        if bool(window, "AXFullScreen") == true { Log.write("snap pid=\(pid): window is full screen"); return }
        var target = target
        if let known = tuckOffset, let offset = known ?? sidebarOffset(of: window) {
            // Keep the browser's sidebar showing (so it never "peeks"), but hidden behind ours.
            target.origin.x -= offset
            target.size.width += offset
        }
        // Already in place: don't touch it (no jump).
        if let current = frame(of: window), approximatelyEqual(current, target) { return }
        setFrame(window, target)
        Log.write("snap pid=\(pid) target=\(target) result=\(frame(of: window).map { "\($0)" } ?? "unknown")")
        // Some apps restore their own frame right after activation; check once more.
        axQueue.asyncAfter(deadline: .now() + 0.4) {
            if let f = frame(of: window), !approximatelyEqual(f, target) { setFrame(window, target) }
        }
    }

    /// Moves a specific window into `rect` (AX coordinates), e.g. a new window an app just opened.
    /// `onlyResizable`: leave fixed-size windows (settings panels, about boxes) where they are.
    static func place(window: AXUIElement, rect: CGRect, onlyResizable: Bool = false) {
        guard isTrusted else { return }
        // Give the app a moment to finish setting up the window (it may position it itself).
        axQueue.asyncAfter(deadline: .now() + 0.15) {
            if bool(window, "AXFullScreen") == true { return }
            if onlyResizable {
                var settable: DarwinBoolean = false
                guard AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success,
                      settable.boolValue else { return }
            }
            setFrame(window, rect)
            axQueue.asyncAfter(deadline: .now() + 0.4) {
                if let f = frame(of: window), !approximatelyEqual(f, rect) { setFrame(window, rect) }
            }
        }
    }

    /// Runs `action` only if `pid` has another standard window besides `window`.
    static func whenOtherWindowsExist(pid: pid_t, besides window: AXUIElement, _ action: @escaping @MainActor () -> Void) {
        axQueue.async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { return }
            let others = windows.filter { !CFEqual($0, window) && isStandard($0) && bool($0, "AXMinimized") != true }
            if !others.isEmpty { DispatchQueue.main.async { MainActor.assumeIsolated(action) } }
        }
    }

    /// Runs `action` only if `window` is `pid`'s only standard window.
    static func whenNoOtherWindows(pid: pid_t, besides window: AXUIElement, _ action: @escaping @MainActor () -> Void) {
        axQueue.async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { return }
            let others = windows.filter { !CFEqual($0, window) && isStandard($0) && bool($0, "AXMinimized") != true }
            if others.isEmpty { DispatchQueue.main.async { MainActor.assumeIsolated(action) } }
        }
    }

    /// Distance from the window's left edge to where the web page starts (the browser's own
    /// sidebar), or nil if there's no visible sidebar.
    nonisolated private static func sidebarOffset(of window: AXUIElement) -> CGFloat? {
        guard let windowFrame = frame(of: window), let web = findWebArea(window, depth: 0), let webFrame = frame(of: web) else { return nil }
        let offset = webFrame.minX - windowFrame.minX
        return offset > 40 ? offset : nil
    }

    nonisolated private static func findWebArea(_ el: AXUIElement, depth: Int) -> AXUIElement? {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        if (role as? String) == "AXWebArea" { return el }
        guard depth < 18 else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for child in children { if let hit = findWebArea(child, depth: depth + 1) { return hit } }
        return nil
    }

    nonisolated private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attr as CFString, &value) == .success, let value,
               CFGetTypeID(value) == AXUIElementGetTypeID() {
                let w = value as! AXUIElement
                if isStandard(w) { return w }
            }
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            return windows.first(where: isStandard)
        }
        return nil
    }

    nonisolated private static func isStandard(_ w: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &value) == .success,
              let subrole = value as? String else { return true }
        return subrole == kAXStandardWindowSubrole
    }

    nonisolated private static func bool(_ w: AXUIElement, _ attr: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, attr as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    nonisolated private static func frame(of w: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        // (Checked above: another app could answer with anything.)
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    nonisolated private static func setFrame(_ w: AXUIElement, _ r: CGRect) {
        var p = r.origin, s = r.size
        guard let pos = AXValueCreate(.cgPoint, &p), let size = AXValueCreate(.cgSize, &s) else { return }
        // Position, size, position: moving first lets the window grow; the second move
        // corrects apps that clamp their position while resizing.
        let e1 = AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
        let e2 = AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, size)
        let e3 = AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
        if e1 != .success || e2 != .success || e3 != .success {
            Log.write("snap: AX set errors position=\(e1.rawValue) size=\(e2.rawValue) position=\(e3.rawValue)")
        }
    }

    nonisolated private static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
}

/// The arithmetic behind snapping, kept apart from screens and windows so it can be tested.
enum Geometry {
    /// The area next to the bar on a screen's usable part: `left` is taken by the bar (and its
    /// docks), `rightDock` by a files dock on the right. Edges in `openEdges` continue onto
    /// another screen and get no frame gap.
    static func area(visibleFrame vf: CGRect, left: CGFloat, rightDock: CGFloat, gap: CGFloat,
                     openEdges: Set<CGRectEdge>) -> CGRect {
        let gap = left > 0 ? gap : 0
        // A dock on the right brings its own gap; otherwise the frame (none where a screen continues).
        let right = rightDock > 0 ? rightDock : (openEdges.contains(.maxXEdge) ? 0 : gap)
        let bottom = openEdges.contains(.minYEdge) ? 0 : gap
        let top = openEdges.contains(.maxYEdge) ? 0 : gap
        return CGRect(x: vf.minX + left, y: vf.minY + bottom,
                      width: max(0, vf.width - left - right), height: max(0, vf.height - bottom - top))
    }

    /// The area inside the frame on a screen without the bar: the frame all around, none where
    /// another screen continues.
    static func framedArea(visibleFrame vf: CGRect, gap: CGFloat, openEdges: Set<CGRectEdge>) -> CGRect {
        let left = openEdges.contains(.minXEdge) ? 0 : gap
        let right = openEdges.contains(.maxXEdge) ? 0 : gap
        let bottom = openEdges.contains(.minYEdge) ? 0 : gap
        let top = openEdges.contains(.maxYEdge) ? 0 : gap
        return CGRect(x: vf.minX + left, y: vf.minY + bottom,
                      width: max(0, vf.width - left - right), height: max(0, vf.height - bottom - top))
    }

    /// Left and right halves of `full` with `gap` between them (whole points).
    static func halves(of full: CGRect, gap: CGFloat) -> (left: CGRect, right: CGRect) {
        let w = ((full.width - gap) / 2).rounded(.down)
        return (CGRect(x: full.minX, y: full.minY, width: w, height: full.height),
                CGRect(x: full.maxX - w, y: full.minY, width: w, height: full.height))
    }

    /// Cocoa (origin bottom-left of the primary screen) ↔ Accessibility (origin top-left).
    static func flipped(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
