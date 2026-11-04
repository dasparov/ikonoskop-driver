import Foundation

private let takes = [FixtureTake(frames: 2, seed: 100), FixtureTake(frames: 3, seed: 200),
                     FixtureTake(frames: 1, seed: 300)]

/// Card 42 with `takes` in <scratch>/card, an empty <scratch>/dest, and a card job configured
/// with a matching EEPROM dump and a clean driver log.
private func setUp(_ t: TestContext, _ name: String, takes: [FixtureTake] = takes,
                   eeprom: String? = nil, clean: Bool = false) throws -> (card: URL, dest: URL, job: CardJob) {
    let dir = try t.scratchDirectory(name)
    let card = try Fixture.card(in: dir.appendingPathComponent("card"), number: 42, takes: takes)
    let dest = dir.appendingPathComponent("dest")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let dump = eeprom ?? Fixture.eepromDump(number: 42, takes: takes)
    let frames = takes.reduce(0) { $0 + $1.frames }
    let offload = OffloadOptions(source: card, destination: dest, eeprom: try EepromImage.parseHexDump(dump),
                                 eepromText: dump,
                                 kernelLog: { Fixture.cleanLog(number: 42, takes: takes.count, frames: frames) })
    let job = CardJob(CardJobOptions(offload: offload, clean: clean))
    job.progress = { _ in }
    return (card, dest, job)
}

private func report(_ result: OffloadResult) throws -> String {
    try String(contentsOf: result.cardFolder.appendingPathComponent("REPORT.md"), encoding: .utf8)
}

/// (path, xxh64) of every <hash> in an ASC MHL manifest.
private func manifestHashes(_ url: URL) throws -> [String: String] {
    let doc = try XMLDocument(data: try Data(contentsOf: url))
    var listed: [String: String] = [:]
    for hash in try doc.nodes(forXPath: "//*[local-name()='hash']") {
        let path = try hash.nodes(forXPath: "*[local-name()='path']").first?.stringValue ?? ""
        listed[path] = try hash.nodes(forXPath: "*[local-name()='xxh64']").first?.stringValue
    }
    return listed
}

func offloadVerifiedTests(_ t: TestContext) throws {
    let s = try setUp(t, "verified", clean: true)
    let job = try s.job.run()
    let r = job.offload
    t.expect(job.allVerified, "all verified; problems: \(r.cardProblems + r.takes.flatMap { $0.problems })")
    t.expectEqual(r.takes.map { $0.name }, ["AC042001", "AC042002", "AC042003"])
    t.expectEqual(r.takes.map { $0.files.count }, [2, 3, 1])

    let fm = FileManager.default
    for take in try CardVolume.open(s.card).takes {
        let folder = r.cardFolder.appendingPathComponent(take.name)
        for f in take.frames {
            // The copy is byte-identical and keeps the source modification date.
            let copy = folder.appendingPathComponent("frames").appendingPathComponent(f.name)
            t.expect(try Data(contentsOf: copy) == Data(contentsOf: f.url), "\(take.name)/\(f.name) identical")
            let src = try fm.attributesOfItem(atPath: f.url.path)[.modificationDate] as? Date ?? .distantPast
            let dst = try fm.attributesOfItem(atPath: copy.path)[.modificationDate] as? Date ?? .distantFuture
            // FAT (the card) and HFS+ keep whole seconds.
            t.expect(abs(dst.timeIntervalSince(src)) < 1, "\(f.name) modification date \(dst) vs \(src)")
            // The clean DNG holds the same pixels.
            let clean = folder.appendingPathComponent("clean").appendingPathComponent(f.name)
            t.expect(try CleanDNG.samples(ofClean: Data(contentsOf: clean)) == CleanDNG.samples(ofOriginal: Data(contentsOf: f.url)),
                     "\(take.name)/clean/\(f.name) pixels")
        }
        // Generation 1 lists the copies with the xxHash64 of the source files, generation 2 the
        // WAV, generation 3 the clean DNGs; the chain lists all three with their C4 ids.
        let ascmhl = folder.appendingPathComponent("ascmhl")
        let manifests = try fm.contentsOfDirectory(atPath: ascmhl.path).filter { $0.hasSuffix(".mhl") }.sorted()
        t.expectEqual(manifests.count, 3, "\(take.name) manifests")
        guard manifests.count == 3 else {
            continue
        }
        t.expect(manifests[0].hasPrefix("0001_\(take.name)_") && manifests[0].hasSuffix("Z.mhl"), "name \(manifests[0])")
        let generations = try manifests.map { try manifestHashes(ascmhl.appendingPathComponent($0)) }
        for f in take.frames {
            t.expectEqual(generations[0]["frames/\(f.name)"], XXHash64.hex(XXHash64.hash(try Data(contentsOf: f.url))),
                          "manifest hash of \(f.name)")
        }
        t.expectEqual(generations[0].count, take.frames.count, "generation 1 entries")
        let wav = "\(take.name)_Audio.wav"
        t.expectEqual(generations[1][wav], XXHash64.hex(XXHash64.hash(try Data(contentsOf: folder.appendingPathComponent(wav)))),
                      "generation 2 lists the WAV")
        t.expectEqual(Set(generations[2].keys), Set(take.frames.map { "clean/\($0.name)" }), "generation 3 lists the clean DNGs")
        let chain = try ASCMHL.readChain(ascmhl.appendingPathComponent("ascmhl_chain.xml"))
        t.expectEqual(chain.map { $0.path }, manifests, "chain lists every manifest")
        t.expectEqual(chain.first?.c4, ASCMHL.c4(try Data(contentsOf: ascmhl.appendingPathComponent(manifests[0]))),
                      "chain C4 of generation 1")
    }
    let text = try report(r)
    t.expect(text.hasSuffix("**ALL VERIFIED**\n"), "report ends with ALL VERIFIED")
    t.expect(text.contains("| AC042002 | 3 | 0:00:00.12 | 24 | 01:00:00:00 | 01:00:00:02 | OK (3) | OK,"),
             "take row with frames, duration, rate, timecodes and clean status:\n\(text)")
    t.expect(text.contains("matches: 3 takes, 6 frames"), "take table summary")
    t.expect(fm.fileExists(atPath: r.cardFolder.appendingPathComponent("EEPROM.txt").path), "EEPROM.txt kept")
}

func offloadCorruptCopyTests(_ t: TestContext) throws {
    let s = try setUp(t, "corrupt-copy", clean: true)
    // Flip one byte of take 2's second frame on the destination disk after it was written.
    s.job.offload.afterCopy = { url in
        guard url.path.contains("AC042002"), url.lastPathComponent == "04200004.DNG",
              let h = FileHandle(forUpdatingAtPath: url.path) else {
            return
        }
        h.seek(toFileOffset: 0x200000)
        let b = h.readData(ofLength: 1)
        h.seek(toFileOffset: 0x200000)
        h.write(Data([b[0] ^ 0x01]))
        h.closeFile()
    }
    let job = try s.job.run()
    let r = job.offload
    t.expect(!job.allVerified, "a corrupted copy must not verify")
    t.expectEqual(r.takes.map { $0.failed }, [false, true, false], "only take 2 fails")
    t.expect(r.takes[1].problems.contains { $0.contains("04200004.DNG") && $0.contains("copy on disk differs") },
             "names the bad file: \(r.takes[1].problems)")
    t.expect(r.takes[1].manifest == nil, "no manifest for the failed take")
    t.expect(job.clean["AC042002"] == nil, "no clean DNGs made from a failed take")
    t.expect(job.clean["AC042001"] != nil && job.clean["AC042003"] != nil, "clean DNGs for the good takes")
    let text = try report(r)
    t.expect(text.hasSuffix("**PROBLEMS FOUND**\n"), "report ends with PROBLEMS FOUND")
    t.expect(text.contains("**FAILED** (2 of 3 OK)"), "take row shows the failure")
}

func offloadFlakySourceTests(_ t: TestContext) throws {
    // The card's flash sometimes returns different data for the same frame: 04200001 reads wrong
    // once (the second read) and right afterwards; 04200006 never reads the same twice.
    let s = try setUp(t, "flaky-source")
    var calls: [String: Int] = [:]
    s.job.offload.verificationRead = { path, buffer in
        let n = try FileIO.read(path, into: buffer)
        let name = URL(fileURLWithPath: path).lastPathComponent
        calls[name, default: 0] += 1
        if name == "04200001.DNG" && calls[name] == 1 {
            buffer[0x100000] ^= 0x80
        } else if name == "04200006.DNG" {
            buffer[0x200000 + calls[name]!] ^= 0x01
        }
        return n
    }
    let r = try s.job.run().offload
    let files = r.takes.flatMap { $0.files }
    let f1 = files.first { $0.name == "04200001.DNG" }!
    t.expect(f1.verified && !f1.rewritten && f1.sourceReads == 3, "a bad second read is resolved by a third: \(f1)")
    let f6 = files.first { $0.name == "04200006.DNG" }!
    t.expect(!f6.verified && f6.sourceReads == Offload.maxSourceReads, "never two equal reads: \(f6)")
    t.expect(r.takes[2].problems.contains { $0.contains("04200006.DNG") && $0.contains("different version each of the 8 times") },
             "reports the frame that never read the same: \(r.takes[2].problems)")
    t.expectEqual(r.takes.map { $0.failed }, [false, false, true], "only the take with the unreadable frame fails")
    t.expect(r.cardWarnings.contains { $0.contains("read each of them again") }, "explains the re-reads: \(r.cardWarnings)")
}

func offloadRereadReplacesBadCopyTests(_ t: TestContext) throws {
    // The first read (the copy) was wrong; every later read returns the same, different data.
    let s = try setUp(t, "bad-first-read")
    let name = "04200004.DNG"
    let source = try Data(contentsOf: s.card.appendingPathComponent("IMAGE/AC042002/\(name)"))
    var later = source
    later[0x200000] ^= 0x04
    s.job.offload.verificationRead = { path, buffer in
        let n = try FileIO.read(path, into: buffer)
        if path.hasSuffix(name) {
            buffer[0x200000] ^= 0x04
        }
        return n
    }
    let job = try s.job.run()
    let r = job.offload
    let f = r.takes[1].files.first { $0.name == name }!
    t.expect(f.verified && f.rewritten && f.sourceReads == 3, "two later reads agree, the copy is replaced: \(f)")
    let copy = r.cardFolder.appendingPathComponent("AC042002/frames/\(name)")
    t.expect(try Data(contentsOf: copy) == later, "the copy now holds the version read twice")
    t.expect(!FileManager.default.fileExists(atPath: copy.path + ".acam-reread"), "no temporary file left")
    t.expect(job.allVerified, "resolved re-reads still verify: \(r.cardProblems + r.takes.flatMap { $0.problems })")
    let text = try report(r)
    t.expect(text.contains("OK (3; 1 read again)"), "the take row counts the re-read:\n\(text)")
}

func offloadFirstFrameTests(_ t: TestContext) throws {
    // Take 3 starts with take 1's first frame (the 2026-11-01 bug served take 1 for every take).
    var dup = takes
    dup[2].seed = dup[0].seed
    let s = try setUp(t, "first-frames", takes: dup)
    let r = try s.job.run().offload
    t.expect(!r.allVerified, "duplicate first frames are a problem")
    t.expect(r.takes[2].problems.contains { $0.contains("same image data as AC042001's first frame") },
             "names the take it duplicates: \(r.takes[2].problems)")
    t.expect(!r.takes[0].failed && !r.takes[1].failed, "the other takes are fine")
}

func offloadTakeTableTests(_ t: TestContext) throws {
    // The EEPROM has a fourth take, after an invalid entry (the driver stops at the gap), and
    // take 2 with more frames than the volume lists.
    var table = takes + [FixtureTake(frames: 5, seed: 400)]
    table[1].frames = 4
    let s = try setUp(t, "take-table", eeprom: Fixture.eepromDump(number: 42, takes: table, invalid: [3]))
    let r = try s.job.run().offload
    t.expect(!r.allVerified, "take table differences are problems")
    t.expect(r.cardProblems.contains { $0.contains("AC042005") && $0.contains("missing") },
             "reports the take after the gap as missing: \(r.cardProblems)")
    t.expect(r.takes[1].problems.contains { $0.contains("take table says 4 frames; the volume has 3") },
             "reports the frame count: \(r.takes[1].problems)")

    // Without a dump the check is not done, which is not ALL VERIFIED either.
    let dir = try t.scratchDirectory("no-eeprom")
    let card = try Fixture.card(in: dir.appendingPathComponent("card"), number: 42, takes: takes)
    let options = OffloadOptions(source: card, destination: dir,
                                 kernelLog: { Fixture.cleanLog(number: 42, takes: 3, frames: 6) })
    let o = Offload(options)
    o.progress = { _ in }
    let r2 = try o.run()
    t.expect(!r2.allVerified && r2.cardProblems.contains { $0.contains("take table was not checked") },
             "missing EEPROM dump is reported: \(r2.cardProblems)")

    // Entries after the empty one that are older than every listed take are left over from
    // earlier recordings on the card: a warning, not a problem.
    var current = takes
    for i in current.indices {
        current[i].created = Fixture.fatTime(2019, 12, 4, 13, 16 + i)
    }
    let old = [FixtureTake(frames: 7, seed: 500, created: Fixture.fatTime(2019, 11, 27, 11, 19)),
               FixtureTake(frames: 9, seed: 600, created: Fixture.fatTime(2015, 10, 8, 14, 40))]
    let s3 = try setUp(t, "take-table-history", eeprom: Fixture.eepromDump(number: 42, takes: current + old, invalid: [3]))
    let r3 = try s3.job.run().offload
    t.expect(r3.allVerified, "older entries are not problems: \(r3.cardProblems)")
    t.expect(r3.cardWarnings.contains { $0.contains("2 entries from earlier recordings") && $0.contains("2015-10-08 14:40 to 2019-11-27 11:19") },
             "summarised as a warning: \(r3.cardWarnings)")
    t.expect(r3.takeTableSummary.contains("matches: 3 takes, 6 frames; 2 older entries"), r3.takeTableSummary)
}

func offloadKernelLogTests(_ t: TestContext) throws {
    let s = try setUp(t, "kernel-log")
    let before = Date(timeIntervalSinceNow: -60)
    let line = { (text: String) in
        KernelLogLine(date: before, text: "2026-01-01 00:00:00.000 Df kernel[0:1] (IkonoskopCardReader) \(text)")
    }
    let log = [
        line("IkonoskopCardReader: start (arm64e port of v1.2)"),
        line("IkonoskopCardReader[core]: ERROR: eeprom_create_frame2page_table, corrupted data take 2, block =65535!"),
        line("IkonoskopCardReader[core]: fpga_read_dma ERROR: frame 3 (page 9) not read"),
        line("IkonoskopCardReader[core]: flash geometry not reported (FLASH_SIZE 0x0, FLASH_ERASE_SIZE 0x0), using 0x12c0000 / 0x2800"),
    ]
    var options = s.job.options.offload
    options.kernelLog = { log }
    let o = Offload(options)
    o.progress = { _ in }
    let r = try o.run()
    t.expect(r.takes[2].problems.contains { $0.contains("corrupted data take 2") }, "take index 2 is AC042003")
    t.expect(r.takes[1].problems.contains { $0.contains("frame 3 (page 9) not read") }, "frame 3 is in take 2")
    t.expect(!r.takes[0].failed, "take 1 unaffected")
    t.expect(r.cardWarnings.contains { $0.contains("flash geometry not reported") }, "geometry fallback is a warning")

    // A driver start after the offload began means the reader was reconnected.
    let restart = [line("IkonoskopCardReader: start (arm64e port of v1.2)"),
                   KernelLogLine(date: Date(timeIntervalSinceNow: 3600), text: "x IkonoskopCardReader: start (arm64e port of v1.2)")]
    let found = KernelLog.session(restart, offloadStart: Date())
    t.expect(found.found && found.restarted, "restart detected")
}

func offloadRefusesExistingTests(_ t: TestContext) throws {
    let s = try setUp(t, "existing")
    let existing = s.dest.appendingPathComponent("ACAM 042")
    try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
    try Data("keep me".utf8).write(to: existing.appendingPathComponent("note.txt"))
    var threw = false
    do {
        _ = try s.job.run()
    } catch {
        threw = true
    }
    t.expect(threw, "refuses a destination that already has the card folder")
    t.expectEqual(try FileManager.default.contentsOfDirectory(atPath: existing.path), ["note.txt"],
                  "nothing written into it")
    t.expectEqual(try String(contentsOf: existing.appendingPathComponent("note.txt"), encoding: .utf8), "keep me")
}
