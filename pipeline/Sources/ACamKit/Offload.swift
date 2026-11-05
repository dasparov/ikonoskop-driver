// Verified offload: copy the takes of a mounted card into <destination>/<card>/<take>/frames/
// (and, optionally, at the same time into a second destination), verify every copy with
// xxHash64, check the take table, the driver log and the first frames, and write an ASC MHL
// manifest per verified take. CardPlan decides beforehand which takes are copied; takes an earlier
// run already copied are kept and checked with the rest. CardJob adds the later steps and
// REPORT.md.
//
// Verification: each source file is hashed while it is copied, read a second time after every
// take has been copied (the driver's 8-frame cache and the file cache are long evicted by then),
// and its copies are read back from the destinations; all hashes must be equal.
import Foundation

struct OffloadOptions {
    var source: URL
    /// The card folder is made inside it; an existing one only with `addToExisting`.
    var destination: URL
    /// Take table from `ikctl eeprom`; without it the offload cannot report ALL VERIFIED.
    var eeprom: EepromImage?
    /// The `ikctl eeprom` text it was parsed from, kept as <card>/EEPROM.txt.
    var eepromText: String?
    /// Driver log lines since boot; nil skips the check (which counts as a problem).
    var kernelLog: (() throws -> [KernelLogLine])? = KernelLog.linesSinceBoot
    /// Take folders to copy, by name; nil copies every take. The others are listed in the report as
    /// not copied, and such a run is never ALL VERIFIED.
    var takes: Set<String>? = nil
    /// A second copy of everything, on another drive.
    var secondDestination: URL? = nil
    /// Add the takes and outputs an existing card folder lacks, instead of refusing it. Takes it
    /// already holds verified copies of are kept as they are; unfinished copies go to the Trash.
    var addToExisting = false
}

struct FileResult {
    let name: String
    let size: Int
    let modified: Date
    var copyHash: UInt64?
    var sourceHash: UInt64?
    var destinationHash: UInt64?
    var error: String?
    /// The second copy, when the take was also written to the second destination.
    var secondHash: UInt64?
    var secondError: String?
    /// Reads of the source file: 1 while copying, 2 after verification, more when the card
    /// returned different data and the frame was read again until two reads matched.
    var sourceReads = 1
    /// The copy was made from a bad read and replaced by the version two later reads agreed on.
    var rewritten = false

    var verified: Bool {
        error == nil && copyHash != nil && sourceHash == copyHash && destinationHash == copyHash
    }

    var secondVerified: Bool {
        verified && secondError == nil && secondHash == copyHash
    }
}

struct TakeResult {
    let name: String
    var files: [FileResult]
    var firstHeader: FrameHeader?
    var lastHeader: FrameHeader?
    /// xxHash64 of the first frame's raw data (everything after the 4 KiB header).
    var firstFrameRawHash: UInt64?
    var problems: [String] = []
    var warnings: [String] = []
    var manifest: URL?
    /// Copied and verified by an earlier run into the same card folder; kept as it was.
    var copiedEarlier = false
    /// Also written to the second destination while it was copied.
    var second = false
    var secondProblems: [String] = []
    var secondManifest: URL?

    var failed: Bool { !problems.isEmpty || files.contains { !$0.verified } }
    var secondFailed: Bool { second && (!secondProblems.isEmpty || files.contains { !$0.secondVerified }) }
    var bytes: Int { files.reduce(0) { $0 + $1.size } }
    var verifiedCount: Int { files.filter { $0.verified }.count }
    /// Frames the card returned differently at first, read until two reads matched.
    var rereadCount: Int { files.filter { $0.sourceReads > 2 }.count }
}

struct OffloadResult {
    let cardName: String
    let source: URL
    /// <destination>/<card name>
    let cardFolder: URL
    /// <second destination>/<card name>
    let secondFolder: URL?
    let started: Date
    var finished: Date
    /// Every take now in the card folder, in card order: copied in this run or kept from an
    /// earlier one (`copiedEarlier`).
    var takes: [TakeResult]
    var cardProblems: [String] = []
    var cardWarnings: [String] = []
    var takeTableSummary = ""
    var kernelLogSummary = ""
    var firstFrameSummary = ""
    /// Takes on the card that are not in the card folder: not chosen, so not copied.
    var notCopied: [String] = []

    var allVerified: Bool { cardProblems.isEmpty && !takes.contains { $0.failed } }
    var copiedNow: [TakeResult] { takes.filter { !$0.copiedEarlier } }
}

final class Offload {
    static let frameFileBytes = 0x336000

    let options: OffloadOptions
    var progress: (String) -> Void = { print($0) }
    var stop = StopSignal()
    /// Test seam: runs after each frame has been written (to either destination), before
    /// verification.
    var afterCopy: ((URL) -> Void)?
    /// Test seam: the second (verification) read of a source file.
    var verificationRead: (String, UnsafeMutableRawBufferPointer) throws -> Int = FileIO.read

    init(_ options: OffloadOptions) {
        self.options = options
    }

    /// Plans the run (CardPlan) and runs it; CardJob plans first to check the space.
    func run() throws -> OffloadResult {
        try run(CardPlan.make(CardJobOptions(offload: options, audio: false, clean: false)))
    }

    /// Copies `plan.copy`. Stopped, it removes the take folders it made and throws StoppedError:
    /// nothing is kept before every copy has been verified.
    func run(_ plan: CardPlan) throws -> OffloadResult {
        let fm = FileManager.default
        let card = plan.card
        let takes = plan.copy
        let cardFolder = plan.cardFolder
        let started = Date()
        var result = OffloadResult(cardName: card.name, source: card.url, cardFolder: cardFolder,
                                   secondFolder: plan.secondFolder, started: started, finished: started, takes: [])
        result.notCopied = plan.notCopied
        // Folders this run makes, removed again if it is stopped.
        var made: [URL] = []
        for folder in [cardFolder, plan.secondFolder].compactMap({ $0 }) where !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            made.append(folder)
        }
        for url in plan.unfinished {
            do {
                try FileIO.trash(url)
            } catch {
                throw FileIOError(description: "could not move the unfinished copy \(url.path) to the Trash (\(error.localizedDescription)); move it away and try again")
            }
            result.cardWarnings.append("`\(url.path)` held an unfinished copy from an earlier run: it was moved to the Trash and the take copied again.")
        }

        let maxSize = max(takes.flatMap { $0.frames.map { $0.size } }.max() ?? 0, 1)
        let buffers = (0..<(plan.secondFolder == nil ? 4 : 5)).map { _ in
            UnsafeMutableRawBufferPointer.allocate(byteCount: maxSize, alignment: 16_384)
        }
        defer { buffers.forEach { $0.deallocate() } }

        var copied: [TakeResult] = []
        do {
            for take in takes {
                try stop.check()
                let second = plan.copyToSecond.contains(take.name) ? plan.secondFolder : nil
                made += [cardFolder, second].compactMap { $0?.appendingPathComponent(take.name) }
                copied.append(try copy(take, into: cardFolder, second: second, buffers: Array(buffers[0..<3])))
            }
            for i in copied.indices {
                try verify(&copied[i], take: takes[i], cardFolder: cardFolder, second: plan.secondFolder,
                           buffers: Array(buffers[3...]) + [buffers[0]])
            }
            try rereadUnstable(&copied, takes: takes, cardFolder: cardFolder, second: plan.secondFolder,
                               buffers: (buffers[0], buffers[1]))
        } catch {
            // Nothing of this run is kept before every copy has been verified.
            for url in made.reversed() {
                try? fm.removeItem(at: url)
            }
            throw error
        }
        for i in copied.indices {
            recordFileProblems(&copied[i])
        }
        let reread = copied.reduce(0) { $0 + $1.rereadCount }
        if reread > 0 {
            result.cardWarnings.append("The card returned different data the second time \(reread) frames were read (random read errors of the card's flash). a-card read each of them again until two reads matched exactly and kept that version; any frame where no two reads matched is listed under Problems.")
        }
        let totalFrames = takes.reduce(0) { $0 + $1.frames.count }
        if totalFrames > 0 && totalFrames <= 8 {
            result.cardWarnings.append("Only \(totalFrames) frames: the second read may have come from the driver's 8-frame cache.")
        }
        // Every take in the card folder, in card order.
        let byName = Dictionary(uniqueKeysWithValues: copied.map { ($0.name, $0) })
        result.takes = card.takes.compactMap { t in byName[t.name] ?? plan.kept[t.name].map { keptResult(t, $0) } }
        for i in result.takes.indices {
            let t = result.takes[i]
            if t.files.isEmpty {
                result.takes[i].problems.append("The take folder has no frames.")
            }
            let odd = t.files.filter { $0.size != Offload.frameFileBytes }.count
            if odd > 0 {
                result.takes[i].warnings.append("\(odd) files are not \(Offload.frameFileBytes) bytes.")
            }
        }
        if !card.unexpectedFiles.isEmpty {
            result.cardWarnings.append("Files outside IMAGE/ (not copied): \(card.unexpectedFiles.joined(separator: ", ")).")
        }
        checkFirstFrames(&result)
        checkTakeTable(&result, card: card)
        checkKernelLog(&result, card: card)

        for i in result.takes.indices where !result.takes[i].copiedEarlier && !result.takes[i].failed {
            let t = result.takes[i]
            let entries = t.files.map {
                MHLEntry(path: "frames/\($0.name)", size: $0.size, modified: $0.modified,
                         xxh64: $0.copyHash!, hashDate: started)
            }
            do {
                result.takes[i].manifest = try ASCMHL.addGeneration(
                    folder: cardFolder.appendingPathComponent(t.name), entries: entries, process: "transfer",
                    created: started)
            } catch {
                result.takes[i].problems.append("Could not write the ASC MHL manifest: \(error)")
            }
            if let second = plan.secondFolder, t.second, !t.secondFailed {
                do {
                    result.takes[i].secondManifest = try ASCMHL.addGeneration(
                        folder: second.appendingPathComponent(t.name), entries: entries, process: "transfer",
                        created: started)
                } catch {
                    result.takes[i].secondProblems.append("Could not write the ASC MHL manifest: \(error)")
                }
            }
        }
        result.finished = Date()
        return result
    }

    /// A take an earlier run copied: its frames as that run's checksum history lists them.
    private func keptResult(_ take: TakeFolder, _ kept: KeptTake) -> TakeResult {
        var result = TakeResult(name: take.name, files: take.frames.map { f in
            let entry = kept.history.entries["frames/\(f.name)"]
            var file = FileResult(name: f.name, size: f.size, modified: entry?.modified ?? f.modified)
            file.copyHash = entry?.xxh64
            file.sourceHash = entry?.xxh64
            file.destinationHash = entry?.xxh64
            file.sourceReads = 2
            return file
        })
        result.copiedEarlier = true
        result.firstHeader = kept.firstHeader
        result.lastHeader = kept.lastHeader
        result.firstFrameRawHash = kept.firstFrameRawHash
        result.problems = kept.problems
        return result
    }

    // ---- copy pass -------------------------------------------------------------------------

    /// Reads each frame once and writes it to the destination and, with `second`, to the second
    /// destination at the same time.
    private func copy(_ take: TakeFolder, into cardFolder: URL, second: URL?,
                      buffers: [UnsafeMutableRawBufferPointer]) throws -> TakeResult {
        let fm = FileManager.default
        let dirs = [cardFolder, second].compactMap { $0?.appendingPathComponent(take.name).appendingPathComponent("frames") }
        for dir in dirs {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var result = TakeResult(name: take.name, files: take.frames.map {
            FileResult(name: $0.name, size: $0.size, modified: $0.modified)
        })
        result.second = second != nil
        let writers = dirs.map { _ in DispatchQueue(label: "acam.offload.writer") }
        let freeSlots = DispatchSemaphore(value: buffers.count)
        let lock = NSLock()
        // Per destination: frame index -> error. A slot is free again once every writer is done.
        var writeErrors: [[Int: String]] = dirs.map { _ in [:] }
        var pending = [Int](repeating: 0, count: buffers.count)
        let started = Date()
        var bytes = 0
        // Slots are handed out in turn and freed in the same order (each writer writes in order),
        // so the slot freed first is always the next one; a frame that could not be read hands its
        // slot to the next frame.
        var nextSlot = 0

        for (i, frame) in take.frames.enumerated() {
            if stop.isSet {
                break
            }
            freeSlots.wait()
            let slotIndex = nextSlot % buffers.count
            let slot = buffers[slotIndex]
            let length: Int
            do {
                length = try FileIO.read(frame.url.path, into: slot)
            } catch {
                result.files[i].error = "read: \(error)"
                freeSlots.signal()
                continue
            }
            let data = UnsafeRawBufferPointer(rebasing: slot[0..<length])
            result.files[i].copyHash = XXHash64.hash(data)
            if i == 0 || i == take.frames.count - 1 {
                let header = try? FrameHeader(Data(data.prefix(FrameHeader.headerBytes)))
                if i == 0 {
                    result.firstHeader = header
                    if length > FrameHeader.headerBytes {
                        result.firstFrameRawHash = XXHash64.hash(UnsafeRawBufferPointer(rebasing: data[FrameHeader.headerBytes...]))
                    }
                }
                if i == take.frames.count - 1 {
                    result.lastHeader = header
                }
            }
            bytes += length
            nextSlot += 1
            let modified = result.files[i].modified
            lock.lock()
            pending[slotIndex] = dirs.count
            lock.unlock()
            for (w, dir) in dirs.enumerated() {
                let destination = dir.appendingPathComponent(frame.name)
                writers[w].async { [afterCopy] in
                    do {
                        try FileIO.create(destination.path, bytes: data)
                        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
                        afterCopy?(destination)
                    } catch {
                        lock.lock()
                        writeErrors[w][i] = "write: \(error)"
                        lock.unlock()
                    }
                    lock.lock()
                    pending[slotIndex] -= 1
                    let free = pending[slotIndex] == 0
                    lock.unlock()
                    if free {
                        freeSlots.signal()
                    }
                }
            }
            if (i + 1) % 200 == 0 || i + 1 == take.frames.count {
                let mbps = Double(bytes) / 1_000_000 / max(Date().timeIntervalSince(started), 0.001)
                progress(String(format: "copy   %@  %5d/%d frames  %.0f MB/s", take.name, i + 1, take.frames.count, mbps))
            }
        }
        writers.forEach { $0.sync {} }
        try stop.check()
        for (i, error) in writeErrors[0] {
            result.files[i].error = error
        }
        if dirs.count > 1 {
            for (i, error) in writeErrors[1] {
                result.files[i].secondError = error
            }
        }
        for (w, dir) in dirs.enumerated() {
            let ok = result.files.indices.last {
                result.files[$0].error == nil && (w == 0 || result.files[$0].secondError == nil)
            }
            guard let last = ok else {
                continue
            }
            do {
                try FileIO.fullSync(dir.appendingPathComponent(result.files[last].name).path)
            } catch {
                if w == 0 {
                    result.problems.append("Could not flush the copies to disk: \(error)")
                } else {
                    result.secondProblems.append("Could not flush the copies to disk: \(error)")
                }
            }
        }
        return result
    }

    // ---- verification pass -----------------------------------------------------------------

    /// The second read of every frame, and the read-back of its copies. `buffers`: source, copy,
    /// second copy.
    private func verify(_ result: inout TakeResult, take: TakeFolder, cardFolder: URL, second: URL?,
                        buffers: [UnsafeMutableRawBufferPointer]) throws {
        let framesDir = cardFolder.appendingPathComponent(take.name).appendingPathComponent("frames")
        let secondDir = result.second ? second?.appendingPathComponent(take.name).appendingPathComponent("frames") : nil
        let started = Date()
        for (i, frame) in take.frames.enumerated() where result.files[i].error == nil {
            try stop.check()
            let sourcePath = frame.url.path
            let copyPath = framesDir.appendingPathComponent(frame.name).path
            var sourceOutcome: Result<UInt64, Error> = .failure(FileIOError(description: "not read"))
            var copyOutcome: Result<UInt64, Error> = .failure(FileIOError(description: "not read"))
            var secondOutcome: Result<UInt64, Error>?
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) { [verificationRead] in
                sourceOutcome = Result {
                    FileIO.evictCache(sourcePath)
                    let n = try verificationRead(sourcePath, buffers[0])
                    return XXHash64.hash(UnsafeRawBufferPointer(rebasing: buffers[0][0..<n]))
                }
            }
            DispatchQueue.global().async(group: group) {
                copyOutcome = Result {
                    FileIO.evictCache(copyPath)
                    let n = try FileIO.read(copyPath, into: buffers[1])
                    return XXHash64.hash(UnsafeRawBufferPointer(rebasing: buffers[1][0..<n]))
                }
            }
            if let dir = secondDir, result.files[i].secondError == nil {
                let path = dir.appendingPathComponent(frame.name).path
                DispatchQueue.global().async(group: group) {
                    secondOutcome = Result {
                        FileIO.evictCache(path)
                        let n = try FileIO.read(path, into: buffers[2])
                        return XXHash64.hash(UnsafeRawBufferPointer(rebasing: buffers[2][0..<n]))
                    }
                }
            }
            group.wait()
            switch sourceOutcome {
            case .success(let h):
                result.files[i].sourceHash = h
                result.files[i].sourceReads = 2
            case .failure(let e): result.files[i].error = "second read: \(e)"
            }
            switch copyOutcome {
            case .success(let h): result.files[i].destinationHash = h
            case .failure(let e): result.files[i].error = "copy read-back: \(e)"
            }
            switch secondOutcome {
            case .success(let h)?: result.files[i].secondHash = h
            case .failure(let e)?: result.files[i].secondError = "read-back: \(e)"
            case nil: break
            }
            if (i + 1) % 200 == 0 || i + 1 == take.frames.count {
                let mbps = Double(take.frames[0...i].reduce(0) { $0 + $1.size }) / 1_000_000
                    / max(Date().timeIntervalSince(started), 0.001)
                progress(String(format: "verify %@  %5d/%d frames  %.0f MB/s", take.name, i + 1, take.frames.count, mbps))
            }
        }
    }

    // ---- frames that read differently ------------------------------------------------------

    static let maxSourceReads = 8

    /// Reads each frame whose second read differed from the first again, up to maxSourceReads
    /// reads in all, until two reads agree byte for byte. That version is the verified one; if the
    /// copies were made from a bad read, they are replaced. Every re-read comes from the flash:
    /// the pending frames are read in turn with at least 8 other frames in between (the driver
    /// keeps the last 8 frames), and the file cache is dropped before each read.
    private func rereadUnstable(_ results: inout [TakeResult], takes: [TakeFolder], cardFolder: URL, second: URL?,
                                buffers: (UnsafeMutableRawBufferPointer, UnsafeMutableRawBufferPointer)) throws {
        var pending: [(take: Int, file: Int)] = []
        var seen: [Int: [UInt64]] = [:] // hashes read so far: the copy's first
        for (ti, t) in results.enumerated() {
            for (fi, f) in t.files.enumerated() where f.error == nil && f.destinationHash == f.copyHash
                && f.sourceHash != nil && f.sourceHash != f.copyHash {
                pending.append((ti, fi))
                seen[ti << 32 | fi] = [f.copyHash!, f.sourceHash!]
            }
        }
        guard !pending.isEmpty else {
            return
        }
        let pendingKeys = Set(seen.keys)
        let fillers = takes.enumerated().flatMap { ti, t in
            t.frames.enumerated().compactMap { fi, f in pendingKeys.contains(ti << 32 | fi) ? nil : f.url.path }
        }.prefix(8)
        progress("reread \(pending.count) frames that read differently the second time")
        for _ in 3...Offload.maxSourceReads where !pending.isEmpty {
            if pending.count <= 8 {
                for path in fillers {
                    FileIO.evictCache(path)
                    _ = try? FileIO.read(path, into: buffers.0)
                }
            }
            var still: [(take: Int, file: Int)] = []
            for p in pending {
                try stop.check()
                let frame = takes[p.take].frames[p.file]
                let key = p.take << 32 | p.file
                FileIO.evictCache(frame.url.path)
                guard let n = try? verificationRead(frame.url.path, buffers.0) else {
                    still.append(p)
                    continue
                }
                let data = UnsafeRawBufferPointer(rebasing: buffers.0[0..<n])
                let h = XXHash64.hash(data)
                var f = results[p.take].files[p.file]
                f.sourceReads += 1
                if h == f.copyHash {
                    f.sourceHash = h
                } else if seen[key]!.dropFirst().contains(h) {
                    let name = results[p.take].name
                    let path = { (folder: URL) in
                        folder.appendingPathComponent(name).appendingPathComponent("frames").appendingPathComponent(frame.name).path
                    }
                    do {
                        try replaceCopy(at: path(cardFolder), with: data, hash: h, modified: f.modified, scratch: buffers.1)
                        f.copyHash = h
                        f.sourceHash = h
                        f.destinationHash = h
                        f.rewritten = true
                        if p.file == 0 && n > FrameHeader.headerBytes {
                            results[p.take].firstFrameRawHash = XXHash64.hash(UnsafeRawBufferPointer(rebasing: data[FrameHeader.headerBytes...]))
                        }
                    } catch {
                        f.error = "could not replace the copy with the version read twice: \(error)"
                    }
                    if let second = second, results[p.take].second, f.error == nil, f.secondError == nil {
                        do {
                            try replaceCopy(at: path(second), with: data, hash: h, modified: f.modified, scratch: buffers.1)
                            f.secondHash = h
                        } catch {
                            f.secondError = "could not replace the copy with the version read twice: \(error)"
                        }
                    }
                } else {
                    seen[key]!.append(h)
                    still.append(p)
                }
                results[p.take].files[p.file] = f
            }
            pending = still
        }
    }

    /// Replaces this offload's own copy at `path` with `bytes`: written next to it, read back and
    /// checked, then renamed over it.
    private func replaceCopy(at path: String, with bytes: UnsafeRawBufferPointer, hash: UInt64, modified: Date,
                             scratch: UnsafeMutableRawBufferPointer) throws {
        let tmp = path + ".acam-reread"
        try FileIO.create(tmp, bytes: bytes)
        FileIO.evictCache(tmp)
        let n = try FileIO.read(tmp, into: scratch)
        guard XXHash64.hash(UnsafeRawBufferPointer(rebasing: scratch[0..<n])) == hash else {
            unlink(tmp)
            throw FileIOError(description: "the new copy did not read back correctly")
        }
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: tmp)
        guard rename(tmp, path) == 0 else {
            throw FileIO.failure("rename", tmp)
        }
        try FileIO.fullSync(path)
    }

    private func recordFileProblems(_ take: inout TakeResult) {
        for f in take.files where !f.verified {
            if let e = f.error {
                take.problems.append("\(f.name): \(e)")
            } else if f.destinationHash != f.copyHash {
                take.problems.append("\(f.name): the copy on disk differs from the card")
            } else {
                take.problems.append("\(f.name): the card returned a different version each of the \(f.sourceReads) times it was read")
            }
        }
        guard take.second else {
            return
        }
        for f in take.files where f.verified && !f.secondVerified {
            take.secondProblems.append("\(f.name): \(f.secondError ?? "the copy on disk differs from the card")")
        }
    }

    // ---- checks ----------------------------------------------------------------------------

    private func checkFirstFrames(_ result: inout OffloadResult) {
        var firstTakeWith: [UInt64: String] = [:]
        var duplicates = 0
        for i in result.takes.indices {
            guard let h = result.takes[i].firstFrameRawHash else {
                continue
            }
            if let other = firstTakeWith[h] {
                result.takes[i].problems.append("Its first frame has the same image data as \(other)'s first frame.")
                duplicates += 1
            } else {
                firstTakeWith[h] = result.takes[i].name
            }
        }
        let which = result.notCopied.isEmpty ? "all \(result.takes.count) takes" : "the \(result.takes.count) copied takes"
        result.firstFrameSummary = duplicates == 0
            ? "the first frames of \(which) are different"
            : "\(duplicates) takes start with another take's first frame"
    }

    private func checkTakeTable(_ result: inout OffloadResult, card: CardVolume) {
        guard let eeprom = options.eeprom else {
            result.takeTableSummary = "not checked"
            result.cardProblems.append("The take table was not checked: no EEPROM dump. Run `sudo tools/ikctl eeprom 0 0x2000 > eeprom.txt` and pass `--eeprom eeprom.txt`, or use `--read-eeprom`.")
            return
        }
        if let n = Int(card.name.filter { $0.isNumber }), n != eeprom.cardNumber {
            result.cardProblems.append("The EEPROM dump is from card \(eeprom.cardNumber), not \(card.name).")
        }
        // The driver lists the valid entries before the first invalid one. Valid entries after it
        // are either left over from earlier recordings on the card (older than every listed take,
        // their flash partly reused) or takes the driver does not show (newer): a problem.
        let valid = eeprom.validTakes
        let listed = valid.filter { $0.index < eeprom.listedCount }
        let after = valid.filter { $0.index > eeprom.listedCount }
        let newestListed = listed.map { $0.createdKey }.max()
        let hidden = after.filter { newestListed == nil || $0.createdKey >= newestListed! }
        let earlier = after.filter { newestListed != nil && $0.createdKey < newestListed! }
        var problems = 0
        // Compared with the card's volume, so takes that were not chosen for copying count too.
        for entry in listed {
            let name = eeprom.folderName(index: entry.index)
            guard let folder = card.takes.first(where: { $0.name == name }) else {
                result.cardProblems.append("Take \(name) (\(entry.frames) frames in the take table) is missing from the card's volume.")
                problems += 1
                continue
            }
            if folder.frames.count != entry.frames {
                let message = "The take table says \(entry.frames) frames; the volume has \(folder.frames.count)."
                if let i = result.takes.firstIndex(where: { $0.name == name }) {
                    result.takes[i].problems.append(message)
                } else {
                    result.cardProblems.append("\(name) (not copied): \(message)")
                }
                problems += 1
            }
        }
        for entry in hidden {
            result.cardProblems.append("Take \(eeprom.folderName(index: entry.index)) (\(entry.frames) frames, recorded \(entry.createdText)) is in the take table after an empty entry and is not older than the listed takes, but it is missing from the card's volume: the driver shows only the takes before the first empty entry.")
            problems += 1
        }
        for t in card.takes where !listed.contains(where: { eeprom.folderName(index: $0.index) == t.name }) {
            result.cardProblems.append("Take folder \(t.name) is not in the take table.")
            problems += 1
        }
        if let first = earlier.min(by: { $0.createdKey < $1.createdKey }),
           let last = earlier.max(by: { $0.createdKey < $1.createdKey }) {
            result.cardWarnings.append("The take table also keeps \(earlier.count) entries from earlier recordings on this card (\(first.createdText) to \(last.createdText)), after the end of the current list. They are older than every listed take, and the current takes were recorded over at least part of their flash. The driver does not show them, so they were not copied.")
        }
        let frames = listed.reduce(0) { $0 + $1.frames }
        result.takeTableSummary = problems == 0
            ? "matches: \(listed.count) takes, \(frames) frames" + (earlier.isEmpty ? "" : "; \(earlier.count) older entries from earlier recordings (see warnings)")
            : "\(problems) differences (see problems)"
    }

    private func checkKernelLog(_ result: inout OffloadResult, card: CardVolume) {
        guard let source = options.kernelLog else {
            result.kernelLogSummary = "not checked"
            result.cardProblems.append("The driver log was not checked.")
            return
        }
        let lines: [KernelLogLine]
        do {
            lines = try source()
        } catch {
            result.kernelLogSummary = "not readable"
            result.cardProblems.append("The driver log could not be read: \(error)")
            return
        }
        let session = KernelLog.session(lines, offloadStart: result.started)
        if session.restarted {
            result.cardProblems.append("The driver restarted during the offload (reader reconnected?): copies may be wrong.")
        }
        if !session.found {
            result.cardWarnings.append("No driver start found in the log since boot.")
        }
        var firstFrame: [Int] = []
        var sum = 0
        for t in card.takes {
            firstFrame.append(sum)
            sum += t.frames.count
        }
        let cardNumber = card.name.filter { $0.isNumber }
        var errors = 0
        // A finding about a take copied in this run is that take's problem. Takes an earlier run
        // copied were checked by that run: a finding about one of them is a warning.
        func record(_ message: String, take name: String?) {
            if let name = name, let i = result.takes.firstIndex(where: { $0.name == name }) {
                if result.takes[i].copiedEarlier {
                    result.cardWarnings.append("Driver log, \(name) (copied by an earlier run, see its report): \(message)")
                    return
                }
                result.takes[i].problems.append("Driver log: \(message)")
            } else {
                result.cardProblems.append("Driver log\(name.map { " (\($0), not copied)" } ?? ""): \(message)")
            }
            errors += 1
        }
        for f in KernelLog.findings(session.lines) {
            switch f.scope {
            case .card:
                if f.isWarning {
                    result.cardWarnings.append("Driver log: \(f.message)")
                } else {
                    result.cardProblems.append("Driver log: \(f.message)")
                    errors += 1
                }
            case .take(let n):
                record(f.message, take: "AC\(cardNumber)\(String(format: "%03d", n + 1))")
            case .frame(let n):
                record(f.message, take: firstFrame.lastIndex { $0 <= n }.map { card.takes[$0].name })
            }
        }
        result.kernelLogSummary = errors == 0 ? "no driver errors" : "\(errors) driver errors (see problems)"
    }
}
