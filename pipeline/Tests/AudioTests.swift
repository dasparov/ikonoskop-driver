import Foundation

/// `count` stereo pairs of a ramp continuing across frames; channel 2's lowest bit is 0 as on
/// the camera.
private func pairs(from start: Int, count: Int) -> Data {
    var d = Data()
    for i in start..<start + count {
        d.append16(UInt16(bitPattern: Int16(truncatingIfNeeded: i % 30_000 - 15_000)))
        d.append16(UInt16(bitPattern: Int16(truncatingIfNeeded: (i * 2) % 30_000 - 15_000)) & 0xfffe)
    }
    return d
}

/// A take folder <scratch>/<name>/AC042001 whose frames/ hold one frame per audio block.
private func take(_ t: TestContext, _ name: String, blocks: [Data]) throws -> URL {
    let folder = try t.scratchDirectory(name).appendingPathComponent("AC042001")
    let frames = folder.appendingPathComponent("frames")
    try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
    for (i, block) in blocks.enumerated() {
        let tc = Timecode(frameCount: Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0).frameCount(fps: 24) + i, fps: 24)
        try Fixture.frame(seed: UInt64(i), fps: 24, timecode: tc, reel: "AC042001", audio: block)
            .write(to: frames.appendingPathComponent(String(format: "042%05d.DNG", i + 1)))
    }
    return folder
}

/// The payload of each top-level RIFF chunk.
private func chunks(_ wav: Data) -> [String: Data] {
    var out: [String: Data] = [:]
    var at = 12
    while at + 8 <= wav.count {
        let id = String(decoding: wav.subdata(in: at..<at + 4), as: UTF8.self)
        let size = Int(wav.u32(at + 4))
        out[id] = wav.subdata(in: at + 8..<min(at + 8 + size, wav.count))
        at += 8 + size + (size & 1)
    }
    return out
}

func audioTests(_ t: TestContext) throws {
    // Three frames at 24 fps, the second with the occasional extra pair.
    let counts = [2000, 2001, 2000]
    var blocks: [Data] = []
    var next = 0
    for c in counts {
        blocks.append(pairs(from: next, count: c))
        next += c
    }
    let folder = try take(t, "stream", blocks: blocks)
    let r = try AudioTake.run(take: folder)
    t.expect(!r.failed && r.warnings.isEmpty, "clean extraction: \(r.problems) \(r.warnings)")
    t.expectEqual(r.samplePairs, 6001)
    t.expect(abs(r.drift - 1.0 / 48_000) < 1e-9, "drift is the one extra pair: \(r.drift)")

    let wav = try Data(contentsOf: folder.appendingPathComponent("AC042001_Audio.wav"))
    t.expectEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
    t.expectEqual(Int(wav.u32(4)), wav.count - 8, "RIFF size")
    let c = chunks(wav)
    guard let fmt = c["fmt "], let bext = c["bext"], let data = c["data"] else {
        t.expect(false, "fmt, bext and data chunks: \(c.keys.sorted())")
        return
    }
    t.expectEqual([fmt.u16(0), fmt.u16(2), fmt.u16(14)], [1, 2, 16], "PCM, 2 channels, 16 bit")
    t.expectEqual(fmt.u32(4), 48_000, "sample rate")
    // TimeReference: 01:00:00:00 at 24 fps in samples since midnight.
    let reference = UInt64(bext.u32(338)) | UInt64(bext.u32(342)) << 32
    t.expectEqual(reference, 3600 * 48_000, "bext TimeReference")
    t.expectEqual(bext.u16(346), 1, "bext version")
    t.expect(data == blocks.reduce(Data(), +), "samples copied unchanged, in frame order")
    t.expect(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("ascmhl").path)
                .contains { $0.hasSuffix(".mhl") }, "WAV recorded in the ASC MHL history")

    // A block without an end marker is cut to 2,001 pairs, a short one padded to 1,999.
    var full = Data()
    for i in 0..<CameraAudio.blockBytes / 4 {
        full.append(pairs(from: i, count: 1))
    }
    let odd = try take(t, "odd", blocks: [full, pairs(from: 0, count: 100)])
    let r2 = try AudioTake.run(take: odd)
    t.expectEqual(r2.samplePairs, 2001 + 1999, "clamped to the expected count")
    t.expectEqual(r2.warnings.count, 2, "both frames reported: \(r2.warnings)")
}
