// One card, start to finish: the run plan (CardPlan: what to copy, whether it fits), the verified
// offload, the per-take outputs made from the verified copies (audio WAV, clean DNGs, ProRes), the
// second copy, then EEPROM.txt and REPORT.md. `acam offload` and the Mac app run this.
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

    /// The one-line result in REPORT.md, `acam offload` and the app.
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

    /// Plans and runs the card, keeping the Mac awake. Stopped during the copy, it throws
    /// StoppedError and keeps nothing of this run; stopped later, the result says so.
    func run() throws -> CardJobResult {
        let plan = try self.plan()
        return try KeepAwake.during("Copying \(plan.card.name)") {
            try run(plan)
        }
    }

    private func run(_ plan: CardPlan) throws -> CardJobResult {
        let fm = FileManager.default
        var result = CardJobResult(offload: try offload.run(plan), profile: options.profile?.profile)
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
                        try make(output, take: take.name, folder: folder, result: &result)
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

    /// Makes one output for a take. An unfinished one an earlier run left goes to the Trash first.
    private func make(_ output: Output, take: String, folder: URL, result: inout CardJobResult) throws {
        do {
            switch output {
            case .audio:
                progress("audio  \(take)")
                try trashLeftover(folder.appendingPathComponent("\(take)_Audio.wav"), result: &result)
                result.audio[take] = try AudioTake.run(take: folder, stop: stop)
            case .clean:
                try trashLeftover(folder.appendingPathComponent("clean"), result: &result)
                result.clean[take] = try CleanTake.run(take: folder, profile: options.profile?.profile, stop: stop,
                                                       progress: progress)
            case .prores(let look):
                result.prores[take, default: [:]][look] = try ProResTake.run(
                    take: folder, look: look, outputDir: result.offload.cardFolder.appendingPathComponent("prores"),
                    stop: stop, progress: progress)
            }
        } catch let error as StoppedError {
            throw error
        } catch {
            switch output {
            case .audio: result.audio[take] = AudioResult(problems: ["\(error)"])
            case .clean: result.clean[take] = CleanResult(problems: ["\(error)"])
            case .prores(let look): result.prores[take, default: [:]][look] = ProResResult(problems: ["\(error)"])
            }
        }
    }

    /// The plan made this output for a take whose history does not list it: whatever is there was
    /// left by a run that did not finish.
    private func trashLeftover(_ url: URL, result: inout CardJobResult) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileIO.trash(url)
        result.warnings.append("`\(url.path)` was left by a run that did not finish: it was moved to the Trash and made again.")
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
