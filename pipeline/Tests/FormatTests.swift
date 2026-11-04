import Foundation

func eepromTests(_ t: TestContext) throws {
    let takes = [FixtureTake(frames: 300, seed: 1, fps: 25), FixtureTake(frames: 2, seed: 2)]
    let e = try EepromImage.parseHexDump(Fixture.eepromDump(number: 102, takes: takes, invalid: [1]))
    t.expectEqual(e.cardNumber, 102)
    t.expectEqual(e.validTakes.map { $0.index }, [0, 2], "valid entries, including the one after the gap")
    t.expectEqual(e.validTakes.map { $0.frames }, [300, 2])
    t.expectEqual(e.validTakes.first?.frameRateCode, 25)
    t.expectEqual(e.folderName(index: 2), "AC102003")

    // A dump missing its last line is rejected rather than read as zeros.
    let truncated = Fixture.eepromDump(number: 102, takes: takes).split(separator: "\n").dropLast().joined(separator: "\n")
    var threw = false
    do {
        _ = try EepromImage.parseHexDump(truncated)
    } catch {
        threw = true
    }
    t.expect(threw, "truncated dump rejected")
}

func ascmhlTests(_ t: TestContext) throws {
    // Reference values from the ascmhl implementation's C4 algorithm (hasher.py).
    t.expectEqual(ASCMHL.c4(Data()),
                  "c459dsjfscH38cYeXXYogktxf4Cd9ibshE3BHUo6a58hBXmRQdZrAkZzsWcbWtDg5oQstpDuni4Hirj75GEmTc1sFT")
    t.expectEqual(ASCMHL.c4(Data("acam".utf8)),
                  "c44L13Xg1hUGfh4ULGymxDbr7Au795wYV4abr9Nig5XQDecBqYhjQkXLjXXz93Vzp4m9BWkGgseyeMEnFjoK6AJ71x")

    // A second generation gets the next number and both stay in the chain.
    let folder = try t.scratchDirectory("AC001001")
    let entry = MHLEntry(path: "a & b.wav", size: 3, modified: Date(timeIntervalSince1970: 0), xxh64: 0xff, hashDate: Date())
    let first = try ASCMHL.addGeneration(folder: folder, entries: [entry], process: "transfer",
                                         created: Date(timeIntervalSince1970: 1_800_000_000))
    let second = try ASCMHL.addGeneration(folder: folder, entries: [entry], process: "in-place",
                                          created: Date(timeIntervalSince1970: 1_800_000_060))
    t.expectEqual(first.lastPathComponent, "0001_AC001001_2027-01-15_080000Z.mhl")
    t.expectEqual(second.lastPathComponent, "0002_AC001001_2027-01-15_080100Z.mhl")
    let chain = try ASCMHL.readChain(folder.appendingPathComponent("ascmhl/ascmhl_chain.xml"))
    t.expectEqual(chain.map { $0.sequence }, [1, 2])
    t.expectEqual(chain.last?.c4, ASCMHL.c4(try Data(contentsOf: second)))
    let xml = try String(contentsOf: first, encoding: .utf8)
    t.expect(xml.contains("<path size=\"3\" lastmodificationdate=\"1970-01-01T00:00:00+00:00\">a &amp; b.wav</path>"),
             "path escaped, size and date:\n\(xml)")
    t.expect(xml.contains("<xxh64 action=\"original\""), "xxh64 element")

    // readGeneration gives back what manifestXML wrote, in order and to the second.
    let entries = [entry,
                   MHLEntry(path: "frames/10200001.DNG", size: 3_317_760, modified: Date(timeIntervalSince1970: 1_799_999_999),
                            xxh64: 0x0123_4567_89ab_cdef, hashDate: Date(timeIntervalSince1970: 1_800_000_001)),
                   MHLEntry(path: "clean/<odd>\"name\".DNG", size: 0, modified: Date(timeIntervalSince1970: 1_800_000_002),
                            xxh64: .max, hashDate: Date(timeIntervalSince1970: 1_800_000_003))]
    let generation = folder.appendingPathComponent("roundtrip.mhl")
    try Data(ASCMHL.manifestXML(entries: entries, process: "transfer", created: Date()).utf8).write(to: generation)
    let read = try ASCMHL.readGeneration(generation)
    let fields = { (e: MHLEntry) in
        "\(e.path)|\(e.size)|\(Int(e.modified.timeIntervalSince1970))|\(e.xxh64)|\(Int(e.hashDate.timeIntervalSince1970))"
    }
    t.expectEqual(read.map(fields), entries.map(fields), "generation round trip")

    // A hash that is not 16 hex digits is refused.
    try xml.replacingOccurrences(of: ">00000000000000ff<", with: ">00000000000000fg<")
        .write(to: generation, atomically: true, encoding: .utf8)
    var refused = ""
    do {
        _ = try ASCMHL.readGeneration(generation)
    } catch {
        refused = "\(error)"
    }
    t.expect(refused.contains("xxh64") && refused.contains("a & b.wav"), "invalid xxh64 refused: \(refused)")
}

func timecodeTests(_ t: TestContext) throws {
    let tc = Timecode(hours: 23, minutes: 59, seconds: 58, frames: 23)
    t.expectEqual(Timecode(smpte: tc.smpte), tc, "SMPTE bytes round trip")
    t.expectEqual(tc.smpte.prefix(4).map { $0 }, [0x23, 0x58, 0x59, 0x23], "BCD layout")
    t.expectEqual(tc.frameCount(fps: 24), ((23 * 60 + 59) * 60 + 58) * 24 + 23)
    t.expectEqual(Timecode(frameCount: tc.frameCount(fps: 24) + 1, fps: 24).description, "23:59:59:00")
}
