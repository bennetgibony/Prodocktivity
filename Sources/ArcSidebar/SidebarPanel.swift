import AppKit
import SwiftUI

/// Hosting view that reacts to the first click even while the panel isn't key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Lets views ask for keyboard focus (e.g. the New Tab field) without activating the app.
@MainActor enum PanelFocus {
    static var makeKey: (() -> Void)?
}

/// Borderless, non-activating floating panel pinned to the left screen edge.
final class SidebarPanel: NSPanel {
    @MainActor init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Layout.barWidth, height: 600),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        let host = FirstMouseHostingView(rootView: rootView.designRoot())
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ⌃-click freezes what's clicked (FreezeClick): passed on as a plain click, so it doesn't
    /// open the right-click menu.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .leftMouseUp {
            let flags = event.modifierFlags
            if flags.contains(.control), !flags.contains(.command),
               let plain = NSEvent.mouseEvent(with: event.type, location: event.locationInWindow,
                                              modifierFlags: flags.subtracting(.control), timestamp: event.timestamp,
                                              windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
                                              clickCount: event.clickCount, pressure: event.pressure) {
                if event.type == .leftMouseDown { MainActor.assumeIsolated { FreezeClick.arm() } }
                super.sendEvent(plain)
                return
            }
            if event.type == .leftMouseDown { MainActor.assumeIsolated { FreezeClick.disarm() } }
        }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        EditKeys.perform(event, in: self) || super.performKeyEquivalent(with: event)
    }

    /// A key typed while the bar has the focus but no field is being edited (it would only
    /// beep): it goes to the page in the built-in browser instead, if one is showing.
    override func noResponder(for eventSelector: Selector) {
        if eventSelector == #selector(NSResponder.keyDown(with:)), let event = NSApp.currentEvent,
           event.type == .keyDown, event.modifierFlags.intersection([.command, .control]).isEmpty,
           MainActor.assumeIsolated({ WebBrowser.shared.focusPage() }) {
            NSApp.keyWindow?.sendEvent(event)
            return
        }
        super.noResponder(for: eventSelector)
    }

    /// Frame on `screen` when shown.
    @MainActor static func shownFrame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        if Settings.shared.frameMode {
            // Frame mode, like Arc: the bar is part of the frame, one piece from the screen's
            // left edge (or the Dock) to the windows, menu bar to bottom. Same height as the backdrop,
            // so its color gradient and grain line up exactly; BarChrome pads the content.
            let top = Settings.shared.frameUnderMenuBar ? screen.frame.maxY : vf.maxY
            return NSRect(x: vf.minX, y: screen.frame.minY, width: Layout.barWidth, height: top - screen.frame.minY)
        }
        // Frame mode: no frame on an edge where another screen continues.
        let open = Layout.sharedEdges(of: screen)
        let left = open.contains(.minXEdge) ? 0 : Layout.inset
        let bottom = open.contains(.minYEdge) ? 0 : Layout.inset
        let top = open.contains(.maxYEdge) ? 0 : Layout.inset
        return NSRect(
            x: vf.minX + left,
            y: vf.minY + bottom,
            width: Layout.barWidth - left - Layout.windowGap,
            height: vf.height - bottom - top
        )
    }

    func show(on screen: NSScreen, animated: Bool) {
        let target = Self.shownFrame(on: screen)
        BarChrome.shared.update(for: screen)
        hasShadow = !Settings.shared.frameMode
        if !isVisible || alphaValue < 1 {
            setFrame(target.offsetBy(dx: -24, dy: 0), display: false)
            alphaValue = 0
            orderFrontRegardless()
        }
        guard animated else {
            setFrame(target, display: true)
            alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(target, display: true)
            animator().alphaValue = 1
        } completionHandler: { [weak self] in
            self?.invalidateShadow()
        }
    }

    func hide(animated: Bool) {
        guard animated else { orderOut(nil); return }
        let target = frame.offsetBy(dx: -24, dy: 0)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().setFrame(target, display: true)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.orderOut(nil)
        }
    }
}

/// How the bar is drawn: its own floating card, or (frame mode) one piece with the frame.
@MainActor final class BarChrome: ObservableObject {
    static let shared = BarChrome()
    /// Frame mode: padding that keeps the bar's content inside the frame (menu bar, Dock, edges).
    @Published private(set) var framed: EdgeInsets?
    /// Frame mode below the menu bar: the frame's top corners are rounded, like a window.
    @Published private(set) var roundTop = false

    func update(for screen: NSScreen) {
        guard Settings.shared.frameMode else { if framed != nil { framed = nil }; return }
        let f = screen.frame, vf = screen.visibleFrame
        let open = Layout.sharedEdges(of: screen)
        let insets = EdgeInsets(
            top: (Settings.shared.frameUnderMenuBar ? f.maxY - vf.maxY : 0) + (open.contains(.maxYEdge) ? 0 : Layout.inset),
            leading: open.contains(.minXEdge) ? 0 : Layout.inset,
            bottom: vf.minY - f.minY + (open.contains(.minYEdge) ? 0 : Layout.inset),
            trailing: Layout.windowGap)
        if framed != insets { framed = insets }
        let round = !Settings.shared.frameUnderMenuBar && f.maxY > vf.maxY
        if roundTop != round { roundTop = round }
    }
}
