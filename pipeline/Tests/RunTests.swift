import Foundation

private let takes = [FixtureTake(frames: 2, seed: 700), FixtureTake(frames: 3, seed: 800),
                     FixtureTake(frames: 1, seed: 900)]

/// Card 42 with `takes` in <scratch>/card, empty <scratch>/dest and <scratch>/second, and job
/// options (audio and clean DNGs) with a matching EEPROM dump and a clean driver log. What would
/// go to the Trash goes to <scratch>/trash.
private func setUp(_ t: TestContext, _ name: String, takes: [FixtureTake] = takes,
                   seed: UInt64 = 0) throws -> (dir: URL, dest: URL, second: URL, options: CardJobOptions) {
    let dir = try t.scratchDirectory(name)
    let shifted = takes.map { FixtureTake(frames: $0.frames, seed: $0.seed + seed) }
    let card = try Fixture.card(in: dir.appendingPathComponent("card"), number: 42, takes: shifted)
    let dest = dir.appendingPathComponent("dest"), second = dir.appendingPathComponent("second")
    for folder in [dest, second] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    FileIO.trashFolder = dir.appendingPathComponent("trash")
    let dump = Fixture.eepromDump(number: 42, takes: shifted)
    let frames = takes.reduce(0) { $0 + $1.frames }
    let offload = OffloadOptions(source: card, destination: dest, eeprom: try EepromImage.parseHexDump(dump),
                                 eepromText: dump,
                                 kernelLog: { Fixture.cleanLog(number: 42, takes: takes.count, frames: frames) })
    return (dir, dest, second, CardJobOptions(offload: offload, audio: true, clean: true))
}

private func run(_ options: CardJobOptions, _ configure: (CardJob) -> Void = { _ in }) throws -> CardJobResult {
    let job = CardJob(options)
    job.progress = { _ in }
    configure(job)
    return try job.run()
}

/// The error a run throws, as text ("" when it does not throw).
private func refusal(_ options: CardJobOptions, _ configure: (CardJob) -> Void = { _ in }) -> String {
    do {
        _ = try run(options, configure)
        return ""
    } catch {
        return "\(error)"
    }
}

/// Relative path -> bytes of every file below `folder`, without ascmhl/ and hidden files.
private func contents(_ folder: URL) throws -> [String: Data] {
    var out: [String: Data] = [:]
    guard let walk = FileManager.default.enumerator(atPath: folder.path) else {
        return out
    }
    while let path = walk.nextObject() as? String {
        let name = (path as NSString).lastPathComponent
        if name == "ascmhl" || name.hasPrefix(".") {
            walk.skipDescendants()
            continue
        }
        if walk.fileAttributes?[.type] as? FileAttributeType == .typeRegular {
            out[path] = try Data(contentsOf: folder.appendingPathComponent(path))
        }
    }
    return out
}

private func problems(_ job: CardJobResult) -> [String] {
    job.problems + job.offload.cardProblems + job.offload.takes.flatMap { $0.problems + $0.secondProblems }
        + (job.second?.problems ?? [])
}

/// Runs `body` with <second> on what looks like another drive.
private func separateDrives(_ second: URL, _ body: () throws -> Void) rethrows {
    let real = CardPlan.volumeID
    CardPlan.volumeID = { url in
        real(url).map { url.path.hasPrefix(second.path) ? $0 &+ 1 : $0 }
    }
    defer { CardPlan.volumeID = real }
    try body()
}

func runSecondCopyTests(_ t: TestContext) throws {
    let s = try setUp(t, "second")
    var options = s.options
    options.offload.secondDestination = s.second
    t.expect(refusal(options).contains("another drive"), "both copies on one drive are refused")
    try separateDrives(s.second) {
        let job = try run(options)
        t.expect(job.verdict == .allVerified, "\(job.headline): \(problems(job))")
        let first = s.dest.appendingPathComponent("ACAM 042"), second = s.second.appendingPathComponent("ACAM 042")
        let files = try contents(first)
        t.expect(files.keys.contains("AC042002/clean/04200003.DNG") && files.keys.contains("AC042002/AC042002_Audio.wav"),
                 "the first copy has frames, WAV and clean DNGs: \(files.keys.sorted())")
        t.expect(try contents(second) == files, "the second copy holds the same files, report included")
        for take in job.offload.takes {
            let mine = try TakeHistory.read(first.appendingPathComponent(take.name))?.entries ?? [:]
            let theirs = try TakeHistory.read(second.appendingPathComponent(take.name))?.entries ?? [:]
            t.expectEqual(theirs.mapValues { $0.xxh64 }, mine.mapValues { $0.xxh64 }, "\(take.name): the second history lists every file with its hash")
            t.expect(take.second && take.secondManifest != nil, "\(take.name) frames written to both as the card was read")
        }
        t.expect(try String(contentsOf: second.appendingPathComponent("REPORT.md"), encoding: .utf8).contains("| Second copy |"),
                 "the report describes the second copy")
        let check = try CopyVerifier.verify(second)
        t.expect(check.ok && check.takes.map { $0.files } == [5, 7, 3], "the second copy verifies on its own: \(check.takes)")

        // Without the drive the run is refused, not made with one copy: choosing single-drive
        // runs is up to the caller (the app leaves the second destination out).
        var gone = options
        gone.offload.secondDestination = s.dir.appendingPathComponent("unplugged")
        t.expect(refusal(gone).contains("not connected"), "a second destination that is not there is refused")
    }
}

func runSecondCopyFailsTests(_ t: TestContext) throws {
    let s = try setUp(t, "second-fails")
    var options = s.options
    options.offload.secondDestination = s.second
    let second = s.second.appendingPathComponent("ACAM 042")
    try separateDrives(s.second) {
        // One frame of take 2 is damaged on the second drive only.
        let job = try run(options) { job in
            job.offload.afterCopy = { url in
                if url.path.hasPrefix(second.path) && url.lastPathComponent == "04200004.DNG" {
                    var data = try! Data(contentsOf: url)
                    data[9_000] ^= 0x10
                    try! data.write(to: url)
                }
            }
        }
        let take = job.offload.takes[1]
        t.expect(!take.failed && take.manifest != nil, "the first copy of AC042002 is verified")
        t.expect(take.secondFailed && take.secondManifest == nil, "its second copy failed and has no checksum history")
        t.expect(take.secondProblems.contains { $0.contains("04200004.DNG") }, "the damaged frame is named: \(take.secondProblems)")
        t.expect(job.verdict == .problems, "a failed second copy is a problem: \(job.headline)")
        t.expect(!FileManager.default.fileExists(atPath: second.appendingPathComponent("AC042002/AC042002_Audio.wav").path),
                 "nothing more is added to the failed take")

        // Processing the card again into the same folders repairs the second copy from the first.
        options.offload.addToExisting = true
        let repair = try run(options)
        t.expect(repair.verdict == .allVerified, "\(repair.headline): \(problems(repair))")
        t.expect(repair.offload.takes.allSatisfy { $0.copiedEarlier }, "no take is read from the card again")
        t.expect(try contents(second) == contents(s.dest.appendingPathComponent("ACAM 042")), "the second copy is whole again")
        t.expect(try contents(s.dir.appendingPathComponent("trash")).keys.contains { $0.hasSuffix("AC042002/frames/04200004.DNG") },
                 "the unfinished second copy of AC042002 went to the Trash")
    }
}

func runSpaceTests(_ t: TestContext) throws {
    let s = try setUp(t, "space")
    let footage = Int64(takes.reduce(0) { $0 + $1.frames }) * Int64(Offload.frameFileBytes)
    // Room for the copies and the WAVs, not for the clean DNGs: refused before anything is written.
    let room = footage + 100_000
    let why = refusal(s.options) { $0.freeSpace = { _ in room } }
    t.expect(why.contains("Not enough space"), "refused: \(why)")
    t.expectEqual(try FileManager.default.contentsOfDirectory(atPath: s.dest.path), [], "nothing written")
    var noClean = s.options
    noClean.clean = false
    t.expectEqual(refusal(noClean) { $0.freeSpace = { _ in room } }, "", "the copies and WAVs alone fit")

    // The second destination is checked as well.
    var two = s.options
    two.offload.secondDestination = s.second
    two.offload.destination = s.dir.appendingPathComponent("dest-two")
    try FileManager.default.createDirectory(at: two.offload.destination, withIntermediateDirectories: true)
    separateDrives(s.second) {
        let second = refusal(two) { job in job.freeSpace = { $0.path.hasPrefix(s.second.path) ? room : footage * 4 } }
        t.expect(second.contains("second copy"), "the second drive's space is checked: \(second)")
    }
}

func runStopTests(_ t: TestContext) throws {
    // Stopped while copying: nothing of the run is kept.
    let s = try setUp(t, "stop-copy")
    var stopped = false
    do {
        _ = try run(s.options) { job in
            job.offload.afterCopy = { _ in job.stop.set() }
        }
    } catch is StoppedError {
        stopped = true
    }
    t.expect(stopped, "the run stops with StoppedError")
    t.expectEqual(try FileManager.default.contentsOfDirectory(atPath: s.dest.path), [], "no card folder is left")

    // Stopped while making the clean DNGs: the verified copies stay, the report says STOPPED.
    let late = try setUp(t, "stop-outputs")
    let job = try run(late.options) { job in
        job.progress = { if $0.hasPrefix("clean") { job.stop.set() } }
    }
    let folder = job.offload.cardFolder
    t.expect(job.verdict == .stopped, "verdict \(job.headline)")
    t.expectEqual(job.headline, "STOPPED: 3 of 3 takes copied and verified")
    t.expect(job.offload.takes.allSatisfy { $0.manifest != nil }, "every take's copies are verified and listed")
    t.expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("AC042001/clean").path),
             "the unfinished clean DNGs are removed")
    t.expectEqual(job.notMade, ["AC042001: clean DNGs", "AC042002: audio WAV, clean DNGs", "AC042003: audio WAV, clean DNGs"])
    let report = try String(contentsOf: folder.appendingPathComponent("REPORT.md"), encoding: .utf8)
    t.expect(report.hasSuffix("**STOPPED: 3 of 3 takes copied and verified**\n"), "report ends STOPPED")

    // Processing again into the same folder makes what is missing.
    var again = late.options
    again.offload.addToExisting = true
    let finished = try run(again)
    t.expect(finished.verdict == .allVerified, "\(finished.headline): \(problems(finished))")
    t.expectEqual(finished.audio.keys.sorted(), ["AC042002", "AC042003"], "only the missing WAVs are made")
    t.expectEqual(finished.clean.keys.sorted(), ["AC042001", "AC042002", "AC042003"])
    t.expect(try String(contentsOf: folder.appendingPathComponent("REPORT-1.md"), encoding: .utf8) == report,
             "the stopped run's report is kept as REPORT-1.md")
    t.expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("EEPROM-1.txt").path), "and its EEPROM.txt")
}

func runAddMissingTests(_ t: TestContext) throws {
    let s = try setUp(t, "add")
    let fm = FileManager.default
    var some = s.options
    some.offload.takes = ["AC042002"]
    let partial = try run(some)
    t.expect(partial.verdict == .partial, partial.headline)
    let folder = partial.offload.cardFolder
    let kept = folder.appendingPathComponent("AC042002/frames/04200003.DNG")
    let before = try fm.attributesOfItem(atPath: kept.path)

    var add = s.options
    add.offload.addToExisting = true
    let job = try run(add)
    t.expect(job.verdict == .allVerified, "\(job.headline): \(problems(job))")
    t.expectEqual(job.offload.takes.map { "\($0.name) \($0.copiedEarlier ? "kept" : "copied")" },
                  ["AC042001 copied", "AC042002 kept", "AC042003 copied"])
    let after = try fm.attributesOfItem(atPath: kept.path)
    t.expect(after[.systemFileNumber] as? Int == before[.systemFileNumber] as? Int
             && after[.modificationDate] as? Date == before[.modificationDate] as? Date, "the kept take's files are untouched")
    t.expectEqual(try fm.contentsOfDirectory(atPath: folder.appendingPathComponent("AC042002/ascmhl").path).filter { $0.hasSuffix(".mhl") }.count,
                  3, "the kept take's history is unchanged")
    let report = try String(contentsOf: folder.appendingPathComponent("REPORT.md"), encoding: .utf8)
    t.expect(report.contains("| Takes | 3 (2 copied in this run, 1 by an earlier run) |"), "report counts both runs:\n\(report)")
    t.expect(report.contains("| AC042002 | 3 |") && report.contains("OK (3, earlier run)") && report.contains("OK (earlier run)"),
             "the kept take's row")
    t.expect(report.contains("`REPORT-1.md`"), "the report names the earlier one")
    t.expect(refusal(add).contains("nothing to add"), "a complete folder has nothing to add")
    let check = try CopyVerifier.verify(folder)
    t.expect(check.ok && check.takes.count == 3, "the card folder verifies after both runs: \(check.takes)")

    // An unfinished take folder (no checksum history) goes to the Trash and the take is copied.
    let u = try setUp(t, "add-unfinished")
    let unfinished = u.dest.appendingPathComponent("ACAM 042/AC042001/frames")
    try fm.createDirectory(at: unfinished, withIntermediateDirectories: true)
    try Data(count: 10).write(to: unfinished.appendingPathComponent("04200001.DNG"))
    var addU = u.options
    addU.offload.addToExisting = true
    let repaired = try run(addU)
    t.expect(repaired.verdict == .allVerified, "\(repaired.headline): \(problems(repaired))")
    t.expect(repaired.offload.cardWarnings.contains { $0.contains("unfinished copy") }, "the report says so")
    t.expectEqual(try contents(u.dir.appendingPathComponent("trash")).map { $0.value.count }, [10], "the unfinished copy is in the Trash")

    // A folder holding another recording under the same names is refused and left alone.
    let other = try setUp(t, "add-other", seed: 5_000)
    _ = try run(other.options)
    let mine = try setUp(t, "add-mine")
    var into = mine.options
    into.offload.destination = other.dest
    into.offload.addToExisting = true
    let untouched = try contents(other.dest)
    let why = refusal(into)
    t.expect(why.contains("another recording"), "refused: \(why)")
    t.expect(try contents(other.dest) == untouched, "nothing changed")

    // A take folder that is not on the card means the folder is from another recording.
    try fm.moveItem(at: other.dest.appendingPathComponent("ACAM 042/AC042003"),
                    to: other.dest.appendingPathComponent("ACAM 042/AC042009"))
    try fm.removeItem(at: other.dest.appendingPathComponent("ACAM 042/AC042001"))
    try fm.removeItem(at: other.dest.appendingPathComponent("ACAM 042/AC042002"))
    let foreign = refusal(into)
    t.expect(foreign.contains("AC042009"), "refused: \(foreign)")
}

func runOutputsFromCopyTests(_ t: TestContext) throws {
    // Copies only, then the card is gone: the outputs are made from the copies alone.
    let s = try setUp(t, "outputs")
    var copiesOnly = s.options
    copiesOnly.audio = false
    copiesOnly.clean = false
    let job = try run(copiesOnly)
    t.expect(job.verdict == .allVerified, "\(job.headline): \(problems(job))")
    let folder = job.offload.cardFolder
    try FileManager.default.removeItem(at: s.dir.appendingPathComponent("card"))
    let made = try CopyOutputs.make(folder, CopyOutputsOptions(audio: true, clean: true))
    t.expectEqual(made.headline, "OUTPUTS MADE", "\(made.lines)")
    t.expectEqual(made.audio.keys.sorted(), ["AC042001", "AC042002", "AC042003"])
    t.expectEqual(made.clean.keys.sorted(), ["AC042001", "AC042002", "AC042003"])
    let check = try CopyVerifier.verify(folder)
    t.expect(check.ok && check.takes.map { $0.files } == [5, 7, 3], "the new files are in the checksum histories: \(check.takes)")
    let report = try String(contentsOf: folder.appendingPathComponent("REPORT.md"), encoding: .utf8)
    t.expect(report.contains("**ALL VERIFIED**") && report.contains("## Outputs made later")
             && report.hasSuffix("**OUTPUTS MADE**\n"), "the run is added to the end of the report:\n\(report)")
    let before = try contents(folder)
    let again = try CopyOutputs.make(folder, CopyOutputsOptions(audio: true, clean: true))
    t.expectEqual(again.headline, "NOTHING TO MAKE")
    t.expect(try contents(folder) == before, "a second run changes nothing")

    // A frame changed on the drive: that take gets no clean DNGs, the others do.
    let d = try setUp(t, "outputs-changed")
    var copies = d.options
    copies.audio = false
    copies.clean = false
    let changed = try run(copies).offload.cardFolder
    let flip = { (url: URL) in
        var data = try Data(contentsOf: url)
        data[9_000] ^= 0x10
        try data.write(to: url)
    }
    try flip(changed.appendingPathComponent("AC042002/frames/04200004.DNG"))
    let r = try CopyOutputs.make(changed, CopyOutputsOptions(audio: false, clean: true))
    t.expectEqual(r.headline, "PROBLEMS FOUND")
    t.expect(r.clean["AC042002"]?.problems.contains { $0.contains("04200004.DNG") && $0.contains("checksum") } == true,
             "the changed frame is named: \(r.allProblems)")
    t.expect(r.clean["AC042001"]?.failed == false && r.clean["AC042003"]?.failed == false, "the other takes get clean DNGs")
    // A changed first frame: nothing is made for that take.
    try flip(changed.appendingPathComponent("AC042003/frames/04200006.DNG"))
    let r2 = try CopyOutputs.make(changed, CopyOutputsOptions(audio: true, clean: false))
    t.expect(r2.audio["AC042003"] == nil && r2.problems.contains { $0.contains("AC042003") && $0.contains("first frame") },
             "AC042003 is left alone: \(r2.allProblems)")
    t.expect(r2.audio["AC042001"]?.failed == false, "AC042001 gets its WAV")
    // Too little room: refused before anything is written.
    var why = ""
    do {
        _ = try CopyOutputs.make(changed, CopyOutputsOptions(audio: false, clean: true), freeSpace: { _ in 1_000 })
    } catch {
        why = "\(error)"
    }
    t.expect(why.contains("Not enough space"), "refused: \(why)")
}

func runDetailsTests(_ t: TestContext) throws {
    // The camera's COL. TEMP setting from the header template.
    let tc = Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0)
    for (kind, balance) in [(0, WhiteBalance.monochrome), (1, .tungsten), (2, .daylight)] {
        let frame = Fixture.frame(seed: 1, fps: 24, timecode: tc, reel: "AC042001", kind: kind)
        t.expectEqual(try FrameHeader(frame.prefix(FrameHeader.headerBytes)).whiteBalance, balance, "template \(kind)")
    }

    // A driver log error in a take that was not chosen stays with that take.
    let s = try setUp(t, "log-chosen")
    var options = s.options.offload
    options.takes = ["AC042003"]
    options.kernelLog = {
        [KernelLogLine(date: Date(timeIntervalSinceNow: -60), text: "x IkonoskopCardReader: start (arm64e port of v1.2)"),
         KernelLogLine(date: Date(timeIntervalSinceNow: -60), text: "x IkonoskopCardReader[core]: fpga_read_dma ERROR: frame 0 (page 0) not read")]
    }
    let o = Offload(options)
    o.progress = { _ in }
    let r = try o.run()
    t.expect(!r.takes[0].failed, "AC042003 is not blamed for AC042001's frame: \(r.takes[0].problems)")
    t.expect(r.cardProblems.contains { $0.contains("AC042001, not copied") && $0.contains("frame 0") }, "\(r.cardProblems)")
}
