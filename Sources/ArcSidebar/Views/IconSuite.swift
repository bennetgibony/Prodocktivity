import SwiftUI

/// A built-in set of clear, colorful icons people can put on their pins (instead of the app
/// icon or website favicon). Each is a white symbol on a two-tone rounded tile.
struct SuiteIcon: Identifiable, Hashable {
    let key: String
    let name: String
    let symbol: String
    let top: Color
    let bottom: Color
    var id: String { key }

    static func find(_ key: String?) -> SuiteIcon? {
        guard let key else { return nil }
        return all.first { $0.key == key }
    }

    private static func c(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// Grouped by meaning so similar things share a color family.
    static let all: [SuiteIcon] = [
        // Communication (blues)
        .init(key: "mail", name: "Mail", symbol: "envelope.fill", top: c(0x5AB0FF), bottom: c(0x2F6BEA)),
        .init(key: "chat", name: "Chat", symbol: "bubble.left.and.bubble.right.fill", top: c(0x6DD3FF), bottom: c(0x2D8BE0)),
        .init(key: "call", name: "Calls", symbol: "video.fill", top: c(0x7BC8FF), bottom: c(0x3A7BD5)),
        .init(key: "contacts", name: "People", symbol: "person.2.fill", top: c(0x8FB8FF), bottom: c(0x4C6FE0)),
        .init(key: "news", name: "News", symbol: "newspaper.fill", top: c(0x9DB4D6), bottom: c(0x51688F)),
        // Organisation (greens / teals)
        .init(key: "calendar", name: "Calendar", symbol: "calendar", top: c(0x6EE7A8), bottom: c(0x1FA76A)),
        .init(key: "todo", name: "To-dos", symbol: "checklist", top: c(0x7BE3C2), bottom: c(0x1E9E86)),
        .init(key: "notes", name: "Notes", symbol: "note.text", top: c(0xA6E87A), bottom: c(0x4CA83A)),
        .init(key: "focus", name: "Focus", symbol: "scope", top: c(0x5FE0D0), bottom: c(0x13968F)),
        .init(key: "timer", name: "Timer", symbol: "timer", top: c(0x8EE3D8), bottom: c(0x2D9C95)),
        .init(key: "cloud", name: "Cloud & Files", symbol: "icloud.fill", top: c(0x93E0F2), bottom: c(0x3497B8)),
        .init(key: "folder", name: "Documents", symbol: "folder.fill", top: c(0x7FD8F0), bottom: c(0x2A93C2)),
        // Study & work (purples / indigos)
        .init(key: "study", name: "Study", symbol: "graduationcap.fill", top: c(0xA89BFF), bottom: c(0x5B4AE0)),
        .init(key: "book", name: "Reading", symbol: "book.fill", top: c(0xB79CFF), bottom: c(0x7247D6)),
        .init(key: "work", name: "Work", symbol: "briefcase.fill", top: c(0x9C9EFF), bottom: c(0x4A4FD1)),
        .init(key: "docs", name: "Writing", symbol: "doc.text.fill", top: c(0xA5B4FF), bottom: c(0x4C61D8)),
        .init(key: "slides", name: "Slides", symbol: "rectangle.on.rectangle.angled", top: c(0xC3A4FF), bottom: c(0x8150D9)),
        .init(key: "sheet", name: "Spreadsheets", symbol: "tablecells.fill", top: c(0x9FD7A4), bottom: c(0x3D8F4A)),
        .init(key: "chart", name: "Data & Stats", symbol: "chart.bar.xaxis", top: c(0xB2A6FF), bottom: c(0x6556E0)),
        .init(key: "code", name: "Code", symbol: "chevron.left.forwardslash.chevron.right", top: c(0x8B93A8), bottom: c(0x3B4256)),
        .init(key: "ai", name: "AI", symbol: "sparkles", top: c(0xF3A6FF), bottom: c(0x9B4DE6)),
        .init(key: "research", name: "Research", symbol: "magnifyingglass", top: c(0xA7B9E8), bottom: c(0x5168B0)),
        // Creative (pinks / oranges)
        .init(key: "design", name: "Design", symbol: "paintbrush.pointed.fill", top: c(0xFF9AC8), bottom: c(0xE0457F)),
        .init(key: "photo", name: "Photos", symbol: "photo.fill", top: c(0xFFB27A), bottom: c(0xE86A3A)),
        .init(key: "music", name: "Music", symbol: "music.note", top: c(0xFF8FA3), bottom: c(0xE33A5C)),
        .init(key: "video", name: "Video", symbol: "play.rectangle.fill", top: c(0xFF8A80), bottom: c(0xD9362B)),
        .init(key: "podcast", name: "Podcasts", symbol: "mic.fill", top: c(0xD9A0FF), bottom: c(0x9A45D6)),
        .init(key: "game", name: "Games", symbol: "gamecontroller.fill", top: c(0xFFA6E1), bottom: c(0xC2449A)),
        // Life (warm)
        .init(key: "shop", name: "Shopping", symbol: "bag.fill", top: c(0xFFC36B), bottom: c(0xE58A12)),
        .init(key: "money", name: "Money", symbol: "creditcard.fill", top: c(0x8EDB9A), bottom: c(0x2F9447)),
        .init(key: "travel", name: "Travel", symbol: "airplane", top: c(0x89D4FF), bottom: c(0x2A86D6)),
        .init(key: "map", name: "Maps", symbol: "map.fill", top: c(0x9EE29B), bottom: c(0x47A54A)),
        .init(key: "food", name: "Food", symbol: "fork.knife", top: c(0xFFB089), bottom: c(0xE0603A)),
        .init(key: "health", name: "Health", symbol: "heart.fill", top: c(0xFF9BA6), bottom: c(0xE0384E)),
        .init(key: "fitness", name: "Fitness", symbol: "figure.run", top: c(0xFFC48A), bottom: c(0xE2732C)),
        .init(key: "home", name: "Home", symbol: "house.fill", top: c(0xFFD27A), bottom: c(0xE09B1F)),
        .init(key: "package", name: "Deliveries", symbol: "shippingbox.fill", top: c(0xE3BE8A), bottom: c(0xA9763A)),
        // General
        .init(key: "star", name: "Favorite", symbol: "star.fill", top: c(0xFFE07A), bottom: c(0xE8A512)),
        .init(key: "bolt", name: "Quick", symbol: "bolt.fill", top: c(0xFFE57A), bottom: c(0xF0A800)),
        .init(key: "web", name: "Website", symbol: "globe", top: c(0x8FC3FF), bottom: c(0x3F72D6)),
        .init(key: "settings", name: "Tools", symbol: "wrench.and.screwdriver.fill", top: c(0xB7BCC8), bottom: c(0x5F6675)),
        .init(key: "lock", name: "Private", symbol: "lock.fill", top: c(0xA9AFC0), bottom: c(0x4A5163)),
    ]
}

/// Draws one suite icon as an app-icon-like tile.
struct SuiteIconView: View {
    let icon: SuiteIcon
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [icon.top, icon.bottom], startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
            )
            .overlay(
                Image(systemName: icon.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.18), radius: size * 0.06, y: size * 0.03)
            .accessibilityLabel(icon.name)
    }
}

/// Grid to pick an icon (or go back to the original one).
struct IconPicker: View {
    let current: String?
    let onPick: (String?) -> Void
    private let columns = Array(repeating: GridItem(.fixed(DS.Size.pickerCell.width), spacing: DS.Space.s), count: 6)
    @Environment(\.dsAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Text("Choose an icon").textRole(.title3).foregroundStyle(Palette.text)
                Spacer()
                Button("Use original") { onPick(nil) }.disabled(current == nil)
                    .buttonStyle(DSButtonStyle(kind: .secondary, height: DS.Size.controlSmall))
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: DS.Space.m) {
                    ForEach(SuiteIcon.all) { icon in
                        Button { onPick(icon.key) } label: {
                            VStack(spacing: DS.Space.xs) {
                                SuiteIconView(icon: icon, size: DS.Size.pickerIcon)
                                Text(icon.name).textRole(.caption).lineLimit(1).foregroundStyle(Palette.text2)
                            }
                            .frame(width: DS.Size.pickerCell.width, height: DS.Size.pickerCell.height)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                                .fill(current == icon.key ? accent.soft : .clear))
                        }
                        .buttonStyle(.plain)
                        .help(icon.name)
                    }
                }
                .padding(DS.Space.xs)
            }
        }
        .padding(DS.Space.l)
        .frame(width: DS.Size.iconPicker.width, height: DS.Size.iconPicker.height)
    }
}

/// The whole icon set as a static sheet (for overviews and the guide).
struct IconSheet: View {
    var columns = 7

    var body: some View {
        let rows = stride(from: 0, to: SuiteIcon.all.count, by: columns).map { Array(SuiteIcon.all[$0..<min($0 + columns, SuiteIcon.all.count)]) }
        VStack(alignment: .leading, spacing: DS.Space.l) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: DS.Space.l) {
                    ForEach(rows[r]) { icon in
                        VStack(spacing: DS.Space.xs) {
                            SuiteIconView(icon: icon, size: DS.Size.pickerIcon)
                            Text(icon.name).textRole(.caption).foregroundStyle(Palette.text2).lineLimit(1)
                        }
                        .frame(width: DS.Size.pickerCell.width)
                    }
                }
            }
        }
        .padding(DS.Space.xl)
    }
}
