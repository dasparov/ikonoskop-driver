import Foundation

func colourProfileTests(_ t: TestContext) throws {
    // A profile folder like pipeline/colour/profiles/<id>/.
    let folder = try t.scratchDirectory("profile")
    let json = """
        {"id": "test", "name": "Test profile", "calibrationIlluminant1": 17, "calibrationIlluminant2": 21,
         "colorMatrix1": [1.7863, -1.0426, 0.2259, -0.339, 1.2733, 0.2132, -0.1371, 0.2676, 0.8788],
         "colorMatrix2": [1.11, -0.4159, -0.0387, -0.3333, 1.129, 0.1725, -0.2375, 0.3805, 0.654],
         "forwardMatrix1": [0.5978, 0.3368, 0.0296, 0.1272, 0.9434, -0.0707, 0.1531, -0.5373, 1.2091],
         "forwardMatrix2": null, "rationalDenominator": 10000}
        """
    try Data(json.utf8).write(to: folder.appendingPathComponent("profile.json"))
    let (profile, _) = try ColourProfile.load(folder)

    let original = Fixture.frame(seed: 5, fps: 24, timecode: Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0),
                                 reel: "AC042001", kind: 2)
    let clean = try TIFFHeader(try CleanDNG.make(fromOriginal: original, profile: profile).dng)
    t.expectEqual(clean.uint(DNGTag.calibrationIlluminant1), 17, "profile illuminant 1")
    t.expectEqual(clean.uint(DNGTag.calibrationIlluminant2), 21, "profile illuminant 2")
    t.expectEqual(clean.ascii(DNGTag.profileName), "Test profile")
    let cm1 = clean.rationals(DNGTag.colorMatrix1) ?? []
    t.expectEqual(cm1.map { $0.0 }, [17863, -10426, 2259, -3390, 12733, 2132, -1371, 2676, 8788], "ColorMatrix1 numerators")
    t.expect(cm1.allSatisfy { $0.1 == 10_000 }, "denominator 10000")
    t.expectEqual(clean.rationals(DNGTag.forwardMatrix1)?.count, 9, "ForwardMatrix1 written")
    t.expect(clean.entry(DNGTag.forwardMatrix2) == nil, "no ForwardMatrix2 in the profile, none in the DNG")
    t.expectEqual(clean.entries.filter { $0.tag == DNGTag.colorMatrix1 }.count, 1, "factory ColorMatrix1 replaced")

    // A monochrome frame has no colour matrices, so the profile is not applied.
    let mono = Fixture.frame(seed: 6, fps: 24, timecode: Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0),
                             reel: "AC042001", kind: 0)
    let monoClean = try TIFFHeader(try CleanDNG.make(fromOriginal: mono, profile: profile).dng)
    t.expect(monoClean.entry(DNGTag.colorMatrix1) == nil && monoClean.entry(DNGTag.profileName) == nil,
             "monochrome stays without colour tags")
}
