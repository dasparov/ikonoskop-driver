// Draws the ACam app icon: the A-Cam dII seen from its right side, as on Ikonoskop's product
// sheet (2013): the long milled body with its side screen, connectors and red button, the grey
// eyecup above it and a cine lens on the IMS mount, on a light rounded square.
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

/// A vertical gradient over `rect` through `stops` (position 0 = top).
func fillVertical(_ c: CGContext, _ path: CGPath, _ rect: CGRect, _ stops: [(CGFloat, UInt32)]) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: stops.map { colour($0.1) } as CFArray, locations: stops.map { $0.0 })!
    c.saveGState()
    c.addPath(path)
    c.clip()
    c.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// A lens or mount section seen from the side: lit from above like a cylinder.
func cylinder(_ c: CGContext, x: CGFloat, width: CGFloat, axis: CGFloat, height: CGFloat, radius: CGFloat = 6,
              base: UInt32 = 0x161618, light: UInt32 = 0x3c3c41) {
    let r = CGRect(x: x, y: axis - height / 2, width: width, height: height)
    fillVertical(c, rounded(r, radius), r, [(0, base), (0.22, light), (0.5, base), (0.9, 0x0c0c0e), (1, 0x1e1e21)])
}

/// Thin vertical lines across a section: knurling or the gear teeth of a focus ring.
func stripes(_ c: CGContext, x: CGFloat, width: CGFloat, axis: CGFloat, height: CGFloat, step: CGFloat, hex: UInt32) {
    c.saveGState()
    c.addPath(rounded(CGRect(x: x, y: axis - height / 2, width: width, height: height), 6))
    c.clip()
    c.setStrokeColor(colour(hex, 0.9))
    c.setLineWidth(step * 0.4)
    var px = x + step / 2
    while px < x + width {
        c.move(to: CGPoint(x: px, y: axis - height / 2))
        c.addLine(to: CGPoint(x: px, y: axis + height / 2))
        px += step
    }
    c.strokePath()
    c.restoreGState()
}

/// The icon on a 1024 x 1024 canvas, y pointing down.
func draw(_ c: CGContext) {
    // Background: the macOS rounded square, light like the product sheet's paper, with its shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 10), blur: 22, color: colour(0x000000, 0.28))
    c.addPath(rounded(tile, 185))
    c.setFillColor(colour(0xe9e6e0))
    c.fillPath()
    c.restoreGState()
    fillVertical(c, rounded(tile, 185), tile, [(0, 0xf7f5f1), (1, 0xd8d3ca)])

    let axis: CGFloat = 556
    let top: CGFloat = 461, bottom: CGFloat = 651
    let rear: CGFloat = 150, front: CGFloat = 610

    // Shadow on the ground.
    let ground = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                            colors: [colour(0x000000, 0.30), colour(0x000000, 0)] as CFArray, locations: [0, 1])!
    c.saveGState()
    c.translateBy(x: 515, y: 702)
    c.scaleBy(x: 1, y: 0.07)
    c.drawRadialGradient(ground, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 380, options: [])
    c.restoreGState()

    // Eyecup: grey rubber rising above the body, steep at the back, sloping toward the lens.
    let cup = CGMutablePath()
    cup.move(to: CGPoint(x: 322, y: top + 6))
    cup.addCurve(to: CGPoint(x: 372, y: top - 78), control1: CGPoint(x: 318, y: top - 40), control2: CGPoint(x: 336, y: top - 74))
    cup.addCurve(to: CGPoint(x: 492, y: top + 6), control1: CGPoint(x: 420, y: top - 84), control2: CGPoint(x: 480, y: top - 46))
    cup.closeSubpath()
    let cupBox = CGRect(x: 318, y: top - 84, width: 176, height: 90)
    fillVertical(c, cup, cupBox, [(0, 0xb3b7bc), (0.45, 0x989ca1), (1, 0x75797e)])
    c.saveGState()
    c.addPath(cup)
    c.clip()
    c.setStrokeColor(colour(0xffffff, 0.35))
    c.setLineWidth(4)
    c.move(to: CGPoint(x: 336, y: top - 40))
    c.addCurve(to: CGPoint(x: 430, y: top - 66), control1: CGPoint(x: 350, y: top - 70), control2: CGPoint(x: 400, y: top - 76))
    c.strokePath()
    c.restoreGState()

    // Body: milled aluminium, black. The rear part is a little shallower than the front block,
    // with a sloping step between them, as on the camera.
    let step: CGFloat = bottom - 22
    let body = CGMutablePath()
    let r: CGFloat = 24
    body.move(to: CGPoint(x: rear + r, y: top))
    body.addLine(to: CGPoint(x: front - r, y: top))
    body.addArc(tangent1End: CGPoint(x: front, y: top), tangent2End: CGPoint(x: front, y: top + r), radius: r)
    body.addLine(to: CGPoint(x: front, y: bottom - r))
    body.addArc(tangent1End: CGPoint(x: front, y: bottom), tangent2End: CGPoint(x: front - r, y: bottom), radius: r)
    body.addLine(to: CGPoint(x: 492, y: bottom))
    body.addCurve(to: CGPoint(x: 440, y: step), control1: CGPoint(x: 470, y: bottom), control2: CGPoint(x: 462, y: step))
    body.addLine(to: CGPoint(x: rear + r, y: step))
    body.addArc(tangent1End: CGPoint(x: rear, y: step), tangent2End: CGPoint(x: rear, y: step - r), radius: r)
    body.addLine(to: CGPoint(x: rear, y: top + r))
    body.addArc(tangent1End: CGPoint(x: rear, y: top), tangent2End: CGPoint(x: rear + r, y: top), radius: r)
    body.closeSubpath()
    let whole = CGRect(x: rear, y: top, width: front - rear, height: bottom - top)
    fillVertical(c, body, whole, [(0, 0x34343a), (0.08, 0x232326), (0.6, 0x161618), (1, 0x0b0b0c)])
    // Connector block under the rear, with the three Lemo sockets.
    let connectors = CGRect(x: 190, y: step - 8, width: 118, height: 40)
    fillVertical(c, rounded(connectors, 10), connectors, [(0, 0x1d1d20), (1, 0x0c0c0d)])
    for i in 0..<3 {
        let centre = CGPoint(x: connectors.minX + 27 + CGFloat(i) * 32, y: connectors.midY + 2)
        c.setFillColor(colour(0x0a0a0b))
        c.fillEllipse(in: CGRect(x: centre.x - 13, y: centre.y - 13, width: 26, height: 26))
        c.setStrokeColor(colour(0xc4c7cb))
        c.setLineWidth(4)
        c.strokeEllipse(in: CGRect(x: centre.x - 11, y: centre.y - 11, width: 22, height: 22))
    }
    // Top edge highlight and the seam in front of the step.
    c.setStrokeColor(colour(0x6a6a70, 0.8))
    c.setLineWidth(3)
    c.move(to: CGPoint(x: rear + 22, y: top + 2.5))
    c.addLine(to: CGPoint(x: front - 22, y: top + 2.5))
    c.strokePath()
    c.setStrokeColor(colour(0x000000, 0.55))
    c.setLineWidth(4)
    c.move(to: CGPoint(x: 474, y: top + 10))
    c.addLine(to: CGPoint(x: 474, y: bottom - 10))
    c.strokePath()
    c.setStrokeColor(colour(0x47474c, 0.7))
    c.setLineWidth(2)
    c.move(to: CGPoint(x: 478, y: top + 10))
    c.addLine(to: CGPoint(x: 478, y: bottom - 10))
    c.strokePath()
    // Side screen, with a reflection.
    let screen = CGRect(x: 200, y: 498, width: 76, height: 70)
    fillVertical(c, rounded(screen, 7), screen, [(0, 0x52677a), (1, 0x223039)])
    c.saveGState()
    c.addPath(rounded(screen, 7))
    c.clip()
    c.setFillColor(colour(0xffffff, 0.14))
    c.move(to: CGPoint(x: screen.minX, y: screen.minY))
    c.addLine(to: CGPoint(x: screen.minX + 52, y: screen.minY))
    c.addLine(to: CGPoint(x: screen.minX, y: screen.minY + 50))
    c.fillPath()
    c.restoreGState()
    c.setStrokeColor(colour(0x050506))
    c.setLineWidth(5)
    c.addPath(rounded(screen.insetBy(dx: -4, dy: -4), 10))
    c.strokePath()
    // Red button on top, at the back.
    let button = CGRect(x: 230, y: top - 13, width: 44, height: 17)
    fillVertical(c, rounded(button, 5), button, [(0, 0xff4a5b), (1, 0xc41a2e)])

    // IMS mount, knurled.
    cylinder(c, x: front - 4, width: 46, axis: axis, height: 172)
    stripes(c, x: front + 2, width: 36, axis: axis, height: 172, step: 7, hex: 0x2c2c30)
    // Cine prime: rear barrel, blue band, aperture ring, focus gear, front barrel.
    cylinder(c, x: 650, width: 44, axis: axis, height: 150)
    cylinder(c, x: 692, width: 52, axis: axis, height: 192)
    c.setFillColor(colour(0x2f6fd6))
    c.fill(CGRect(x: 694, y: axis - 92, width: 7, height: 184))
    cylinder(c, x: 742, width: 62, axis: axis, height: 218)
    stripes(c, x: 744, width: 58, axis: axis, height: 218, step: 6, hex: 0x2b2b2f)
    cylinder(c, x: 802, width: 80, axis: axis, height: 238, radius: 10, base: 0x18181a, light: 0x45454b)
    // Distance and stop markings, yellow-green as on the lens in the product sheet.
    c.setFillColor(colour(0xc6dd4a))
    for (i, y) in stride(from: axis - 70, through: axis + 70, by: 20).enumerated() {
        c.fill(CGRect(x: 708, y: y, width: i % 2 == 0 ? 18 : 11, height: 4))
        c.fill(CGRect(x: 818, y: y + 8, width: i % 2 == 0 ? 26 : 15, height: 4))
    }
    // Front rim.
    let rim = CGRect(x: 872, y: axis - 119, width: 12, height: 238)
    fillVertical(c, rounded(rim, 5), rim, [(0, 0x55555b), (0.5, 0x232326), (1, 0x3a3a3f)])
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
