// Draws the a-card app icon: the A-Cam dII memory cartridge seen from above and slightly to the
// front-left, a long hexagon whose connector end has both corners cut off at 45 degrees and slopes
// down from a crease. Champagne-gold brushed aluminium on top, darker gold sides with the groove
// between the two halves, the black connector slot in the end face, and "a-card" engraved in large
// lowercase where the card has its logo. Transparent around it, with a soft drop shadow. Drawn on a
// 1024 x 1024 canvas, y pointing down; the small lines only from 256 px, the word only from 64 px.
//
//   cd pipeline/icon && /Library/Developer/CommandLineTools/usr/bin/swiftc -sdk \
//     /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk make-icon.swift -o /tmp/make-icon && \
//     /tmp/make-icon ../Sources/ACamApp/AppIcon.icns
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ stops: [(UInt32, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { colour($0.0) } as CFArray,
               locations: stops.map { $0.1 })!
}

func polygon(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
}

func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }

/// The cartridge for one icon size: its geometry on the 1024 canvas and how much detail to draw.
struct Cartridge {
    let pixels: Int
    /// Device pixels per canvas unit, for shadows, which do not follow the CTM.
    var scale: CGFloat { CGFloat(pixels) / 1024 }
    var small: Bool { pixels <= 32 }

    // The top face, length (u) along x and width (w) foreshortened along y; a little larger when tiny.
    var length: CGFloat { small ? 850 : 770 }
    var width: CGFloat { small ? 580 : 520 }
    let squash: CGFloat = 0.82
    /// How far the two connector-end corners are cut back; larger when tiny, so they still read.
    var chamfer: CGFloat { width * (small ? 0.32 : 0.25) }
    /// The thickness on screen: the bottom face is the top face moved down and to the left.
    var depth: CGPoint { small ? CGPoint(x: -60, y: 72) : CGPoint(x: -58, y: 62) }
    /// The nose slopes down to the connector: how much of the thickness the end face loses on top.
    let taper: CGFloat = 0.3
    var origin: CGPoint {
        let w = length - depth.x, h = width * squash + depth.y
        return CGPoint(x: (1024 - w) / 2 - depth.x, y: (1024 - h) / 2 - (small ? 8 : 20))
    }

    /// A point on the top face in (u, w) to the canvas, lowered by `drop` of the thickness, and the
    /// same point on the bottom face. At 16 and 32 px corners land on whole pixels, for crisp edges.
    func top(_ u: CGFloat, _ w: CGFloat, drop: CGFloat = 0) -> CGPoint {
        snap(CGPoint(x: origin.x + u, y: origin.y + w * squash) + depth * drop)
    }
    func bottom(_ u: CGFloat, _ w: CGFloat) -> CGPoint { top(u, w, drop: 1) }
    func snap(_ p: CGPoint) -> CGPoint {
        guard small else { return p }
        let unit = 1024 / CGFloat(pixels)
        return CGPoint(x: (p.x / unit).rounded() * unit, y: (p.y / unit).rounded() * unit)
    }

    /// The flat top: far edge, near edge, and the crease where the nose begins.
    var flat: [CGPoint] { [top(chamfer, 0), top(length, 0), top(length, width), top(chamfer, width)] }
    /// The sloping nose between the crease and the end face, with the two cut corners.
    var nose: [CGPoint] {
        [top(chamfer, 0), top(chamfer, width), top(0, width - chamfer, drop: taper), top(0, chamfer, drop: taper)]
    }
    /// The whole outline, clockwise from the far end of the crease.
    var outline: CGPath {
        let n = nose, c = chamfer
        return polygon([n[0], top(length, 0), top(length, width), bottom(length, width), bottom(c, width),
                        bottom(0, width - c), bottom(0, c), n[3]])
    }
}

func shade(_ c: CGContext, _ path: CGPath, _ g: CGGradient, from a: CGPoint, to b: CGPoint) {
    c.saveGState()
    c.addPath(path)
    c.clip()
    c.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
}

/// One side face from a to b along the top, down to the bottom face, with the groove between the
/// cartridge's two halves at a fixed height above the bottom.
func side(_ c: CGContext, _ k: Cartridge, _ a: CGPoint, _ b: CGPoint, _ a1: CGPoint, _ b1: CGPoint,
          light: UInt32, dark: UInt32, groove: Bool = true) {
    let quad = polygon([a, b, b1, a1])
    shade(c, quad, gradient([(light, 0), (dark, 1)]), from: a, to: a1)
    guard groove, k.pixels > 16 else { return }
    c.saveGState()
    c.addPath(quad)
    c.clip()
    let up = k.depth * -0.42, w: CGFloat = k.small ? 0.6 / k.scale : 3.5
    c.setLineCap(.butt)
    c.setStrokeColor(colour(0x2a2310, 0.8))
    c.setLineWidth(w)
    c.strokeLineSegments(between: [a1 + up, b1 + up])
    if !k.small {
        let lip = CGPoint(x: 0, y: w * 0.9)
        c.setStrokeColor(colour(0xf2e6b8, 0.5))
        c.setLineWidth(w * 0.6)
        c.strokeLineSegments(between: [a1 + up + lip, b1 + up + lip])
    }
    c.restoreGState()
}

func line(_ text: String, _ font: CTFont, tracking: CGFloat, _ fill: CGColor) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill,
        NSAttributedString.Key(kCTKernAttributeName as String): tracking,
    ]))
}

func advance(_ text: String, font name: String, size: CGFloat, tracking: CGFloat = 0) -> CGFloat {
    let font = CTFontCreateWithName(name as CFString, size, nil)
    // The kern after the last glyph is not part of the word's width.
    return CGFloat(CTLineGetTypographicBounds(line(text, font, tracking: tracking, colour(0)), nil, nil, nil)) - tracking
}

/// Text on the flat top with its baseline starting at (u, w), cut into the metal: a dark floor, the
/// upper wall in shadow, the lower wall catching the light, and a lit rim just below the cut.
func engrave(_ c: CGContext, _ k: Cartridge, _ text: String, font name: String, size: CGFloat,
             at u: CGFloat, _ w: CGFloat, tracking: CGFloat = 0) {
    let font = CTFontCreateWithName(name as CFString, size, nil)
    let e = max(size * 0.028, 1.6)
    c.saveGState()
    c.translateBy(x: k.origin.x + u, y: k.origin.y + w * k.squash)
    c.scaleBy(x: 1, y: -k.squash)
    c.textMatrix = .identity
    func glyphs(_ dy: CGFloat, _ fill: CGColor, clip: Bool = false) {
        c.setTextDrawingMode(clip ? .clip : .fill)
        c.textPosition = CGPoint(x: 0, y: dy)
        CTLineDraw(line(text, font, tracking: tracking, fill), c)
    }
    glyphs(-e * 0.8, colour(0xfff7d8, 0.7))
    glyphs(0, colour(0), clip: true)
    c.setFillColor(colour(0x1c1910))
    c.fill(CGRect(x: -50, y: -size, width: 4000, height: size * 3))
    glyphs(-e, colour(0x8c8160))
    glyphs(-e, colour(0), clip: true)
    glyphs(e * 0.25, colour(0x3c372b))
    c.restoreGState()
}

/// The icon on a 1024 x 1024 canvas, y pointing down: the cartridge, transparent around it.
func draw(_ c: CGContext, _ k: Cartridge) {
    let n = k.nose, d = k.depth, L = k.length, W = k.width, ch = k.chamfer

    // A soft drop shadow, and a tighter one where it rests.
    for (offset, blur, alpha) in [(30 as CGFloat, 50 as CGFloat, 0.38 as CGFloat), (8, 10, 0.32)] {
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -offset * k.scale), blur: blur * k.scale, color: colour(0x000000, alpha))
        c.addPath(k.outline)
        c.setFillColor(colour(0x6e6136))
        c.fillPath()
        c.restoreGState()
    }

    // The sides, in darker gold: the end face with the connector, the cut corner, the long near side.
    side(c, k, n[3], n[2], k.bottom(0, ch), k.bottom(0, W - ch), light: 0x86784a, dark: 0x5e532f, groove: false)
    side(c, k, n[2], n[1], k.bottom(0, W - ch), k.bottom(ch, W), light: 0xa09058, dark: 0x766a3e)
    side(c, k, n[1], k.top(L, W), k.bottom(ch, W), k.bottom(L, W), light: 0xb6a46a, dark: 0x8a7b48)

    // The connector slot: a black opening centred in the end face, with the contacts' lip inside.
    let inset = ch * (k.small ? 0.1 : 0.14)
    let e0 = n[3] + CGPoint(x: 0, y: inset * k.squash), e1 = n[2] + CGPoint(x: 0, y: -inset * k.squash)
    let tall = d * (1 - k.taper)
    let (t0, t1): (CGFloat, CGFloat) = k.small ? (0.22, 0.78) : (0.3, 0.72)
    let slot = polygon([e0 + tall * t0, e1 + tall * t0, e1 + tall * t1, e0 + tall * t1])
    c.addPath(slot)
    c.setFillColor(colour(0x0a0907))
    c.fillPath()
    if !k.small {
        c.addPath(slot)
        c.setLineJoin(.round)
        c.setStrokeColor(colour(0x2b2820))
        c.setLineWidth(2.5)
        c.strokePath()
        let mid = (t0 + t1) / 2
        c.setStrokeColor(colour(0x47443a))
        c.setLineWidth(2.5)
        c.strokeLineSegments(between: [e0 + tall * mid + CGPoint(x: 0, y: 12), e1 + tall * mid + CGPoint(x: 0, y: -12)])
    }

    // The top: champagne gold, lighter to the left and far side, brushed along its length.
    let flat = polygon(k.flat), nose = polygon(n)
    shade(c, flat, gradient([(0xf3e9c2, 0), (0xe3d5a3, 0.5), (0xcdbd85, 1)]), from: k.top(ch, 0), to: k.top(L, W))
    shade(c, nose, gradient([(0xd9c993, 0), (0xc4b37b, 1)]), from: n[0], to: n[2])
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        colour(0xffffff, 0), colour(0xffffff, 0.24), colour(0xffffff, 0)] as CFArray, locations: [0.28, 0.45, 0.62])!
    shade(c, flat, sheen, from: k.top(ch + L * 0.1, 0), to: k.top(L * 0.8, W))
    if !k.small {
        c.saveGState()
        c.addPath(flat)
        c.addPath(nose)
        c.clip()
        var seed: UInt64 = 0x2545f4914f6cdd1d
        func random() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(1 << 31)
        }
        for _ in 0..<900 {
            let w = random() * W, u0 = random() * L - 100, run = 60 + random() * L * 0.7
            c.setStrokeColor(random() < 0.5 ? colour(0xffffff, 0.04 + random() * 0.08) : colour(0x6b5a28, 0.02 + random() * 0.05))
            c.setLineWidth(0.5 + random() * 1.1)
            c.strokeLineSegments(between: [k.top(u0, w), k.top(u0 + run, w)])
        }
        c.restoreGState()
    }

    // The engraving, on the flat top, reading away from the connector as on the real card. The
    // small lines only where they stay legible; the word alone, a little larger, at 64 and 128 px.
    if k.pixels >= 64 {
        let detailed = k.pixels >= 256
        let big: CGFloat = detailed ? 170 : 186, font = "AvenirNext-DemiBold"
        let word = advance("a-card", font: font, size: big, tracking: -2)
        let left = ch + (L - ch - word) / 2 + 6
        let baseline: CGFloat = detailed ? W * 0.53 : W * 0.6
        engrave(c, k, "a-card", font: font, size: big, at: left, baseline, tracking: -2)
        if detailed {
            let gb = advance("80 GB", font: "AvenirNext-Bold", size: 34, tracking: 1)
            engrave(c, k, "MEMORY CARTRIDGE", font: "AvenirNext-DemiBold", size: 24, at: left + 8, baseline + 66, tracking: 2.5)
            engrave(c, k, "80 GB", font: "AvenirNext-Bold", size: 34, at: left + word - gb - 4, baseline + 68, tracking: 1)
        }
    }

    // Crisp edges: the crease, the lit rim where the top turns down, then a fine dark outline.
    c.setLineJoin(.round)
    c.setLineCap(.round)
    c.setStrokeColor(colour(0x8a7a45, 0.7))
    c.setLineWidth(k.small ? 0.5 / k.scale : 2)
    c.strokeLineSegments(between: [n[0], n[1]])
    c.setStrokeColor(colour(0xfff8de, 0.95))
    c.setLineWidth(k.small ? 0.6 / k.scale : 3)
    c.addLines(between: [n[3], n[2], n[1], k.top(L, W)])
    c.strokePath()
    c.setStrokeColor(colour(0x3a3115, 0.6))
    c.setLineWidth(k.small ? 0.7 / k.scale : 2.5)
    c.addPath(k.outline)
    c.strokePath()
}

func png(size: Int) -> Data {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.translateBy(x: 0, y: CGFloat(size))
    c.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
    draw(c, Cartridge(pixels: size))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, c.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

// An .iconset with every size macOS uses, turned into the .icns by iconutil.
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
