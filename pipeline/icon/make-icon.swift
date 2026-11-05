// Draws the a-card app icon: the A-Cam dII memory card seen from above, as in Ikonoskop's product
// photos. Black anodised aluminium; the connector end (left, where the arrow points) is square with
// its back corner cut off, the far end slants outwards towards the front. Bevels run along the back,
// the far end and the front; the cut corner is a triangular facet, and the sloping nose is a lighter
// trapezoid behind a diagonal crease. The red write-protect slider sits between its locked and
// unlocked padlocks. "a-card" is written in the letters of the card's "a-cam" logo, traced from a
// photo: hollow, outlined in thin white lines. Transparent around it, with a soft drop shadow. Drawn
// on a 1024 x 1024 canvas, y pointing down; less detail at small sizes, small print from 256 px.
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

/// The memory card for one icon size, on the 1024 canvas. The card lies flat and is seen from
/// straight above, tilted just enough to show its front edge. Plan coordinates: u runs along the
/// card from the connector end (left) to the far end, w across it from the back edge to the front.
/// The proportions are measured from a straight-on photo of the card.
struct Card {
    let pixels: Int
    /// Device pixels per canvas unit, for shadows and hairlines, which do not follow the CTM.
    var scale: CGFloat { CGFloat(pixels) / 1024 }
    var tiny: Bool { pixels <= 32 }

    /// The length along the front edge; the far end slants, so the card is shorter along the back.
    let length: CGFloat = 824, backLength: CGFloat = 800, width: CGFloat = 500
    /// The view's foreshortening across the card, and the front edge's height on screen.
    let squash: CGFloat = 0.93, thickness: CGFloat = 28
    /// The back corner at the connector end is cut off: this far along the card, this far across.
    let cutAlong: CGFloat = 203, cutAcross: CGFloat = 135
    /// The bevel along the back edge, the narrower ones along the front edge and the far end.
    var backBevel: CGFloat { width * (tiny ? 0.15 : 0.12) }
    var frontBevel: CGFloat { width * 0.035 }
    let endBevel: CGFloat = 12
    /// The crease between the sloping nose and the flat top runs diagonally, from where the cut
    /// corner's facet meets the back bevel down and back towards the connector end.
    let creaseTop = CGPoint(x: 189.5, y: 87), creaseFoot: CGFloat = 108.8
    var origin: CGPoint {
        CGPoint(x: (1024 - length) / 2, y: (1024 - width * squash - thickness) / 2 - 14)
    }

    /// Where the slanting far end is, at a given distance across the card.
    func end(_ w: CGFloat) -> CGFloat { backLength + (length - backLength) * w / width }

    /// The outline seen from above with the front edge below it, clockwise from the cut corner.
    var outline: CGPath {
        let t = thickness / squash
        return polygon([CGPoint(x: cutAlong, y: 0), CGPoint(x: backLength, y: 0), CGPoint(x: length, y: width),
                        CGPoint(x: length, y: width + t), CGPoint(x: 0, y: width + t), CGPoint(x: 0, y: cutAcross)])
    }
}

func p(_ u: CGFloat, _ w: CGFloat) -> CGPoint { CGPoint(x: u, y: w) }

func fill(_ c: CGContext, _ path: CGPath, _ g: CGGradient, from a: CGPoint, to b: CGPoint) {
    c.saveGState()
    c.addPath(path)
    c.clip()
    c.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
}

func line(_ text: String, _ font: CTFont, tracking: CGFloat, _ fill: CGColor) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill,
        NSAttributedString.Key(kCTKernAttributeName as String): tracking,
    ]))
}

/// The width of a line of text, without the kern after its last letter.
func advance(_ text: String, _ font: CTFont, tracking: CGFloat = 0) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(line(text, font, tracking: tracking, colour(0)), nil, nil, nil)) - tracking
}

/// White print on the card, its baseline starting at (u, w).
func print(_ c: CGContext, _ text: String, _ font: CTFont, at u: CGFloat, _ w: CGFloat, tracking: CGFloat = 0) {
    c.saveGState()
    c.translateBy(x: u, y: w)
    c.scaleBy(x: 1, y: -1)
    c.textMatrix = .identity
    c.textPosition = .zero
    CTLineDraw(line(text, font, tracking: tracking, colour(0xf1f1ee)), c)
    c.restoreGState()
}

/// A closed polygon whose corners are cut back by their own amounts: (x, y, cut).
func chamfered(_ corners: [(CGFloat, CGFloat, CGFloat)], into path: CGMutablePath, _ t: CGAffineTransform) {
    let n = corners.count
    for i in 0..<n {
        let (x, y, cut) = corners[i]
        let (px, py, _) = corners[(i + n - 1) % n], (nx, ny, _) = corners[(i + 1) % n]
        func toward(_ ax: CGFloat, _ ay: CGFloat) -> CGPoint {
            let len = hypot(ax - x, ay - y)
            return CGPoint(x: x + (ax - x) * cut / len, y: y + (ay - y) * cut / len).applying(t)
        }
        let a = toward(px, py), b = toward(nx, ny)
        if i == 0 { path.move(to: a) } else { path.addLine(to: a) }
        if cut > 0 { path.addLine(to: b) }
    }
    path.closeSubpath()
}

/// "a-card" in the letters of the card's "a-cam dII" logo, traced from a straight-on photo of the
/// card in its pixels (x-height 47.9, y down from the top of the letters; 306 wide). a, - and c are
/// the logo's own; r is the logo's m cut after its first arch, ending like the c's upper arm; d is
/// the logo's d (bowl on the lower three fifths, stem to the top) drawn at the weight of a-cam.
func lettering(_ t: CGAffineTransform) -> CGPath {
    let path = CGMutablePath()
    let co: CGFloat = 10.5, ci: CGFloat = 3.5, ch: CGFloat = 2.5  // outer, inner and counter corner cuts
    let y1: CGFloat = 10.1, y2: CGFloat = 19.7, y3: CGFloat = 29.5, y4: CGFloat = 38.7, y5: CGFloat = 47.9
    for x in [0, 151] as [CGFloat] {                    // a, twice
        chamfered([(x + 12.3, 0, 0), (x + 57.1, 0, co), (x + 57.1, y5, co), (x, y5, co), (x, y2, co),
                   (x + 45.9, y2, ci), (x + 45.9, y1, ci), (x + 12.3, y1, 0)], into: path, t)
        chamfered([(x + 12.3, y3, ch), (x + 45.9, y3, ch), (x + 45.9, y4, ch), (x + 12.3, y4, ch)], into: path, t)
    }
    chamfered([(62.8, y2, 1.5), (84.9, y2, 1.5), (84.9, y3, 1.5), (62.8, y3, 1.5)], into: path, t)
    chamfered([(89.4, 0, co), (146.9, 0, co), (146.9, y2, ci), (135.4, y2, ci), (135.4, y1, ci), (100.9, y1, ci),
               (100.9, y4, ci), (135.4, y4, ci), (135.4, y3, ci), (146.9, y3, ci), (146.9, y5, co), (89.4, y5, co)],
              into: path, t)
    chamfered([(213.1, 0, co), (249.9, 0, co), (249.9, y2, ci), (238.9, y2, ci), (238.9, y1, ci), (224.9, y1, ci),
               (224.9, y5, 0), (213.1, y5, 0)], into: path, t)
    chamfered([(294.8, 0, 0), (306, 0, 0), (306, y5, 0), (254.1, y5, co), (254.1, y2, co), (294.8, y2, ci)],
              into: path, t)
    chamfered([(266.5, y3, ch), (294.8, y3, ch), (294.8, y4, ch), (266.5, y4, ch)], into: path, t)
    return path
}

/// A padlock, white, centred on (u, w) and `size` tall; open with its shackle lifted to one side.
func padlock(_ c: CGContext, at u: CGFloat, _ w: CGFloat, size: CGFloat, open: Bool) {
    let bodyW = size * 0.78, bodyH = size * 0.56
    let body = CGRect(x: u - bodyW / 2, y: w + size / 2 - bodyH, width: bodyW, height: bodyH)
    c.addPath(CGPath(roundedRect: body, cornerWidth: size * 0.08, cornerHeight: size * 0.08, transform: nil))
    c.setFillColor(colour(0xf1f1ee))
    c.fillPath()
    let r = bodyW * 0.3, stroke = size * 0.13
    let cx = open ? u + bodyW * 0.42 : u
    let shackle = CGMutablePath()
    shackle.move(to: p(cx - r, body.minY + stroke))
    shackle.addLine(to: p(cx - r, body.minY - size * 0.18))
    shackle.addArc(center: p(cx, body.minY - size * 0.18), radius: r, startAngle: .pi, endAngle: 0, clockwise: false)
    shackle.addLine(to: p(cx + r, open ? body.minY - size * 0.12 : body.minY + stroke))
    c.addPath(shackle)
    c.setStrokeColor(colour(0xf1f1ee))
    c.setLineWidth(stroke)
    c.setLineCap(.butt)
    c.strokePath()
}

/// The icon on a 1024 x 1024 canvas, y pointing down: the card, transparent around it.
func draw(_ c: CGContext, _ k: Card) {
    let L = k.length, W = k.width, cu = k.cutAlong, cw = k.cutAcross, b = k.backBevel, f = k.frontBevel
    let t = k.thickness / k.squash, e = k.endBevel, ct = k.creaseTop
    c.translateBy(x: k.origin.x, y: k.origin.y)
    c.scaleBy(x: 1, y: k.squash)

    // A soft drop shadow, and a tighter one where it rests.
    for (offset, blur, alpha) in [(28 as CGFloat, 48 as CGFloat, 0.42 as CGFloat), (8, 10, 0.35)] {
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -offset * k.scale), blur: blur * k.scale, color: colour(0x000000, alpha))
        c.addPath(k.outline)
        c.setFillColor(colour(0x101012))
        c.fillPath()
        c.restoreGState()
    }

    // The front edge: two black halves with the seam between them.
    let edge = polygon([p(0, W), p(L, W), p(L, W + t), p(0, W + t)])
    fill(c, edge, gradient([(0x232427, 0), (0x0b0b0c, 1)]), from: p(0, W), to: p(0, W + t))
    c.setStrokeColor(colour(0x34353a))
    c.setLineWidth(k.tiny ? 0.6 / k.scale : 2.5)
    c.strokeLineSegments(between: [p(0, W + t * 0.52), p(L, W + t * 0.52)])

    // The top: black anodised aluminium, its facets catching the light differently. The bevels
    // along the back, the far end and the front meet at mitres; the sloping nose is a trapezoid.
    let backInner = p(k.end(b) - e, b), frontInner = p(k.end(W - f) - e, W - f)
    let foot = p(k.creaseFoot, W - f), shoulder = p(ct.x + b * 0.49, b)
    let main = polygon([ct, shoulder, backInner, frontInner, foot])
    let nose = polygon([p(0, cw), ct, foot, p(0, W - f)])
    let corner = polygon([p(0, cw), p(cu, 0), ct])
    let back = polygon([p(cu, 0), p(k.backLength, 0), backInner, shoulder, ct])
    let far = polygon([p(k.backLength, 0), p(L, W), frontInner, backInner])
    let front = polygon([p(0, W - f), frontInner, p(L, W), p(0, W)])
    fill(c, main, gradient([(0x2a2b2e, 0), (0x1c1d1f, 0.55), (0x18191b, 1)]), from: ct, to: p(L, W))
    fill(c, nose, gradient([(0x505156, 0), (0x3a3b3f, 1)]), from: p(0, cw), to: foot)
    fill(c, corner, gradient([(0x45464b, 0), (0x2c2d31, 1)]), from: p(0, cw), to: p(cu, 0))
    fill(c, back, gradient([(0x55565b, 0), (0x3a3b3f, 0.5), (0x2b2c2f, 1)]), from: p(cu, 0), to: p(L, b))
    fill(c, far, gradient([(0x1a1b1d, 0), (0x111213, 1)]), from: p(k.backLength, 0), to: p(L, W))
    fill(c, front, gradient([(0x3d3e42, 0), (0x2a2b2e, 1)]), from: p(0, W - f), to: p(L, W))
    // A broad soft sheen across the flat top.
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        colour(0xffffff, 0), colour(0xffffff, 0.07), colour(0xffffff, 0)] as CFArray, locations: [0.2, 0.42, 0.64])!
    fill(c, main, sheen, from: ct, to: p(L, W))

    // Crisp creases between the facets, light where an edge faces the light.
    c.setLineCap(.round)
    c.setLineJoin(.round)
    let hair: CGFloat = k.tiny ? 0.5 / k.scale : 2
    c.setLineWidth(hair)
    c.setStrokeColor(colour(0x0c0c0d, 0.8))
    c.addLines(between: [p(0, cw), ct, shoulder, backInner, frontInner])
    c.strokePath()
    c.strokeLineSegments(between: [ct, foot, ct, p(cu, 0)])
    c.setStrokeColor(colour(0x6e6f74, 0.9))
    c.strokeLineSegments(between: [p(0, W - f), frontInner])

    // The write-protect switch: a red slider in a black recess, padlocks either side.
    let su = L * 0.53, sw = W * 0.3
    let rw = L * (k.tiny ? 0.16 : 0.12), rh = W * (k.tiny ? 0.24 : 0.18)
    let recess = CGRect(x: su - rw / 2, y: sw - rh / 2, width: rw, height: rh)
    c.addPath(CGPath(roundedRect: recess, cornerWidth: rh * 0.38, cornerHeight: rh * 0.38, transform: nil))
    c.setFillColor(colour(0x050506))
    c.fillPath()
    if !k.tiny {
        // Its lit lower lip.
        c.saveGState()
        c.addPath(CGPath(roundedRect: recess, cornerWidth: rh * 0.38, cornerHeight: rh * 0.38, transform: nil))
        c.clip()
        c.addPath(CGPath(roundedRect: recess.offsetBy(dx: 0, dy: -5), cornerWidth: rh * 0.38, cornerHeight: rh * 0.38, transform: nil))
        c.setStrokeColor(colour(0x5a5b60))
        c.setLineWidth(6)
        c.strokePath()
        c.restoreGState()
    }
    let sliderW = rw * 0.46, sliderH = rh * 0.44
    let slider = CGRect(x: su - sliderW / 2, y: sw - sliderH / 2, width: sliderW, height: sliderH)
    let sliderPath = CGPath(roundedRect: slider, cornerWidth: sliderH * 0.14, cornerHeight: sliderH * 0.14, transform: nil)
    fill(c, sliderPath, gradient([(0xff5a4e, 0), (0xe8322b, 0.45), (0xb81f1a, 1)]), from: p(su, slider.minY), to: p(su, slider.maxY))
    if !k.tiny {
        c.setStrokeColor(colour(0xff9a90, 0.8))
        c.setLineWidth(2.5)
        c.strokeLineSegments(between: [p(slider.minX + 6, slider.minY + 3), p(slider.maxX - 6, slider.minY + 3)])
    }
    if k.pixels >= 128 {
        let lock = W * 0.075
        padlock(c, at: su - rw / 2 - lock * 0.95, sw + lock * 0.08, size: lock, open: false)
        padlock(c, at: su + rw / 2 + lock * 0.85, sw + lock * 0.08, size: lock, open: true)
    }

    // The arrow on the nose, pointing the way the card goes into the camera.
    if k.pixels >= 64 {
        let a = W * 0.035, au: CGFloat = 92, aw: CGFloat = 271
        c.addPath(polygon([p(au - a, aw), p(au + a * 0.8, aw - a), p(au + a * 0.8, aw + a)]))
        c.setFillColor(colour(0xf1f1ee))
        c.fillPath()
    }

    // The name where the card has its logo, in the logo's letters: hollow, outlined in thin white
    // lines as on the card from 256 px, filled below that, where the lines would be too thin.
    let left = L * 0.36, right = L * 0.9, baseline = W * 0.625
    if k.pixels >= 64 {
        let s = (right - left) / 306
        c.saveGState()
        c.scaleBy(x: 1, y: 1 / k.squash)   // draw the letters in screen proportions, as photographed
        let letters = lettering(CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: left, ty: baseline * k.squash - 47.9 * s))
        c.addPath(letters)
        if k.pixels >= 256 {
            c.setStrokeColor(colour(0xf1f1ee))
            c.setLineWidth(3.8 * s)
            c.setLineJoin(.round)
            c.strokePath()
        } else {
            c.setFillColor(colour(0xf1f1ee))
            c.fillPath(using: .evenOdd)
        }
        c.restoreGState()
    }
    if k.pixels >= 256 {
        // The capacity, boxed as on the card, and a line of small print up to it.
        let label = CTFontCreateWithName("AvenirNext-DemiBold" as CFString, 25, nil)
        let gb = advance("80GB", label, tracking: 0.5)
        let box = CGRect(x: right - gb - 18, y: W * 0.775 - 27, width: gb + 18, height: 34)
        c.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
        c.setStrokeColor(colour(0xf1f1ee))
        c.setLineWidth(2.2)
        c.strokePath()
        print(c, "80GB", label, at: box.minX + 9, W * 0.775, tracking: 0.5)
        let text = "CINEMA DIGITAL NEGATIVE RAW", unit = CTFontCreateWithName("AvenirNext-Medium" as CFString, 10, nil)
        let fit = 10 * (box.minX - 28 - left) / advance(text, unit, tracking: 0.5)
        let small = CTFontCreateWithName("AvenirNext-Medium" as CFString, fit, nil)
        print(c, text, small, at: left + 4, W * 0.775, tracking: fit * 0.05)
    }

    // A fine light rim, so the black card holds its shape on a dark background.
    c.addPath(k.outline)
    c.setStrokeColor(k.tiny ? colour(0xa4a5aa, 0.9) : colour(0x8a8b90, 0.55))
    c.setLineWidth(k.tiny ? 0.8 / k.scale : 2.5)
    c.strokePath()
}

func png(size: Int) -> Data {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.translateBy(x: 0, y: CGFloat(size))
    c.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
    draw(c, Card(pixels: size))
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
