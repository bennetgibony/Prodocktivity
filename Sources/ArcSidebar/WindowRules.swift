import AppKit
@preconcurrency import ApplicationServices
import SwiftUI

/// Where an app's windows go.
enum WindowPlacement: String, Codable, CaseIterable, Identifiable {
    case fill, right, left, center, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fill: return "Fill the space next to the bar"
        case .right: return "Right half"
        case .left: return "Left half"
        case .center: return "Small in the middle"
        case .none: return "Don't snap"
        }
    }
}

/// A per-app rule. `extraOnly`: the app's first window snaps as usual, only further windows
/// (like a new email in Mail) follow the rule.
struct WindowRule: Codable, Equatable {
    var placement: WindowPlacement
    var extraOnly = false
}

/// Per-app rules for windows, applied when an app is opened from the bar and whenever the
/// app opens a new window.
@MainActor
final class WindowRules: ObservableObject {
    static let shared = WindowRules()

    /// Built-in defaults; the user's own rules (including "fill") override them.
    static let defaults: [String: WindowRule] = [
        "com.apple.finder": WindowRule(placement: .none),
        "com.apple.Terminal": WindowRule(placement: .none),
        "com.apple.mail": WindowRule(placement: .right, extraOnly: true),
    ]

    @Published private(set) var custom: [String: WindowRule] {
        didSet {
            defaults.set(try? JSONEncoder().encode(custom), forKey: "windowRules")
            syncWatching()
        }
    }

    private var observers: [NSObjectProtocol] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        custom = defaults.data(forKey: "windowRules")
            .flatMap { try? JSONDecoder().decode([String: WindowRule].self, from: $0) } ?? [:]
    }

    func rule(for id: String) -> WindowRule { custom[id] ?? Self.defaults[id] ?? WindowRule(placement: .fill) }

    func setPlacement(_ placement: WindowPlacement, for id: String) {
        var r = rule(for: id)
        r.placement = placement
        if placement == .fill || placement == .none { r.extraOnly = false }
        custom[id] = r
    }

    /// Back to the built-in default (or "fill").
    func removeRule(for id: String) { custom[id] = nil }

    func setExtraOnly(_ on: Bool, for id: String) {
        var r = rule(for: id)
        r.extraOnly = on
        custom[id] = r
    }

    /// Starts watching apps that have a rule for new windows.
    func start() {
        WindowWatcher.shared.onNewWindow = { pid, window in
            DispatchQueue.main.async { MainActor.assumeIsolated { WindowRules.shared.newWindow(pid: pid, window: window) } }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WindowRules.shared.syncWatching() }
            })
        }
        syncWatching()
    }

    /// Hook for other features (freeze) that also want to see new windows of every app.
    var watchAllApps = false { didSet { syncWatching() } }

    func syncWatching() {
        guard AXIsProcessTrusted() else { return }
        let me = getpid()
        let pids = NSWorkspace.shared.runningApplications.compactMap { app -> pid_t? in
            guard app.activationPolicy == .regular, app.processIdentifier != me, let id = app.bundleIdentifier else { return nil }
            let all = watchAllApps || WindowManager.isContaining
            return all || rule(for: id).placement != .fill ? app.processIdentifier : nil
        }
        WindowWatcher.shared.watch(Set(pids))
    }

    /// What happens to a new window of an app with this rule.
    enum NewWindowAction: Equatable {
        /// Left where the app put it.
        case leave
        /// Snapped inside the frame (frame mode).
        case frame
        /// Placed by the rule; with `extraOnly`, only when the app has other windows
        /// (a first window then goes into the frame in frame mode).
        case place(WindowPlacement, extraOnly: Bool)
    }

    static func newWindowAction(rule r: WindowRule, framed: Bool) -> NewWindowAction {
        switch r.placement {
        case .none: return .leave
        case .fill: return framed ? .frame : .leave
        default: return .place(r.placement, extraOnly: r.extraOnly)
        }
    }

    private func newWindow(pid: pid_t, window: AXUIElement) {
        guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return }
        if Freeze.shared.placeNewWindow(pid: pid, bundleID: id, window: window) { return }
        // Frame mode: every new window snaps inside the frame, unless its app has its own rule.
        let framed = WindowManager.isContaining && pid != WindowManager.tuckPID()
        switch Self.newWindowAction(rule: rule(for: id), framed: framed) {
        case .leave:
            return
        case .frame:
            guard let rect = WindowManager.targetAXRect() else { return }
            WindowManager.place(window: window, rect: rect, onlyResizable: true)
            Log.write("frame: \(id) new window -> inside the frame")
        case .place(let placement, let extraOnly):
            guard let rect = rect(for: placement) else { return }
            // A first window (the app just opened) snaps as usual when the rule is for extra windows only.
            if extraOnly {
                WindowManager.whenOtherWindowsExist(pid: pid, besides: window) { WindowManager.place(window: window, rect: rect) }
                if framed, let fill = WindowManager.targetAXRect() {
                    WindowManager.whenNoOtherWindows(pid: pid, besides: window) {
                        WindowManager.place(window: window, rect: fill, onlyResizable: true)
                    }
                }
            } else {
                WindowManager.place(window: window, rect: rect)
            }
            Log.write("window rule: \(id) new window -> \(placement.rawValue)")
        }
    }

    /// Target rect (AX coordinates) for a placement.
    func rect(for placement: WindowPlacement) -> CGRect? {
        switch placement {
        case .fill: return WindowManager.targetAXRect()
        case .left: return WindowManager.splitRects()?.left
        case .right: return WindowManager.splitRects()?.right
        case .center: return WindowManager.targetAXRect().map(Self.centered)
        case .none: return nil
        }
    }

    /// "Small in the middle": 60 % × 72 % of the area, centered.
    static func centered(in full: CGRect) -> CGRect {
        let w = (full.width * 0.6).rounded(), h = (full.height * 0.72).rounded()
        return CGRect(x: full.midX - w / 2, y: full.midY - h / 2, width: w, height: h)
    }

    /// Places an app just opened from the bar, following its rule. Returns false if the
    /// caller should snap it the usual way.
    func placeOpenedApp(pid: pid_t, bundleID: String) -> Bool {
        switch Self.openedAppAction(rule: rule(for: bundleID), frozen: Freeze.shared.isFrozen(app: bundleID),
                                    freezeActive: Freeze.shared.isActive) {
        case .usual: return false
        case .leave: return true
        case .frozenHalf:
            guard let rect = Freeze.shared.frozenRect else { return false }
            WindowManager.fillNow(pid: pid, rect: rect)
            return true
        case .place(let placement):
            guard let rect = rect(for: placement) else { return false }
            WindowManager.fillNow(pid: pid, rect: rect)
            return true
        }
    }

    enum OpenedAppAction: Equatable {
        /// Snapped the usual way (fill, or the free half while something is frozen).
        case usual
        case leave
        /// The frozen app goes to its half.
        case frozenHalf
        case place(WindowPlacement)
    }

    /// The frozen app stays on its half; while frozen, everything else fills the free half.
    static func openedAppAction(rule r: WindowRule, frozen: Bool, freezeActive: Bool) -> OpenedAppAction {
        if frozen { return .frozenHalf }
        if r.placement == .none { return .leave }
        if freezeActive || r.extraOnly || r.placement == .fill { return .usual }
        return .place(r.placement)
    }
}

/// Watches apps for new windows via Accessibility, on a thread of its own so a busy app
/// never blocks the bar.
final class WindowWatcher: @unchecked Sendable {
    static let shared = WindowWatcher()

    /// Called on the watcher thread with the app and its new window.
    var onNewWindow: ((pid_t, AXUIElement) -> Void)?

    private var runLoop: CFRunLoop?
    private var observers: [pid_t: AXObserver] = [:]
    /// The apps that should be watched (only touched on the watcher thread).
    private var wanted: Set<pid_t> = []
    /// Apps that refused to be watched after a few tries: left alone until they quit
    /// (otherwise every app switch would start the retries over).
    private var unwatchable: Set<pid_t> = []

    private init() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            // A source that never fires keeps the run loop alive.
            let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), keepAlive, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "ArcSidebar.windowWatcher"
        thread.start()
        ready.wait()
    }

    private func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// Watches exactly these apps (adds new ones, drops the rest).
    func watch(_ pids: Set<pid_t>) {
        perform { [self] in
            wanted = pids
            unwatchable.formIntersection(pids)
            for pid in observers.keys where !pids.contains(pid) { remove(pid) }
            for pid in pids where observers[pid] == nil && !unwatchable.contains(pid) { add(pid) }
        }
    }

    private func add(_ pid: pid_t, attempt: Int = 0) {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            // Only real windows: no sheets, dialogs or panels.
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            if let subrole = subrole as? String, subrole != kAXStandardWindowSubrole { return }
            watcher.onNewWindow?(pid, element)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, refcon)
        guard result == .success else {
            // An app that's still starting can't be watched yet: try again shortly.
            if attempt < 5 {
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                    perform { [self] in if observers[pid] == nil, wanted.contains(pid) { add(pid, attempt: attempt + 1) } }
                }
            } else {
                unwatchable.insert(pid)
                Log.write("window watcher: pid \(pid) not watched (\(result.rawValue)); not trying again until it restarts")
            }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func remove(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}

/// "New windows" section for an app's right-click menu.
struct WindowRuleMenu: View {
    let appID: String
    @ObservedObject private var rules = WindowRules.shared

    var body: some View {
        let rule = rules.rule(for: appID)
        Menu("New Windows") {
            ForEach(WindowPlacement.allCases) { p in
                Toggle(p.label, isOn: Binding(get: { rule.placement == p }, set: { if $0 { rules.setPlacement(p, for: appID) } }))
            }
            if rule.placement != .fill, rule.placement != .none {
                Divider()
                Toggle("Only extra windows (e.g. a new email)", isOn: Binding(
                    get: { rule.extraOnly }, set: { rules.setExtraOnly($0, for: appID) }))
            }
        }
    }
}
