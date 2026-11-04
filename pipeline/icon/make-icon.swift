// Draws the ACam app icon: a television test card with colour bars, in the style of the Philips
// PM5544 (white grid on black, a large circle with grey squares, a rainbow, colour bars, gratings,
// grey steps), filling the macOS rounded square. Drawn on a 520 x 520 card, y pointing down.
//
//   cd pipeline/icon && /Library/Developer/CommandLineTools/usr/bin/swiftc -sdk \
//     /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk make-icon.swift -o /tmp/make-icon && \
//     /tmp/make-icon ../Sources/ACamApp/AppIcon.icns
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func fill(_ c: CGContext, _ hex: UInt32, _ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
    c.setFillColor(colour(hex))
    c.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
}

/// Vertical lines `pitch` apart (half white, half black) between x0 and x1: a grating.
func grating(_ c: CGContext, _ x0: CGFloat, _ x1: CGFloat, _ y0: CGFloat, _ y1: CGFloat, pitch: CGFloat,
             light: UInt32 = 0xffffff, dark: UInt32 = 0x000000) {
    fill(c, dark, x0, y0, x1, y1)
    var x = x0
    while x < x1 {
        fill(c, light, x, y0, min(x + pitch / 2, x1), y1)
        x += pitch
    }
}

/// The card, 520 x 520.
func card(_ c: CGContext) {
    fill(c, 0x000000, 0, 0, 520, 520)
    // White grid, a line every 40.
    for k in 0...13 {
        let p = 1.5 + CGFloat(k) * 40
        fill(c, 0xdcdcdc, p - 2, 0, p + 2, 520)
        fill(c, 0xdcdcdc, 0, p - 2, 520, p + 2)
    }

    // Inside the circle.
    c.saveGState()
    c.addEllipse(in: CGRect(x: 21, y: 19, width: 480, height: 480))
    c.clip()
    // Top: white, with a black block in the middle.
    fill(c, 0xffffff, 0, 0, 520, 80)
    fill(c, 0x000000, 181, 40, 342, 80)
    // Fine gratings under it.
    grating(c, 143, 249, 80, 120, pitch: 4, light: 0xbdbdbd, dark: 0x5a5a5a)
    grating(c, 249, 279, 80, 120, pitch: 2.5, light: 0xbdbdbd, dark: 0x5a5a5a)
    grating(c, 279, 381, 80, 120, pitch: 3, light: 0xbdbdbd, dark: 0x5a5a5a)
    // Grey squares on black.
    fill(c, 0x000000, 0, 120, 520, 158)
    for (x0, x1) in [(66, 92), (121, 147), (177, 203), (236, 262), (290, 316), (347, 373), (405, 431), (459, 485)] {
        fill(c, 0xc1bfc2, CGFloat(x0), 122, CGFloat(x1), 156)
    }
    // Rainbow.
    let stops: [(CGFloat, UInt32)] = [(40, 0xc8323a), (90, 0xd7913b), (120, 0xe8d64b), (150, 0xd6f351), (180, 0x93da46),
                                      (210, 0x60c43c), (270, 0x59b393), (300, 0x5eb0da), (330, 0x5487de), (360, 0x3c47b5),
                                      (390, 0x2b0d8a), (450, 0x8b1a87), (490, 0xb0288c)]
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { colour($0.1) } as CFArray,
                              locations: stops.map { ($0.0 - 21) / 480 })!
    c.saveGState()
    c.clip(to: CGRect(x: 0, y: 158, width: 520, height: 39))
    c.drawLinearGradient(gradient, start: CGPoint(x: 21, y: 0), end: CGPoint(x: 501, y: 0),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
    // Colour bars.
    for (x0, x1, hex) in [(0, 102, 0xfaf260), (102, 182, 0x9192be), (182, 242, 0x73d64d), (242, 282, 0x000000),
                          (282, 342, 0xc8598e), (342, 420, 0xe0392d), (420, 520, 0x422d76)] as [(CGFloat, CGFloat, UInt32)] {
        fill(c, hex, x0, 197, x1, 241)
    }
    // Black band with the horizontal centre line.
    fill(c, 0x000000, 0, 241, 520, 281)
    fill(c, 0xe6e6e6, 0, 258, 520, 261)
    // Gratings: white on the left, finer to the middle; grey on the right.
    fill(c, 0x000000, 0, 281, 520, 361)
    grating(c, 84, 137, 281, 361, pitch: 7)
    grating(c, 137, 190, 281, 361, pitch: 5)
    grating(c, 190, 242, 281, 361, pitch: 3.5)
    grating(c, 282, 335, 281, 361, pitch: 3.5, light: 0xa8a8a8, dark: 0x3c3c3c)
    grating(c, 335, 388, 281, 361, pitch: 5, light: 0xa8a8a8, dark: 0x3c3c3c)
    grating(c, 388, 441, 281, 361, pitch: 7, light: 0xa8a8a8, dark: 0x3c3c3c)
    // Grey steps, black to white.
    for (x0, x1, hex) in [(0, 102, 0x000000), (102, 182, 0x363336), (182, 262, 0x686868), (262, 342, 0x999999),
                          (342, 422, 0xcecccf), (422, 520, 0xffffff)] as [(CGFloat, CGFloat, UInt32)] {
        fill(c, hex, x0, 361, x1, 400)
    }
    // White band with a black block.
    fill(c, 0xffffff, 0, 400, 520, 440)
    fill(c, 0x000000, 141, 400, 382, 440)
    // Bottom: blue, red, green.
    fill(c, 0x000000, 0, 440, 520, 520)
    fill(c, 0x2e6bf6, 141, 440, 241, 520)
    fill(c, 0xe0382d, 241, 440, 281, 520)
    fill(c, 0x366a32, 281, 440, 381, 520)
    // The centre: a black bar with a white edge and a white line, across the bars and gratings.
    fill(c, 0xffffff, 238, 197, 286, 326)
    fill(c, 0x000000, 242, 201, 282, 322)
    fill(c, 0xffffff, 260, 197, 263, 326)
    c.restoreGState()
}

/// The icon on a 1024 x 1024 canvas, y pointing down: the card in the macOS rounded square.
func draw(_ c: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 10), blur: 22, color: colour(0x000000, 0.35))
    c.addPath(shape)
    c.setFillColor(colour(0x000000))
    c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(shape)
    c.clip()
    c.translateBy(x: tile.minX, y: tile.minY)
    c.scaleBy(x: tile.width / 520, y: tile.height / 520)
    card(c)
    c.restoreGState()
    // A faint edge, so the black square stands out on a dark background.
    c.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    c.setStrokeColor(colour(0xffffff, 0.18))
    c.setLineWidth(3)
    c.strokePath()
}

func png(size: Int) -> Data {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.translateBy(x: 0, y: CGFloat(size))
    c.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
    draw(c)
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
