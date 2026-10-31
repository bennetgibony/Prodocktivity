import Foundation

/// Parsed `~/Library/Application Support/Arc/StorableSidebar.json`: Arc's own record of
/// spaces, favorites, pinned tabs and folders. Undocumented format, so every field is optional
/// and `load()` returns nil when the structure isn't recognized.
struct ArcTree {
    struct Item {
        enum Kind { case tab, folder, split }
        let kind: Kind
        let customTitle: String?
        let savedTitle: String
        let savedURL: String
        let children: [String]
    }

    struct Space {
        let id: String
        let title: String
        let icon: SpaceIcon?
        let colors: [RGB]
        /// Arc's grain amount for the space theme (0…1), if set.
        let noise: Double?
        let profileKey: String
        let pinnedContainer: String?
        let unpinnedContainer: String?
    }

    var items: [String: Item] = [:]
    /// Container ids are kept separately because containers aren't shown themselves.
    var containers: [String: [String]] = [:]
    var spaces: [Space] = []
    var favorites: [(profileKey: String, container: String)] = []

    func children(of container: String) -> [String]? { containers[container] }

    func favoritesContainer(forProfile key: String?) -> String? {
        favorites.first(where: { $0.profileKey == (key ?? "default") })?.container ?? favorites.first?.container
    }
}

/// Arc's own sidebar width while it's shown ("anchored"), from StorableWindows.json.
enum ArcWindowState {
    static func anchoredSidebarWidth() -> CGFloat? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/StorableWindows.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let window = (root["windows"] as? [[String: Any]])?.first
        let prefs = root["sidebarViewPreferences"] as? [String: Any]
        let mode = window?["sidebarMode"] as? String ?? prefs?["sidebarMode"] as? String
        guard mode == "anchored" else { return nil }
        let width = window?["sidebarWidth"] as? Double ?? prefs?["sidebarWidth"] as? Double
        return width.map { CGFloat($0) }
    }
}

final class ArcSidebarFile: @unchecked Sendable {
    private let url: URL

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")) {
        self.url = url
    }
    private var lastModified: Date?
    private var cached: ArcTree?

    func load() -> ArcTree? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mod = attrs[.modificationDate] as? Date else { return nil }
        if mod == lastModified { return cached }
        // Caught while Arc was writing it: keep the last good copy and read it again next time.
        guard let tree = (try? Data(contentsOf: url)).flatMap(Self.parse) else { return cached }
        lastModified = mod
        cached = tree
        return cached
    }

    /// Arc's sidebar file → spaces, items and favorites; nil if the structure isn't recognized.
    static func parse(_ data: Data) -> ArcTree? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = (root["sidebar"] as? [String: Any])?["containers"] as? [[String: Any]],
              let main = containers.first(where: { $0["spaces"] != nil }),
              let rawItems = main["items"] as? [Any],
              let rawSpaces = main["spaces"] as? [Any] else { return nil }

        var tree = ArcTree()

        for case let item as [String: Any] in rawItems {
            guard let id = item["id"] as? String, let data = item["data"] as? [String: Any] else { continue }
            let children = item["childrenIds"] as? [String] ?? []
            let title = item["title"] as? String
            if data["itemContainer"] != nil {
                tree.containers[id] = children
            } else if let tab = data["tab"] as? [String: Any] {
                tree.items[id] = .init(kind: .tab, customTitle: title,
                                       savedTitle: tab["savedTitle"] as? String ?? "",
                                       savedURL: tab["savedURL"] as? String ?? "", children: [])
            } else if data["splitView"] != nil {
                tree.items[id] = .init(kind: .split, customTitle: title, savedTitle: "", savedURL: "", children: children)
            } else if !children.isEmpty || data["list"] != nil {
                tree.items[id] = .init(kind: .folder, customTitle: title, savedTitle: "", savedURL: "", children: children)
            }
        }

        for case let space as [String: Any] in rawSpaces {
            guard let id = space["id"] as? String else { continue }
            let ids = space["containerIDs"] as? [Any] ?? []
            func container(after marker: String) -> String? {
                guard let i = ids.firstIndex(where: { ($0 as? String) == marker }), i + 1 < ids.count else { return nil }
                return ids[i + 1] as? String
            }
            let info = space["customInfo"] as? [String: Any]
            tree.spaces.append(.init(
                id: id,
                title: space["title"] as? String ?? "",
                icon: icon(info?["iconType"] as? [String: Any]),
                colors: colors((info?["windowTheme"] as? [String: Any])?["background"]),
                noise: noise((info?["windowTheme"] as? [String: Any])?["background"]),
                profileKey: profileKey(space["profile"]),
                pinnedContainer: container(after: "pinned"),
                unpinnedContainer: container(after: "unpinned")
            ))
        }

        // topAppsContainerIDs alternates: <profile descriptor>, <container id>
        let top = main["topAppsContainerIDs"] as? [Any] ?? []
        var i = 0
        while i + 1 < top.count {
            if let container = top[i + 1] as? String {
                tree.favorites.append((profileKey(top[i]), container))
            }
            i += 2
        }
        return tree.spaces.isEmpty ? nil : tree
    }

    private static func profileKey(_ any: Any?) -> String {
        guard let dict = any as? [String: Any] else { return "default" }
        if dict["default"] != nil { return "default" }
        if let custom = (dict["custom"] as? [String: Any])?["_0"] as? [String: Any],
           let name = custom["directoryBasename"] as? String { return name }
        return "default"
    }

    private static func icon(_ dict: [String: Any]?) -> SpaceIcon? {
        guard let dict else { return nil }
        if let emoji = dict["emoji_v2"] as? String { return .emoji(emoji) }
        if let code = dict["emoji"] as? Int, let scalar = Unicode.Scalar(code) { return .emoji(String(Character(scalar))) }
        if let name = dict["icon"] as? String { return .symbol(Self.symbols[name] ?? "circle.fill") }
        return nil
    }

    /// Arc's space icon names mapped to the closest SF Symbols.
    private static let symbols: [String: String] = [
        "flash": "bolt.fill", "shapes": "square.on.circle", "calendar": "calendar", "sunny": "sun.max.fill",
        "star": "star.fill", "heart": "heart.fill", "home": "house.fill", "work": "briefcase.fill",
        "book": "book.fill", "code": "chevron.left.forwardslash.chevron.right", "music": "music.note",
        "moon": "moon.fill", "leaf": "leaf.fill", "planet": "globe.americas.fill", "cloud": "cloud.fill",
        "fire": "flame.fill", "gamecontroller": "gamecontroller.fill", "camera": "camera.fill",
        "cart": "cart.fill", "bag": "bag.fill", "graduationcap": "graduationcap.fill",
    ]

    /// Background colors from `windowTheme.background` (single color or gradient).
    private static func colors(_ background: Any?) -> [RGB] {
        guard let single = ((background as? [String: Any])?["single"] as? [String: Any])?["_0"] as? [String: Any],
              let style = ((single["style"] as? [String: Any])?["color"] as? [String: Any])?["_0"] as? [String: Any]
        else { return [] }
        if let s = (style["blendedSingleColor"] as? [String: Any])?["_0"] as? [String: Any],
           let c = rgb(s["color"]) { return [c] }
        if let g = (style["blendedGradient"] as? [String: Any])?["_0"] as? [String: Any] {
            return (g["baseColors"] as? [Any] ?? []).compactMap(rgb)
        }
        return []
    }

    /// `modifiers.noiseFactor` of the space background, wherever the style keeps it.
    private static func noise(_ background: Any?) -> Double? {
        guard let single = ((background as? [String: Any])?["single"] as? [String: Any])?["_0"] as? [String: Any],
              let style = ((single["style"] as? [String: Any])?["color"] as? [String: Any])?["_0"] as? [String: Any] else { return nil }
        for key in ["blendedSingleColor", "blendedGradient"] {
            if let inner = (style[key] as? [String: Any])?["_0"] as? [String: Any],
               let n = (inner["modifiers"] as? [String: Any])?["noiseFactor"] as? Double { return n }
        }
        return nil
    }

    private static func rgb(_ any: Any?) -> RGB? {
        guard let d = any as? [String: Any],
              let r = d["red"] as? Double, let g = d["green"] as? Double, let b = d["blue"] as? Double else { return nil }
        func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
        return RGB(r: clamp(r), g: clamp(g), b: clamp(b))
    }
}
