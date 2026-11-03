import Foundation

/// The A-Cam dII image strip: 12-bit CFA samples packed big-endian (MSB-first, as TIFF/DNG
/// BitsPerSample = 12 requires), two samples in three bytes:
///
///     byte 0 = s0[11:4]   byte 1 = s0[3:0] s1[11:8]   byte 2 = s1[7:0]
///
/// Verified on real frames (cards 000 and 102): this order gives a smooth image whose interior
/// floor sits at 88-91 (header BlackLevel 80/90/90/80) and same-colour neighbours differ by ~15 on
/// average; the little-endian order gives noise with means near 2000. Columns 0-27 and 2020-2047
/// read as 0 in every frame (unexposed margins).
enum Raw12 {
    static let width = 2048
    static let height = 1092
    static let sampleCount = width * height
    /// 0x333000: the size of the image strip at `stripOffset` in an original frame.
    static let stripByteCount = sampleCount * 3 / 2
    static let stripOffset = 0x1000

    /// Unpacks `bytes.count / 3 * 2` samples. `bytes.count` must be a multiple of 3 and `out` must
    /// hold `bytes.count / 3 * 2` samples.
    static func unpack(_ bytes: UnsafeRawBufferPointer, into out: UnsafeMutableBufferPointer<UInt16>) {
        precondition(bytes.count % 3 == 0, "packed 12-bit data must be a multiple of 3 bytes")
        let groups = bytes.count / 3
        precondition(out.count >= groups * 2, "output too small")
        guard groups > 0 else { return }
        let src = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let dst = out.baseAddress!
        for g in 0..<groups {
            let b0 = UInt16(src[3 * g]), b1 = UInt16(src[3 * g + 1]), b2 = UInt16(src[3 * g + 2])
            dst[2 * g] = b0 << 4 | b1 >> 4
            dst[2 * g + 1] = (b1 & 0xF) << 8 | b2
        }
    }

    /// Unpacks a whole packed buffer (count a multiple of 3), e.g. a 0x333000-byte strip.
    static func unpack(_ data: Data) -> [UInt16] {
        let count = data.count / 3 * 2
        return [UInt16](unsafeUninitializedCapacity: count) { out, initialized in
            data.withUnsafeBytes { unpack($0, into: out) }
            initialized = count
        }
    }

    /// Packs an even number of samples (each <= 4095) into `samples.count / 2 * 3` bytes.
    static func pack(_ samples: UnsafeBufferPointer<UInt16>, into out: UnsafeMutableRawBufferPointer) {
        precondition(samples.count % 2 == 0, "12-bit packing needs an even number of samples")
        let groups = samples.count / 2
        precondition(out.count >= groups * 3, "output too small")
        guard groups > 0 else { return }
        let src = samples.baseAddress!
        let dst = out.baseAddress!.assumingMemoryBound(to: UInt8.self)
        var high: UInt16 = 0
        for g in 0..<groups {
            let s0 = src[2 * g], s1 = src[2 * g + 1]
            high |= s0 | s1
            dst[3 * g] = UInt8(truncatingIfNeeded: s0 >> 4)
            dst[3 * g + 1] = UInt8(truncatingIfNeeded: s0 << 4 | (s1 >> 8 & 0xF))
            dst[3 * g + 2] = UInt8(truncatingIfNeeded: s1)
        }
        precondition(high < 4096, "sample exceeds 12 bits")
    }

    static func pack(_ samples: [UInt16]) -> Data {
        var data = Data(count: samples.count / 2 * 3)
        samples.withUnsafeBufferPointer { src in
            data.withUnsafeMutableBytes { pack(src, into: $0) }
        }
        return data
    }
}
