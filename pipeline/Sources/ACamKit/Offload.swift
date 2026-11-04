// Verified offload: copy every take of a mounted card into <destination>/<card>/<take>/frames/,
// verify every copy with xxHash64, check the take table, the driver log and the first frames, and
// write an ASC MHL manifest per verified take. CardJob adds the later steps and REPORT.md.
//
// Verification: each source file is hashed while it is copied, read a second time after every
// take has been copied (the driver's 8-frame cache and the file cache are long evicted by then),
// and its copy is read back from the destination; all three hashes must be equal.
import Foundation

struct OffloadOptions {
    var source: URL
    /// The card folder is created inside it and must not exist yet.
    var destination: URL
    /// Take table from `ikctl eeprom`; without it the offload cannot report ALL VERIFIED.
    var eeprom: EepromImage?
    /// The `ikctl eeprom` text it was parsed from, kept as <card>/EEPROM.txt.
    var eepromText: String?
    /// Driver log lines since boot; nil skips the check (which counts as a problem).
    var kernelLog: (() throws -> [KernelLogLine])? = KernelLog.linesSinceBoot
}

struct FileResult {
    let name: String
    let size: Int
    let modified: Date
    var copyHash: UInt64?
    var sourceHash: UInt64?
    var destinationHash: UInt64?
    var error: String?
    /// Reads of the source file: 1 while copying, 2 after verification, more when the card
    /// returned different data and the frame was read again until two reads matched.
    var sourceReads = 1
    /// The copy was made from a bad read and replaced by the version two later reads agreed on.
    var rewritten = false

    var verified: Bool {
        error == nil && copyHash != nil && sourceHash == copyHash && destinationHash == copyHash
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

    var failed: Bool { !problems.isEmpty || files.contains { !$0.verified } }
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
    let started: Date
    var finished: Date
    var takes: [TakeResult]
    var cardProblems: [String] = []
    var cardWarnings: [String] = []
    var takeTableSummary = ""
    var kernelLogSummary = ""
    var firstFrameSummary = ""

    var allVerified: Bool { cardProblems.isEmpty && !takes.contains { $0.failed } }
}

final class Offload {
    static let frameFileBytes = 0x336000

    let options: OffloadOptions
    var progress: (String) -> Void = { print($0) }
    /// Test seam: runs after each frame has been written, before verification.
    var afterCopy: ((URL) -> Void)?
    /// Test seam: the second (verification) read of a source file.
    var verificationRead: (String, UnsafeMutableRawBufferPointer) throws -> Int = FileIO.read

    init(_ options: OffloadOptions) {
        self.options = options
    }

    func run() throws -> OffloadResult {
        let fm = FileManager.default
        let card = try CardVolume.open(options.source)
        let cardFolder = options.destination.appendingPathComponent(card.name)
        guard !fm.fileExists(atPath: cardFolder.path) else {
            throw FileIOError(description: "\(cardFolder.path) already exists; choose a new destination folder")
        }
        let needed = card.takes.reduce(0) { $0 + $1.frames.reduce(0) { $0 + $1.size } }
        if let free = try fm.attributesOfFileSystem(forPath: options.destination.path)[.systemFreeSize] as? Int,
           free < needed {
            throw FileIOError(description: "\(options.destination.path) has \(free / 1_000_000) MB free, the card needs \(needed / 1_000_000) MB")
        }
        try fm.createDirectory(at: cardFolder, withIntermediateDirectories: false)
        if let text = options.eepromText {
            try Data(text.utf8).write(to: cardFolder.appendingPathComponent("EEPROM.txt"), options: .withoutOverwriting)
        }

        let started = Date()
        var result = OffloadResult(cardName: card.name, source: card.url, cardFolder: cardFolder,
                                   started: started, finished: started, takes: [])
        let maxSize = max(card.takes.flatMap { $0.frames.map { $0.size } }.max() ?? 0, 1)
        let buffers = (0..<4).map { _ in
            UnsafeMutableRawBufferPointer.allocate(byteCount: maxSize, alignment: 16_384)
        }
        defer { buffers.forEach { $0.deallocate() } }

        for take in card.takes {
            result.takes.append(try copy(take, into: cardFolder, buffers: Array(buffers[0..<3])))
        }
        for i in result.takes.indices {
            verify(&result.takes[i], take: card.takes[i], cardFolder: cardFolder,
                   buffers: (buffers[0], buffers[3]))
        }
        rereadUnstable(&result, card: card, cardFolder: cardFolder, buffers: (buffers[0], buffers[1]))
        for i in result.takes.indices {
            recordFileProblems(&result.takes[i])
        }
        let reread = result.takes.reduce(0) { $0 + $1.rereadCount }
        if reread > 0 {
            result.cardWarnings.append("The card returned different data the second time \(reread) frames were read (random read errors of the card's flash). acam read each of them again until two reads matched exactly and kept that version; any frame where no two reads matched is listed under Problems.")
        }
        let totalFrames = card.takes.reduce(0) { $0 + $1.frames.count }
        if totalFrames <= 8 {
            result.cardWarnings.append("Only \(totalFrames) frames: the second read may have come from the driver's 8-frame cache.")
        }
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

        for i in result.takes.indices where !result.takes[i].failed {
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
        }
        result.finished = Date()
        return result
    }

    // ---- copy pass -------------------------------------------------------------------------

    private func copy(_ take: TakeFolder, into cardFolder: URL, buffers: [UnsafeMutableRawBufferPointer]) throws -> TakeResult {
        let fm = FileManager.default
        let framesDir = cardFolder.appendingPathComponent(take.name).appendingPathComponent("frames")
        try fm.createDirectory(at: framesDir, withIntermediateDirectories: true)
        var result = TakeResult(name: take.name, files: take.frames.map { f in
            let modified = (try? fm.attributesOfItem(atPath: f.url.path)[.modificationDate] as? Date) ?? nil
            return FileResult(name: f.name, size: f.size, modified: modified ?? Date(timeIntervalSince1970: 0))
        })
        let writer = DispatchQueue(label: "acam.offload.writer")
        let freeSlots = DispatchSemaphore(value: buffers.count)
        let lock = NSLock()
        var writeErrors: [Int: String] = [:]
        let started = Date()
        var bytes = 0

        for (i, frame) in take.frames.enumerated() {
            freeSlots.wait()
            let slot = buffers[i % buffers.count]
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
            let destination = framesDir.appendingPathComponent(frame.name)
            let modified = result.files[i].modified
            writer.async { [afterCopy] in
                do {
                    try FileIO.create(destination.path, bytes: data)
                    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
                    afterCopy?(destination)
                } catch {
                    lock.lock()
                    writeErrors[i] = "write: \(error)"
                    lock.unlock()
                }
                freeSlots.signal()
            }
            if (i + 1) % 200 == 0 || i + 1 == take.frames.count {
                let mbps = Double(bytes) / 1_000_000 / max(Date().timeIntervalSince(started), 0.001)
                progress(String(format: "copy   %@  %5d/%d frames  %.0f MB/s", take.name, i + 1, take.frames.count, mbps))
            }
        }
        writer.sync {}
        for (i, error) in writeErrors {
            result.files[i].error = error
        }
        if let last = result.files.indices.last(where: { result.files[$0].error == nil }) {
            do {
                try FileIO.fullSync(framesDir.appendingPathComponent(result.files[last].name).path)
            } catch {
                result.problems.append("Could not flush the copies to disk: \(error)")
            }
        }
        return result
    }

    // ---- verification pass -----------------------------------------------------------------

    private func verify(_ result: inout TakeResult, take: TakeFolder, cardFolder: URL,
                        buffers: (UnsafeMutableRawBufferPointer, UnsafeMutableRawBufferPointer)) {
        let framesDir = cardFolder.appendingPathComponent(take.name).appendingPathComponent("frames")
        let started = Date()
        for (i, frame) in take.frames.enumerated() where result.files[i].error == nil {
            let sourcePath = frame.url.path
            let copyPath = framesDir.appendingPathComponent(frame.name).path
            var sourceOutcome: Result<UInt64, Error> = .failure(FileIOError(description: "not read"))
            var copyOutcome: Result<UInt64, Error> = .failure(FileIOError(description: "not read"))
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) { [verificationRead] in
                sourceOutcome = Result {
                    FileIO.evictCache(sourcePath)
                    let n = try verificationRead(sourcePath, buffers.0)
                    return XXHash64.hash(UnsafeRawBufferPointer(rebasing: buffers.0[0..<n]))
                }
            }
            DispatchQueue.global().async(group: group) {
                copyOutcome = Result {
                    FileIO.evictCache(copyPath)
                    let n = try FileIO.read(copyPath, into: buffers.1)
                    return XXHash64.hash(UnsafeRawBufferPointer(rebasing: buffers.1[0..<n]))
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
    /// copy was made from a bad read, it is replaced. Every re-read comes from the flash: the
    /// pending frames are read in turn with at least 8 other frames in between (the driver keeps
    /// the last 8 frames), and the file cache is dropped before each read.
    private func rereadUnstable(_ result: inout OffloadResult, card: CardVolume, cardFolder: URL,
                                buffers: (UnsafeMutableRawBufferPointer, UnsafeMutableRawBufferPointer)) {
        var pending: [(take: Int, file: Int)] = []
        var seen: [Int: [UInt64]] = [:] // hashes read so far: the copy's first
        for (ti, t) in result.takes.enumerated() {
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
        let fillers = card.takes.enumerated().flatMap { ti, t in
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
                let frame = card.takes[p.take].frames[p.file]
                let key = p.take << 32 | p.file
                FileIO.evictCache(frame.url.path)
                guard let n = try? verificationRead(frame.url.path, buffers.0) else {
                    still.append(p)
                    continue
                }
                let data = UnsafeRawBufferPointer(rebasing: buffers.0[0..<n])
                let h = XXHash64.hash(data)
                var f = result.takes[p.take].files[p.file]
                f.sourceReads += 1
                if h == f.copyHash {
                    f.sourceHash = h
                } else if seen[key]!.dropFirst().contains(h) {
                    let copy = cardFolder.appendingPathComponent(result.takes[p.take].name)
                        .appendingPathComponent("frames").appendingPathComponent(frame.name).path
                    do {
                        try replaceCopy(at: copy, with: data, hash: h, modified: f.modified, scratch: buffers.1)
                        f.copyHash = h
                        f.sourceHash = h
                        f.destinationHash = h
                        f.rewritten = true
                        if p.file == 0 && n > FrameHeader.headerBytes {
                            result.takes[p.take].firstFrameRawHash = XXHash64.hash(UnsafeRawBufferPointer(rebasing: data[FrameHeader.headerBytes...]))
                        }
                    } catch {
                        f.error = "could not replace the copy with the version read twice: \(error)"
                    }
                } else {
                    seen[key]!.append(h)
                    still.append(p)
                }
                result.takes[p.take].files[p.file] = f
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
        result.firstFrameSummary = duplicates == 0
            ? "the first frames of all \(result.takes.count) takes are different"
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
        for entry in listed {
            let name = eeprom.folderName(index: entry.index)
            guard let i = result.takes.firstIndex(where: { $0.name == name }) else {
                result.cardProblems.append("Take \(name) (\(entry.frames) frames in the take table) is missing from the card's volume.")
                problems += 1
                continue
            }
            if result.takes[i].files.count != entry.frames {
                result.takes[i].problems.append("The take table says \(entry.frames) frames; the volume has \(result.takes[i].files.count).")
                problems += 1
            }
        }
        for entry in hidden {
            result.cardProblems.append("Take \(eeprom.folderName(index: entry.index)) (\(entry.frames) frames, recorded \(entry.createdText)) is in the take table after an empty entry and is not older than the listed takes, but it is missing from the card's volume: the driver shows only the takes before the first empty entry.")
            problems += 1
        }
        for t in result.takes where !listed.contains(where: { eeprom.folderName(index: $0.index) == t.name }) {
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
        func takeIndex(ofFrame frame: Int) -> Int? {
            firstFrame.lastIndex { $0 <= frame }
        }
        let cardNumber = card.name.filter { $0.isNumber }
        var errors = 0
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
                let name = "AC\(cardNumber)\(String(format: "%03d", n + 1))"
                if let i = result.takes.firstIndex(where: { $0.name == name }) {
                    result.takes[i].problems.append("Driver log: \(f.message)")
                } else {
                    result.cardProblems.append("Driver log (take \(n + 1)): \(f.message)")
                }
                errors += 1
            case .frame(let n):
                if let i = takeIndex(ofFrame: n), i < result.takes.count {
                    result.takes[i].problems.append("Driver log: \(f.message)")
                } else {
                    result.cardProblems.append("Driver log: \(f.message)")
                }
                errors += 1
            }
        }
        result.kernelLogSummary = errors == 0 ? "no driver errors" : "\(errors) driver errors (see problems)"
    }
}
