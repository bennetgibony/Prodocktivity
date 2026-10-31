import AppKit

/// One side of a split view: an app, or a browser tab.
enum SplitTarget: Codable, Equatable {
    case app(bundleID: String)
    case tab(id: String, url: String, title: String)
}

/// A split view created with ⌥-click, kept as its own "tab" in the sidebar so it can be
/// brought back with one click (like Arc's split-view tabs).
struct SplitPair: Codable, Equatable, Identifiable {
    let id: UUID
    var left: SplitTarget
    var right: SplitTarget
}

@MainActor
final class SplitManager: ObservableObject {
    static let shared = SplitManager()
    @Published private(set) var pairs: [SplitPair] = [] {
        didSet { defaults.set(try? JSONEncoder().encode(pairs), forKey: "splitPairs") }
    }
    private let defaults: UserDefaults

    private weak var browser: BrowserModel?
    private static let maxPairs = 6

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "splitPairs"),
           let saved = try? JSONDecoder().decode([SplitPair].self, from: data) {
            pairs = saved
        }
    }

    func attach(browser: BrowserModel) { self.browser = browser }

    /// The thing currently in front, as a split side (Arc → its active tab).
    func currentTarget() -> SplitTarget? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(),
              let id = front.bundleIdentifier else { return nil }
        if let browser, id == browser.provider.bundleID,
           let tabID = browser.snapshot.activeTabID, let tab = browser.snapshot.tab(id: tabID) {
            return .tab(id: tab.id, url: tab.url, title: tab.title)
        }
        return .app(bundleID: id)
    }

    /// Records a new split, replacing an existing one with the same two sides.
    func record(left: SplitTarget, right: SplitTarget) {
        guard left != right else { return }
        pairs.removeAll { ($0.left == left && $0.right == right) || ($0.left == right && $0.right == left) }
        pairs.insert(SplitPair(id: UUID(), left: left, right: right), at: 0)
        if pairs.count > Self.maxPairs { pairs.removeLast(pairs.count - Self.maxPairs) }
    }

    /// Removes the split tab and gives both windows the full area again.
    func remove(_ pair: SplitPair) {
        pairs.removeAll { $0.id == pair.id }
        for target in [pair.left, pair.right] {
            if let pid = pid(of: target) { WindowManager.fillNow(pid: pid) }
        }
    }

    private func pid(of target: SplitTarget) -> pid_t? {
        switch target {
        case .app(let bundleID):
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
        case .tab:
            return browser?.provider.runningApp?.processIdentifier
        }
    }

    /// Brings both sides forward and arranges them left/right again.
    func restore(_ pair: SplitPair) {
        bringForward(pair.left) { [weak self] leftPID in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                MainActor.assumeIsolated {
                    self?.bringForward(pair.right) { rightPID in
                        guard let leftPID, let rightPID, leftPID != rightPID else { return }
                        WindowManager.split(left: leftPID, right: rightPID)
                    }
                }
            }
        }
    }

    private func bringForward(_ target: SplitTarget, then: @escaping (pid_t?) -> Void) {
        switch target {
        case .app(let bundleID):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { then(nil); return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
                let pid = app?.processIdentifier
                Task { @MainActor in then(pid) }
            }
        case .tab(let id, let url, let title):
            guard let browser else { then(nil); return }
            if browser.snapshot.tab(id: id) != nil {
                browser.select(BrowserItem(id: id, title: title, url: url, kind: .tab), spaceID: nil, arrange: false)
            } else {
                browser.openPinned(url: url)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { then(browser.provider.runningApp?.processIdentifier) }
            }
        }
    }
}
