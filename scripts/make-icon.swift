// Draws the proDOCKtivity app icon: a soft
// vertical gradient in the app's accent (Indigo), a white glyph of the bar with three dots and,
// lighter, the window beside it. No outline, no shadow, no gloss; the system adds those.
//
// Usage: swift scripts/make-icon.swift <output folder>
//   <out>/AppIcon.iconset     all sizes of the default (light) icon, for iconutil → Resources/AppIcon.icns
//   <out>/layers/             Icon Composer layers: background-light/-dark.png (full bleed), glyph.svg,
//                             glyph-light.png, glyph-dark.png, window-light.png, window-dark.png
//   <out>/preview-*.png       light and dark at 1024 px, and the light icon at 16 and 32 px
//
// The colors are the Indigo and canvas tokens of Sources/ArcSidebar/Views/Theme.swift (a script
// can't import the app); change them there first if the default accent ever changes.
import AppKit

// MARK: Tokens (from Theme.swift)

let accentLight: UInt32 = 0x5551D8      // Accent.indigo, light
let accentDark: UInt32 = 0x8E8CF7       // Accent.indigo, dark
let accentSoftLight: UInt32 = 0xE8EBFD  // Accent.indigo accentSoft, light: the glyph on dark
let canvasLight: UInt32 = 0xF7F5F2      // Palette.canvas, light
let canvasDark: UInt32 = 0x131315       // Palette.canvas, dark

// MARK: Color mixing in OKLab (for perceptually even tints)

struct Lab { var l, a, b: Double }

func rgb(_ hex: UInt32) -> (Double, Double, Double) {
    (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
}

func toLab(_ hex: UInt32) -> Lab {
    func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    let (r0, g0, b0) = rgb(hex)
    let (r, g, b) = (lin(r0), lin(g0), lin(b0))
    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return Lab(l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
               a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
               b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
}

func toColor(_ c: Lab) -> NSColor {
    let l = pow(c.l + 0.3963377774 * c.a + 0.2158037573 * c.b, 3)
    let m = pow(c.l - 0.1055613458 * c.a - 0.0638541728 * c.b, 3)
    let s = pow(c.l - 0.0894841775 * c.a - 1.2914855480 * c.b, 3)
    func gam(_ x: Double) -> CGFloat {
        let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return CGFloat(min(max(v, 0), 1))
    }
    return NSColor(srgbRed: gam(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                   green: gam(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                   blue: gam(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s), alpha: 1)
}

/// `amount` of `accent` mixed into `base`.
func mix(_ accent: UInt32, into base: UInt32, _ amount: Double) -> NSColor {
    let a = toLab(accent), b = toLab(base)
    return toColor(Lab(l: b.l + (a.l - b.l) * amount, a: b.a + (a.a - b.a) * amount, b: b.b + (a.b - b.b) * amount))
}

func color(_ hex: UInt32) -> NSColor {
    let (r, g, b) = rgb(hex)
    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

enum Look { case light, dark }

/// Top and bottom of the background gradient.
func gradient(_ look: Look) -> (NSColor, NSColor) {
    switch look {
    case .light: (mix(accentLight, into: canvasLight, 0.60), mix(accentLight, into: canvasLight, 0.90))
    case .dark: (mix(accentDark, into: canvasDark, 0.30), mix(accentDark, into: canvasDark, 0.15))
    }
}

func glyphColor(_ look: Look) -> NSColor { look == .light ? .white : color(accentSoftLight) }

// MARK: Geometry, in units of the icon's side (0…1, origin bottom left)

/// The glyph spans 56 % of the side: the bar (with three dots cut out) and the window beside it.
struct Glyph {
    static let size = 0.56
    static let left = (1 - size) / 2
    static let bottom = (1 - size) / 2
    static let bar = CGRect(x: left, y: bottom, width: 0.2, height: size)
    static let barRadius = 0.07
    static let dot = 0.1
    /// Centers of the three dots, top to bottom, like apps in the bar.
    static let dots: [CGPoint] = (0..<3).map { i in CGPoint(x: bar.midX, y: bar.midY + Double(1 - i) * 0.15) }
    static let window = CGRect(x: left + 0.26, y: bottom + 0.06, width: size - 0.26, height: size - 0.12)
    static let windowRadius = 0.05
    static let windowAlpha = 0.5
}

func scaled(_ r: CGRect, _ tile: CGRect) -> CGRect {
    CGRect(x: tile.minX + r.minX * tile.width, y: tile.minY + r.minY * tile.height,
           width: r.width * tile.width, height: r.height * tile.height)
}

func barPath(in tile: CGRect) -> NSBezierPath {
    let r = Glyph.barRadius * tile.width
    let path = NSBezierPath(roundedRect: scaled(Glyph.bar, tile), xRadius: r, yRadius: r)
    for c in Glyph.dots {
        let d = Glyph.dot * tile.width
        path.appendOval(in: CGRect(x: tile.minX + c.x * tile.width - d / 2, y: tile.minY + c.y * tile.height - d / 2, width: d, height: d))
    }
    path.windingRule = .evenOdd
    return path
}

func windowPath(in tile: CGRect) -> NSBezierPath {
    let r = Glyph.windowRadius * tile.width
    return NSBezierPath(roundedRect: scaled(Glyph.window, tile), xRadius: r, yRadius: r)
}

// MARK: Drawing

struct Layers: OptionSet {
    let rawValue: Int
    static let background = Layers(rawValue: 1)
    static let bar = Layers(rawValue: 2)
    static let window = Layers(rawValue: 4)
    static let all: Layers = [.background, .bar, .window]
}

/// `masked`: drawn on the macOS icon grid (824 of 1024, rounded square) for the .icns; otherwise full
/// bleed, as Icon Composer wants its layers.
func render(px: Int, look: Look, layers: Layers, masked: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let tile = masked ? CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
                      : CGRect(x: 0, y: 0, width: s, height: s)
    if masked {
        let r = tile.width * 0.2237
        NSBezierPath(roundedRect: tile, xRadius: r, yRadius: r).addClip()
    }
    if layers.contains(.background) {
        let (top, bottom) = gradient(look)
        NSGradient(starting: bottom, ending: top)!.draw(in: tile, angle: 90)
    }
    if layers.contains(.window) {
        glyphColor(look).withAlphaComponent(Glyph.windowAlpha).setFill()
        windowPath(in: tile).fill()
    }
    if layers.contains(.bar) {
        glyphColor(look).setFill()
        barPath(in: tile).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// The glyph as SVG on a 1024 canvas, for Icon Composer (it recolors layers itself).
func glyphSVG() -> String {
    func f(_ v: Double) -> String { String(format: "%.1f", v * 1024) }
    func y(_ r: CGRect) -> Double { 1 - r.maxY }  // SVG's origin is top left
    let b = Glyph.bar, w = Glyph.window
    var dots = ""
    for c in Glyph.dots {
        let cy = 1 - c.y, r = Glyph.dot / 2
        dots += " M\(f(c.x - r)),\(f(cy)) a\(f(r)),\(f(r)) 0 1,0 \(f(2 * r)),0 a\(f(r)),\(f(r)) 0 1,0 \(f(-2 * r)),0 Z"
    }
    let br = Glyph.barRadius, wr = Glyph.windowRadius
    let bar = "M\(f(b.minX + br)),\(f(y(b))) h\(f(b.width - 2 * br)) a\(f(br)),\(f(br)) 0 0 1 \(f(br)),\(f(br)) v\(f(b.height - 2 * br)) a\(f(br)),\(f(br)) 0 0 1 \(f(-br)),\(f(br)) h\(f(-(b.width - 2 * br))) a\(f(br)),\(f(br)) 0 0 1 \(f(-br)),\(f(-br)) v\(f(-(b.height - 2 * br))) a\(f(br)),\(f(br)) 0 0 1 \(f(br)),\(f(-br)) Z"
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      <rect id="window" x="\(f(w.minX))" y="\(f(y(w)))" width="\(f(w.width))" height="\(f(w.height))" rx="\(f(wr))" fill="#FFFFFF" fill-opacity="\(Glyph.windowAlpha)"/>
      <path id="bar" fill="#FFFFFF" fill-rule="evenodd" d="\(bar)\(dots)"/>
    </svg>

    """
}

// MARK: Output

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = out.appendingPathComponent("AppIcon.iconset")
let layers = out.appendingPathComponent("layers")
for dir in [iconset, layers] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px: px, look: .light, layers: .all, masked: true).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
for (look, suffix) in [(Look.light, "light"), (.dark, "dark")] {
    try render(px: 1024, look: look, layers: .background, masked: false).write(to: layers.appendingPathComponent("background-\(suffix).png"))
    try render(px: 1024, look: look, layers: .bar, masked: false).write(to: layers.appendingPathComponent("glyph-\(suffix).png"))
    try render(px: 1024, look: look, layers: .window, masked: false).write(to: layers.appendingPathComponent("window-\(suffix).png"))
    try render(px: 1024, look: look, layers: .all, masked: true).write(to: out.appendingPathComponent("preview-\(suffix).png"))
}
try render(px: 16, look: .light, layers: .all, masked: true).write(to: out.appendingPathComponent("preview-16.png"))
try render(px: 32, look: .light, layers: .all, masked: true).write(to: out.appendingPathComponent("preview-32.png"))
try glyphSVG().write(to: layers.appendingPathComponent("glyph.svg"), atomically: true, encoding: .utf8)
let (top, bottom) = gradient(.light), (dtop, dbottom) = gradient(.dark)
func hex(_ c: NSColor) -> String {
    let c = c.usingColorSpace(.sRGB)!
    return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
}
print("background light \(hex(top)) → \(hex(bottom)), dark \(hex(dtop)) → \(hex(dbottom))")
