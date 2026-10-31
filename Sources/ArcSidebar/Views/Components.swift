import AppKit
import SwiftUI

/// A row's background in the bar: the quiet hover square, or the selected pill (the accent, a bit
/// stronger than a Favorites square, outlined like the address row) that glides from row to row
/// inside a list with a selection namespace.
struct RowBackground: View {
    let selected: Bool
    let hovering: Bool
    /// Resting background (none for rows: only the selection and hover mark a row).
    var idleFill: Color?
    @Environment(\.selectionNamespace) private var selectionSpace
    @Environment(\.dsAccent) private var accent
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let quiet = RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
        let pillShape = RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
        quiet
            .fill(selected ? .clear : hovering ? Palette.hover : idleFill ?? .clear)
            .overlay {
                if selected {
                    // Increase Contrast: the accent's soft fill instead of a shadow.
                    let pill = Group {
                        pillShape.fill(accent.color.opacity(contrast == .increased ? 1 : DS.Opacity.accentSelected))
                            .overlay(pillShape.strokeBorder(accent.color, lineWidth: DS.Line.outline))
                    }
                    if let selectionSpace {
                        pill.matchedGeometryEffect(id: "selection", in: selectionSpace)
                    } else {
                        pill
                    }
                }
            }
    }
}

/// One tab row of the bar: 16 pt icon, `body` title (Medium when selected), hover close button.
struct SidebarRow<Icon: View>: View {
    let title: String
    var isSelected = false
    var dimmed = false
    var idleFill: Color?
    /// The browser's current tab while another app is in front: no pill (only one thing is
    /// current), just a medium-weight title so you can see where the browser is.
    var isRecent = false
    var closeHelp = "Close"
    @ViewBuilder let icon: () -> Icon
    let onTap: () -> Void
    var onClose: (() -> Void)?

    @State private var hovering = false
    @ObservedObject private var design = Settings.shared

    var body: some View {
        HStack(spacing: DS.Space.s) {
            icon().frame(width: design.rowIcon, height: design.rowIcon)
            Text(title.isEmpty ? "Untitled" : title)
                .textRole(.body, weight: isSelected || isRecent ? .medium : nil)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(dimmed ? Palette.text3 : Palette.text)
            Spacer(minLength: 0)
            if hovering, let onClose {
                // A high-priority tap so the row's own tap (open) can't swallow the click.
                CloseButton(help: closeHelp, action: onClose)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, DS.Space.rowInset)
        .frame(height: design.rowHeight)
        .background(RowBackground(selected: isSelected, hovering: hovering, idleFill: idleFill))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { h in DS.Motion.perform(DS.Motion.quick) { hovering = h } }
        .dsAnimation(DS.Motion.quick, value: isSelected)
        // VoiceOver: one button per row, named after its title.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.isEmpty ? "Untitled" : title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onTap)
        .accessibilityActions {
            if let onClose { Button(closeHelp, action: onClose) }
        }
    }
}

/// The small × on a hovered row; lights up under the pointer.
private struct CloseButton: View {
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: "xmark")
            .textRole(.caption, weight: .semibold)
            .frame(width: DS.Size.closeMark, height: DS.Size.closeMark)
            .background(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous).fill(hovering ? Palette.pressed : .clear))
            .frame(width: DS.Size.closeTarget, height: DS.Size.closeTarget)
            .contentShape(Rectangle())
            .foregroundStyle(hovering ? Palette.text : Palette.text2)
            .highPriorityGesture(TapGesture().onEnded { action() })
            .onHover { h in DS.Motion.perform(DS.Motion.quick) { hovering = h } }
            .help(help)
            .accessibilityLabel(help)
    }
}

/// The one section label style of the bar ("Favorites", "Split View", "Apps", "Today" …):
/// `caption`, `text3`, uppercase with a little tracking.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            SectionLabel(title: title)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, DS.Space.rowInset)
        .frame(minHeight: DS.Size.sectionHeader)
    }
}

struct SectionLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .textRole(.caption, weight: .semibold)
            .tracking(TextRole.labelTracking)
            .foregroundStyle(Palette.text3)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.title = title
        self.trailing = { EmptyView() }
    }
}

/// A card that asks for a permission: headline, one sentence, one secondary button.
struct PermissionCard: View {
    let symbol: String
    let title: String
    let message: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Label(title, systemImage: symbol)
                .textRole(.headline)
                .foregroundStyle(Palette.text)
            Text(message)
                .textRole(.footnote)
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            Button(buttonTitle, action: action)
                .buttonStyle(DSButtonStyle(kind: .secondary, height: DS.Size.controlSmall))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: DS.Space.m)
    }
}

/// A site's icon (see `Favicons`); its first letter on the accent when it has none.
struct FaviconView: View {
    let host: String?
    /// The page's address, when known: Google's apps share one host but have icons of their own.
    var url: String?
    @State private var image: NSImage?
    /// Looked everywhere (so a missing icon shows the letter, not a globe that might still change).
    @State private var loaded = false
    @Environment(\.dsAccent) private var accent

    init(host: String?) { self.host = host }
    init(url: String?) {
        self.url = url
        host = url.flatMap { URL(string: $0)?.host }
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else if loaded, let letter = Self.letter(host) {
                // No icon anywhere: the site's first letter on the workspace's accent.
                GeometryReader { g in
                    Text(letter)
                        .font(.system(size: g.size.height * 0.62, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent.on)
                        .frame(width: g.size.width, height: g.size.height)
                        .background(accent.color)
                }
            } else {
                Image(systemName: "globe").resizable().foregroundStyle(Palette.text2)
            }
        }
        .aspectRatio(contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.favicon, style: .continuous))
        .task(id: (url ?? "") + "|" + (host ?? "")) {
            guard let host else { image = nil; return }
            image = await FaviconStore.shared.image(for: host, url: url)
            loaded = true
        }
    }

    /// "moodle.example.edu" → "M" (the name, not "www").
    static func letter(_ host: String?) -> String? {
        guard let host else { return nil }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return name.first(where: \.isLetter).map { String($0).uppercased() }
    }
}

@MainActor
final class FaviconStore {
    static let shared = FaviconStore()
    private var cache: [String: NSImage] = [:]
    private var pending: [String: Task<NSImage?, Never>] = [:]

    /// Icons of Google's apps (the general favicon service shows the plain Google "G" for most).
    private static func googleProduct(host: String, path: String) -> String? {
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let logo = "https://www.gstatic.com/images/branding/product/2x/"
        switch h {
        case "mail.google.com": return logo + "gmail_2020q4_48dp.png"
        case "calendar.google.com": return logo + "calendar_2020q4_48dp.png"
        case "drive.google.com": return logo + "drive_2020q4_48dp.png"
        case "meet.google.com": return logo + "meet_2020q4_48dp.png"
        case "keep.google.com": return logo + "keep_2020q4_48dp.png"
        case "chat.google.com": return logo + "chat_2020q4_48dp.png"
        case "sites.google.com": return logo + "sites_2020q4_48dp.png"
        case "photos.google.com": return logo + "photos_48dp.png"
        case "classroom.google.com": return logo + "classroom_48dp.png"
        case "contacts.google.com": return logo + "contacts_2022_48dp.png"
        case "translate.google.com": return logo + "translate_48dp.png"
        case "maps.google.com": return logo + "maps_48dp.png"
        case "docs.google.com":
            if path.hasPrefix("/spreadsheets") { return logo + "sheets_2020q4_48dp.png" }
            if path.hasPrefix("/presentation") { return logo + "slides_2020q4_48dp.png" }
            if path.hasPrefix("/forms") { return logo + "forms_2020q4_48dp.png" }
            return logo + "docs_2020q4_48dp.png"
        case "google.com", "google.de":
            if path.hasPrefix("/maps") { return logo + "maps_48dp.png" }
            return nil
        default: return nil
        }
    }

    func image(for host: String, url: String? = nil) async -> NSImage? {
        let path = url.flatMap { URL(string: $0)?.path } ?? ""
        let product = Self.googleProduct(host: host, path: path)
        let key = product ?? host
        if let img = cache[key] { return img }
        if let task = pending[key] { return await task.value }
        let task = Task<NSImage?, Never> {
            if let product { return await Favicons.download(product) }
            if let saved = Favicons.saved(host) { return saved }
            let found = await Favicons.find(host: host)
            if let found { Favicons.save(found, host: host) }
            return found
        }
        pending[key] = task
        let img = await task.value
        pending[key] = nil
        if let img {
            // Bounded: one small image per site, but a long browsing session visits many sites.
            if cache.count >= 400 { cache.removeAll(keepingCapacity: true) }
            cache[key] = img
        }
        return img
    }
}

/// Finding a site's icon: Google's icon service first (its answer for an unknown site is a 404 with a
/// grey globe, which doesn't count), then the site itself: the icons its page names (the largest),
/// apple-touch-icon.png, favicon.ico. Found icons are kept on disk, so each site is looked up once.
enum Favicons {
    static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("proDOCKtivity/Favicons", isDirectory: true)

    static func find(host: String) async -> NSImage? {
        if let google = await download("https://www.google.com/s2/favicons?domain=\(host)&sz=64") { return google }
        var candidates: [String] = []
        if let page = URL(string: "https://\(host)/"), let html = await text(page) {
            candidates += iconLinks(in: html.text, base: html.url)
        }
        candidates += ["https://\(host)/apple-touch-icon.png", "https://\(host)/favicon.ico"]
        // Sites on a subdomain often keep their icon on the main domain (moodle.uni-x.de → uni-x.de).
        let parts = host.split(separator: ".")
        if parts.count > 2 { candidates.append("https://\(parts.suffix(2).joined(separator: "."))/favicon.ico") }
        var seen = Set<String>()
        for c in candidates where seen.insert(c).inserted {
            if let img = await download(c) { return img }
        }
        return nil
    }

    /// An image at `address`, if it answers 200 with something that decodes and isn't a speck.
    static func download(_ address: String) async -> NSImage? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let img = NSImage(data: data), img.isValid,
              img.representations.contains(where: { $0.pixelsWide >= 16 }) else { return nil }
        return img
    }

    private static func text(_ url: URL) async -> (text: String, url: URL)? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        // Only the head matters, and it's near the start.
        let head = data.prefix(200_000)
        guard let html = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return nil }
        return (html, response.url ?? url)
    }

    /// The icons a page names in `<link rel="…icon…" href="…">`, largest first (by `sizes`; apple-touch
    /// icons count as large), as absolute addresses.
    static func iconLinks(in html: String, base: URL) -> [String] {
        guard let tag = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive) else { return [] }
        func attribute(_ name: String, _ tag: String) -> String? {
            let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
            for i in 1...3 { if let r = Range(m.range(at: i), in: tag) { return String(tag[r]) } }
            return nil
        }
        var found: [(String, Int)] = []
        for m in tag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range, in: html) else { continue }
            let t = String(html[r])
            guard let rel = attribute("rel", t)?.lowercased(), rel.contains("icon"), !rel.contains("mask"),
                  let href = attribute("href", t), !href.hasPrefix("data:"),
                  let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL,
                  url.pathExtension.lowercased() != "svg" else { continue }
            let size = attribute("sizes", t).flatMap { Int($0.lowercased().split(separator: "x").first ?? "") }
                ?? (rel.contains("apple-touch") ? 180 : 32)
            found.append((url.absoluteString, size))
        }
        return found.enumerated().sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }.map(\.element.0)
    }

    static func saved(_ host: String) -> NSImage? {
        NSImage(contentsOf: folder.appendingPathComponent(host + ".png"))
    }

    static func save(_ image: NSImage, host: String) {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? png.write(to: folder.appendingPathComponent(host + ".png"))
    }
}

/// Installed apps' icons and names by bundle id, looked up once (views redraw often;
/// Launch Services lookups are not free).
@MainActor enum AppIcons {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]

    static func icon(of bundleID: String) -> NSImage? {
        if let image = icons[bundleID] { return image }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = image
        return image
    }

    static func name(of bundleID: String) -> String? {
        if let name = names[bundleID] { return name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        names[bundleID] = name
        return name
    }
}
