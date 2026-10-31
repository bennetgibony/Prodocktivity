import AppKit
import SwiftUI

/// Small window with the icon set, to choose an icon for one pin.
@MainActor
final class IconPickerWindow {
    private var window: NSWindow?

    func show(title: String, current: String?, onPick: @escaping (String?) -> Void) {
        let w = window ?? NSWindow(contentRect: NSRect(origin: .zero, size: DS.Size.iconPicker),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Icon for “\(title)”"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: IconPicker(current: current) { [weak w] key in
            onPick(key)
            w?.close()
        }.designRoot())
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
