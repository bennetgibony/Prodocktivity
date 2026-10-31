import AppKit
import SwiftUI

/// Ideas and wishes for proDOCKtivity, jotted down with a shortcut and kept in a plain
/// text file that's easy to open, export or email.
@MainActor
final class IdeasModel: ObservableObject {
    static let defaultRecipient = "prodocktivity@bennet-gibony.com"

    let fileURL = AppPaths.file("proDOCKtivity Ideas.txt")

    @Published var recipient: String {
        didSet { UserDefaults.standard.set(recipient, forKey: "ideas.recipient") }
    }
    @Published private(set) var count = 0
    /// Ask for feedback every N days (0 = never).
    @Published var askEveryDays: Int { didSet { UserDefaults.standard.set(askEveryDays, forKey: "ideas.askEveryDays") } }
    private var lastAsked: Date {
        get { UserDefaults.standard.object(forKey: "ideas.lastAsked") as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "ideas.lastAsked") }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "ideas.recipient")
        recipient = saved ?? Self.defaultRecipient
        askEveryDays = UserDefaults.standard.object(forKey: "ideas.askEveryDays") as? Int ?? 3
        count = entries().count
        // Don't ask right after installing; start counting from today.
        if UserDefaults.standard.object(forKey: "ideas.lastAsked") == nil { lastAsked = Date() }
    }

    /// True when it's time for the gentle "anything to improve?" check-in.
    var isCheckInDue: Bool {
        askEveryDays > 0 && Date().timeIntervalSince(lastAsked) >= Double(askEveryDays) * 86_400
    }

    func markAsked() { lastAsked = Date() }

    /// What's typed in the note window and not saved yet, kept on every change so closing the
    /// window or quitting never loses it.
    var draft: String {
        get { UserDefaults.standard.string(forKey: "ideas.draft") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "ideas.draft") }
    }

    /// Appends one idea with date and time. False if it couldn't be written.
    @discardableResult
    func add(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let stamp = Formats.stamp(Date())
        let entry = "• \(stamp)\n\(trimmed)\n\n"
        // (The throwing calls: the old write(_:) ends the whole app on a disk error.)
        var ok = true
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(entry.utf8))
            } catch {
                Log.write("ideas: couldn't save (\(error))")
                ok = false
            }
            try? handle.close()
        } else {
            let header = "proDOCKtivity — ideas & wishes\n\n"
            do {
                try (header + entry).write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                Log.write("ideas: couldn't save (\(error))")
                ok = false
            }
        }
        count = entries().count
        return ok
    }

    func entries() -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "• ").dropFirst().map { $0 }
    }

    func openFile() {
        if !FileManager.default.fileExists(atPath: fileURL.path) { add("(first note)") }
        NSWorkspace.shared.open(fileURL)
    }

    /// Saves a copy wherever the user picks (Desktop by default).
    func export() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "proDOCKtivity Ideas.txt"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportCopy(to: url)
    }

    /// Writes the ideas to `url`. A file already there is only replaced once the new copy
    /// exists (removing it first lost it whenever the copy then failed).
    @discardableResult
    func exportCopy(to url: URL) -> Bool {
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "proDOCKtivity — ideas & wishes\n\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            Log.write("ideas: export failed (\(error))")
            return false
        }
    }

    /// Opens a new email with the ideas file attached, addressed to the recipient.
    /// Opens a new email to the recipient with all ideas in the text, in whatever mail app is
    /// the default (Mail, Spark, Outlook…). Attachments aren't possible that way, so the ideas
    /// go into the message itself; very long lists are cut and the file can be attached by hand.
    func email() {
        let ideas = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "(no ideas yet)"
        let limit = 6000
        let body = "Hi! Here are my ideas for proDOCKtivity (\(count) so far):\n\n"
            + (ideas.count > limit ? String(ideas.prefix(limit)) + "\n\n[…more in the attached file: ⋯ → Ideas & Wishes → Export]" : ideas)
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = recipient
        parts.queryItems = [URLQueryItem(name: "subject", value: "proDOCKtivity ideas from \(NSFullUserName())"),
                            URLQueryItem(name: "body", value: body)]
        if let url = parts.url, NSWorkspace.shared.open(url) {
            Log.write("ideas: opened email to \(recipient) with \(count) ideas")
        } else {
            Log.write("ideas: couldn't open a mail app, exporting instead")
            export()
        }
    }
}

/// Small floating note window opened with ⌃⌥I.
@MainActor
final class IdeasPanelController {
    private let model: IdeasModel
    private var panel: CommandPanel?

    init(model: IdeasModel) { self.model = model }

    func toggle() { panel?.isVisible == true ? close() : show() }

    /// The periodic check-in: same note window, with a friendly question.
    func showCheckIn() {
        model.markAsked()
        show(checkIn: true)
    }

    func show(checkIn: Bool = false) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let scale = CGFloat(Settings.shared.textScale)
        let size = NSSize(width: DS.Size.notePanel.width * scale, height: DS.Size.notePanel.height * scale)
        let vf = screen.visibleFrame
        panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY, width: size.width, height: size.height), display: false)
        panel.contentView = NSHostingView(rootView: IdeasNoteView(model: model, checkIn: checkIn, close: { [weak self] in self?.close() }).designRoot())
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func close() { panel?.orderOut(nil) }

    private func makePanel() -> CommandPanel {
        let p = CommandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .modalPanel
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.onResign = { [weak self] in self?.close() }
        return p
    }
}

private struct IdeasNoteView: View {
    @ObservedObject var model: IdeasModel
    var checkIn = false
    let close: () -> Void
    @State private var text = ""
    @State private var saved = false
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Label(checkIn ? "Quick check-in: what could be better?" : "Idea for proDOCKtivity",
                      systemImage: checkIn ? "hand.wave" : "lightbulb")
                    .textRole(.title3)
                    .foregroundStyle(Palette.text)
                Spacer()
                Text("\(model.count) saved").textRole(.footnote).monospacedDigit().foregroundStyle(Palette.text3)
            }
            // Running text: the reading size and font, on a sunken well.
            TextEditor(text: $text)
                .readingText()
                .frame(maxWidth: .infinity)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs)
                .background(Palette.sunken, in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                .focused($focused)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("What should be better? Anything goes…")
                            .readingText()
                            .foregroundStyle(Palette.text3)
                            .padding(.horizontal, DS.Space.m)
                            .padding(.vertical, DS.Space.xs)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: DS.Space.s) {
                if saved {
                    Label("Saved", systemImage: "checkmark.circle").textRole(.footnote).foregroundStyle(Palette.success)
                } else if failed {
                    Label("Couldn't save. Your text is kept; try again.", systemImage: "exclamationmark.triangle")
                        .textRole(.footnote).foregroundStyle(Palette.danger)
                } else {
                    HStack(spacing: DS.Space.xs) { Keycap(text: "⌘⏎"); Text("save").textRole(.footnote).foregroundStyle(Palette.text3) }
                }
                Spacer()
                Button(checkIn ? "Not now" : "Cancel", action: close).keyboardShortcut(.cancelAction)
                    .buttonStyle(.secondary)
                Button("Save idea", action: save).keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.primary)
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .floatingSurface()
        .onAppear {
            if text.isEmpty { text = model.draft }
            focused = true
        }
        .onChange(of: text) { _, new in model.draft = new }
    }

    private func save() {
        guard model.add(text) else { failed = true; return }
        failed = false
        text = ""
        model.draft = ""
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { close() }
    }
}
