// A camera colour profile chosen in Phase 5 (pipeline/colour/profiles/<id>/): the matrices the
// clean DNGs carry, plus the files copied next to the footage (DCP, ACES IDTs, OpenColorIO).
import Foundation

struct ColourProfile: Decodable {
    let id: String
    let name: String
    let calibrationIlluminant1: UInt16
    let calibrationIlluminant2: UInt16
    /// Row-major 3x3, XYZ to camera (DNG ColorMatrix).
    let colorMatrix1: [Double]
    let colorMatrix2: [Double]
    /// Row-major 3x3, camera to XYZ D50 (DNG ForwardMatrix); none for the factory profile.
    let forwardMatrix1: [Double]?
    let forwardMatrix2: [Double]?

    private enum CodingKeys: String, CodingKey {
        case id, name, calibrationIlluminant1, calibrationIlluminant2, colorMatrix1, colorMatrix2
        case forwardMatrix1, forwardMatrix2
    }

    /// Reads <folder>/profile.json.
    static func load(_ folder: URL) throws -> (profile: ColourProfile, folder: URL) {
        let profile = try JSONDecoder().decode(ColourProfile.self,
                                               from: Data(contentsOf: folder.appendingPathComponent("profile.json")))
        for m in [profile.colorMatrix1, profile.colorMatrix2] + [profile.forwardMatrix1, profile.forwardMatrix2].compactMap({ $0 })
            where m.count != 9 {
            throw TIFFError("\(folder.path)/profile.json: a matrix does not have 9 numbers")
        }
        return (profile, folder)
    }

    /// The DNG tags it sets, as SRATIONAL n/10000 (the precision the matrices are given in).
    var fields: [TIFFField] {
        func matrix(_ tag: UInt16, _ m: [Double]) -> TIFFField {
            .srational(tag, m.map { (Int32(($0 * 10_000).rounded()), 10_000) })
        }
        var f = [matrix(DNGTag.colorMatrix1, colorMatrix1), matrix(DNGTag.colorMatrix2, colorMatrix2),
                 .short(DNGTag.calibrationIlluminant1, [calibrationIlluminant1]),
                 .short(DNGTag.calibrationIlluminant2, [calibrationIlluminant2]),
                 .ascii(DNGTag.profileName, name)]
        if let m = forwardMatrix1 {
            f.append(matrix(DNGTag.forwardMatrix1, m))
        }
        if let m = forwardMatrix2 {
            f.append(matrix(DNGTag.forwardMatrix2, m))
        }
        return f
    }

    /// Tags the profile replaces in a clean DNG.
    static let tags: Set<UInt16> = [DNGTag.colorMatrix1, DNGTag.colorMatrix2, DNGTag.calibrationIlluminant1,
                                    DNGTag.calibrationIlluminant2, DNGTag.forwardMatrix1, DNGTag.forwardMatrix2,
                                    DNGTag.profileName]
}
