import SwiftUI

/// First run: no tour, but a "Getting started" card in the bar with four things to do in the
/// real app. Each ticks itself off when done; the card can be closed any time and comes back from
/// ⋯ → Show Getting Started.
@MainActor
final class GettingStarted: ObservableObject {
    static let shared = GettingStarted()

    enum Step: String, CaseIterable, Identifiable {
        case favorite, space, docklight, hideBar
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .favorite: "star"
            case .space: "square.stack.3d.up"
            case .docklight: "magnifyingglass"
            case .hideBar: "sidebar.left"
            }
        }

        var text: String {
            switch self {
            case .favorite: "Drag an app or website into Favorites"
            case .space: "Add a workspace for one part of your life with +"
            case .docklight: "Search everything with ⌥Space"
            case .hideBar: "Hide and show the bar with ⌃⌥S"
            }
        }
    }

    private let defaults: UserDefaults
    /// Steps done by doing them (favorites and spaces are counted from what's there).
    @Published private(set) var marked: Set<Step>
    @Published private(set) var dismissed: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        marked = Set((defaults.stringArray(forKey: "gettingStarted.done") ?? []).compactMap(Step.init(rawValue:)))
        // Anyone who saw the old three-step intro has started already.
        dismissed = defaults.bool(forKey: "gettingStarted.dismissed") || defaults.bool(forKey: "didShowIntro")
    }

    func mark(_ step: Step) {
        guard !marked.contains(step) else { return }
        marked.insert(step)
        defaults.set(marked.map(\.rawValue).sorted(), forKey: "gettingStarted.done")
    }

    func dismiss() {
        dismissed = true
        defaults.set(true, forKey: "gettingStarted.dismissed")
    }

    func showAgain() {
        dismissed = false
        defaults.set(false, forKey: "gettingStarted.dismissed")
        defaults.set(false, forKey: "didShowIntro")
    }

    func done(favorites: Int, spaces: Int) -> Set<Step> {
        var done = marked
        if favorites > 0 { done.insert(.favorite) }
        if spaces > 1 { done.insert(.space) }
        return done
    }

    /// Shown until closed, or until everything is done.
    func isShown(favorites: Int, spaces: Int) -> Bool {
        !dismissed && done(favorites: favorites, spaces: spaces).count < Step.allCases.count
    }
}

struct GettingStartedCard: View {
    @ObservedObject var guide = GettingStarted.shared
    let favorites: Int
    let spaces: Int

    var body: some View {
        if guide.isShown(favorites: favorites, spaces: spaces) {
            let done = guide.done(favorites: favorites, spaces: spaces)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Text("Getting started").textRole(.headline).foregroundStyle(Palette.text)
                    Spacer(minLength: 0)
                    Text("\(done.count) of \(GettingStarted.Step.allCases.count)")
                        .textRole(.footnote).monospacedDigit().foregroundStyle(Palette.text3)
                    Button { DS.Motion.perform(DS.Motion.exit) { guide.dismiss() } } label: {
                        Image(systemName: "xmark").textRole(.footnote)
                    }
                    .buttonStyle(.ghostSmall)
                    .help("Close; ⋯ → Show Getting Started brings it back")
                    .accessibilityLabel("Close Getting started")
                }
                ForEach(GettingStarted.Step.allCases) { step in
                    let isDone = done.contains(step)
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                        Image(systemName: isDone ? "checkmark.circle.fill" : step.symbol)
                            .foregroundStyle(isDone ? Palette.success : Palette.text2)
                            .frame(width: DS.Size.icon)
                        Text(step.text)
                            .foregroundStyle(isDone ? Palette.text3 : Palette.text)
                            .strikethrough(isDone, color: Palette.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .textRole(.footnote)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(isDone ? "Done" : "To do")
                }
            }
            .card(padding: DS.Space.m)
            .transition(.appear)
            .dsAnimation(DS.Motion.quick, value: done)
        }
    }
}
