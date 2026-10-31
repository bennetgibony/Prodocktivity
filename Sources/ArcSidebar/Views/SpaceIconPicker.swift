import AppKit
import SwiftUI

/// What a space can show: an emoji, a symbol, or nothing (its color dot).
enum SpaceIconChoice: Equatable {
    case emoji(String)
    case symbol(String)
    case none
}

/// The emoji and symbols offered for spaces, and searching them by name.
enum SpaceIcons {
    /// Suggested emoji, by theme. Every other emoji is found by searching its name.
    static let emojiGroups: [(title: String, items: [String])] = [
        ("Work & study", ["💼", "💻", "🖥️", "📚", "📖", "🎓", "✏️", "📝", "📊", "📈", "🗂️", "📁", "📅", "🗓️", "📌", "📎",
                          "🔬", "🧪", "🧮", "⚖️", "🏛️", "🧠", "💡", "🎯", "✅", "📬", "☎️", "🏢"]),
        ("Life", ["🏠", "🛒", "🍳", "☕️", "🍽️", "💰", "💳", "🧾", "🏥", "💊", "🧘", "🏋️", "🏃", "🚲", "🚗", "✈️",
                  "🧳", "🗺️", "👨‍👩‍👧", "❤️", "🎁", "🐶", "🐱", "🌱"]),
        ("Hobbies", ["🎨", "🎵", "🎧", "🎸", "🎹", "📷", "🎬", "🎮", "⚽️", "🏀", "🎾", "⛰️", "🏕️", "🏖️", "📺", "🍿",
                     "🧩", "♟️", "🪴", "🧶", "📰", "🎙️", "✍️", "🛠️"]),
        ("Nature", ["☀️", "🌙", "⭐️", "🌈", "🔥", "💧", "🌊", "❄️", "⚡️", "🌸", "🌻", "🍀", "🌲", "🍁", "🍎", "🍋",
                    "🦋", "🐝", "🐢", "🦊", "🐼", "🦉", "🐳", "🌍"]),
        ("Faces & hands", ["😀", "😎", "🤓", "🥳", "😴", "🤔", "🙂", "😇", "🤖", "👻", "👽", "💀", "👋", "👍", "🙌", "✌️",
                           "🤝", "💪", "👀", "🫶"]),
        ("Symbols", ["🔴", "🟠", "🟡", "🟢", "🔵", "🟣", "⚫️", "⚪️", "🟥", "🟧", "🟨", "🟩", "🟦", "🟪", "⭕️", "❗️",
                     "❓", "💬", "🔒", "🔑", "⚙️", "🔔", "🏷️", "🚀"]),
    ]

    /// SF Symbols for spaces; they take the space's color.
    static let symbols: [String] = [
        "briefcase.fill", "laptopcomputer", "desktopcomputer", "book.fill", "books.vertical.fill", "graduationcap.fill",
        "pencil", "doc.text.fill", "folder.fill", "tray.full.fill", "archivebox.fill", "calendar", "clock.fill",
        "chart.bar.fill", "chart.pie.fill", "list.bullet", "checklist", "checkmark.circle.fill", "target", "flag.fill",
        "bookmark.fill", "tag.fill", "paperclip", "link", "envelope.fill", "paperplane.fill", "bubble.left.fill",
        "phone.fill", "person.fill", "person.2.fill", "person.3.fill", "building.2.fill", "building.columns.fill",
        "house.fill", "cart.fill", "bag.fill", "creditcard.fill", "banknote.fill", "eurosign.circle.fill", "gift.fill",
        "heart.fill", "star.fill", "sparkles", "bolt.fill", "flame.fill", "drop.fill", "leaf.fill", "tree.fill",
        "sun.max.fill", "moon.fill", "cloud.fill", "snowflake", "globe.europe.africa.fill", "map.fill", "location.fill",
        "airplane", "car.fill", "bicycle", "tram.fill", "figure.walk", "figure.run", "dumbbell.fill", "sportscourt.fill",
        "soccerball", "tennisball.fill", "gamecontroller.fill", "puzzlepiece.fill", "music.note", "headphones",
        "guitars.fill", "pianokeys", "camera.fill", "photo.fill", "film.fill", "tv.fill", "mic.fill", "paintbrush.fill",
        "paintpalette.fill", "hammer.fill", "wrench.and.screwdriver.fill", "gearshape.fill", "terminal.fill",
        "chevron.left.forwardslash.chevron.right", "cpu.fill", "server.rack", "lock.fill", "key.fill", "shield.fill",
        "lightbulb.fill", "brain.head.profile", "atom", "flask.fill", "testtube.2", "function", "sum", "percent",
        "stethoscope", "cross.case.fill", "pills.fill", "fork.knife", "cup.and.saucer.fill", "pawprint.fill",
        "bell.fill", "megaphone.fill", "newspaper.fill", "magazine.fill", "graduationcap", "studentdesk",
        "circle.fill", "square.fill", "triangle.fill", "diamond.fill", "hexagon.fill", "seal.fill",
    ].filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }

    /// Every single-character emoji macOS draws as emoji, with its Unicode name for searching.
    static let allEmoji: [(emoji: String, name: String)] = {
        let ranges: [ClosedRange<UInt32>] = [0x2300...0x23FF, 0x2600...0x27BF, 0x2B00...0x2BFF, 0x1F000...0x1FAFF]
        return ranges.flatMap { $0 }.compactMap { code in
            guard let scalar = Unicode.Scalar(code), scalar.properties.isEmojiPresentation,
                  let name = scalar.properties.name else { return nil }
            return (String(scalar), name.lowercased())
        }
    }()

    /// Emoji whose name contains every word typed ("red heart", "book").
    static func emoji(matching query: String) -> [String] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return [] }
        var found: [String] = []
        var seen = Set<String>()
        // Suggested ones first (they include sequences like 👨‍👩‍👧 that have no single name).
        for e in emojiGroups.flatMap(\.items) where seen.insert(e).inserted {
            if let name = e.unicodeScalars.first?.properties.name?.lowercased(), words.allSatisfy({ name.contains($0) }) { found.append(e) }
        }
        for (e, name) in allEmoji where words.allSatisfy({ name.contains($0) }) && seen.insert(e).inserted { found.append(e) }
        return found
    }

    /// Symbols whose name contains every word typed ("book", "person 2").
    static func symbols(matching query: String) -> [String] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return symbols }
        return symbols.filter { name in
            let readable = name.replacingOccurrences(of: ".", with: " ")
            return words.allSatisfy { readable.contains($0) }
        }
    }

    /// Typed or pasted text that is itself one emoji (e.g. from the Emoji & Symbols viewer).
    static func typedEmoji(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count == 1, let first = t.unicodeScalars.first,
              first.properties.isEmojiPresentation || (first.properties.isEmoji && t.unicodeScalars.count > 1) else { return nil }
        return t
    }
}

/// Picks a space's icon: emoji or symbols in a grid, a search field, and None.
/// Used inline in the bar (under the space's title) and in a popover in Settings.
struct SpaceIconPicker: View {
    let current: SpaceIconChoice
    let choose: (SpaceIconChoice) -> Void
    var done: (() -> Void)?

    enum Kind: String, CaseIterable { case emoji = "Emoji", symbols = "Symbols" }
    @State private var kind: Kind
    @State private var query = ""
    @FocusState private var searching: Bool
    @Environment(\.dsAccent) private var accent

    init(current: SpaceIconChoice, choose: @escaping (SpaceIconChoice) -> Void, done: (() -> Void)? = nil) {
        self.current = current
        self.choose = choose
        self.done = done
        if case .symbol = current { _kind = State(initialValue: .symbols) } else { _kind = State(initialValue: .emoji) }
    }

    private let columns = [GridItem(.adaptive(minimum: DS.Size.hitTarget, maximum: DS.Size.hitTarget), spacing: DS.Space.xxs)]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Picker("", selection: $kind) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField(kind == .emoji ? "Search emoji (English)" : "Search symbols", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
                .onSubmit {
                    if let e = SpaceIcons.typedEmoji(query) { choose(.emoji(e)) }
                }

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.xxs) {
                    if kind == .emoji { emojiCells } else { symbolCells }
                }
                .padding(DS.Space.xxs)
            }
            .frame(height: DS.Size.spaceIconGrid)

            HStack(spacing: DS.Space.s) {
                Button("None") { choose(.none) }
                    .buttonStyle(.ghostSmall)
                    .disabled(current == .none)
                    .help("Show the workspace's color dot")
                if kind == .emoji {
                    Button("More…") {
                        searching = true
                        DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
                    }
                    .buttonStyle(.ghostSmall)
                    .help("Opens the Mac's Emoji & Symbols viewer; the emoji you pick is used")
                }
                Spacer()
                if let done {
                    Button("Done", action: done).buttonStyle(.ghostSmall)
                }
            }
        }
        // An emoji typed, pasted or picked in the viewer is used at once.
        .onChange(of: query) { _, text in
            if kind == .emoji, let e = SpaceIcons.typedEmoji(text) { choose(.emoji(e)); query = "" }
        }
    }

    @ViewBuilder private var emojiCells: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            ForEach(SpaceIcons.emojiGroups, id: \.title) { group in
                Section {
                    ForEach(group.items, id: \.self) { emojiCell($0) }
                } header: {
                    SectionLabel(title: group.title).frame(maxWidth: .infinity, alignment: .leading).padding(.top, DS.Space.xs)
                }
            }
        } else {
            let found = SpaceIcons.emoji(matching: q)
            if found.isEmpty {
                Text("No emoji named “\(q)”. Try an English word, or More….")
                    .textRole(.footnote).foregroundStyle(Palette.text2)
            }
            ForEach(found.prefix(300), id: \.self) { emojiCell($0) }
        }
    }

    @ViewBuilder private var symbolCells: some View {
        let found = SpaceIcons.symbols(matching: query.trimmingCharacters(in: .whitespaces))
        if found.isEmpty {
            Text("No symbol named “\(query)”.").textRole(.footnote).foregroundStyle(Palette.text2)
        }
        ForEach(found, id: \.self) { name in
            cell(selected: current == .symbol(name), help: name.replacingOccurrences(of: ".", with: " ")) {
                choose(.symbol(name))
            } label: {
                Image(systemName: name).font(.system(size: DS.Size.spaceIconGlyph * 0.85)).foregroundStyle(Palette.text)
            }
        }
    }

    private func emojiCell(_ e: String) -> some View {
        cell(selected: current == .emoji(e), help: e.unicodeScalars.first?.properties.name?.capitalized ?? e) {
            choose(.emoji(e))
        } label: {
            Text(e).font(.system(size: DS.Size.spaceIconGlyph))
        }
    }

    private func cell<Label: View>(selected: Bool, help: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .frame(width: DS.Size.hitTarget, height: DS.Size.hitTarget)
                .background(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous).fill(selected ? accent.soft : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension LibrarySpace {
    var iconChoice: SpaceIconChoice {
        if let emoji { return .emoji(emoji) }
        if let symbol { return .symbol(symbol) }
        return .none
    }

    mutating func setIcon(_ choice: SpaceIconChoice) {
        switch choice {
        case .emoji(let e): emoji = e; symbol = nil
        case .symbol(let s): symbol = s; emoji = nil
        case .none: emoji = nil; symbol = nil
        }
    }
}
