import AppKit
@preconcurrency import ApplicationServices
import SwiftUI

/// Notification counts: apps' badges as the Dock shows them (e.g. Slack), read from the Dock
/// via Accessibility every few seconds, and counts in website titles (e.g. Gmail's "(3)").
@MainActor
final class Badges: ObservableObject {
    static let shared = Badges()

    /// Bundle id → badge text (a number or "•").
    @Published private(set) var apps: [String: String] = [:]

    private var timer: Timer?
    /// Off while the bar is hidden: nobody sees the dots, so the Dock isn't read.
    var isActive = true { didSet { if isActive && !oldValue { refresh() } } }
    private let queue = DispatchQueue(label: "ArcSidebar.badges", qos: .utility)

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            MainActor.assumeIsolated { Badges.shared.refresh() }
        }
        timer?.tolerance = 0.5
    }

    private func refresh() {
        guard isActive, AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let pid = dock.processIdentifier
        queue.async {
            let found = Self.readDock(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard found != Badges.shared.apps else { return }
                    Badges.shared.apps = found
                    Log.write("badges: \(found.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
                }
            }
        }
    }

    /// The Dock's items carry their badge as "AXStatusLabel".
    nonisolated private static func readDock(pid: pid_t) -> [String: String] {
        let dock = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(dock, 0.5)
        var result: [String: String] = [:]
        for list in children(dock) where role(list) == "AXList" {
            for item in children(list) {
                guard let label = string(item, "AXStatusLabel"), !label.isEmpty,
                      let url = value(item, "AXURL") as? URL ?? (value(item, "AXURL") as? NSURL).map({ $0 as URL }),
                      let id = bundleID(of: url) else { continue }
                result[id] = label
            }
        }
        return result
    }

    /// App bundle → its id; apps don't change their id, so each is read once.
    nonisolated(unsafe) private static var bundleIDs: [URL: String] = [:]
    nonisolated private static func bundleID(of url: URL) -> String? {
        if let id = bundleIDs[url] { return id }
        let id = Bundle(url: url)?.bundleIdentifier
        bundleIDs[url] = id
        return id
    }

    nonisolated private static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }
    nonisolated private static func children(_ el: AXUIElement) -> [AXUIElement] {
        value(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    nonisolated private static func role(_ el: AXUIElement) -> String? { value(el, kAXRoleAttribute) as? String }
    nonisolated private static func string(_ el: AXUIElement, _ attr: String) -> String? { value(el, attr) as? String }

    /// A count in a page title: "(3) Gmail", "Inbox (12) – …".
    nonisolated static func count(inTitle title: String) -> String? {
        guard let r = title.range(of: #"\((\d{1,4}\+?)\)"#, options: .regularExpression) else { return nil }
        let n = title[r].dropFirst().dropLast()
        return n == "0" ? nil : String(n)
    }
}

/// The red notification dot on an icon.
struct NotificationDot: View {
    let text: String

    var body: some View {
        Circle()
            .fill(Palette.danger)
            .frame(width: DS.Size.dot, height: DS.Size.dot)
            .overlay(Circle().strokeBorder(Palette.surface, lineWidth: DS.Line.hairline))
            .help(text == "•" || text.isEmpty ? "New notifications" : "\(text) new")
    }
}

extension View {
    /// Puts a notification dot on the top-right of an icon when `text` is set.
    func notificationDot(_ text: String?, size: CGFloat = 0) -> some View {
        overlay(alignment: .topTrailing) {
            if let text { NotificationDot(text: text).offset(x: DS.Space.xs + size * DS.Size.badgeInset, y: -DS.Space.xs - size * DS.Size.badgeInset) }
        }
    }
}
