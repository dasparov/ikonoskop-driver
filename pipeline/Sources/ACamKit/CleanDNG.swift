// acam clean: corrected, losslessly compressed copies of verified frames, in <take>/clean/.
//
// Changes from the camera's DNG: Make and Model added; one WhiteLevel instead of two; valid
// CalibrationIlluminant codes; BaselineExposure 0; the image tiled and lossless-JPEG compressed
// (Compression 7, as Adobe DNG Converter writes it); the 8 KiB block after the image
// (DNGPrivateData, the audio) left out, since `acam audio` exports it to a WAV. TimeCodes,
// FrameRate, ReelName, the colour matrices and every other tag are kept as they are.
import Foundation

enum CleanDNG {
    static let make = "Ikonoskop"
    static let model = "A-Cam dII"
    /// The camera stores 0x8000 + kelvin: ColorMatrix1 is for 5500 K, ColorMatrix2 for 3400 K.
    /// Closest EXIF LightSource codes: 20 = D55 (5503 K), 24 = ISO studio tungsten (3200 K).
    static let illuminant1: UInt16 = 20
    static let illuminant2: UInt16 = 24

    /// Tags replaced or dropped: the strip layout, the compression, the private data block, the
    /// illuminants, and the all-zero entry of two of the original templates.
    static let replacedTags: Set<UInt16> = [0, DNGTag.compression, DNGTag.stripOffsets, DNGTag.rowsPerStrip,
                                            DNGTag.stripByteCounts, DNGTag.dngPrivateData,
                                            DNGTag.calibrationIlluminant1, DNGTag.calibrationIlluminant2]

    /// Raw samples of a camera DNG (uncompressed 12-bit strip).
    static func samples(ofOriginal file: Data) throws -> [UInt16] {
        let tiff = try TIFFHeader(file.prefix(FrameHeader.headerBytes))
        guard tiff.uint(DNGTag.compression) == 1,
              let offset = tiff.uint(DNGTag.stripOffsets).map(Int.init),
              let count = tiff.uint(DNGTag.stripByteCounts).map(Int.init),
              count == Raw12.sampleCount / 2 * 3, offset + count <= file.count else {
            throw TIFFError("not an uncompressed 2048x1092 12-bit camera DNG")
        }
        return Raw12.unpack(file.subdata(in: offset..<offset + count))
    }

    /// The clean DNG of one camera DNG, and the raw samples it holds. With `profile`, colour frames
    /// carry its matrices, illuminants and name instead of the factory ones.
    static func make(fromOriginal file: Data, profile: ColourProfile? = nil) throws -> (dng: Data, samples: [UInt16]) {
        let tiff = try TIFFHeader(file.prefix(FrameHeader.headerBytes))
        let samples = try samples(ofOriginal: file)
        let encoded = samples.withUnsafeBufferPointer {
            LosslessJPEG.encodeTiles(frame: $0, width: Raw12.width, height: Raw12.height, bitDepth: 12)
        }
        let colour = tiff.entry(DNGTag.colorMatrix1) != nil
        let applied = colour ? profile : nil
        let skip = replacedTags.union(applied == nil ? [] : ColourProfile.tags)
        var fields: [TIFFField] = []
        var seen = Set<UInt16>()
        for e in tiff.entries where !skip.contains(e.tag) && seen.insert(e.tag).inserted {
            guard let f = TIFFField.copy(e, from: tiff) else {
                throw TIFFError("tag 0x\(String(e.tag, radix: 16)) points outside the header")
            }
            fields.append(f)
        }
        fields += [
            .ascii(DNGTag.make, make),
            .ascii(DNGTag.model, model),
            .short(DNGTag.compression, [7]),
            .srational(DNGTag.baselineExposure, [(0, 1)]),
            .long(DNGTag.tileWidth, [UInt32(encoded.geometry.tileWidth)]),
            .long(DNGTag.tileLength, [UInt32(encoded.geometry.tileLength)]),
        ]
        if let p = applied {
            fields += p.fields
        } else {
            if colour {
                fields.append(.short(DNGTag.calibrationIlluminant1, [illuminant1]))
            }
            if tiff.entry(DNGTag.colorMatrix2) != nil {
                fields.append(.short(DNGTag.calibrationIlluminant2, [illuminant2]))
            }
        }
        let counts = encoded.tiles.map { UInt32($0.count) }
        // The header size does not depend on the offset values, only on their number.
        let headerSize = TIFFWriter.size(of: fields + [.long(DNGTag.tileOffsets, counts), .long(DNGTag.tileByteCounts, counts)])
        var offsets: [UInt32] = []
        var at = UInt32(headerSize)
        for c in counts {
            offsets.append(at)
            at += c
        }
        var out = TIFFWriter.header(fields: fields + [.long(DNGTag.tileOffsets, offsets),
                                                      .long(DNGTag.tileByteCounts, counts)])
        precondition(out.count == headerSize, "TIFF header size changed")
        encoded.tiles.forEach { out.append($0) }
        return (out, samples)
    }

    /// Raw samples of a clean DNG, decoded from its tiles.
    static func samples(ofClean file: Data) throws -> [UInt16] {
        let tiff = try TIFFHeader(file)
        guard tiff.uint(DNGTag.compression) == 7,
              let width = tiff.uint(DNGTag.imageWidth).map(Int.init),
              let height = tiff.uint(DNGTag.imageLength).map(Int.init),
              let tileWidth = tiff.uint(DNGTag.tileWidth).map(Int.init),
              let tileLength = tiff.uint(DNGTag.tileLength).map(Int.init),
              let offsets = tiff.uints(DNGTag.tileOffsets), let counts = tiff.uints(DNGTag.tileByteCounts),
              offsets.count == counts.count else {
            throw TIFFError("not a tiled lossless-JPEG DNG")
        }
        let geometry = LosslessJPEG.TileGeometry(imageWidth: width, imageHeight: height,
                                                 tileWidth: tileWidth, tileLength: tileLength)
        guard geometry.tileCount == offsets.count else {
            throw TIFFError("\(offsets.count) tiles, the geometry needs \(geometry.tileCount)")
        }
        let tiles = try zip(offsets, counts).map { (o, c) -> Data in
            let start = Int(o), end = Int(o) + Int(c)
            guard end <= file.count else {
                throw TIFFError("tile data beyond the end of the file")
            }
            return file.subdata(in: start..<end)
        }
        return try LosslessJPEG.decodeTiles(tiles, geometry: geometry)
    }
}
