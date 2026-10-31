import AppKit

/// The screens as far as the bar cares: which ones there are, where they are and their usable
/// area (without the menu bar and the Dock).
struct ScreenLayout: Equatable {
    struct Screen: Equatable {
        let name: String
        let frame: CGRect
        let visibleFrame: CGRect
    }
    let screens: [Screen]

    @MainActor static var current: ScreenLayout {
        ScreenLayout(screens: NSScreen.screens.map { Screen(name: $0.localizedName, frame: $0.frame, visibleFrame: $0.visibleFrame) })
    }
}

/// Tells when the screens really changed (one plugged in or out, moved, another resolution, the
/// Dock or menu bar shown or hidden). macOS also reports "screen parameters changed" when only
/// the brightness changes: about 120 times while the display fades in after waking, and again
/// with every automatic brightness step. Each of those re-laid out the bar, the frame, the
/// docks and every window for nothing.
@MainActor
final class ScreenWatcher {
    static let shared = ScreenWatcher()
    /// Posted on the main queue after the screens changed.
    static let didChange = Notification.Name("proDOCKtivity.screenLayoutDidChange")

    private var filter = ScreenChangeFilter(last: ScreenLayout.current)
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let watcher = ScreenWatcher.shared
                guard watcher.filter.changed(to: ScreenLayout.current) else { return }
                NotificationCenter.default.post(name: ScreenWatcher.didChange, object: nil)
            }
        }
    }
}

/// Remembers the last layout and says whether a new one differs from it.
struct ScreenChangeFilter {
    private(set) var last: ScreenLayout

    init(last: ScreenLayout) { self.last = last }

    mutating func changed(to layout: ScreenLayout) -> Bool {
        guard layout != last else { return false }
        last = layout
        return true
    }
}
