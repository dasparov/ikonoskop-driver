// Little-endian TIFF/DNG IFD0 reading and writing, as used by the camera's DNG headers.
import Foundation

struct TIFFError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

enum TIFFType {
    static let byte: UInt16 = 1
    static let ascii: UInt16 = 2
    static let short: UInt16 = 3
    static let long: UInt16 = 4
    static let rational: UInt16 = 5
    static let undefined: UInt16 = 7
    static let srational: UInt16 = 10

    static func size(_ type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11: return 4
        case 5, 10, 12: return 8
        default: return 0
        }
    }
}

/// TIFF 6.0, TIFF/EP, DNG and CinemaDNG tags used here.
enum DNGTag {
    static let newSubfileType: UInt16 = 0x00fe
    static let imageWidth: UInt16 = 0x0100
    static let imageLength: UInt16 = 0x0101
    static let bitsPerSample: UInt16 = 0x0102
    static let compression: UInt16 = 0x0103
    static let photometricInterpretation: UInt16 = 0x0106
    static let fillOrder: UInt16 = 0x010a
    static let make: UInt16 = 0x010f
    static let model: UInt16 = 0x0110
    static let stripOffsets: UInt16 = 0x0111
    static let orientation: UInt16 = 0x0112
    static let samplesPerPixel: UInt16 = 0x0115
    static let rowsPerStrip: UInt16 = 0x0116
    static let stripByteCounts: UInt16 = 0x0117
    static let planarConfiguration: UInt16 = 0x011c
    static let software: UInt16 = 0x0131
    static let tileWidth: UInt16 = 0x0142
    static let tileLength: UInt16 = 0x0143
    static let tileOffsets: UInt16 = 0x0144
    static let tileByteCounts: UInt16 = 0x0145
    static let cfaRepeatPatternDim: UInt16 = 0x828d
    static let cfaPattern: UInt16 = 0x828e
    static let dngVersion: UInt16 = 0xc612
    static let dngBackwardVersion: UInt16 = 0xc613
    static let uniqueCameraModel: UInt16 = 0xc614
    static let blackLevelRepeatDim: UInt16 = 0xc619
    static let blackLevel: UInt16 = 0xc61a
    static let whiteLevel: UInt16 = 0xc61d
    static let defaultCropOrigin: UInt16 = 0xc61f
    static let defaultCropSize: UInt16 = 0xc620
    static let colorMatrix1: UInt16 = 0xc621
    static let colorMatrix2: UInt16 = 0xc622
    static let asShotNeutral: UInt16 = 0xc628
    static let baselineExposure: UInt16 = 0xc62a
    static let bayerGreenSplit: UInt16 = 0xc62d
    static let dngPrivateData: UInt16 = 0xc634
    static let calibrationIlluminant1: UInt16 = 0xc65a
    static let calibrationIlluminant2: UInt16 = 0xc65b
    static let forwardMatrix1: UInt16 = 0xc714
    static let forwardMatrix2: UInt16 = 0xc715
    static let timeCodes: UInt16 = 0xc763
    static let frameRate: UInt16 = 0xc764
    static let profileName: UInt16 = 0xc6f8
    static let reelName: UInt16 = 0xc789
}

struct TIFFEntry {
    let tag: UInt16
    let type: UInt16
    let count: UInt32
    /// Offset of the value in the file: inside the entry when it fits in 4 bytes.
    let valueOffset: Int

    var byteCount: Int { Int(count) * TIFFType.size(type) }
}

/// IFD0 of a little-endian TIFF, parsed from the first bytes of the file.
struct TIFFHeader {
    let bytes: Data
    let entries: [TIFFEntry]

    init(_ data: Data) throws {
        bytes = Data(data) // re-based to index 0
        guard bytes.count >= 8, bytes[0] == 0x49, bytes[1] == 0x49, bytes.u16(2) == 42 else {
            throw TIFFError("not a little-endian TIFF")
        }
        let ifd = Int(bytes.u32(4))
        guard ifd >= 8, ifd + 2 <= bytes.count else {
            throw TIFFError("IFD0 offset \(ifd) outside the header")
        }
        let n = Int(bytes.u16(ifd))
        guard ifd + 2 + 12 * n + 4 <= bytes.count else {
            throw TIFFError("IFD0 (\(n) entries) overruns the header")
        }
        var entries: [TIFFEntry] = []
        for i in 0..<n {
            let e = ifd + 2 + 12 * i
            let type = bytes.u16(e + 2)
            let count = bytes.u32(e + 4)
            let size = Int(count) * TIFFType.size(type)
            entries.append(TIFFEntry(tag: bytes.u16(e), type: type, count: count,
                                     valueOffset: size <= 4 ? e + 8 : Int(bytes.u32(e + 8))))
        }
        self.entries = entries
    }

    func entry(_ tag: UInt16) -> TIFFEntry? {
        entries.first { $0.tag == tag }
    }

    /// Value bytes of `entry`, when they lie inside the parsed header.
    func value(_ entry: TIFFEntry) -> Data? {
        let end = entry.valueOffset + entry.byteCount
        guard entry.valueOffset >= 0, end <= bytes.count else {
            return nil
        }
        return bytes.subdata(in: entry.valueOffset..<end)
    }

    /// First value of a BYTE, SHORT or LONG field.
    func uint(_ tag: UInt16) -> UInt32? {
        guard let e = entry(tag), e.count >= 1, let v = value(e) else {
            return nil
        }
        switch e.type {
        case TIFFType.byte: return UInt32(v[0])
        case TIFFType.short: return UInt32(v.u16(0))
        case TIFFType.long: return v.u32(0)
        default: return nil
        }
    }

    /// All values of a SHORT or LONG field.
    func uints(_ tag: UInt16) -> [UInt32]? {
        guard let e = entry(tag), let v = value(e) else {
            return nil
        }
        switch e.type {
        case TIFFType.short: return (0..<Int(e.count)).map { UInt32(v.u16(2 * $0)) }
        case TIFFType.long: return (0..<Int(e.count)).map { v.u32(4 * $0) }
        default: return nil
        }
    }

    /// Numerator/denominator pairs of a RATIONAL or SRATIONAL field.
    func rationals(_ tag: UInt16) -> [(Int64, Int64)]? {
        guard let e = entry(tag), let v = value(e) else {
            return nil
        }
        switch e.type {
        case TIFFType.rational:
            return (0..<Int(e.count)).map { (Int64(v.u32(8 * $0)), Int64(v.u32(8 * $0 + 4))) }
        case TIFFType.srational:
            return (0..<Int(e.count)).map {
                (Int64(Int32(bitPattern: v.u32(8 * $0))), Int64(Int32(bitPattern: v.u32(8 * $0 + 4))))
            }
        default:
            return nil
        }
    }

    /// ASCII value up to the first NUL.
    func ascii(_ tag: UInt16) -> String? {
        guard let e = entry(tag), e.type == TIFFType.ascii, let v = value(e) else {
            return nil
        }
        return String(decoding: v.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// One IFD entry to write; `value` holds the little-endian value bytes (count * type size).
struct TIFFField {
    let tag: UInt16
    let type: UInt16
    let count: UInt32
    let value: Data

    static func bytes(_ tag: UInt16, _ values: [UInt8], type: UInt16 = TIFFType.byte) -> TIFFField {
        TIFFField(tag: tag, type: type, count: UInt32(values.count), value: Data(values))
    }

    static func short(_ tag: UInt16, _ values: [UInt16]) -> TIFFField {
        var d = Data()
        values.forEach { d.append16($0) }
        return TIFFField(tag: tag, type: TIFFType.short, count: UInt32(values.count), value: d)
    }

    static func long(_ tag: UInt16, _ values: [UInt32]) -> TIFFField {
        var d = Data()
        values.forEach { d.append32($0) }
        return TIFFField(tag: tag, type: TIFFType.long, count: UInt32(values.count), value: d)
    }

    /// NUL-terminated; padded with NULs to `count` if given.
    static func ascii(_ tag: UInt16, _ text: String, count: Int? = nil) -> TIFFField {
        var d = Data(text.utf8)
        d.append(0)
        if let count = count, d.count < count {
            d.append(Data(count: count - d.count))
        }
        return TIFFField(tag: tag, type: TIFFType.ascii, count: UInt32(d.count), value: d)
    }

    static func rational(_ tag: UInt16, _ values: [(UInt32, UInt32)]) -> TIFFField {
        var d = Data()
        values.forEach { d.append32($0.0); d.append32($0.1) }
        return TIFFField(tag: tag, type: TIFFType.rational, count: UInt32(values.count), value: d)
    }

    static func srational(_ tag: UInt16, _ values: [(Int32, Int32)]) -> TIFFField {
        var d = Data()
        values.forEach { d.append32(UInt32(bitPattern: $0.0)); d.append32(UInt32(bitPattern: $0.1)) }
        return TIFFField(tag: tag, type: TIFFType.srational, count: UInt32(values.count), value: d)
    }

    /// The raw value of `entry` in `header`, unchanged.
    static func copy(_ entry: TIFFEntry, from header: TIFFHeader) -> TIFFField? {
        guard let v = header.value(entry) else {
            return nil
        }
        return TIFFField(tag: entry.tag, type: entry.type, count: entry.count, value: v)
    }
}

enum TIFFWriter {
    /// Size of the header `header(fields:)` writes: TIFF header, IFD0, then the values longer
    /// than 4 bytes, each at an even offset.
    static func size(of fields: [TIFFField]) -> Int {
        var size = 8 + 2 + 12 * fields.count + 4
        for f in fields where f.value.count > 4 {
            size += f.value.count + (f.value.count & 1)
        }
        return size
    }

    /// Little-endian TIFF with one IFD holding `fields` in ascending tag order (TIFF requires it).
    static func header(fields: [TIFFField]) -> Data {
        let sorted = fields.sorted { $0.tag < $1.tag }
        var out = Data()
        out.append(contentsOf: [0x49, 0x49])
        out.append16(42)
        out.append32(8)
        out.append16(UInt16(sorted.count))
        var dataOffset = 8 + 2 + 12 * sorted.count + 4
        var values = Data()
        for f in sorted {
            out.append16(f.tag)
            out.append16(f.type)
            out.append32(f.count)
            if f.value.count <= 4 {
                var inline = f.value
                inline.append(Data(count: 4 - inline.count))
                out.append(inline)
            } else {
                out.append32(UInt32(dataOffset))
                values.append(f.value)
                if f.value.count & 1 == 1 {
                    values.append(0)
                }
                dataOffset += f.value.count + (f.value.count & 1)
            }
        }
        out.append32(0) // no IFD1
        out.append(values)
        return out
    }
}

extension Data {
    func u16(_ at: Int) -> UInt16 {
        let i = startIndex + at
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func u32(_ at: Int) -> UInt32 {
        UInt32(u16(at)) | UInt32(u16(at + 2)) << 16
    }

    mutating func append16(_ v: UInt16) {
        append(UInt8(v & 0xff))
        append(UInt8(v >> 8))
    }

    mutating func append32(_ v: UInt32) {
        append16(UInt16(v & 0xffff))
        append16(UInt16(v >> 16))
    }
}
