// Frame previews for the ACam app: a camera DNG shown as its clean DNG looks in the Rec.709
// ProRes preview, in the chosen colour profile.
import CoreImage
import Foundation

enum FramePreview {
    /// `file` (a camera DNG, as on the card) made into its clean DNG with `profile`, developed like
    /// the Rec709 ProRes look, `width` pixels wide, in sRGB for the screen.
    static func image(ofOriginal file: Data, profile: ColourProfile?, width: Int, context: CIContext) throws -> CGImage {
        let raw = try ProResTake.develop(CleanDNG.make(fromOriginal: file, profile: profile).dng, look: .preview)
        raw.scaleFactor = Float(width) / Float(Raw12.width)
        guard var image = raw.outputImage else {
            throw TIFFError("Core Image cannot develop the DNG")
        }
        let scale = CGFloat(width) / image.extent.width
        if abs(scale - 1) > 0.001 {
            image = image.applyingFilter("CILanczosScaleTransform",
                                         parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        }
        guard let preview = context.createCGImage(image, from: image.extent.integral, format: .RGBA8,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw TIFFError("Core Image cannot render the preview")
        }
        return preview
    }
}
