import AppKit
import SwiftUI

enum Layout {
    /// Width of the bar itself (user-adjustable).
    @MainActor static var barWidth: CGFloat { CGFloat(Settings.shared.sidebarWidth) }
    /// Width of the website dock next to the bar (0 when it's off).
    @MainActor static var websiteDockWidth: CGFloat { Settings.shared.websiteDock ? CGFloat(Settings.shared.websiteDockWidth) : 0 }
    /// Width of the files dock on `side` (0 when it's elsewhere or off).
    @MainActor static func filesDockWidth(_ side: Settings.FilesDock) -> CGFloat {
        Settings.shared.filesDock == side ? CGFloat(Settings.shared.filesDockWidth) : 0
    }
    /// Horizontal space the bar and the docks next to it claim on the left of the screen.
    @MainActor static var reservedWidth: CGFloat { barWidth + websiteDockWidth + filesDockWidth(.left) }
    /// Space the files dock claims on the right edge of the screen.
    @MainActor static var rightReservedWidth: CGFloat { filesDockWidth(.right) }
    static let dockWidthRange: ClosedRange<Double> = 170...380
    static let widthRange: ClosedRange<Double> = 160...420
    /// Gap between the floating sidebar card and the screen edges (the frame's width in frame mode).
    @MainActor static var inset: CGFloat { Settings.shared.frameMode ? CGFloat(Settings.shared.frameWidth) : 6 }
    /// Gap kept around windows that are snapped next to the sidebar.
    @MainActor static var windowGap: CGFloat { inset }
    static let frameWidthRange: ClosedRange<Double> = 2...24
    /// Top corners of the frame when it stops below the menu bar.
    static let frameCornerRadius: CGFloat = DS.Radius.l
    /// Corner radius of a typical macOS window; the frame's window area is rounded the same.
    static var windowCornerRadius: CGFloat = 16

    /// Edges of `screen` that touch another screen (only where the usable area reaches the
    /// edge, so not past the menu bar or the Dock). Frame mode leaves no frame there.
    @MainActor static func sharedEdges(of screen: NSScreen) -> Set<CGRectEdge> {
        guard Settings.shared.frameMode else { return [] }
        let f = screen.frame, vf = screen.visibleFrame
        var edges = Set<CGRectEdge>()
        for other in NSScreen.screens where other != screen {
            let o = other.frame
            let rowsOverlap = o.minY < f.maxY && o.maxY > f.minY
            let columnsOverlap = o.minX < f.maxX && o.maxX > f.minX
            if rowsOverlap, abs(o.maxX - f.minX) < 1, vf.minX == f.minX { edges.insert(.minXEdge) }
            if rowsOverlap, abs(o.minX - f.maxX) < 1, vf.maxX == f.maxX { edges.insert(.maxXEdge) }
            if columnsOverlap, abs(o.maxY - f.minY) < 1, vf.minY == f.minY { edges.insert(.minYEdge) }
            if columnsOverlap, abs(o.minY - f.maxY) < 1, vf.maxY == f.maxY { edges.insert(.maxYEdge) }
        }
        return edges
    }
    static let cornerRadius: CGFloat = DS.Radius.l
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults: UserDefaults

    @Published var autoFitWindows: Bool {
        didSet { defaults.set(autoFitWindows, forKey: "autoFitWindows") }
    }
    /// Open apps only in the workspace they were opened in (and the Open area as one list of apps and
    /// tabs), instead of in every workspace.
    @Published var openAppsPerWorkspace: Bool {
        didSet { defaults.set(openAppsPerWorkspace, forKey: "openApps.perWorkspace") }
    }
    /// The bar and the frame take the space's color (otherwise the neutral canvas).
    @Published var matchArcSpace: Bool {
        didSet { defaults.set(matchArcSpace, forKey: "matchArcSpace") }
    }

    /// Stop Arc's hidden sidebar from popping out when the mouse crosses its left edge.
    @Published var blockArcSidebarPeek: Bool {
        didSet { defaults.set(blockArcSidebarPeek, forKey: "blockArcSidebarPeek") }
    }

    // MARK: Browser sync

    /// How often proDOCKtivity asks the browser for its tabs.
    enum ArcSync: String, CaseIterable, Identifiable {
        case live, light, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .live: return "Live (every second)"
            case .light: return "Light (recommended)"
            case .off: return "Off: only workspaces, colors & pins"
            }
        }
    }

    @Published var arcSync: ArcSync { didSet { defaults.set(arcSync.rawValue, forKey: "arcSync") } }
    /// The browser that shows websites (built-in by default).
    @Published var browserEngine: BrowserEngine { didSet { defaults.set(browserEngine.rawValue, forKey: "browserEngine") } }

    // MARK: Frame

    /// Frame mode: a backdrop in the space's color behind everything, and windows kept
    /// inside it next to the bar, so it all looks like one proDOCKtivity window.
    @Published var frameMode: Bool { didSet { defaults.set(frameMode, forKey: "frameMode") } }
    /// With more than one screen: the space-colored frame (and the browser inside it) on the other screens too.
    @Published var frameOtherScreens: Bool { didSet { defaults.set(frameOtherScreens, forKey: "frameOtherScreens") } }
    /// Width of the frame around the bar and the windows.
    @Published var frameWidth: Double { didSet { defaults.set(frameWidth, forKey: "design.frameWidth") } }
    /// The frame reaches up behind the menu bar; otherwise it stops below it with rounded top corners.
    @Published var frameUnderMenuBar: Bool { didSet { defaults.set(frameUnderMenuBar, forKey: "design.frameUnderMenuBar") } }

    /// Two-finger swipe on the bar goes the other way (fingers left → previous space).
    @Published var reverseSpaceSwipe: Bool { didSet { defaults.set(reverseSpaceSwipe, forKey: "reverseSpaceSwipe") } }

    /// The built-in browser's address field sits in the menu bar.
    @Published var menuBarAddress: Bool { didSet { defaults.set(menuBarAddress, forKey: "menuBarAddress.v2") } }
    /// Where typed searches go (address field, DOCKlight).
    @Published var searchEngine: SearchEngine { didSet { defaults.set(searchEngine.rawValue, forKey: "searchEngine") } }

    // MARK: Docks

    /// A second bar just for websites, next to the bar (the bar keeps the favorites and apps).
    @Published var websiteDock: Bool { didSet { defaults.set(websiteDock, forKey: "dock.websites") } }
    @Published var websiteDockWidth: Double { didSet { defaults.set(websiteDockWidth, forKey: "dock.websitesWidth") } }

    enum FilesDock: String, CaseIterable, Identifiable {
        case off, left, right
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .left: return "Left, next to the bar"
            case .right: return "Right screen edge"
            }
        }
    }

    /// A compact Finder overview of chosen folders.
    @Published var filesDock: FilesDock { didSet { defaults.set(filesDock.rawValue, forKey: "dock.files") } }
    @Published var filesDockWidth: Double { didSet { defaults.set(filesDockWidth, forKey: "dock.filesWidth") } }

    // MARK: Screen

    /// Where the bar lives: "main" (the screen with the menu bar), "mouse" (follows the
    /// mouse), or "display:<name>" for one particular screen.
    @Published var barScreen: String { didSet { defaults.set(barScreen, forKey: "barScreen") } }

    /// The screen for the bar right now; `mouseScreen` is the screen the mouse was last on.
    func resolvedBarScreen(mouseScreen: NSScreen?) -> NSScreen? {
        let main = NSScreen.screens.first
        switch barScreen {
        case "mouse": return mouseScreen ?? main
        case let s where s.hasPrefix("display:"):
            let name = String(s.dropFirst(8))
            // A screen that isn't connected right now falls back to the main one.
            return NSScreen.screens.first { $0.localizedName == name } ?? main
        default: return main
        }
    }

    /// Where the built-in browser's window opens: "bar" (beside the bar, the default), "other" (the
    /// screen without the bar), or "display:<name>" for one particular screen.
    @Published var browserScreen: String { didSet { defaults.set(browserScreen, forKey: "browserScreen") } }

    /// The name of the screen the browser window fills instead of the space beside the bar, or nil
    /// when it stays beside the bar (also when the chosen screen isn't connected or is the bar's own).
    nonisolated static func browserScreenName(setting: String, barName: String?, names: [String]) -> String? {
        switch setting {
        case "other": return names.first { $0 != barName }
        case let s where s.hasPrefix("display:"):
            let name = String(s.dropFirst(8))
            return names.contains(name) && name != barName ? name : nil
        default: return nil
        }
    }

    /// The screen the browser window fills right now, if it isn't the bar's.
    func resolvedBrowserScreen(barScreen: NSScreen?) -> NSScreen? {
        let names = NSScreen.screens.map(\.localizedName)
        guard let name = Self.browserScreenName(setting: browserScreen, barName: barScreen?.localizedName, names: names) else { return nil }
        return NSScreen.screens.first { $0.localizedName == name }
    }

    // MARK: Design

    /// Width the bar claims at the left screen edge.
    @Published var sidebarWidth: Double { didSet { defaults.set(sidebarWidth, forKey: "design.sidebarWidth") } }
    /// Height of the pinboard tiles (icons scale with it).
    @Published var tileSize: Double { didSet { defaults.set(tileSize, forKey: "design.tileSize") } }
    /// How much lighter (+) or darker (−) than the offered tones the space colors are, −1…1.
    @Published var barTone: Double { didSet { defaults.set(barTone, forKey: "design.barTone") } }

    /// The space whose color and accent are being edited in the bar (not saved).
    @Published var editingColorSpace: String?
    /// The space whose icon is being chosen in the bar (not saved).
    @Published var editingIconSpace: String?

    // MARK: Appearance

    /// System, light or dark.
    @Published var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: "appearance.theme") } }
    /// Text size: 0.9, 1.0, 1.15 or 1.3 times every text role.
    @Published var textScale: Double { didSet { defaults.set(textScale, forKey: "appearance.textScale") } }
    /// Sans or Serif for running text (ideas, notes); labels stay in the system font.
    @Published var readingFont: ReadingFont { didSet { defaults.set(readingFont.rawValue, forKey: "appearance.readingFont") } }
    /// Row height: compact, default or comfortable.
    @Published var density: Density { didSet { defaults.set(density.rawValue, forKey: "appearance.density") } }
    /// The accent where no space has its own (and for new spaces).
    @Published var accent: Accent { didSet { defaults.set(accent.rawValue, forKey: "appearance.accent") } }

    /// Height of a row in the bar.
    var rowHeight: CGFloat { DS.Size.barRow(density, scale: CGFloat(textScale)) }
    /// Icon size in a row of the bar.
    var rowIcon: CGFloat { (DS.Size.icon * CGFloat(textScale)).rounded() }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoFitWindows = defaults.object(forKey: "autoFitWindows") as? Bool ?? true
        openAppsPerWorkspace = defaults.bool(forKey: "openApps.perWorkspace")
        matchArcSpace = defaults.object(forKey: "matchArcSpace") as? Bool ?? true
        blockArcSidebarPeek = defaults.object(forKey: "blockArcSidebarPeek") as? Bool ?? true
        arcSync = ArcSync(rawValue: defaults.string(forKey: "arcSync") ?? "") ?? .light
        browserEngine = BrowserEngine(rawValue: defaults.string(forKey: "browserEngine") ?? "") ?? .builtIn
        barScreen = defaults.string(forKey: "barScreen") ?? "main"
        browserScreen = defaults.string(forKey: "browserScreen") ?? "bar"
        frameMode = defaults.object(forKey: "frameMode") as? Bool ?? true
        frameOtherScreens = defaults.object(forKey: "frameOtherScreens") as? Bool ?? true
        websiteDock = defaults.object(forKey: "dock.websites") as? Bool ?? false
        websiteDockWidth = defaults.object(forKey: "dock.websitesWidth") as? Double ?? 230
        filesDock = FilesDock(rawValue: defaults.string(forKey: "dock.files") ?? "") ?? .off
        filesDockWidth = defaults.object(forKey: "dock.filesWidth") as? Double ?? 230
        reverseSpaceSwipe = defaults.bool(forKey: "reverseSpaceSwipe")
        // Off by default: the address lives in the bar's top corner (v2: earlier builds had it on).
        menuBarAddress = defaults.object(forKey: "menuBarAddress.v2") as? Bool ?? false
        searchEngine = SearchEngine(rawValue: defaults.string(forKey: "searchEngine") ?? "") ?? .google
        frameWidth = defaults.object(forKey: "design.frameWidth") as? Double ?? 8
        frameUnderMenuBar = defaults.object(forKey: "design.frameUnderMenuBar") as? Bool ?? false
        sidebarWidth = defaults.object(forKey: "design.sidebarWidth") as? Double ?? 240
        tileSize = defaults.object(forKey: "design.tileSize") as? Double ?? 48
        barTone = min(max(defaults.object(forKey: "design.barTone") as? Double ?? 0, -1), 1)
        theme = Theme(rawValue: defaults.string(forKey: "appearance.theme") ?? "") ?? .system
        // The old point-size slider (13 pt was the default) becomes the nearest step.
        if let scale = defaults.object(forKey: "appearance.textScale") as? Double {
            textScale = TextScale.snapped(scale)
        } else if let old = defaults.object(forKey: "design.textSize") as? Double {
            textScale = TextScale.fromOldPointSize(old)
        } else {
            textScale = 1.0
        }
        readingFont = ReadingFont(rawValue: defaults.string(forKey: "appearance.readingFont") ?? "") ?? .sans
        density = Density(rawValue: defaults.string(forKey: "appearance.density") ?? "") ?? .standard
        accent = Accent(rawValue: defaults.string(forKey: "appearance.accent") ?? "") ?? .indigo
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        func byte(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}
