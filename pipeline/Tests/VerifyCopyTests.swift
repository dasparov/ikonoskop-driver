import Foundation

private let takes = [FixtureTake(frames: 2, seed: 400), FixtureTake(frames: 3, seed: 500),
                     FixtureTake(frames: 1, seed: 600)]

/// A copy of fixture card 42 made by a card job with audio and clean DNGs, so every take has
/// three generations (frames, WAV, clean DNGs). Returns the card folder of the copy.
private func makeCopy(_ t: TestContext) throws -> URL {
    let dir = try t.scratchDirectory("source")
    let card = try Fixture.card(in: dir.appendingPathComponent("card"), number: 42, takes: takes)
    let dest = dir.appendingPathComponent("dest")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let dump = Fixture.eepromDump(number: 42, takes: takes)
    let frames = takes.reduce(0) { $0 + $1.frames }
    let offload = OffloadOptions(source: card, destination: dest, eeprom: try EepromImage.parseHexDump(dump),
                                 eepromText: dump,
                                 kernelLog: { Fixture.cleanLog(number: 42, takes: takes.count, frames: frames) })
    let job = CardJob(CardJobOptions(offload: offload, audio: true, clean: true))
    job.progress = { _ in }
    let result = try job.run()
    t.expect(result.allVerified, "the fixture copy verified")
    return result.offload.cardFolder
}

/// A fresh duplicate of `copy` in scratch folder `name`, to damage without touching the original.
private func duplicate(_ t: TestContext, _ copy: URL, _ name: String) throws -> URL {
    let out = try t.scratchDirectory(name).appendingPathComponent(copy.lastPathComponent)
    try FileManager.default.copyItem(at: copy, to: out)
    return out
}

private func take(_ r: CopyVerifyResult, _ name: String) -> VerifiedTake {
    r.takes.first { $0.name == name } ?? VerifiedTake(name: "absent \(name)")
}

func verifyCopyTests(_ t: TestContext) throws {
    let copy = try makeCopy(t)
    let fm = FileManager.default

    // Untouched: every take matches; each lists its frames, the WAV and the clean DNGs.
    let good = try CopyVerifier.verify(copy)
    t.expect(good.ok, "untouched copy matches: \(good.takes)")
    t.expectEqual(good.takes.map { $0.name }, ["AC042001", "AC042002", "AC042003"])
    t.expectEqual(good.takes.map { $0.files }, takes.map { 2 * $0.frames + 1 }, "frames + WAV + clean DNGs")
    for v in good.takes {
        let folder = copy.appendingPathComponent(v.name)
        let listed = CopyVerifier.filesOnDisk(folder)
        let bytes = try listed.reduce(Int64(0)) {
            $0 + ((try fm.attributesOfItem(atPath: folder.appendingPathComponent($1).path)[.size] as? Int64) ?? 0)
        }
        t.expectEqual(v.bytes, bytes, "\(v.name) bytes read")
        t.expect(v.unlisted.isEmpty, "\(v.name) has no unlisted files: \(v.unlisted)")
    }

    // One flipped byte in a frame.
    let flipped = try duplicate(t, copy, "flipped")
    let frameDir = flipped.appendingPathComponent("AC042002/frames")
    let frame = try fm.contentsOfDirectory(atPath: frameDir.path).sorted()[1]
    var bytes = try Data(contentsOf: frameDir.appendingPathComponent(frame))
    bytes[bytes.count / 2] ^= 0x01
    try bytes.write(to: frameDir.appendingPathComponent(frame))
    let r1 = try CopyVerifier.verify(flipped)
    t.expect(!r1.ok, "a flipped byte fails the copy")
    t.expectEqual(take(r1, "AC042002").mismatched, ["frames/\(frame)"])
    t.expect(take(r1, "AC042001").ok && take(r1, "AC042003").ok, "the other takes still match")

    // A deleted WAV is missing.
    let noWav = try duplicate(t, copy, "no-wav")
    try fm.removeItem(at: noWav.appendingPathComponent("AC042001/AC042001_Audio.wav"))
    let r2 = try CopyVerifier.verify(noWav)
    t.expect(!r2.ok, "a missing WAV fails the copy")
    t.expectEqual(take(r2, "AC042001").missing, ["AC042001_Audio.wav"])
    t.expect(take(r2, "AC042001").mismatched.isEmpty, "missing is not reported as changed")

    // A stray file is a warning only; hidden files are ignored.
    let stray = try duplicate(t, copy, "stray")
    try Data("notes".utf8).write(to: stray.appendingPathComponent("AC042003/clean/notes.txt"))
    try Data("finder".utf8).write(to: stray.appendingPathComponent("AC042003/.DS_Store"))
    let r3 = try CopyVerifier.verify(stray)
    t.expect(r3.ok, "a stray file does not fail the copy: \(r3.takes)")
    t.expectEqual(take(r3, "AC042003").unlisted, ["clean/notes.txt"])

    // An edited generation no longer matches its C4 id in the chain, even with the hashes intact.
    let edited = try duplicate(t, copy, "edited-generation")
    let ascmhl = edited.appendingPathComponent("AC042002/ascmhl")
    let first = try fm.contentsOfDirectory(atPath: ascmhl.path).filter { $0.hasPrefix("0001_") }.first ?? "?"
    let manifestURL = ascmhl.appendingPathComponent(first)
    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    try manifest.replacingOccurrences(of: "<process>transfer</process>", with: "<process>in-place</process>")
        .write(to: manifestURL, atomically: true, encoding: .utf8)
    let r4 = try CopyVerifier.verify(edited)
    t.expect(!r4.ok, "an edited generation fails the copy")
    t.expect(take(r4, "AC042002").problems.contains { $0.contains(first) }, "problem names \(first): \(take(r4, "AC042002").problems)")
    t.expect(take(r4, "AC042002").mismatched.isEmpty, "the files themselves still match")

    // A later generation that re-lists a file overrides the earlier hash.
    let relisted = try duplicate(t, copy, "relisted")
    let folder = relisted.appendingPathComponent("AC042001")
    let wav = folder.appendingPathComponent("AC042001_Audio.wav")
    let newWav = try Data(contentsOf: wav) + Data([1, 2, 3, 4])
    try newWav.write(to: wav)
    try ASCMHL.addGeneration(folder: folder, entries: [MHLEntry(path: wav.lastPathComponent, size: newWav.count, modified: Date(),
                                                                xxh64: XXHash64.hash(newWav), hashDate: Date())],
                             process: "in-place")
    let r5 = try CopyVerifier.verify(relisted)
    t.expect(r5.ok, "the latest generation's hash counts: \(r5.takes)")

    // A single take folder.
    let single = try CopyVerifier.verify(copy.appendingPathComponent("AC042002"))
    t.expectEqual(single.takes.map { $0.name }, ["AC042002"])
    t.expect(single.ok, "a single take folder matches")

    // A take folder without a history fails; a folder without takes is refused.
    let unverified = try duplicate(t, copy, "unverified")
    try fm.createDirectory(at: unverified.appendingPathComponent("AC042009/frames"), withIntermediateDirectories: true)
    let r6 = try CopyVerifier.verify(unverified)
    t.expect(!r6.ok, "a take without a history fails the copy")
    t.expectEqual(take(r6, "AC042009").problems, [CopyVerifier.noHistory])
    var refused = ""
    do {
        _ = try CopyVerifier.verify(copy.deletingLastPathComponent())
    } catch {
        refused = "\(error)"
    }
    t.expect(refused.contains("no take folder"), "a folder without takes is refused: \(refused)")

    // Cancelled part-way: what was checked comes back, marked stopped.
    var asked = 0
    let r7 = try CopyVerifier.verify(copy, isCancelled: { asked += 1; return asked > 8 })
    t.expect(r7.stopped && !r7.ok, "a cancelled check is stopped and not OK")
    t.expect(!r7.takes.isEmpty && r7.takes.count < 3, "stopped inside the takes: \(r7.takes.map { $0.name })")
}
