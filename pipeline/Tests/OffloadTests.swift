import Foundation

private let takes = [FixtureTake(frames: 2, seed: 100), FixtureTake(frames: 3, seed: 200),
                     FixtureTake(frames: 1, seed: 300)]

/// Card 42 with `takes` in <scratch>/card, an empty <scratch>/dest, and an offload configured
/// with a matching EEPROM dump and a clean driver log.
private func setUp(_ t: TestContext, _ name: String, takes: [FixtureTake] = takes,
                   eeprom: String? = nil) throws -> (card: URL, dest: URL, offload: Offload) {
    let dir = try t.scratchDirectory(name)
    let card = try Fixture.card(in: dir.appendingPathComponent("card"), number: 42, takes: takes)
    let dest = dir.appendingPathComponent("dest")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let dump = eeprom ?? Fixture.eepromDump(number: 42, takes: takes)
    let frames = takes.reduce(0) { $0 + $1.frames }
    let options = OffloadOptions(source: card, destination: dest, eeprom: try EepromImage.parseHexDump(dump),
                                 eepromText: dump,
                                 kernelLog: { Fixture.cleanLog(number: 42, takes: takes.count, frames: frames) })
    let offload = Offload(options)
    offload.progress = { _ in }
    return (card, dest, offload)
}

private func report(_ result: OffloadResult) throws -> String {
    try String(contentsOf: result.cardFolder.appendingPathComponent("REPORT.md"), encoding: .utf8)
}

func offloadVerifiedTests(_ t: TestContext) throws {
    let s = try setUp(t, "verified")
    let r = try s.offload.run()
    t.expect(r.allVerified, "all verified; problems: \(r.cardProblems + r.takes.flatMap { $0.problems })")
    t.expectEqual(r.takes.map { $0.name }, ["AC042001", "AC042002", "AC042003"])
    t.expectEqual(r.takes.map { $0.files.count }, [2, 3, 1])

    let fm = FileManager.default
    for take in try CardVolume.open(s.card).takes {
        let folder = r.cardFolder.appendingPathComponent(take.name)
        // The copies are byte-identical and keep the source modification date.
        for f in take.frames {
            let copy = folder.appendingPathComponent("frames").appendingPathComponent(f.name)
            t.expect(try Data(contentsOf: copy) == Data(contentsOf: f.url), "\(take.name)/\(f.name) identical")
            let src = try fm.attributesOfItem(atPath: f.url.path)[.modificationDate] as? Date ?? .distantPast
            let dst = try fm.attributesOfItem(atPath: copy.path)[.modificationDate] as? Date ?? .distantFuture
            // FAT (the card) and HFS+ keep whole seconds.
            t.expect(abs(dst.timeIntervalSince(src)) < 1, "\(f.name) modification date \(dst) vs \(src)")
        }
        // The manifest lists every frame with the xxHash64 of the source file.
        let ascmhl = folder.appendingPathComponent("ascmhl")
        let manifests = try fm.contentsOfDirectory(atPath: ascmhl.path).filter { $0.hasSuffix(".mhl") }
        t.expectEqual(manifests.count, 1, "\(take.name) manifests")
        guard let name = manifests.first else {
            continue
        }
        t.expect(name.hasPrefix("0001_\(take.name)_") && name.hasSuffix("Z.mhl"), "manifest name \(name)")
        let manifest = try Data(contentsOf: ascmhl.appendingPathComponent(name))
        let doc = try XMLDocument(data: manifest)
        var listed: [String: String] = [:]
        for hash in try doc.nodes(forXPath: "//*[local-name()='hash']") {
            let path = try hash.nodes(forXPath: "*[local-name()='path']").first?.stringValue ?? ""
            listed[path] = try hash.nodes(forXPath: "*[local-name()='xxh64']").first?.stringValue
        }
        for f in take.frames {
            t.expectEqual(listed["frames/\(f.name)"], XXHash64.hex(XXHash64.hash(try Data(contentsOf: f.url))),
                          "manifest hash of \(f.name)")
        }
        t.expectEqual(listed.count, take.frames.count, "manifest entries")
        let chain = try ASCMHL.readChain(ascmhl.appendingPathComponent("ascmhl_chain.xml"))
        t.expectEqual(chain.map { $0.path }, [name], "chain lists the manifest")
        t.expectEqual(chain.first?.c4, ASCMHL.c4(manifest), "chain C4 of the manifest")
    }
    let text = try report(r)
    t.expect(text.hasSuffix("**ALL VERIFIED**\n"), "report ends with ALL VERIFIED")
    t.expect(text.contains("| AC042002 | 3 | 0:00:00.12 | 24 | 01:00:00:00 | 01:00:00:02 | OK (3) |"),
             "take row with frames, duration, rate and timecodes:\n\(text)")
    t.expect(text.contains("matches: 3 takes, 6 frames"), "take table summary")
    t.expect(fm.fileExists(atPath: r.cardFolder.appendingPathComponent("EEPROM.txt").path), "EEPROM.txt kept")
}

func offloadCorruptCopyTests(_ t: TestContext) throws {
    let s = try setUp(t, "corrupt-copy")
    // Flip one byte of take 2's second frame on the destination disk after it was written.
    s.offload.afterCopy = { url in
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
    let r = try s.offload.run()
    t.expect(!r.allVerified, "a corrupted copy must not verify")
    t.expectEqual(r.takes.map { $0.failed }, [false, true, false], "only take 2 fails")
    t.expect(r.takes[1].problems.contains { $0.contains("04200004.DNG") && $0.contains("copy on disk differs") },
             "names the bad file: \(r.takes[1].problems)")
    t.expect(r.takes[1].manifest == nil, "no manifest for the failed take")
    t.expect(r.takes[0].manifest != nil && r.takes[2].manifest != nil, "manifests for the good takes")
    let text = try report(r)
    t.expect(text.hasSuffix("**PROBLEMS FOUND**\n"), "report ends with PROBLEMS FOUND")
    t.expect(text.contains("**FAILED** (2 of 3 OK)"), "take row shows the failure")
}

func offloadFlakySourceTests(_ t: TestContext) throws {
    let s = try setUp(t, "flaky-source")
    // The card returns different data the second time it is read.
    s.offload.verificationRead = { path, buffer in
        let n = try FileIO.read(path, into: buffer)
        if path.hasSuffix("04200001.DNG") {
            buffer[0x100000] ^= 0x80
        }
        return n
    }
    let r = try s.offload.run()
    t.expectEqual(r.takes.map { $0.failed }, [true, false, false], "take 1 fails")
    t.expect(r.takes[0].problems.contains { $0.contains("different data on the second read") },
             "reports the unstable read: \(r.takes[0].problems)")
}

func offloadFirstFrameTests(_ t: TestContext) throws {
    // Take 3 starts with take 1's first frame (the 2026-11-01 bug served take 1 for every take).
    var dup = takes
    dup[2].seed = dup[0].seed
    let s = try setUp(t, "first-frames", takes: dup)
    let r = try s.offload.run()
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
    let r = try s.offload.run()
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
    let options = OffloadOptions(source: s.offload.options.source, destination: s.offload.options.destination,
                                 eeprom: s.offload.options.eeprom, kernelLog: { log })
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
        _ = try s.offload.run()
    } catch {
        threw = true
    }
    t.expect(threw, "refuses a destination that already has the card folder")
    t.expectEqual(try FileManager.default.contentsOfDirectory(atPath: existing.path), ["note.txt"],
                  "nothing written into it")
    t.expectEqual(try String(contentsOf: existing.appendingPathComponent("note.txt"), encoding: .utf8), "keep me")
}
