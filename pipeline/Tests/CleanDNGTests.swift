import Foundation

func cleanDNGTests(_ t: TestContext) throws {
    for (kind, name) in [(0, "monochrome"), (1, "tungsten"), (2, "daylight")] {
        let original = Fixture.frame(seed: UInt64(kind + 7), fps: 25, timecode: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 5),
                                     reel: "AC042003", kind: kind)
        let made = try CleanDNG.make(fromOriginal: original)
        let orig = try TIFFHeader(original.prefix(FrameHeader.headerBytes))
        let clean = try TIFFHeader(made.dng)

        t.expectEqual(clean.ascii(DNGTag.make), "Ikonoskop", "\(name) Make")
        t.expectEqual(clean.ascii(DNGTag.model), "A-Cam dII", "\(name) Model")
        t.expectEqual(clean.entries.filter { $0.tag == DNGTag.whiteLevel }.count, 1, "\(name) one WhiteLevel")
        t.expectEqual(clean.uint(DNGTag.whiteLevel), 4095, "\(name) WhiteLevel")
        t.expectEqual(clean.uint(DNGTag.compression), 7, "\(name) lossless JPEG")
        t.expect(clean.rationals(DNGTag.baselineExposure).map { $0.count == 1 && $0[0] == (0, 1) } ?? false,
                 "\(name) BaselineExposure 0")
        for gone in [DNGTag.dngPrivateData, DNGTag.stripOffsets, DNGTag.stripByteCounts, DNGTag.rowsPerStrip, 0] {
            t.expect(clean.entry(gone) == nil, "\(name) has no tag 0x\(String(gone, radix: 16))")
        }
        t.expect(zip(clean.entries, clean.entries.dropFirst()).allSatisfy { $0.tag < $1.tag }, "\(name) tags ascending")
        if kind == 0 {
            t.expect(clean.entry(DNGTag.calibrationIlluminant1) == nil, "monochrome has no illuminants")
        } else {
            t.expectEqual(clean.uint(DNGTag.calibrationIlluminant1), 20, "\(name) illuminant 1 = D55")
            t.expectEqual(clean.uint(DNGTag.calibrationIlluminant2), 24, "\(name) illuminant 2 = ISO studio tungsten")
            // The template's per-channel black levels (greens 80) become the one measured level.
            t.expectEqual(clean.uints(DNGTag.blackLevel), [90, 90, 90, 90], "\(name) black level 90 in every CFA position")
        }
        // Every other original tag is kept with the same type, count and value bytes: timecodes,
        // frame rate, reel name, colour matrices, CFA pattern, crop, a monochrome frame's black level, ...
        let changed = CleanDNG.replacedTags.union(kind == 0 ? [] : [DNGTag.blackLevel])
        var seen = Set<UInt16>()
        for e in orig.entries where !changed.contains(e.tag) && seen.insert(e.tag).inserted {
            guard let c = clean.entry(e.tag) else {
                t.expect(false, "\(name) lost tag 0x\(String(e.tag, radix: 16))")
                continue
            }
            t.expect(c.type == e.type && c.count == e.count && clean.value(c) == orig.value(e),
                     "\(name) tag 0x\(String(e.tag, radix: 16)) unchanged")
        }

        // A camera DNG developed directly (a-card prores without clean/) gets the same black level,
        // and nothing else in the file changes.
        let patched = try CleanDNG.correctingBlackLevel(ofOriginal: original)
        if kind == 0 {
            t.expect(patched == original, "monochrome camera DNG unchanged")
        } else if let e = orig.entry(DNGTag.blackLevel) {
            let header = try TIFFHeader(patched.prefix(FrameHeader.headerBytes))
            t.expectEqual(header.uints(DNGTag.blackLevel), clean.uints(DNGTag.blackLevel), "\(name) camera DNG black level as in the clean DNG")
            let differing = zip(patched.indices, zip(patched, original)).filter { $0.1.0 != $0.1.1 }.map { $0.0 }
            t.expect(patched.count == original.count && differing.allSatisfy { (e.valueOffset..<e.valueOffset + e.byteCount).contains($0) },
                     "\(name) camera DNG: only the BlackLevel values change")
        }
        t.expect(try CleanDNG.correctingBlackLevel(ofOriginal: made.dng) == made.dng, "\(name) clean DNG left as it is")
        t.expect(try CleanDNG.samples(ofClean: made.dng) == CleanDNG.samples(ofOriginal: original), "\(name) pixels")
        t.expectEqual(made.samples.count, 2048 * 1092, "\(name) sample count")
    }
}
