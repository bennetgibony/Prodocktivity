import AppKit
import SwiftUI

/// Frame mode's backdrop: a desktop-level window in the space's color that covers the bar's
/// screen below the menu bar, behind every app. Windows snap inside it with a thin gap, so the gaps read as one
/// proDOCKtivity frame around the bar and everything next to it. Clicks pass through to the
/// desktop (its icons stay on top).
///
/// A second, click-through copy (`cover`) lies above the windows and paints only the frame
/// strips, so other apps' window shadows can't darken the frame (they did at the bottom and
/// right). It draws the same pixels as the backdrop, so the two can't be told apart.
@MainActor
final class Backdrop {
    private let window: NSWindow
    private let cover: NSWindow
    private let model = BackdropModel()

    init(settings: Settings, apps: AppsModel, browser: BrowserModel) {
        let model = self.model
        func make(level: NSWindow.Level, cover: Bool) -> NSWindow {
            let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = level
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: BackdropView(model: model, settings: settings, apps: apps, browser: browser, cover: cover).designRoot())
            host.sizingOptions = []
            w.contentView = host
            return w
        }
        window = make(level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow))), cover: false)
        // Above normal windows, below the bar (like the edge guard).
        cover = make(level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1), cover: true)
    }

    /// Shows the backdrop on `screen` with the content area at `area` (Cocoa coordinates), or hides it.
    func update(screen: NSScreen?, area: CGRect?, visible: Bool) {
        guard visible, let screen, let area else {
            for w in [window, cover] where w.isVisible { w.orderOut(nil) }
            return
        }
        // Unless set to reach behind it, the menu bar stays separate: the backdrop starts below it.
        var frame = screen.frame
        if !Settings.shared.frameUnderMenuBar { frame.size.height = screen.visibleFrame.maxY - frame.minY }
        let round = frame.maxY < screen.frame.maxY
        if model.roundTop != round { model.roundTop = round }
        for w in [window, cover] where w.frame != frame { w.setFrame(frame, display: true) }
        // Window-local, top-left origin for SwiftUI.
        let local = CGRect(x: area.minX - frame.minX, y: frame.maxY - area.maxY,
                           width: area.width, height: area.height)
        if model.area != local { model.area = local }
        for w in [window, cover] where !w.isVisible { w.orderFrontRegardless() }
    }
}

@MainActor final class BackdropModel: ObservableObject {
    @Published var area: CGRect = .zero
    /// Below the menu bar the frame's top corners are rounded (the bar rounds its own corner).
    @Published var roundTop = false
}

/// The space's background over the whole screen, and a soft, empty "page" where windows go.
private struct BackdropView: View {
    @ObservedObject var model: BackdropModel
    @ObservedObject var settings: Settings
    @ObservedObject var apps: AppsModel
    @ObservedObject var browser: BrowserModel
    /// The copy above the windows: only the frame around the window area, nothing inside it.
    let cover: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Solid: the frame is the space's color itself (or the canvas), never glass.
            BarBackground()
            if !cover {
            // Shows only where no window covers it: the empty space next to the bar.
            RoundedRectangle(cornerRadius: Layout.windowCornerRadius, style: .continuous)
                .fill(Palette.idleOnFill)
                .overlay {
                    if let space = browser.activeSpace {
                        Text(space.title)
                            .textRole(.title2)
                            .foregroundStyle(Palette.text3)
                    }
                }
                .frame(width: model.area.width, height: model.area.height)
                .offset(x: model.area.minX, y: model.area.minY)
            }
        }
        .mask {
            // The cover leaves the window area open; both round the top corners below the menu bar.
            GeometryReader { geo in
                let r = model.roundTop ? Layout.frameCornerRadius : 0
                Path { p in
                    p.addPath(UnevenRoundedRectangle(topLeadingRadius: r, topTrailingRadius: r, style: .continuous)
                        .path(in: CGRect(origin: .zero, size: geo.size)))
                    // Rounded like a window, so the cover also paints the corners next to the window's
                    // own rounded corners, where its shadow would show as a dark square.
                    if cover {
                        p.addPath(RoundedRectangle(cornerRadius: Layout.windowCornerRadius, style: .circular).path(in: model.area))
                    }
                }
                .fill(style: FillStyle(eoFill: true))
            }
        }
        .ignoresSafeArea()
    }
}
