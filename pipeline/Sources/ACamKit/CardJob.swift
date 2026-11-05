// One card, start to finish: the run plan (CardPlan: what to copy, whether it fits), the verified
// offload, the per-take outputs made from the verified copies (audio WAV, clean DNGs, ProRes), the
// second copy, then EEPROM.txt and REPORT.md. `a-card offload` and the Mac app run this.
import Foundation

struct CardJobOptions {
    var offload: OffloadOptions
    /// <take>/<take>_Audio.wav
    var audio = true
    /// Clean DNGs in <take>/clean/.
    var clean = true
    /// Colour profile for the clean DNGs (nil: the factory matrices); its folder's DCP, IDTs and
    /// OpenColorIO config are copied to <card>/colour/<id>/.
    var profile: (profile: ColourProfile, folder: URL)?
    /// ProRes 4444 XQ files in <card>/prores/, one per look and take.
    var prores: [ProResLook] = []
    /// Added to the report's warnings, e.g. that the second drive was not connected.
    var notes: [String] = []
}

struct CardJobResult {
    var offload: OffloadResult
    var profile: ColourProfile?
    var profileFolder: URL?
    var audio: [String: AudioResult] = [:]
    var clean: [String: CleanResult] = [:]
    var prores: [String: [ProResLook: ProResResult]] = [:]
    /// Outputs that takes copied by an earlier run already had.
    var earlierOutputs: [String: [Output]] = [:]
    var problems: [String] = []
    var warnings: [String] = []
    /// What went to the second destination after the offload (nil: no second copy).
    var second: SecondCopyResult?
    /// Stopped while the outputs were made: every take listed is copied and verified, the outputs
    /// in `notMade` are missing.
    var stopped = false
    var notMade: [String] = []
    /// Reports of earlier runs into the same card folder, renamed REPORT-<n>.md.
    var earlierReports: [String] = []

    var allVerified: Bool {
        offload.allVerified && problems.isEmpty && !audio.values.contains { $0.failed }
            && !clean.values.contains { $0.failed } && !prores.values.contains { $0.values.contains { $0.failed } }
            && !offload.takes.contains { $0.secondFailed } && (second?.problems.isEmpty ?? true)
    }

    enum Verdict {
        case allVerified, partial, problems, stopped
    }

    /// PARTIAL when only some takes were chosen and everything copied was verified: never ALL
    /// VERIFIED, since the other takes are still only on the card.
    var verdict: Verdict {
        !allVerified ? .problems : stopped ? .stopped : offload.notCopied.isEmpty ? .allVerified : .partial
    }

    /// The one-line result in REPORT.md, `a-card offload` and the app.
    var headline: String {
        let copied = "\(offload.takes.count) of \(offload.takes.count + offload.notCopied.count) takes copied and verified"
        switch verdict {
        case .allVerified:
            return "ALL VERIFIED"
        case .problems:
            return "PROBLEMS FOUND"
        case .partial:
            return "PARTIAL: \(copied)"
        case .stopped:
            return "STOPPED: \(copied)"
        }
    }
}

final class CardJob {
    let options: CardJobOptions
    let offload: Offload
    /// Set it to stop the run (from any thread).
    let stop = StopSignal()
    /// Free bytes at a destination (test seam).
    var freeSpace: (URL) -> Int64? = CardPlan.freeBytes
    var progress: (String) -> Void = { print($0) } {
        didSet { offload.progress = progress }
    }

    init(_ options: CardJobOptions) {
        self.options = options
        offload = Offload(options.offload)
        offload.stop = stop
    }

    /// The run, worked out and checked against the free space; nothing is written before it
    /// passes. `card`: the card as already read, or nil to read it.
    func plan(card: CardVolume? = nil) throws -> CardPlan {
        let plan = try CardPlan.make(options, card: card)
        if plan.adding && plan.isEmpty {
            throw FileIOError(description: "nothing to add: \(plan.cardFolder.path) already holds \(plan.chosen == nil ? "every take" : "the chosen takes") with these outputs")
        }
        let o = options.offload
        if let why = plan.shortfall(free: freeSpace(o.destination),
                                    secondFree: o.secondDestination.flatMap(freeSpace)) {
            throw FileIOError(description: why)
        }
        return plan
    }

    /// Plans and runs the card. Stopped during the copy, it throws StoppedError and keeps nothing
    /// of this run; stopped later, the result says so.
    func run() throws -> CardJobResult {
        try run(plan())
    }

    /// Runs a plan from `plan()`, keeping the Mac awake.
    func run(_ plan: CardPlan) throws -> CardJobResult {
        try KeepAwake.during("Copying \(plan.card.name)") {
            try perform(plan)
        }
    }

    private func perform(_ plan: CardPlan) throws -> CardJobResult {
        let fm = FileManager.default
        var result = CardJobResult(offload: try offload.run(plan), profile: options.profile?.profile)
        result.warnings = options.notes
        let cardFolder = result.offload.cardFolder
        for (name, kept) in plan.kept {
            let looks = ProResLook.allCases.filter { fm.fileExists(atPath: CardPlan.proresURL(cardFolder, name, $0).path) }
            result.earlierOutputs[name] = [Output.audio, .clean].filter { kept.history.has($0, take: name) }
                + looks.map { .prores($0) }
        }
        if let (profile, folder) = options.profile {
            let dest = cardFolder.appendingPathComponent("colour").appendingPathComponent(profile.id)
            do {
                if !fm.fileExists(atPath: dest.path) {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: folder, to: dest)
                }
                result.profileFolder = dest
            } catch {
                result.problems.append("Could not copy the colour profile files: \(error)")
            }
        }
        let second = plan.secondFolder.map { SecondCopy(first: cardFolder, second: $0, stop: stop) }
        second?.progress = progress
        if second != nil {
            result.second = SecondCopyResult()
        }
        // Later steps only read copies that passed verification.
        do {
            for take in result.offload.takes where !take.failed {
                let folder = cardFolder.appendingPathComponent(take.name)
                if plan.chosen?.contains(take.name) ?? true {
                    for output in plan.outputs[take.name] ?? [] {
                        try stop.check()
                        try make(output, take: take, folder: folder, result: &result)
                    }
                }
                if let second = second, !take.secondFailed {
                    result.second!.add(try second.take(take.name))
                }
            }
            if let second = second {
                result.second!.add(try second.folder("prores") { $0.hasSuffix(".unfinished.mov") })
                result.second!.add(try second.folder("colour"))
            }
        } catch is StoppedError {
            result.stopped = true
            result.notMade = notMade(plan, result)
        }
        result.offload.finished = Date()
        try writeRecords(&result)
        return result
    }

    /// Makes one output for a take, from its verified copies.
    private func make(_ output: Output, take: TakeResult, folder: URL, result: inout CardJobResult) throws {
        let hashes = Dictionary(uniqueKeysWithValues: take.files.compactMap { f in f.copyHash.map { (f.name, $0) } })
        switch try OutputStep.make(output, take: take.name, folder: folder,
                                   proresDir: result.offload.cardFolder.appendingPathComponent("prores"),
                                   profile: options.profile?.profile, frameHashes: hashes, stop: stop,
                                   progress: progress, warnings: &result.warnings) {
        case .audio(let a): result.audio[take.name] = a
        case .clean(let c): result.clean[take.name] = c
        case .prores(let look, let p): result.prores[take.name, default: [:]][look] = p
        }
    }

    /// "AC102005: clean DNGs, ProRes Rec709" for every planned output a stopped run did not make.
    private func notMade(_ plan: CardPlan, _ result: CardJobResult) -> [String] {
        result.offload.takes.filter { !$0.failed && (plan.chosen?.contains($0.name) ?? true) }.compactMap { take in
            let missing = (plan.outputs[take.name] ?? []).filter { output in
                switch output {
                case .audio: return result.audio[take.name] == nil
                case .clean: return result.clean[take.name] == nil
                case .prores(let look): return result.prores[take.name]?[look] == nil
                }
            }
            return missing.isEmpty ? nil : "\(take.name): " + missing.map(OffloadReport.name).joined(separator: ", ")
        }
    }

    /// EEPROM.txt and REPORT.md in each card folder. The earlier run's, when adding, are renamed
    /// EEPROM-<n>.txt and REPORT-<n>.md first.
    private func writeRecords(_ result: inout CardJobResult) throws {
        let fm = FileManager.default
        let folders = [result.offload.cardFolder, result.offload.secondFolder].compactMap { $0 }
        let records = ["REPORT.md", "EEPROM.txt"]
        func numbered(_ name: String, _ n: Int) -> String {
            let url = URL(fileURLWithPath: name)
            return "\(url.deletingPathExtension().lastPathComponent)-\(n).\(url.pathExtension)"
        }
        // The first free number in each folder.
        let numbers = folders.map { folder -> Int in
            var n = 1
            while records.contains(where: { fm.fileExists(atPath: folder.appendingPathComponent(numbered($0, n)).path) }) {
                n += 1
            }
            return n
        }
        let first = result.offload.cardFolder
        let earlier = (try? fm.contentsOfDirectory(atPath: first.path))?.filter {
            $0.range(of: #"^REPORT-[0-9]+\.md$"#, options: .regularExpression) != nil
        } ?? []
        result.earlierReports = (earlier + (fm.fileExists(atPath: first.appendingPathComponent("REPORT.md").path)
            ? [numbered("REPORT.md", numbers[0])] : []))
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        let report = Data(OffloadReport.markdown(result).utf8)
        let eeprom = options.offload.eepromText.map { Data($0.utf8) }
        for (folder, n) in zip(folders, numbers) {
            do {
                for name in records where fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
                    try fm.moveItem(at: folder.appendingPathComponent(name), to: folder.appendingPathComponent(numbered(name, n)))
                }
                try eeprom?.write(to: folder.appendingPathComponent("EEPROM.txt"), options: .withoutOverwriting)
                try report.write(to: folder.appendingPathComponent("REPORT.md"), options: .withoutOverwriting)
            } catch where folder != first {
                progress("second copy: could not write REPORT.md: \(error)")
            }
        }
    }
}
