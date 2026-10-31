import AppKit

/// An invisible strip over the left edge of the browser's window. It catches the mouse there,
/// so Arc's hidden sidebar doesn't pop out when you move between Arc and this sidebar.
/// Arc's own sidebar then only appears on command (⌘S).
@MainActor
final class EdgeGuard {
    private let panel: NSPanel
    /// How far the strip reaches into the browser window (Arc's hover zone is a bit wider than a few points).
    private let reach: CGFloat = 18

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Above normal windows (Arc), below the sidebar, so the sidebar always stays clickable.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = NSColor(white: 0, alpha: 0.003)
        // Explicitly catch events even though the window is (nearly) transparent;
        // by default macOS lets them pass through transparent areas.
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
    }

    /// Places the strip over the left edge of `pid`'s main window, if it's on screen.
    func update(browserPID: pid_t?) {
        guard let browserPID, let frame = Self.mainWindowFrame(of: browserPID) else { hide(); return }
        let strip = NSRect(x: frame.minX - 4, y: frame.minY, width: reach + 4, height: frame.height)
        if panel.frame != strip { panel.setFrame(strip, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() { if panel.isVisible { panel.orderOut(nil) } }

    /// The largest normal on-screen window of the process, in Cocoa coordinates.
    static func mainWindowFrame(of pid: pid_t) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return nil }
        let frames: [NSRect] = list.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  width > 200, height > 200 else { return nil }
            // CG uses a top-left origin; Cocoa a bottom-left one.
            return NSRect(x: x, y: primary.frame.maxY - y - height, width: width, height: height)
        }
        return frames.max { $0.width * $0.height < $1.width * $1.height }
    }
}
