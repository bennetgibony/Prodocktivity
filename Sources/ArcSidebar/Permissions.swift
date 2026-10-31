import AppKit
import ApplicationServices

@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var accessibility = AXIsProcessTrusted()
    private var timer: Timer?

    init() {
        schedule()
    }

    /// Accessibility has no change notification: checked often while it's missing (so the bar
    /// reacts as soon as it's allowed), rarely once it's there.
    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: accessibility ? 10 : 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = AXIsProcessTrusted()
                if now != self.accessibility {
                    self.accessibility = now
                    Log.write("accessibilityTrusted changed to \(now)")
                    self.schedule()
                }
            }
        }
        timer?.tolerance = 0.3
    }

    /// Shows the system "would like to control this computer" prompt (only appears once per build).
    func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        promptAccessibility()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openAutomationSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    private func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
