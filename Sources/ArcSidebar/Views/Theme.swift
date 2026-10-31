import AppKit
import SwiftUI

// The whole look of proDOCKtivity in one file: colors, type, spacing, corners, sizes, depth and
// motion: a warm canvas, white surfaces on soft
// shadows, pastel space colors, one accent per space, 14 pt interface text, nothing longer than
// 150 ms. Views use only the names in here, so the look can be changed (or reverted) from this file.

// MARK: - Color helpers

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// A color that follows the appearance: light or dark, and (optionally) Increase Contrast.
    static func adaptive(light: UInt32, dark: UInt32, alpha: CGFloat = 1, darkAlpha: CGFloat? = nil,
                         contrastLight: UInt32? = nil, contrastDark: UInt32? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            switch match {
            case NSAppearance.Name.darkAqua: return NSColor(hex: dark, alpha: darkAlpha ?? alpha)
            case NSAppearance.Name.accessibilityHighContrastDarkAqua: return NSColor(hex: contrastDark ?? dark, alpha: darkAlpha ?? alpha)
            case NSAppearance.Name.accessibilityHighContrastAqua: return NSColor(hex: contrastLight ?? light, alpha: alpha)
            default: return NSColor(hex: light, alpha: alpha)
            }
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32, alpha: CGFloat = 1) {
        self.init(nsColor: .adaptive(light: light, dark: dark, alpha: alpha))
    }
}

// MARK: - Palette

/// Surfaces, text, lines and states. `Palette.NS` has the same colors for AppKit.
enum Palette {
    enum NS {
        // Surfaces
        static let canvas    = NSColor.adaptive(light: 0xF7F5F2, dark: 0x131315)  // window background
        static let surface   = NSColor.adaptive(light: 0xFFFFFF, dark: 0x1C1C20)  // cards, lists, popovers
        static let raised    = NSColor.adaptive(light: 0xFFFFFF, dark: 0x25252A)  // menus, palette, toasts
        static let sunken    = NSColor.adaptive(light: 0xEFECE7, dark: 0x0F0F11)  // inputs, wells
        static let hover     = NSColor.adaptive(light: 0x171513, dark: 0xFFFFFF, alpha: 0.05)
        static let pressed   = NSColor.adaptive(light: 0x171513, dark: 0xFFFFFF, alpha: 0.09)
        // Text (Increase Contrast turns text2 into text)
        static let text      = NSColor.adaptive(light: 0x171513, dark: 0xEDECEF)
        static let text2     = NSColor.adaptive(light: 0x55504A, dark: 0xA8A6AF, contrastLight: 0x171513, contrastDark: 0xEDECEF)
        static let text3     = NSColor.adaptive(light: 0x6B6660, dark: 0x85838D)
        static let disabled  = NSColor.adaptive(light: 0xB5AFA6, dark: 0x4A4A55)
        // Lines (Increase Contrast: borderStrong)
        static let separator = NSColor.adaptive(light: 0xE8E4DE, dark: 0x2B2B31, contrastLight: 0x6B6660, contrastDark: 0x85838D)
        static let border    = NSColor.adaptive(light: 0xD9D4CC, dark: 0x3A3A42, contrastLight: 0x6B6660, contrastDark: 0x85838D)
        static let borderStrong = NSColor.adaptive(light: 0x6B6660, dark: 0x85838D)
        static let onAccent  = NSColor.adaptive(light: 0xFFFFFF, dark: 0x131315)
        // States, always with an icon or a word
        static let success   = NSColor.adaptive(light: 0x157F3D, dark: 0x5FD38D)
        static let warning   = NSColor.adaptive(light: 0x9A5B00, dark: 0xF5B454)
        static let danger    = NSColor.adaptive(light: 0xB42318, dark: 0xDC8C81)
        // Shadow ink: warm in light mode, black in dark
        static let shadow    = NSColor.adaptive(light: 0x281E14, dark: 0x000000)
        /// The selected row or tile on a space-colored bar: white in light mode; in dark mode a
        /// light veil, because the dark surface would sit below the space color instead of above it.
        static let selectedOnFill = NSColor.adaptive(light: 0xFFFFFF, dark: 0xFFFFFF, alpha: 1, darkAlpha: 0.16)
        /// Resting favorite tiles on the bar: a faint lift, clearly weaker than the selection.
        static let idleOnFill = NSColor.adaptive(light: 0xFFFFFF, dark: 0xFFFFFF, alpha: 0.45, darkAlpha: 0.05)
    }

    static let canvas = Color(nsColor: NS.canvas)
    static let surface = Color(nsColor: NS.surface)
    static let raised = Color(nsColor: NS.raised)
    static let sunken = Color(nsColor: NS.sunken)
    static let hover = Color(nsColor: NS.hover)
    static let pressed = Color(nsColor: NS.pressed)
    static let text = Color(nsColor: NS.text)
    static let text2 = Color(nsColor: NS.text2)
    static let text3 = Color(nsColor: NS.text3)
    static let disabled = Color(nsColor: NS.disabled)
    static let separator = Color(nsColor: NS.separator)
    static let border = Color(nsColor: NS.border)
    static let borderStrong = Color(nsColor: NS.borderStrong)
    static let onAccent = Color(nsColor: NS.onAccent)
    static let success = Color(nsColor: NS.success)
    static let warning = Color(nsColor: NS.warning)
    static let danger = Color(nsColor: NS.danger)
    static let shadow = Color(nsColor: NS.shadow)
    static let selectedOnFill = Color(nsColor: NS.selectedOnFill)
    static let idleOnFill = Color(nsColor: NS.idleOnFill)
    /// Invisible but still hit-testable (SwiftUI ignores fully clear fills for hovering).
    static let clearHit = Color.white.opacity(0.001)
}

// MARK: - Accent (16 choices, one per space)

/// Marks the primary button, selection, focus, links and switches that are on; nothing else.
enum Accent: String, CaseIterable, Identifiable, Codable, Sendable {
    case indigo, blue, sky, cyan, teal, green, olive, gold, orange, red, rose, pink, magenta, purple, cocoa, graphite
    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var nsColor: NSColor { let v = values; return .adaptive(light: v.0, dark: v.1) }
    var nsSoft: NSColor { let v = softValues; return .adaptive(light: v.0, dark: v.1) }
    /// Primary button, links, focus ring. At least 5.2 : 1 on white (light), 7.4 : 1 on the canvas (dark).
    var color: Color { Color(nsColor: nsColor) }
    /// Selected chips, drop targets: 12 % accent into white / 20 % into the dark surface.
    var soft: Color { Color(nsColor: nsSoft) }
    /// Text and icons on `color`.
    var on: Color { Palette.onAccent }

    /// The light-mode accent, for finding the nearest one to an old color.
    var lightRGB: RGB { RGB(hex: values.0) }

    /// The accent closest to `rgb` (perceptually, in OKLab).
    static func nearest(to rgb: RGB) -> Accent {
        allCases.min { $0.lightRGB.distance(to: rgb) < $1.lightRGB.distance(to: rgb) } ?? .indigo
    }

    private var values: (UInt32, UInt32) {
        switch self {
        case .indigo: (0x5551D8, 0x8E8CF7)
        case .blue: (0x236ACE, 0x69A5FE)
        case .sky: (0x0473A9, 0x4DADE9)
        case .cyan: (0x03778B, 0x3CB2CB)
        case .teal: (0x097A70, 0x3BB6A9)
        case .green: (0x007D37, 0x59B771)
        case .olive: (0x597605, 0x91AF5A)
        case .gold: (0x856904, 0xC3A139)
        case .orange: (0xA95602, 0xF08B3C)
        case .red: (0xCB322B, 0xFF7D6F)
        case .rose: (0xC03A5B, 0xFA7D94)
        case .pink: (0xB73E81, 0xF17FB8)
        case .magenta: (0xAD3EA7, 0xE57FDD)
        case .purple: (0x8B4EC4, 0xC28DFB)
        case .cocoa: (0x8B644F, 0xC39D88)
        case .graphite: (0x646D7B, 0x9CA5B3)
        }
    }
    private var softValues: (UInt32, UInt32) {
        switch self {
        case .indigo: (0xE8EBFD, 0x2E2E42)
        case .blue: (0xE4EDFB, 0x2B3546)
        case .sky: (0xE4EEF5, 0x283643)
        case .cyan: (0xE4EEF1, 0x27373E)
        case .teal: (0xE5EEED, 0x273738)
        case .green: (0xE4EFE6, 0x293730)
        case .olive: (0xEAEEE3, 0x31362D)
        case .gold: (0xF0ECE3, 0x393429)
        case .orange: (0xF6EAE3, 0x41312A)
        case .red: (0xFDE8E5, 0x442F2F)
        case .rose: (0xFBE8EA, 0x432F35)
        case .pink: (0xF9E8EF, 0x422F3B)
        case .magenta: (0xF7E8F5, 0x3F2F41)
        case .purple: (0xF0EAF9, 0x393146)
        case .cocoa: (0xF1EBE8, 0x393333)
        case .graphite: (0xEBECEE, 0x33343A)
        }
    }
}

private struct AccentKey: EnvironmentKey { static let defaultValue: Accent = .indigo }

extension EnvironmentValues {
    /// The accent of the current space.
    var dsAccent: Accent {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}

extension View {
    /// Sets the accent for this subtree and tints system controls (switches, focus ring).
    func accent(_ accent: Accent) -> some View {
        environment(\.dsAccent, accent).tint(accent.color)
    }
}

// MARK: - Area colors (one per space)

/// The 18 space colors: 8 primary hues used first, then 10 fallbacks. `base` for dots and icons,
/// `fill` for the pastel background (the bar and the frame), `text` for text on that fill.
enum Area: String, CaseIterable, Identifiable, Codable, Sendable {
    case blue, teal, green, amber, orange, rose, violet, slate
    case indigo, sky, cyan, lime, yellow, red, pink, magenta, brown, stone
    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    static let primary: [Area] = [.blue, .teal, .green, .amber, .orange, .rose, .violet, .slate]
    static let fallback: [Area] = [.indigo, .sky, .cyan, .lime, .yellow, .red, .pink, .magenta, .brown, .stone]

    /// The color for a new space: the next unused primary hue, then the next unused fallback, then repeat.
    static func next(after used: [Area]) -> Area {
        let taken = Set(used)
        return (primary + fallback).first { !taken.contains($0) } ?? allCases[used.count % allCases.count]
    }

    /// The area color closest to `rgb` (perceptually, in OKLab), for spaces from before these colors.
    static func nearest(to rgb: RGB) -> Area {
        allCases.min { $0.lightRGB.distance(to: rgb) < $1.lightRGB.distance(to: rgb) } ?? .slate
    }

    var lightRGB: RGB { RGB(hex: values.base.0) }
    var nsBase: NSColor { let v = values.base; return .adaptive(light: v.0, dark: v.1) }
    var nsFill: NSColor { let v = values.fill; return .adaptive(light: v.0, dark: v.1) }
    var base: Color { Color(nsColor: nsBase) }
    var fill: Color { Color(nsColor: nsFill) }

    /// The fill made lighter (tone > 0) or darker (tone < 0) by up to `DS.Tone.maxShift` in OKLab
    /// lightness, hue and colorfulness kept; in light and dark mode alike.
    func nsFill(tone: Double) -> NSColor {
        guard tone != 0 else { return nsFill }
        let v = values.fill
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return RGB(hex: dark ? v.1 : v.0).shiftingLightness(tone * DS.Tone.maxShift).nsColor
        }
    }
    var text: Color { let v = values.text; return Color(light: v.0, dark: v.1) }

    private var values: (base: (UInt32, UInt32), fill: (UInt32, UInt32), text: (UInt32, UInt32)) {
        switch self {
        case .blue:    ((0x3D7BF2, 0x5A90F6), (0xDFEBFF, 0x25324D), (0x314F89, 0x9EBCF4))
        case .teal:    ((0x12A08A, 0x4DAE9B), (0xE0F0EB, 0x243937), (0x2A6054, 0x9DCAC0))
        case .green:   ((0x43A047, 0x63AF64), (0xE2F0E1, 0x28392B), (0x366033, 0xA4CBA4))
        case .amber:   ((0xE0A31A, 0xE5B151), (0xFBF1E0, 0x453A29), (0x816228, 0xE8CCA0))
        case .orange:  ((0xEE7A3B, 0xF38F5D), (0xFFEAE1, 0x49322B), (0x894E2F, 0xF2BBA3))
        case .rose:    ((0xE2577C, 0xEA738F), (0xFEE5E9, 0x472C34), (0x843D4D, 0xEFACBA))
        case .violet:  ((0x8B5CF6, 0x9A78FA), (0xEAE6FF, 0x332D4E), (0x55418B, 0xBDAFF7))
        case .slate:   ((0x6E7B8F, 0x828E9F), (0xE6E9EC, 0x2E3138), (0x484D56, 0xB2B8C3))
        case .indigo:  ((0x5E65D5, 0x737DDD), (0xE3E7FA, 0x2A2D47), (0x3C4077, 0xA8B1E7))
        case .sky:     ((0x24A5DA, 0x55B3E0), (0xE1F1FA, 0x263A47), (0x2B6079, 0xA1CDE7))
        case .cyan:    ((0x2CB2BF, 0x5BBEC9), (0xE2F3F5, 0x273C42), (0x2E666B, 0xA4D3D9))
        case .lime:    ((0x7FB042, 0x92BC63), (0xEAF3E2, 0x323C2C), (0x4E652F, 0xBBD2A5))
        case .yellow:  ((0xDCBC33, 0xE1C75E), (0xF9F5E3, 0x443E2C), (0x6D5F2A, 0xE5D7A7))
        case .red:     ((0xDB423C, 0xE4645A), (0xFEE3DF, 0x472929), (0x7D312A, 0xEDA59E))
        case .pink:    ((0xDF6AA6, 0xE682B3), (0xFDE8F0, 0x462F3D), (0x7E435E, 0xEBB3CE))
        case .magenta: ((0xB84AC0, 0xC468CA), (0xF5E3F6, 0x3E2942), (0x6A346C, 0xD8A6DC))
        case .brown:   ((0x9B6F52, 0xAA846B), (0xEFE7E2, 0x382F2C), (0x5B4434, 0xC9B2A6))
        case .stone:   ((0x8D8579, 0x9D968C), (0xECEBE8, 0x343334), (0x544F48, 0xC1BCB8))
        }
    }
}

extension RGB {
    init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    /// Perceptual distance (OKLab), so "nearest color" matches what the eye sees.
    func distance(to other: RGB) -> Double {
        let a = oklab, b = other.oklab
        return (a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)
    }

    /// The same color with its OKLab lightness moved by `delta` (clamped to what sRGB can show).
    func shiftingLightness(_ delta: Double) -> RGB {
        let (l, a, b) = oklab
        let nl = min(max(l + delta, 0), 1)
        let l_ = pow(nl + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m_ = pow(nl - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s_ = pow(nl - 0.0894841775 * a - 1.2914855480 * b, 3)
        func gam(_ x: Double) -> Double {
            let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            return min(max(v, 0), 1)
        }
        return RGB(r: gam(4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_),
                   g: gam(-1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_),
                   b: gam(-0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_))
    }

    private var oklab: (Double, Double, Double) {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = lin(r), g = lin(g), b = lin(b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
}

/// What the space you're in looks like right now (its color and accent), for every window.
@MainActor final class SpaceLook: ObservableObject {
    static let shared = SpaceLook()
    /// nil: the bar uses the neutral canvas (no space, or "take the space's color" is off).
    @Published var area: Area?
    @Published var accent: Accent = .indigo
    /// Settings › Appearance › Color tone (−1 darker … 1 lighter).
    @Published var tone: Double = 0

    /// The bar's and the frame's background.
    var barNSColor: NSColor { area?.nsFill(tone: tone) ?? Palette.NS.canvas }
    var barColor: Color { Color(nsColor: barNSColor) }
}

// MARK: - The design system's measures

enum DS {
    /// Spacing scale (4 pt grid). No other values.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
        /// The bar's own side margin, and the left/right inset of a row's content (icons and
        /// text line up across the whole bar).
        static let edge: CGFloat = s
        static let rowInset: CGFloat = s
    }

    /// Corner radii (always continuous corners).
    enum Radius {
        static let xs: CGFloat = 6    // keycaps, badges, tiny chips
        static let s: CGFloat = 8     // rows, hover and selection, tags
        static let m: CGFloat = 10    // buttons, text fields, segmented control
        static let l: CGFloat = 14    // cards, tiles, the bar, the selection pill
        static let xl: CGFloat = 18   // popovers, DOCKlight, sheets, toasts
        /// Favicons and small app icons: the nested-shape minimum.
        static let favicon: CGFloat = 4
    }

    enum Size {
        static let controlSmall: CGFloat = 26
        static let control: CGFloat = 32
        static let controlLarge: CGFloat = 38
        static let rowCompact: CGFloat = 30
        static let row: CGFloat = 34
        static let rowComfortable: CGFloat = 42
        /// A bar (sidebar) item.
        static let sidebarItem: CGFloat = 32
        static let icon: CGFloat = 16
        static let iconSmall: CGFloat = 12
        /// Minimum clickable area.
        static let hitTarget: CGFloat = 28
        /// The quick-capture field (the address field while typing).
        static let captureField: CGFloat = 40
        /// DOCKlight (the command palette).
        static let palette: CGFloat = 600
        static let paletteField: CGFloat = 48
        static let paletteRow: CGFloat = 38
        static let paletteIcon: CGFloat = 20
        /// The palette's top edge, as a share of the screen height from the top.
        static let paletteTop: CGFloat = 0.18
        /// Running text column.
        static let readingWidth: CGFloat = 640
        /// Swatches in the color pickers.
        static let swatch: CGFloat = 20
        static let dot: CGFloat = 8
        /// Badges on icons (notification count, web, duplicate).
        static let badge: CGFloat = 13
        static let badgeSmall: CGFloat = 9
        /// The × on a hovered row: its hover square, inside a hit target.
        static let closeMark: CGFloat = 20
        static let closeTarget: CGFloat = hitTarget
        /// A section label's row ("Favorites", "Today").
        static let sectionHeader: CGFloat = 24
        /// The bar's resize edge: its grip, and the line it shows while hovered or dragged.
        static let resizeGrip: CGFloat = 6
        static let resizeLine: CGFloat = 3
        /// A small state dot on an icon (downloading).
        static let statusDot: CGFloat = 6
        /// Popovers: forms and lists 320, pickers 280.
        static let popoverWide: CGFloat = 320
        static let popover: CGFloat = 280
        /// The symbol of an empty state.
        static let emptyIcon: CGFloat = 32
        /// Favorites tiles: width per height, icon and favicon size per tile height.
        static let tileAspect: CGFloat = 1.25
        static let tileIconRatio: CGFloat = 0.58
        static let faviconRatio: CGFloat = 0.85
        /// The line under a running app's tile.
        static let runningLine: CGFloat = 2
        /// Icons in Settings lists.
        static let settingsIcon: CGFloat = 24
        /// The Settings window's smallest size.
        static let settingsMin = CGSize(width: 680, height: 480)
        static let settingsDefault = CGSize(width: 720, height: 640)
        /// Sliders in Settings and the value label beside them.
        static let settingsSlider: CGFloat = 180
        static let settingsValue: CGFloat = 84
        /// The chevron of a pop-up or pull-down button.
        static let chevron: CGFloat = 10
        /// The ideas note.
        static let notePanel = CGSize(width: 480, height: 260)
        /// How far a badge sits out from an icon's corner, per icon size; its symbol per badge size.
        static let badgeInset: CGFloat = 0.05
        static let badgeGlyph: CGFloat = 0.6
        /// The pill under the pointer while dragging a row.
        static let dragPreview: CGFloat = 200
        /// Pickers in Settings rows; the app chooser's height.
        static let settingsPicker: CGFloat = 140
        static let settingsPickerSmall: CGFloat = 110
        static let appPickerHeight: CGFloat = 380
        /// The icon set picker: its icons, cells and window.
        static let pickerIcon: CGFloat = 40
        static let pickerCell = CGSize(width: 68, height: 64)
        static let iconPicker = CGSize(width: 480, height: 440)
        /// The space icon picker: its scrolling grid and the emoji in it.
        static let spaceIconGrid: CGFloat = 200
        static let spaceIconGlyph: CGFloat = 18
        /// A workspace's card in Show All Workspaces.
        static let overviewColumn: CGFloat = 280
        /// Stripes (the address row while an app is in front): line width and gap.
        static let hatchLine: CGFloat = 1.5
        static let hatchGap: CGFloat = 5
        /// The setup tour's window.
        static let setupTour = CGSize(width: 560, height: 540)
        /// The space switcher: at most this many spaces per row, and the smallest a space may get.
        static let spacesPerRow = 7
        static let spaceDotMin: CGFloat = 18

        /// Height of a bar row for the chosen density, grown with the text size so nothing clips.
        static func barRow(_ density: Density, scale: CGFloat) -> CGFloat {
            let base: CGFloat
            switch density {
            case .compact: base = rowCompact
            case .standard: base = sidebarItem
            case .comfortable: base = rowComfortable
            }
            return (base + TextRole.body.lineHeight * (scale - 1)).rounded()
        }
    }

    /// Line widths.
    enum Line {
        static let hairline: CGFloat = 1
        static let focus: CGFloat = 2
        /// The swatch ring of the selected color.
        static let ring: CGFloat = 2
        /// An outline that marks something without filling it (the tab you just left).
        static let outline: CGFloat = 1.5
        /// Dashes of an empty drop area.
        static let dash: [CGFloat] = [4, 3]
    }

    /// No animation longer than 150 ms; no springs, no bounce.
    /// Settings › Appearance › Color tone: the most the space colors' lightness moves either way
    /// (OKLab L; ±0.1 keeps text on the bar above 4.5 : 1 in both modes).
    enum Tone {
        static let maxShift: Double = 0.1
        static let step: Double = 0.1
    }

    enum Motion {
        static let fast: Double = 0.10     // hover, press, selection, toggle
        static let base: Double = 0.15     // appear, expand/collapse, row move, space change
        static let standard = Animation.timingCurve(0.2, 0.7, 0.2, 1, duration: base)
        static let quick = Animation.timingCurve(0.2, 0.7, 0.2, 1, duration: fast)
        static let exit = Animation.timingCurve(0.4, 0, 1, 1, duration: fast)
        /// Switching spaces: a whole-width slide, at the 150 ms limit (with Reduce Motion it's an instant change like everything else).
        static let slide = Animation.timingCurve(0.2, 0.7, 0.2, 1, duration: base)
        /// The downloads pop-out stretches out of the bar from this size (width, height factors).
        static let stretchFrom = CGSize(width: 0.02, height: 0.6)
        /// How far an appearing element travels (pt).
        static let travel: CGFloat = 8
        /// Pressed and appearing elements start at this scale.
        static let pressScale: CGFloat = 0.98

        /// Use instead of withAnimation: Reduce Motion makes the change instant.
        @MainActor static func perform<Result>(_ animation: Animation = standard, _ body: () throws -> Result) rethrows -> Result {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return try body() }
            return try withAnimation(animation, body)
        }
    }
}

extension AnyTransition {
    /// One space replacing another: in from the trailing edge when the new space lies to the right
    /// (`direction` 1), from the leading edge when it lies to the left (-1); the old one leaves the other way.
    static func spaceSlide(_ direction: Int) -> AnyTransition {
        .asymmetric(insertion: .move(edge: direction > 0 ? .trailing : .leading),
                    removal: .move(edge: direction > 0 ? .leading : .trailing))
    }
}

extension DS {
    enum Opacity {
        /// Disabled controls.
        static let disabled: Double = 0.45
        /// Things that are there but not in use (the other spaces in the switcher).
        static let quiet: Double = 0.6
        /// Past or inactive items (a background app's tab, a sleeping tab).
        static let inactive: Double = 0.6
        /// A highlight laid over content (drop targets), so the content stays readable.
        static let overlay: Double = 0.6
        /// An app that isn't running.
        static let notRunning: Double = 0.8
        /// The accent square behind a Pinwall icon, and while hovered.
        static let accentTile: Double = 0.28
        static let accentTileHover: Double = 0.4
        /// What's open right now (the selected row or tile): a bit stronger than a Favorites square, outlined.
        static let accentSelected: Double = 0.45
        /// The stripes of the address row while an app is in front.
        static let hatch: Double = 0.5
    }
}

/// Row density (Settings → Appearance).
enum Density: String, CaseIterable, Identifiable, Sendable {
    case compact, standard, comfortable
    var id: String { rawValue }
    var label: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Default"
        case .comfortable: return "Comfortable"
        }
    }
}

/// Light, dark, or as the Mac is set (Settings → Appearance).
enum Theme: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Typography

private struct TextScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1.0 }

extension EnvironmentValues {
    /// App-wide text size (Settings → Appearance): 0.9, 1.0, 1.15, 1.3.
    var textScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

/// The text size steps.
enum TextScale {
    static let steps: [(label: String, value: Double)] = [("Small", 0.9), ("Default", 1.0), ("Large", 1.15), ("Extra large", 1.3)]
    /// The step closest to an old point size setting (13 pt was the default).
    static func fromOldPointSize(_ size: Double) -> Double {
        size < 12.5 ? 0.9 : size < 14.5 ? 1.0 : size < 16 ? 1.15 : 1.3
    }
    /// A stored value that isn't one of the steps snaps to the nearest one.
    static func snapped(_ value: Double) -> Double {
        steps.map(\.value).min { abs($0 - value) < abs($1 - value) } ?? 1.0
    }
}

enum TextRole {
    case caption, footnote, body, bodyStrong, bodyLarge, headline, title3, title2, title1, display, mono

    var size: CGFloat {
        switch self {
        case .caption: 12
        case .footnote: 13
        case .body, .bodyStrong, .mono: 14
        case .headline: 15
        case .bodyLarge: 16
        case .title3: 18
        case .title2: 22
        case .title1: 28
        case .display: 36
        }
    }
    var weight: Font.Weight {
        switch self {
        case .bodyStrong, .headline, .title3, .title2: .semibold
        case .title1, .display: .bold
        default: .regular
        }
    }
    /// Line height in points at scale 1.
    var lineHeight: CGFloat {
        switch self {
        case .caption: 16
        case .footnote: 18
        case .body, .bodyStrong, .mono: 20
        case .headline: 22
        case .bodyLarge: 26
        case .title3: 24
        case .title2: 28
        case .title1: 34
        case .display: 42
        }
    }
    var tracking: CGFloat {
        switch self {
        case .title2: -0.2
        case .title1: -0.4
        case .display: -0.8
        default: 0
        }
    }
    /// Section labels are uppercase with a little air between the letters.
    static let labelTracking: CGFloat = 0.4
    var design: Font.Design { self == .mono ? .monospaced : .default }

    func font(scale: CGFloat = 1, weight: Font.Weight? = nil) -> Font {
        .system(size: size * scale, weight: weight ?? self.weight, design: design)
    }

    func nsFont(scale: CGFloat = 1) -> NSFont {
        let w: NSFont.Weight = weight == .semibold ? .semibold : weight == .bold ? .bold : .regular
        return self == .mono ? .monospacedSystemFont(ofSize: size * scale, weight: w) : .systemFont(ofSize: size * scale, weight: w)
    }
}

/// Settings → Appearance → Reading font. Changes only running text, never labels.
enum ReadingFont: String, CaseIterable, Identifiable, Codable, Sendable {
    case sans, serif
    var id: String { rawValue }
    var label: String { self == .sans ? "Sans" : "Serif" }
}

private struct ReadingFontKey: EnvironmentKey { static let defaultValue: ReadingFont = .sans }

extension EnvironmentValues {
    var readingFont: ReadingFont {
        get { self[ReadingFontKey.self] }
        set { self[ReadingFontKey.self] = newValue }
    }
}

struct TextRoleModifier: ViewModifier {
    let role: TextRole
    var weight: Font.Weight?
    @Environment(\.textScale) private var scale

    func body(content: Content) -> some View {
        let size = role.size * scale
        content
            .font(role.font(scale: scale, weight: weight))
            .tracking(role.tracking)
            .lineSpacing(max(0, role.lineHeight * scale - size * 1.2))
    }
}

/// Running text for long reading: 16 / 26, the chosen reading font, `text` color, at most 640 pt wide.
struct ReadingTextModifier: ViewModifier {
    @Environment(\.textScale) private var scale
    @Environment(\.readingFont) private var font

    func body(content: Content) -> some View {
        let size = TextRole.bodyLarge.size * scale
        content
            .font(.system(size: size, weight: .regular, design: font == .serif ? .serif : .default))
            .lineSpacing(max(0, TextRole.bodyLarge.lineHeight * scale - size * 1.2))
            .foregroundStyle(Palette.text)
            .frame(maxWidth: DS.Size.readingWidth * scale, alignment: .leading)
    }
}

extension View {
    /// Sets the font of a text role (size × the text size setting). `weight` only for the
    /// Medium of selected bar items.
    func textRole(_ role: TextRole, weight: Font.Weight? = nil) -> some View {
        modifier(TextRoleModifier(role: role, weight: weight))
    }
    func readingText() -> some View { modifier(ReadingTextModifier()) }
}

/// Applies the design to a window's content: text size, reading font and the current space's accent.
struct DesignRoot: ViewModifier {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var look = SpaceLook.shared

    func body(content: Content) -> some View {
        content
            .environment(\.textScale, CGFloat(settings.textScale))
            .environment(\.readingFont, settings.readingFont)
            .accent(look.accent)
            .foregroundStyle(Palette.text)
    }
}

extension View {
    func designRoot() -> some View { modifier(DesignRoot()) }
}

// MARK: - Motion

struct DSAnimation<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that respects Reduce Motion.
    func dsAnimation<V: Equatable>(_ animation: Animation = DS.Motion.standard, value: V) -> some View {
        modifier(DSAnimation(animation: animation, value: value))
    }
}

extension AnyTransition {
    /// A row joining or leaving a list: fades and moves a little, the list closes up around it.
    static var row: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: -DS.Motion.travel / 2)).combined(with: .scale(scale: DS.Motion.pressScale, anchor: .top)),
                    removal: .opacity)
    }
    /// Something appearing from above (an editor, a hint): fades and travels at most 8 pt.
    static var appear: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: -DS.Motion.travel)), removal: .opacity)
    }
}

// MARK: - Elevation (SwiftUI shadow radius ≈ CSS blur / 2)

enum Elevation { case flat, card, floating }

struct ElevationModifier: ViewModifier {
    let level: Elevation
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        switch level {
        case .flat:
            content
        case .card:      // 0 1px 2px a.05, 0 4px 14px a.05
            content
                .shadow(color: Palette.shadow.opacity(dark ? 0.30 : 0.05), radius: 1, y: 1)
                .shadow(color: Palette.shadow.opacity(dark ? 0.00 : 0.05), radius: 7, y: 4)
        case .floating:  // 0 2px 6px a.06, 0 16px 40px a.16
            content
                .shadow(color: Palette.shadow.opacity(dark ? 0.40 : 0.06), radius: 3, y: 2)
                .shadow(color: Palette.shadow.opacity(dark ? 0.50 : 0.16), radius: 20, y: 16)
        }
    }
}

extension View {
    func elevation(_ level: Elevation) -> some View { modifier(ElevationModifier(level: level)) }
}

// MARK: - Surfaces

/// A card: `surface`, radius l, card elevation; in dark mode a hairline instead of the shadow.
struct CardModifier: ViewModifier {
    var padding: CGFloat = DS.Space.l
    var fill: Color = Palette.surface
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
        let line: Color = contrast == .increased ? Palette.borderStrong : (scheme == .dark ? Palette.separator : .clear)
        content
            .padding(padding)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(line, lineWidth: DS.Line.hairline))
            .elevation(.card)
    }
}

/// Something floating above everything (DOCKlight, the ideas note, toasts): `raised`, radius xl,
/// a hairline in `border` (the window draws the floating shadow).
struct FloatingSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
        content
            .background(Palette.raised, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.border, lineWidth: DS.Line.hairline))
    }
}

extension View {
    func card(padding: CGFloat = DS.Space.l, fill: Color = Palette.surface) -> some View {
        modifier(CardModifier(padding: padding, fill: fill))
    }
    func floatingSurface() -> some View { modifier(FloatingSurface()) }
}

/// The bar's (and the docks' and the frame's) background: the space's pastel color, or the canvas.
struct BarBackground: View {
    @ObservedObject private var look = SpaceLook.shared

    var body: some View {
        Rectangle().fill(look.barColor)
            .dsAnimation(DS.Motion.standard, value: look.area)
            .dsAnimation(DS.Motion.quick, value: look.tone)
    }
}

/// The outline of the bar when it floats as a card of its own (frame off).
struct BarOutline: View {
    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
            .strokeBorder(Palette.separator, lineWidth: DS.Line.hairline)
    }
}

// MARK: - Buttons

struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive }
    var kind: Kind = .secondary
    var height: CGFloat = DS.Size.control

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dsAccent) private var accent
    @Environment(\.textScale) private var scale

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
        configuration.label
            .textRole(.bodyStrong)
            .padding(.horizontal, height >= DS.Size.controlLarge ? DS.Space.l : DS.Space.m)
            .frame(minHeight: height * scale)
            .foregroundStyle(foreground)
            .background(background(pressed: configuration.isPressed), in: shape)
            .overlay(shape.strokeBorder(kind == .secondary ? Palette.border : .clear, lineWidth: DS.Line.hairline))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : DS.Opacity.disabled)
            .dsAnimation(DS.Motion.quick, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: Palette.onAccent
        case .secondary, .ghost: Palette.text
        case .destructive: Palette.danger
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: pressed ? accent.color.opacity(0.85) : accent.color
        case .secondary: pressed ? Palette.sunken : Palette.surface
        case .ghost, .destructive: pressed ? Palette.pressed : .clear
        }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static var primary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var secondary: DSButtonStyle { DSButtonStyle(kind: .secondary) }
    static var ghost: DSButtonStyle { DSButtonStyle(kind: .ghost) }
    static var destructive: DSButtonStyle { DSButtonStyle(kind: .destructive) }
    static var primarySmall: DSButtonStyle { DSButtonStyle(kind: .primary, height: DS.Size.controlSmall) }
    static var ghostSmall: DSButtonStyle { DSButtonStyle(kind: .ghost, height: DS.Size.controlSmall) }
}

/// Buttons sink in a little while pressed.
/// On/off that applies at once is the system switch, small, tinted with the accent
/// (the tint comes from `accent(_:)` / `designRoot()`).
struct DSSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).controlSize(.small)
    }
}

extension ToggleStyle where Self == DSSwitchStyle {
    static var dsSwitch: DSSwitchStyle { DSSwitchStyle() }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? DS.Motion.pressScale : 1)
            .dsAnimation(DS.Motion.quick, value: configuration.isPressed)
    }
}

/// A small symbol button (top bar, bottom bar, row accessories): a 16 pt icon in a 28 pt target,
/// with the quiet hover square. Its tooltip names it (and its shortcut).
struct IconButton: View {
    let symbol: String
    let help: String
    /// A smaller symbol (section headers, row accessories); the target stays 28 pt.
    var small = false
    /// The clickable square (smaller only where many have to fit, like the space switcher).
    var target: CGFloat = DS.Size.hitTarget
    /// The symbol's color (grey unless a place asks for the accent, like the address row).
    var tint: Color = Palette.text2
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .textRole(small ? .footnote : .body, weight: small ? .semibold : nil)
                .frame(width: target, height: target)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .fill(hovering && enabled ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .foregroundStyle(tint)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .dsAnimation(DS.Motion.quick, value: hovering)
    }
}

/// A thin line between groups in the bar.
struct BarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(height: DS.Line.hairline)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.s)
    }
}

/// A keycap (shortcut hint): `sunken`, hairline `border`, radius xs, footnote mono.
struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .textRole(.footnote)
            .fontDesign(.monospaced)
            .foregroundStyle(Palette.text2)
            .padding(.horizontal, DS.Space.xs + DS.Space.xxs)
            .padding(.vertical, DS.Space.xxs)
            .frame(minWidth: DS.Size.swatch)
            .background(Palette.sunken, in: RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous).strokeBorder(Palette.border, lineWidth: DS.Line.hairline))
    }
}

// MARK: - Color swatches for menus

@MainActor enum Swatch {
    private static var cache: [String: NSImage] = [:]

    /// A filled circle for menu items (menus can't take SwiftUI shapes).
    static func image(_ color: NSColor, key: String) -> NSImage {
        if let image = cache[key] { return image }
        let d = DS.Size.iconSmall
        let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }
}

// MARK: - The bar's selection pill

/// The namespace in which a row's selected pill glides to the next selected row.
private struct SelectionNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var selectionNamespace: Namespace.ID? {
        get { self[SelectionNamespaceKey.self] }
        set { self[SelectionNamespaceKey.self] = newValue }
    }
}

// MARK: - Menu bar

enum MenuBarStyle {
    /// The address in the menu bar uses the menu titles' own color (system chrome, drawn as macOS does).
    static let textColor = NSColor.white.withAlphaComponent(0.92)
    static let editingFill = NSColor.white.withAlphaComponent(0.16)
}

/// The menu bar item: a template image (the system colors it), the app glyph simplified to
/// lines: a window whose left part is the bar with three dots, 16 pt drawn in an 18 pt box.
enum MenuBarIcon {
    static let box: CGFloat = 18
    static let line: CGFloat = 1.4          // SF Symbols Regular at this size
    static let frame = CGRect(x: 1, y: 3, width: 16, height: 12)
    static let radius: CGFloat = 3
    static let barWidth: CGFloat = 6
    static let dot: CGFloat = 1.7
    static let dotSpacing: CGFloat = 3

    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: box, height: box), flipped: false) { _ in
            NSColor.black.set()
            let inset = line / 2
            let outline = NSBezierPath(roundedRect: frame.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
            outline.lineWidth = line
            outline.stroke()
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: frame.minX + barWidth, y: frame.minY + inset))
            divider.line(to: NSPoint(x: frame.minX + barWidth, y: frame.maxY - inset))
            divider.lineWidth = line
            divider.stroke()
            for i in -1...1 {
                let c = NSPoint(x: frame.minX + (barWidth + inset) / 2, y: frame.midY + CGFloat(i) * dotSpacing)
                NSBezierPath(ovalIn: NSRect(x: c.x - dot / 2, y: c.y - dot / 2, width: dot, height: dot)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "proDOCKtivity"
        return image
    }
}

/// Diagonal stripes filling a shape's frame (clip it to the shape).
struct Hatch: Shape {
    var line: CGFloat = DS.Size.hatchLine
    var gap: CGFloat = DS.Size.hatchGap

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step = line + gap
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        return path.strokedPath(StrokeStyle(lineWidth: line))
    }
}
