import Foundation

/// Lossless JPEG (ITU-T T.81 process 14, SOF3) for DNG Compression = 7, written the way Adobe's
/// DNG SDK writes CFA data:
///
/// - A CFA tile `width` samples wide is coded as a JPEG frame `width / 2` wide with 2 interleaved
///   components, so each JPEG "pixel" is two horizontally adjacent CFA samples and the predictor
///   always works between samples of the same colour (odd widths fall back to 1 component).
/// - Predictor 1 (left neighbour; the first column uses the sample above, the first sample
///   2^(P-1)), point transform 0, one scan, no restart markers.
/// - One Huffman table per component per tile, optimal for that tile's difference statistics
///   (T.81 Annex K.2, code lengths limited to 16). Same as the SDK; costs ~40 bytes per table and
///   adapts to dark, bright and noisy tiles alike, which a fixed table cannot.
///
/// The decoder reads any single-scan SOF3 stream with 1-4 components, predictor 1, point
/// transform 0 and no restart interval, and returns the samples interleaved in row order: `width`
/// is the frame width times the component count, i.e. the DNG tile width.
enum LosslessJPEG {
    enum DecodeError: Error, CustomStringConvertible {
        case truncated
        case malformed(String)
        case unsupported(String)

        var description: String {
            switch self {
            case .truncated: return "lossless JPEG: data ends early"
            case .malformed(let what): return "lossless JPEG: malformed (\(what))"
            case .unsupported(let what): return "lossless JPEG: unsupported (\(what))"
            }
        }
    }

    // MARK: - Encoder

    /// Encodes `height` rows of `width` samples; row `y` starts at `samples[y * stride]`.
    /// Samples must fit in `bitDepth` (2...16) bits. Even widths use 2 components (DNG CFA).
    static func encode(samples: UnsafeBufferPointer<UInt16>, width: Int, height: Int, stride: Int,
                       bitDepth: Int) -> Data {
        precondition(width > 0 && height > 0 && stride >= width, "bad geometry")
        precondition((2...16).contains(bitDepth), "bit depth must be 2...16")
        precondition(samples.count >= (height - 1) * stride + width, "sample buffer too small")
        let comps = width % 2 == 0 ? 2 : 1
        precondition(width / comps <= 0xFFFF && height <= 0xFFFF, "image too large for one JPEG frame")
        let src = samples.baseAddress!
        let initial = Int32(1) << (bitDepth - 1)
        let cmask = comps - 1

        // Pass 1: histogram of difference categories (SSSS) per component.
        let freq = UnsafeMutablePointer<Int>.allocate(capacity: 2 * 17)
        freq.initialize(repeating: 0, count: 2 * 17)
        defer { freq.deallocate() }
        for y in 0..<height {
            let row = src + y * stride
            for x in 0..<comps {
                let pred = y == 0 ? initial : Int32(row[x - stride])
                freq[x * 17 + category(Int32(row[x]) - pred)] += 1
            }
            var x = comps
            while x < width {
                freq[(x & cmask) * 17 + category(Int32(row[x]) - Int32(row[x - comps]))] += 1
                x += 1
            }
        }

        // Tables: code and code length per (component, category).
        var tables: [(bits: [UInt8], values: [UInt8])] = []
        let codes = UnsafeMutablePointer<UInt32>.allocate(capacity: 2 * 17)
        let lengths = UnsafeMutablePointer<Int>.allocate(capacity: 2 * 17)
        codes.initialize(repeating: 0, count: 2 * 17)
        lengths.initialize(repeating: 0, count: 2 * 17)
        defer { codes.deallocate(); lengths.deallocate() }
        var payloadBits = 0
        for c in 0..<comps {
            let table = optimalTable(freq + c * 17)
            tables.append(table)
            assignCodes(table, codes: codes + c * 17, lengths: lengths + c * 17)
            for s in 0...16 { payloadBits += freq[c * 17 + s] * (lengths[c * 17 + s] + (s & 15)) }
        }

        // Worst case every payload byte is 0xFF and gets stuffed.
        let capacity = 64 + comps * (5 + 16 + 17 + 3) + 2 * ((payloadBits + 7) / 8) + 8
        let buffer = malloc(capacity)!.assumingMemoryBound(to: UInt8.self)
        var w = BitWriter(out: buffer)

        w.u16(0xFFD8)                                   // SOI
        w.u16(0xFFC3); w.u16(8 + 3 * comps)             // SOF3
        w.u8(UInt8(bitDepth)); w.u16(height); w.u16(width / comps); w.u8(UInt8(comps))
        for c in 0..<comps { w.u8(UInt8(c)); w.u8(0x11); w.u8(0) }
        for (c, table) in tables.enumerated() {         // DHT, one per component
            w.u16(0xFFC4); w.u16(2 + 1 + 16 + table.values.count)
            w.u8(UInt8(c))
            for count in table.bits { w.u8(count) }
            for value in table.values { w.u8(value) }
        }
        w.u16(0xFFDA); w.u16(6 + 2 * comps); w.u8(UInt8(comps))   // SOS
        for c in 0..<comps { w.u8(UInt8(c)); w.u8(UInt8(c << 4)) }
        w.u8(1); w.u8(0); w.u8(0)                       // predictor 1, Se = 0, Ah/Al = 0

        // Pass 2: entropy-coded differences.
        for y in 0..<height {
            let row = src + y * stride
            for x in 0..<comps {
                let pred = y == 0 ? initial : Int32(row[x - stride])
                emit(Int32(row[x]) - pred, codes + x * 17, lengths + x * 17, &w)
            }
            var x = comps
            while x < width {
                let t = (x & cmask) * 17
                emit(Int32(row[x]) - Int32(row[x - comps]), codes + t, lengths + t, &w)
                x += 1
            }
        }
        w.flush()
        w.u16(0xFFD9)                                   // EOI
        precondition(w.pos <= capacity)
        return Data(bytesNoCopy: buffer, count: w.pos, deallocator: .free)
    }

    /// SSSS: bit length of |difference|, the difference taken modulo 2^16 as in T.81 H.1.2.1.
    @inline(__always)
    private static func category(_ diff: Int32) -> Int {
        let d = Int32(Int16(truncatingIfNeeded: diff))
        return 32 - UInt32(bitPattern: d < 0 ? -d : d).leadingZeroBitCount
    }

    @inline(__always)
    private static func emit(_ diff: Int32, _ codes: UnsafeMutablePointer<UInt32>,
                             _ lengths: UnsafeMutablePointer<Int>, _ w: inout BitWriter) {
        let d = Int32(Int16(truncatingIfNeeded: diff))
        let ssss = 32 - UInt32(bitPattern: d < 0 ? -d : d).leadingZeroBitCount
        let extra = ssss & 15                           // SSSS 16 (-32768) has no extra bits
        let low = UInt64(UInt32(bitPattern: d < 0 ? d - 1 : d) & ((1 << UInt32(extra)) - 1))
        w.put(UInt64(codes[ssss]) << UInt64(extra) | low, lengths[ssss] + extra)
    }

    /// Optimal length-limited Huffman table (T.81 Annex K.2, Figures K.1-K.4) for categories
    /// 0...16. Returns BITS[1...16] and HUFFVAL.
    static func optimalTable(_ counts: UnsafePointer<Int>) -> (bits: [UInt8], values: [UInt8]) {
        let reserved = 17                               // stands in for T.81's symbol 256
        var freq = (0...16).map { counts[$0] } + [1]
        var codesize = [Int](repeating: 0, count: 18)
        var others = [Int](repeating: -1, count: 18)
        while true {
            // v1: least frequency, ties to the larger symbol; v2: the next least.
            var v1 = -1, v2 = -1
            for v in 0...reserved where freq[v] > 0 && (v1 < 0 || freq[v] <= freq[v1]) { v1 = v }
            for v in 0...reserved where v != v1 && freq[v] > 0 && (v2 < 0 || freq[v] <= freq[v2]) { v2 = v }
            if v2 < 0 { break }
            freq[v1] += freq[v2]
            freq[v2] = 0
            codesize[v1] += 1
            while others[v1] >= 0 { v1 = others[v1]; codesize[v1] += 1 }
            others[v1] = v2
            codesize[v2] += 1
            while others[v2] >= 0 { v2 = others[v2]; codesize[v2] += 1 }
        }
        var bits = [Int](repeating: 0, count: 33)
        for v in 0...reserved where codesize[v] > 0 { bits[codesize[v]] += 1 }
        var i = 32                                      // Figure K.3: limit lengths to 16
        while i > 16 {
            if bits[i] > 0 {
                var j = i - 2
                while bits[j] == 0 { j -= 1 }
                bits[i] -= 2
                bits[i - 1] += 1
                bits[j + 1] += 2
                bits[j] -= 1
            } else {
                i -= 1
            }
        }
        while bits[i] == 0 { i -= 1 }
        bits[i] -= 1                                    // drop the reserved code
        var values: [UInt8] = []
        for size in 1...32 {
            for v in 0...16 where codesize[v] == size { values.append(UInt8(v)) }
        }
        return (bits[1...16].map { UInt8($0) }, values)
    }

    /// Canonical codes (T.81 Annex C) for a table, indexed by category.
    private static func assignCodes(_ table: (bits: [UInt8], values: [UInt8]),
                                    codes: UnsafeMutablePointer<UInt32>,
                                    lengths: UnsafeMutablePointer<Int>) {
        var code: UInt32 = 0
        var k = 0
        for length in 1...16 {
            for _ in 0..<Int(table.bits[length - 1]) {
                let v = Int(table.values[k])
                codes[v] = code
                lengths[v] = length
                code += 1
                k += 1
            }
            code <<= 1
        }
    }

    private struct BitWriter {
        let out: UnsafeMutablePointer<UInt8>
        var pos = 0
        var acc: UInt64 = 0
        var count = 0                                   // valid low bits in acc, < 32 between puts

        init(out: UnsafeMutablePointer<UInt8>) { self.out = out }

        mutating func u8(_ v: UInt8) { out[pos] = v; pos += 1 }
        mutating func u16(_ v: Int) { u8(UInt8(v >> 8)); u8(UInt8(v & 0xFF)) }

        @inline(__always)
        mutating func put(_ bits: UInt64, _ length: Int) {
            acc = acc << UInt64(length) | bits
            count += length
            if count >= 32 {
                count -= 32
                let word = UInt32(truncatingIfNeeded: acc >> UInt64(count))
                let inverted = ~word                    // a zero byte here is an 0xFF byte in word
                if (inverted &- 0x0101_0101) & ~inverted & 0x8080_8080 == 0 {
                    UnsafeMutableRawPointer(out + pos).storeBytes(of: word.bigEndian, as: UInt32.self)
                    pos += 4
                } else {
                    for shift in [24, 16, 8, 0] { stuffed(UInt8(truncatingIfNeeded: word >> UInt32(shift))) }
                }
            }
        }

        @inline(__always)
        mutating func stuffed(_ byte: UInt8) {
            out[pos] = byte
            pos += 1
            if byte == 0xFF { out[pos] = 0; pos += 1 }
        }

        /// Pads the last byte with 1 bits (T.81 F.1.2.3) and writes out what is left.
        mutating func flush() {
            let pad = (8 - count % 8) % 8
            acc = acc << UInt64(pad) | ((1 << UInt64(pad)) - 1)
            count += pad
            while count > 0 {
                count -= 8
                stuffed(UInt8(truncatingIfNeeded: acc >> UInt64(count)))
            }
        }
    }

    // MARK: - Decoder

    static func decode(_ data: Data) throws -> (samples: [UInt16], width: Int, height: Int) {
        try data.withUnsafeBytes { try decode($0) }
    }

    static func decode(_ bytes: UnsafeRawBufferPointer) throws -> (samples: [UInt16], width: Int, height: Int) {
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { throw DecodeError.truncated }
        let end = bytes.count
        var p = 0
        func u8() throws -> Int {
            guard p < end else { throw DecodeError.truncated }
            p += 1
            return Int(base[p - 1])
        }
        func u16() throws -> Int { try u8() << 8 | u8() }

        guard try u16() == 0xFFD8 else { throw DecodeError.malformed("no SOI marker") }
        var precision = 0, frameHeight = 0, frameWidth = 0
        var componentIDs: [Int] = []
        var tables = [HuffmanDecoder?](repeating: nil, count: 4)
        while true {
            guard try u8() == 0xFF else { throw DecodeError.malformed("expected a marker at \(p - 1)") }
            var marker = try u8()
            while marker == 0xFF { marker = try u8() }
            switch marker {
            case 0xC3:
                let length = try u16()
                precision = try u8()
                frameHeight = try u16()
                frameWidth = try u16()
                let count = try u8()
                guard length == 8 + 3 * count, (1...4).contains(count) else {
                    throw DecodeError.unsupported("\(count) components")
                }
                guard (2...16).contains(precision) else { throw DecodeError.malformed("precision \(precision)") }
                guard frameHeight > 0 else { throw DecodeError.unsupported("height defined by DNL") }
                guard frameWidth > 0 else { throw DecodeError.malformed("zero width") }
                componentIDs = []
                for _ in 0..<count {
                    componentIDs.append(try u8())
                    guard try u8() == 0x11 else { throw DecodeError.unsupported("subsampled component") }
                    _ = try u8()
                }
            case 0xC0...0xCF where marker != 0xC4 && marker != 0xC8 && marker != 0xCC:
                throw DecodeError.unsupported("SOF\(marker - 0xC0) (only lossless SOF3)")
            case 0xC4:
                let segmentStart = p
                let segmentEnd = segmentStart + (try u16())
                guard segmentEnd <= end else { throw DecodeError.truncated }
                while p < segmentEnd {
                    let tcth = try u8()
                    guard tcth >> 4 == 0, tcth & 15 < 4 else { throw DecodeError.malformed("DHT class/id \(tcth)") }
                    var bits = [Int]()
                    for _ in 0..<16 { bits.append(try u8()) }
                    var values = [UInt8]()
                    let symbolCount = bits.reduce(0, +)
                    guard symbolCount <= 256 else { throw DecodeError.malformed("DHT with \(symbolCount) symbols") }
                    for _ in 0..<symbolCount {
                        let v = try u8()
                        guard v <= 16 else { throw DecodeError.malformed("Huffman value \(v)") }
                        values.append(UInt8(v))
                    }
                    tables[tcth & 15] = try HuffmanDecoder(bits: bits, values: values)
                }
                guard p == segmentEnd else { throw DecodeError.malformed("DHT length") }
            case 0xDD:
                guard try u16() == 4 else { throw DecodeError.malformed("DRI length") }
                guard try u16() == 0 else { throw DecodeError.unsupported("restart markers") }
            case 0xDA:
                guard !componentIDs.isEmpty else { throw DecodeError.malformed("SOS before SOF3") }
                let length = try u16()
                let count = try u8()
                guard count == componentIDs.count, length == 6 + 2 * count else {
                    throw DecodeError.unsupported("scan does not interleave every component")
                }
                var scanTables: [HuffmanDecoder] = []
                for c in 0..<count {
                    guard try u8() == componentIDs[c] else { throw DecodeError.unsupported("scan component order") }
                    guard let table = tables[(try u8()) >> 4 & 3] else { throw DecodeError.malformed("missing Huffman table") }
                    scanTables.append(table)
                }
                let predictor = try u8()
                _ = try u8()
                let pointTransform = try u8()
                guard predictor == 1 else { throw DecodeError.unsupported("predictor \(predictor)") }
                guard pointTransform == 0 else { throw DecodeError.unsupported("point transform") }
                let width = frameWidth * count
                var reader = BitReader(base: base, pos: p, end: end)
                let samples = try [UInt16](unsafeUninitializedCapacity: width * frameHeight) { out, initialized in
                    try decodeScan(&reader, scanTables, into: out.baseAddress!, width: width,
                                   height: frameHeight, comps: count, initial: Int32(1) << (precision - 1))
                    initialized = width * frameHeight
                }
                return (samples, width, frameHeight)
            case 0xD8, 0xD9, 0xD0...0xD7:
                throw DecodeError.malformed("unexpected marker FF\(String(marker, radix: 16, uppercase: true))")
            default:                                    // APPn, COM, DQT, ...: skip
                let length = try u16()
                guard length >= 2, p + length - 2 <= end else { throw DecodeError.truncated }
                p += length - 2
            }
        }
    }

    private static func decodeScan(_ r: inout BitReader, _ tables: [HuffmanDecoder],
                                   into out: UnsafeMutablePointer<UInt16>, width: Int, height: Int,
                                   comps: Int, initial: Int32) throws {
        // Flatten the tables so the loop indexes plain memory.
        let lut = UnsafeMutablePointer<UInt16>.allocate(capacity: comps * HuffmanDecoder.lookupSize)
        let maxcode = UnsafeMutablePointer<Int32>.allocate(capacity: comps * 17)
        let offset = UnsafeMutablePointer<Int32>.allocate(capacity: comps * 17)
        let values = UnsafeMutablePointer<UInt8>.allocate(capacity: comps * 256)
        defer { lut.deallocate(); maxcode.deallocate(); offset.deallocate(); values.deallocate() }
        for (c, t) in tables.enumerated() {
            for i in 0..<HuffmanDecoder.lookupSize { lut[c * HuffmanDecoder.lookupSize + i] = t.lookup[i] }
            for l in 0...16 { maxcode[c * 17 + l] = t.maxcode[l]; offset[c * 17 + l] = t.offset[l] }
            for i in 0..<256 { values[c * 256 + i] = i < t.values.count ? t.values[i] : 0 }
        }

        for y in 0..<height {
            let row = out + y * width
            var c = 0
            for x in 0..<width {
                if r.count < 32 { r.fill() }
                // Category symbol.
                let tl = lut + c * HuffmanDecoder.lookupSize
                let entry = tl[Int(truncatingIfNeeded: r.acc >> UInt64(64 - HuffmanDecoder.lookupBits))]
                var ssss: Int
                if entry != 0 {
                    ssss = Int(entry & 0xFF)
                    r.consume(Int(entry >> 8))
                } else {
                    var length = HuffmanDecoder.lookupBits + 1
                    var code = Int32(truncatingIfNeeded: r.acc >> UInt64(64 - length))
                    while length <= 16 && code > maxcode[c * 17 + length] {
                        length += 1
                        code = Int32(truncatingIfNeeded: r.acc >> UInt64(64 - length))
                    }
                    guard length <= 16 else { throw DecodeError.malformed("invalid Huffman code") }
                    ssss = Int(values[c * 256 + Int(code + offset[c * 17 + length])])
                    r.consume(length)
                }
                // Difference.
                var diff: Int32
                if ssss == 0 {
                    diff = 0
                } else if ssss == 16 {
                    diff = 32768
                } else {
                    let v = Int32(truncatingIfNeeded: r.acc >> UInt64(64 - ssss))
                    r.consume(ssss)
                    diff = v < Int32(1) << (ssss - 1) ? v - (Int32(1) << ssss) + 1 : v
                }
                let pred: Int32
                if x >= comps {
                    pred = Int32(row[x - comps])
                } else {
                    pred = y == 0 ? initial : Int32(row[x - width])
                }
                row[x] = UInt16(truncatingIfNeeded: pred + diff)
                c += 1
                if c == comps { c = 0 }
            }
        }
        guard r.consumedOnlyRealData else { throw DecodeError.truncated }
    }

    private struct HuffmanDecoder {
        static let lookupBits = 9
        static let lookupSize = 1 << lookupBits
        /// Indexed by the next 9 bits: length << 8 | value, or 0 for codes longer than 9 bits.
        var lookup = [UInt16](repeating: 0, count: lookupSize)
        /// Largest code of each length (-1: none); value index = code + offset[length].
        var maxcode = [Int32](repeating: -1, count: 17)
        var offset = [Int32](repeating: 0, count: 17)
        let values: [UInt8]

        init(bits: [Int], values: [UInt8]) throws {
            self.values = values
            var code: Int32 = 0
            var k = 0
            for length in 1...16 {
                let n = bits[length - 1]
                guard Int(code) + n <= 1 << length else { throw DecodeError.malformed("Huffman table overfull") }
                if n > 0 {
                    offset[length] = Int32(k) - code
                    for _ in 0..<n {
                        if length <= Self.lookupBits {
                            let shift = Self.lookupBits - length
                            let first = Int(code) << shift
                            for i in first..<first + (1 << shift) {
                                lookup[i] = UInt16(length << 8) | UInt16(values[k])
                            }
                        }
                        code += 1
                        k += 1
                    }
                    maxcode[length] = code - 1
                }
                code <<= 1
            }
        }
    }

    private struct BitReader {
        let base: UnsafePointer<UInt8>
        var pos: Int
        let end: Int
        /// Next bits at the top.
        var acc: UInt64 = 0
        var count = 0
        var realBytes = 0
        var fakeBytes = 0                               // zeros fed after a marker or the end

        init(base: UnsafePointer<UInt8>, pos: Int, end: Int) {
            self.base = base
            self.pos = pos
            self.end = end
        }

        @inline(__always)
        mutating func consume(_ n: Int) {
            acc <<= UInt64(n)
            count -= n
        }

        mutating func fill() {
            while count <= 56 {
                var byte: UInt64 = 0
                if fakeBytes == 0 && pos < end {
                    let b = base[pos]
                    if b != 0xFF {
                        byte = UInt64(b)
                        pos += 1
                        realBytes += 1
                    } else if pos + 1 < end && base[pos + 1] == 0 {
                        byte = 0xFF
                        pos += 2
                        realBytes += 1
                    } else {
                        fakeBytes += 1                  // a marker ends the entropy-coded data
                    }
                } else {
                    fakeBytes += 1
                }
                acc |= byte << UInt64(56 - count)
                count += 8
            }
        }

        var consumedOnlyRealData: Bool { (realBytes + fakeBytes) * 8 - count <= realBytes * 8 }
    }

    // MARK: - DNG tiles

    /// Tile layout of one image. Tiles are numbered row by row (TIFF order); the right and bottom
    /// edge tiles extend past the image and are padded with zeros, as the DNG SDK does
    /// (dng_image::edge_zero). Readers discard the padding.
    struct TileGeometry: Equatable {
        let imageWidth: Int
        let imageHeight: Int
        let tileWidth: Int
        let tileLength: Int

        var tilesAcross: Int { (imageWidth + tileWidth - 1) / tileWidth }
        var tilesDown: Int { (imageHeight + tileLength - 1) / tileLength }
        var tileCount: Int { tilesAcross * tilesDown }

        /// The DNG SDK's choice for lossless JPEG (dng_ifd::FindTileSize(128 KiB) with 16-pixel
        /// cells and 2 bytes per sample). 2048x1092 gives 256x224: 8 x 5 tiles, the last row of
        /// tiles holding 196 real rows and 28 rows of padding.
        static func dngDefault(width: Int, height: Int) -> TileGeometry {
            let samplesPerTile = 128 * 1024 / 2
            let side = Int((Double(samplesPerTile)).squareRoot().rounded())
            var tileWidth = min(width, side)
            let across = (width + tileWidth - 1) / tileWidth
            tileWidth = roundUp16((width + across - 1) / across)
            var tileLength = max(1, min(samplesPerTile / tileWidth, height))
            let down = (height + tileLength - 1) / tileLength
            tileLength = roundUp16((height + down - 1) / down)
            return TileGeometry(imageWidth: width, imageHeight: height, tileWidth: tileWidth, tileLength: tileLength)
        }

        private static func roundUp16(_ n: Int) -> Int { (n + 15) / 16 * 16 }
    }

    /// Cuts a row-major CFA image into DNG tiles (`TileGeometry.dngDefault` unless given) and
    /// encodes each one. Returns the tiles in TIFF order (row by row).
    static func encodeTiles(frame: UnsafeBufferPointer<UInt16>, width: Int, height: Int, bitDepth: Int,
                            geometry: TileGeometry? = nil) -> (geometry: TileGeometry, tiles: [Data]) {
        let g = geometry ?? .dngDefault(width: width, height: height)
        precondition(g.imageWidth == width && g.imageHeight == height, "geometry is for another image size")
        precondition(frame.count >= width * height, "frame too small")
        let tw = g.tileWidth, tl = g.tileLength
        var padded = [UInt16]()
        var tiles: [Data] = []
        tiles.reserveCapacity(g.tileCount)
        for ty in 0..<g.tilesDown {
            for tx in 0..<g.tilesAcross {
                let x0 = tx * tw, y0 = ty * tl
                let w = min(tw, width - x0), h = min(tl, height - y0)
                if w == tw && h == tl {
                    let start = frame.baseAddress! + y0 * width + x0
                    tiles.append(encode(samples: UnsafeBufferPointer(start: start, count: (tl - 1) * width + tw),
                                        width: tw, height: tl, stride: width, bitDepth: bitDepth))
                } else {
                    if padded.isEmpty { padded = [UInt16](repeating: 0, count: tw * tl) }
                    padded.withUnsafeMutableBufferPointer { p in
                        p.update(repeating: 0)
                        for y in 0..<h {
                            (p.baseAddress! + y * tw).update(from: frame.baseAddress! + (y0 + y) * width + x0, count: w)
                        }
                    }
                    tiles.append(padded.withUnsafeBufferPointer {
                        encode(samples: $0, width: tw, height: tl, stride: tw, bitDepth: bitDepth)
                    })
                }
            }
        }
        return (g, tiles)
    }

    /// Decodes tiles written by `encodeTiles` (or any DNG writer using the same geometry) back to
    /// the row-major image, dropping the edge padding.
    static func decodeTiles(_ tiles: [Data], geometry g: TileGeometry) throws -> [UInt16] {
        guard tiles.count == g.tileCount else {
            throw DecodeError.malformed("\(tiles.count) tiles, geometry needs \(g.tileCount)")
        }
        var image = [UInt16](repeating: 0, count: g.imageWidth * g.imageHeight)
        try image.withUnsafeMutableBufferPointer { out in
            for (i, tile) in tiles.enumerated() {
                let decoded = try decode(tile)
                guard decoded.width == g.tileWidth && decoded.height == g.tileLength else {
                    throw DecodeError.malformed("tile \(i) is \(decoded.width)x\(decoded.height)")
                }
                let x0 = i % g.tilesAcross * g.tileWidth, y0 = i / g.tilesAcross * g.tileLength
                let w = min(g.tileWidth, g.imageWidth - x0), h = min(g.tileLength, g.imageHeight - y0)
                decoded.samples.withUnsafeBufferPointer { src in
                    for y in 0..<h {
                        (out.baseAddress! + (y0 + y) * g.imageWidth + x0)
                            .update(from: src.baseAddress! + y * g.tileWidth, count: w)
                    }
                }
            }
        }
        return image
    }
}
