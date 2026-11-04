// Ikonoskop's typeface. ikonoskop.com (2009-2013, css/ikonoskop-screen.css: "Arial, Helvetica,
// sans-serif" for text and headings) and the A-Cam dII user guide are set in Helvetica, which
// every Mac has. The brochures' News Gothic is a commercial font and is not bundled. Section labels
// follow the brochures: capitals, spaced out.
import SwiftUI

enum Brand {
    static let family = "Helvetica Neue"

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(family, size: size).weight(weight)
    }

    static let body = font(13)
    static let caption = font(11)
    static let heading = font(13, weight: .bold)
    static let title = font(22, weight: .bold)

    /// "DESTINATION": a section label in the left column.
    static func label(_ text: String) -> some View {
        Text(text.uppercased()).font(font(11, weight: .bold)).tracking(1.5).foregroundColor(.secondary)
    }
}
