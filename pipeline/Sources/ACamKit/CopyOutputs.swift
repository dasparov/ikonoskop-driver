// The outputs of a take, made from its verified copies: the step a card run uses, and the outputs
// a copy made earlier still lacks, made from the copies alone with no card in the reader.
//
// Without the card nothing can be compared with it, so a take is only used when its frames are all
// listed in its ASC MHL history and present at their recorded sizes and its first frame still
// matches its checksum; the clean DNGs check every frame against its checksum before using it.
// Such a run is recorded at the end of the card folder's REPORT.md.
import Foundation

/// One output as made: the WAV, the clean DNGs or one ProRes movie, each with its own checks.
enum MadeOutput {
    case audio(AudioResult)
    case clean(CleanResult)
    case prores(ProResLook, ProResResult)
}

enum OutputStep {
    /// Makes `output` for the take in `folder`. Whatever a run that did not finish left in its place
    /// goes to the Trash first (noted in `warnings`). A failure is the result's problem; only
    /// StoppedError is thrown. `frameHashes`: frame name -> xxHash64 the clean DNGs check.
    static func make(_ output: Output, take: String, folder: URL, proresDir: URL, profile: ColourProfile?,
                     frameHashes: [String: UInt64]?, stop: StopSignal, progress: @escaping (String) -> Void,
                     warnings: inout [String]) throws -> MadeOutput {
        do {
            switch output {
            case .audio:
                progress("audio  \(take)")
                try trashLeftover(folder.appendingPathComponent("\(take)_Audio.wav"), warnings: &warnings)
                return .audio(try AudioTake.run(take: folder, stop: stop))
            case .clean:
                try trashLeftover(folder.appendingPathComponent("clean"), warnings: &warnings)
                return .clean(try CleanTake.run(take: folder, profile: profile, frameHashes: frameHashes, stop: stop,
                                                progress: progress))
            case .prores(let look):
                return .prores(look, try ProResTake.run(take: folder, look: look, outputDir: proresDir, stop: stop,
                                                        progress: progress))
            }
        } catch let error as StoppedError {
            throw error
        } catch {
            switch output {
            case .audio: return .audio(AudioResult(problems: ["\(error)"]))
            case .clean: return .clean(CleanResult(problems: ["\(error)"]))
            case .prores(let look): return .prores(look, ProResResult(problems: ["\(error)"]))
            }
        }
    }

    /// Only called for an output the take's history does not list: whatever is there was left by a
    /// run that did not finish.
    private static func trashLeftover(_ url: URL, warnings: inout [String]) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileIO.trash(url)
        warnings.append("`\(url.path)` was left by a run that did not finish: it was moved to the Trash and made again.")
    }
}

struct CopyOutputsOptions {
    var audio = true
    var clean = true
    var prores: [ProResLook] = []
    /// Colour profile for the clean DNGs; its folder is copied to <card>/colour/<id>/ as in a card run.
    var profile: (profile: ColourProfile, folder: URL)?
}

struct CopyOutputsResult {
    /// The card folder: the folder chosen, or the one holding the take folder chosen.
    let folder: URL
    var started = Date()
    var finished = Date()
    /// Take folders looked at, in order.
    var takes: [String] = []
    var audio: [String: AudioResult] = [:]
    var clean: [String: CleanResult] = [:]
    var prores: [String: [ProResLook: ProResResult]] = [:]
    var problems: [String] = []
    var warnings: [String] = []
    var stopped = false

    var madeAny: Bool { !audio.isEmpty || !clean.isEmpty || !prores.isEmpty }

    var failed: Bool {
        !problems.isEmpty || audio.values.contains { $0.failed } || clean.values.contains { $0.failed }
            || prores.values.contains { $0.values.contains { $0.failed } }
    }

    /// OUTPUTS MADE, NOTHING TO MAKE, STOPPED or PROBLEMS FOUND.
    var headline: String {
        failed ? "PROBLEMS FOUND" : stopped ? "STOPPED" : madeAny ? "OUTPUTS MADE" : "NOTHING TO MAKE"
    }

    /// One line per take that got something, then the problems, as `a-card outputs` prints them and
    /// the app shows them.
    var lines: [String] {
        var out: [String] = []
        for take in takes {
            var made: [String] = []
            if let a = audio[take] {
                made.append(a.failed ? "audio FAILED" : "audio OK")
            }
            if let c = clean[take] {
                made.append(c.failed ? "clean DNGs FAILED" : "clean DNGs OK")
            }
            for (look, p) in (prores[take] ?? [:]).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                made.append("ProRes \(look.rawValue) \(p.failed ? "FAILED" : "OK")")
            }
            if !made.isEmpty {
                out.append("\(take)  \(made.joined(separator: ", "))")
            }
        }
        out += allProblems.map { "problem: \($0)" }
        if stopped {
            out.append("stopped: not everything was made")
        }
        return out
    }

    var allProblems: [String] {
        problems + audio.sorted { $0.key < $1.key }.flatMap { k, a in a.problems.map { "\(k) audio: \($0)" } }
            + clean.sorted { $0.key < $1.key }.flatMap { k, c in c.problems.map { "\(k) clean DNGs: \($0)" } }
            + prores.sorted { $0.key < $1.key }.flatMap { k, looks in
                looks.sorted { $0.key.rawValue < $1.key.rawValue }.flatMap { look, p in p.problems.map { "\(k) ProRes \(look.rawValue): \($0)" } }
            }
    }
}

enum CopyOutputs {
    /// A take folder of the copy and the outputs it lacks.
    struct Take {
        let name: String
        let folder: URL
        let history: TakeHistory
        let missing: [Output]
        let frames: Int
        let frameBytes: Int64
    }

    /// The copy's take folders that can be used and what each lacks, the problems of the others, and
    /// about how many bytes the outputs need. `folder`: a card folder or one take folder in it.
    static func plan(_ folder: URL, _ options: CopyOutputsOptions) throws
        -> (cardFolder: URL, takes: [Take], problems: [String], bytes: Int64) {
        let fm = FileManager.default
        let folders = try CopyVerifier.takeFolders(folder)
        let cardFolder = folders == [folder] && CopyVerifier.looksLikeTake(folder.lastPathComponent)
            ? folder.deletingLastPathComponent() : folder
        var takes: [Take] = []
        var problems: [String] = []
        var bytes: Int64 = 0
        for url in folders {
            let name = url.lastPathComponent
            let history: TakeHistory
            do {
                guard let h = try TakeHistory.read(url) else {
                    problems.append("\(name) has no checksum history, so it is not a copy a-card made and checked: nothing made for it")
                    continue
                }
                history = h
            } catch {
                problems.append("\(name): its checksum history cannot be read (\(error)): nothing made for it")
                continue
            }
            let frames = history.entries.values.filter { $0.path.hasPrefix("frames/") }
            guard !frames.isEmpty else {
                problems.append("\(name): its checksum history lists no frames: nothing made for it")
                continue
            }
            let changed = frames.filter { entry in
                (try? fm.attributesOfItem(atPath: url.appendingPathComponent(entry.path).path)[.size] as? Int) != entry.size
            }
            guard changed.isEmpty else {
                problems.append("\(name): \(changed.count) of its frames are missing or have changed size (check it with Verify a copy): nothing made for it")
                continue
            }
            var missing: [Output] = []
            if options.audio && !history.has(.audio, take: name) {
                missing.append(.audio)
            }
            if options.clean && !history.has(.clean, take: name) {
                missing.append(.clean)
            }
            for look in options.prores where !fm.fileExists(atPath: CardPlan.proresURL(cardFolder, name, look).path) {
                missing.append(.prores(look))
            }
            let frameBytes = Int64(frames.reduce(0) { $0 + $1.size })
            bytes += CardSpace.estimatedOutputBytes(
                frames: frames.count, frameFileBytes: frameBytes / Int64(frames.count),
                audio: missing.contains(.audio), clean: missing.contains(.clean),
                looks: missing.compactMap { if case .prores(let l) = $0 { return l } else { return nil } })
            takes.append(Take(name: name, folder: url, history: history, missing: missing, frames: frames.count,
                              frameBytes: frameBytes))
        }
        return (cardFolder, takes, problems, bytes)
    }

    /// Makes what `plan` found missing and records it at the end of the card folder's REPORT.md.
    /// Refuses to start when the drive has too little room. Stopped, the output being made is
    /// removed and the result says so.
    static func make(_ folder: URL, _ options: CopyOutputsOptions, stop: StopSignal = StopSignal(),
                     progress: @escaping (String) -> Void = { _ in },
                     freeSpace: (URL) -> Int64? = CardPlan.freeBytes) throws -> CopyOutputsResult {
        let plan = try self.plan(folder, options)
        var result = CopyOutputsResult(folder: plan.cardFolder)
        result.takes = plan.takes.map { $0.name }
        result.problems = plan.problems
        let work = plan.takes.filter { !$0.missing.isEmpty }
        guard !work.isEmpty else {
            return result
        }
        if let free = freeSpace(plan.cardFolder), free < plan.bytes {
            throw FileIOError(description: "Not enough space: \(plan.cardFolder.path) is on a drive with \(CardPlan.size(free)) free, these outputs need about \(CardPlan.size(plan.bytes)).")
        }
        try KeepAwake.during("Making outputs for \(plan.cardFolder.lastPathComponent)") {
            try run(work, plan.cardFolder, options, stop: stop, progress: progress, into: &result)
        }
        result.finished = Date()
        let report = plan.cardFolder.appendingPathComponent("REPORT.md")
        var text = (try? String(contentsOf: report, encoding: .utf8)) ?? "# \(plan.cardFolder.lastPathComponent)\n"
        text += OffloadReport.outputsSection(result)
        try Data(text.utf8).write(to: report, options: .atomic)
        return result
    }

    private static func run(_ work: [Take], _ cardFolder: URL, _ options: CopyOutputsOptions, stop: StopSignal,
                            progress: @escaping (String) -> Void, into result: inout CopyOutputsResult) throws {
        let fm = FileManager.default
        if let (profile, source) = options.profile, work.contains(where: { $0.missing.contains(.clean) }) {
            let dest = cardFolder.appendingPathComponent("colour").appendingPathComponent(profile.id)
            if !fm.fileExists(atPath: dest.path) {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: dest)
            }
        }
        let largest = work.flatMap { $0.history.entries.values.filter { $0.path.hasPrefix("frames/") }.map { $0.size } }.max() ?? 1
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: largest, alignment: 16_384)
        defer { buffer.deallocate() }
        do {
            for take in work {
                try stop.check()
                let frames = take.history.entries.values.filter { $0.path.hasPrefix("frames/") }.sorted { $0.path < $1.path }
                let first = frames[0]
                let path = take.folder.appendingPathComponent(first.path).path
                FileIO.evictCache(path)
                let length = try FileIO.read(path, into: buffer)
                guard XXHash64.hash(UnsafeRawBufferPointer(rebasing: buffer[0..<length])) == first.xxh64 else {
                    result.problems.append("\(take.name): its first frame no longer matches its checksum (check it with Verify a copy): nothing made for it")
                    continue
                }
                let hashes = Dictionary(uniqueKeysWithValues: frames.map { ($0.path.dropFirst("frames/".count).description, $0.xxh64) })
                for output in take.missing {
                    try stop.check()
                    switch try OutputStep.make(output, take: take.name, folder: take.folder,
                                               proresDir: cardFolder.appendingPathComponent("prores"),
                                               profile: options.profile?.profile, frameHashes: hashes, stop: stop,
                                               progress: progress, warnings: &result.warnings) {
                    case .audio(let a): result.audio[take.name] = a
                    case .clean(let c): result.clean[take.name] = c
                    case .prores(let look, let p): result.prores[take.name, default: [:]][look] = p
                    }
                }
            }
        } catch is StoppedError {
            result.stopped = true
        }
    }
}
