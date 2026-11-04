// REPORT.md for one offloaded card.
import Foundation

let acamVersion = "0.1.0"

enum OffloadReport {
    static func markdown(_ job: CardJobResult) -> String {
        let r = job.offload
        let verdict = job.headline
        let frames = r.takes.reduce(0) { $0 + $1.files.count }
        let bytes = r.takes.reduce(0) { $0 + $1.bytes }
        let seconds = r.finished.timeIntervalSince(r.started)
        var md = """
        # \(r.cardName): offload report

        **\(verdict)**

        | | |
        |---|---|
        | Card | \(r.cardName) |
        | Source | `\(r.source.path)` |
        | Destination | `\(r.cardFolder.path)` |
        | Started | \(local(r.started)) |
        | Finished | \(local(r.finished)) (\(duration(seconds))) |
        | Takes | \(r.notCopied.isEmpty ? "\(r.takes.count)" : "\(r.takes.count) of \(r.takes.count + r.notCopied.count) copied; **not copied: \(r.notCopied.joined(separator: ", "))**") |
        | Frames | \(grouped(frames)) (\(String(format: "%.1f", Double(bytes) / 1e9)) GB) |
        | Checksums | xxHash64 of each file read twice from the card and once from the copy |
        | Take table (EEPROM) | \(r.takeTableSummary) |
        | Driver log | \(r.kernelLogSummary) |
        | First frames | \(r.firstFrameSummary) |
        | Audio | \(audioSummary(job)) |
        | Clean DNGs | \(cleanSummary(job)) |
        | Colour profile | \(job.profile.map { "\($0.name); DCP, ACES IDTs and OpenColorIO config in `colour/\($0.id)/`" } ?? "factory matrices (illuminants D55 / ISO studio tungsten)") |
        | ProRes | \(proresSummary(job)) |
        | Tool | acam \(acamVersion) |

        ## Takes

        | Take | Frames | Duration | Frame rate | First timecode | Last timecode | Checksums | Audio | Clean DNGs |
        |---|---:|---:|---:|---|---|---|---|---|

        """
        for t in r.takes {
            let fps = t.firstHeader?.fps ?? 0
            let dur = fps > 0 ? duration(Double(t.files.count) / fps) : "?"
            let checksums = t.verifiedCount == t.files.count && !t.files.isEmpty
                ? "OK (\(grouped(t.files.count))\(t.rereadCount > 0 ? "; \(grouped(t.rereadCount)) read again" : ""))"
                : "**FAILED** (\(grouped(t.verifiedCount)) of \(grouped(t.files.count)) OK)"
            var audio = "not made"
            if let a = job.audio[t.name] {
                audio = a.failed ? "**FAILED**" : String(format: "OK, drift %+.1f ms", a.drift * 1000)
            }
            var clean = "not made"
            if let c = job.clean[t.name] {
                clean = c.failed ? "**FAILED**" : String(format: "OK, %.0f%% of the size", c.ratio * 100)
            }
            md += "| \(t.failed ? "**\(t.name)**" : t.name) | \(grouped(t.files.count)) | \(dur) | \(fpsText(t.firstHeader)) | \(t.firstHeader?.timecode?.description ?? "?") | \(t.lastHeader?.timecode?.description ?? "?") | \(checksums) | \(audio) | \(clean) |\n"
        }
        var problems = job.problems + r.cardProblems + r.takes.flatMap { t in t.problems.map { "\(t.name): \($0)" } }
        problems += job.audio.sorted { $0.key < $1.key }.flatMap { k, a in a.problems.map { "\(k) audio: \($0)" } }
        problems += job.clean.sorted { $0.key < $1.key }.flatMap { k, c in c.problems.map { "\(k) clean DNGs: \($0)" } }
        problems += job.prores.sorted { $0.key < $1.key }.flatMap { k, looks in
            looks.sorted { $0.key.rawValue < $1.key.rawValue }.flatMap { look, p in p.problems.map { "\(k) ProRes \(look.rawValue): \($0)" } }
        }
        var warnings = r.notCopied.isEmpty ? [] : ["Only the chosen takes were copied: \(r.notCopied.joined(separator: ", ")) \(r.notCopied.count == 1 ? "is" : "are") still only on the card. Copy \(r.notCopied.count == 1 ? "it" : "them") before the card is reused."]
        warnings += r.cardWarnings + r.takes.flatMap { t in t.warnings.map { "\(t.name): \($0)" } }
        warnings += job.audio.sorted { $0.key < $1.key }.flatMap { k, a in a.warnings.map { "\(k) audio: \($0)" } }
        warnings += job.prores.sorted { $0.key < $1.key }.flatMap { k, looks in
            looks.sorted { $0.key.rawValue < $1.key.rawValue }.flatMap { look, p in p.warnings.map { "\(k) ProRes \(look.rawValue): \($0)" } }
        }
        md += "\n## Problems\n\n"
        md += problems.isEmpty ? "None.\n" : problems.prefix(200).map { "- \($0)\n" }.joined()
        if problems.count > 200 {
            md += "- … and \(problems.count - 200) more\n"
        }
        md += "\n## Warnings\n\n"
        md += warnings.isEmpty ? "None.\n" : warnings.map { "- \($0)\n" }.joined()
        md += "\nEach verified take folder holds `frames/` (the copies), `<take>_Audio.wav`, `clean/` (corrected, "
            + "compressed DNGs) and `ascmhl/` (ASC MHL checksum history; check with `ascmhl-debug verify <take folder>`).\n"
        md += "\n**\(verdict)**\n"
        return md
    }

    static func cleanSummary(_ job: CardJobResult) -> String {
        guard !job.clean.isEmpty else {
            return "not made"
        }
        let ok = job.clean.values.filter { !$0.failed }
        let before = ok.reduce(0) { $0 + $1.originalBytes }, after = ok.reduce(0) { $0 + $1.cleanBytes }
        let failed = job.clean.count - ok.count
        return String(format: "%d takes, %.1f GB → %.1f GB (%.0f%%)", ok.count, Double(before) / 1e9,
                      Double(after) / 1e9, before == 0 ? 0 : 100 * Double(after) / Double(before))
            + (failed > 0 ? "; \(failed) FAILED" : "") + "; every frame decoded and compared with the original"
    }

    static func audioSummary(_ job: CardJobResult) -> String {
        guard !job.audio.isEmpty else {
            return "not made"
        }
        let ok = job.audio.values.filter { !$0.failed }
        let worst = ok.map { abs($0.drift) }.max() ?? 0
        let failed = job.audio.count - ok.count
        return String(format: "%d takes: 48 kHz 16-bit stereo WAV, samples copied unchanged from the frames; largest drift against the picture %.1f ms",
                      ok.count, worst * 1000) + (failed > 0 ? "; \(failed) FAILED" : "")
    }

    static func proresSummary(_ job: CardJobResult) -> String {
        let all = job.prores.values.flatMap { $0.values }
        guard !all.isEmpty else {
            return "not made"
        }
        let looks = Set(job.prores.values.flatMap { $0.keys }).map { $0.rawValue }.sorted().joined(separator: " and ")
        let failed = all.filter { $0.failed }.count
        return "ProRes 4444 XQ (\(looks)) in `prores/`: \(all.count - failed) files" + (failed > 0 ? ", \(failed) FAILED" : "")
    }

    static func fpsText(_ h: FrameHeader?) -> String {
        guard let h = h, h.frameRate.1 != 0 else {
            return "?"
        }
        return h.frameRate.1 == 1 ? "\(h.frameRate.0)" : String(format: "%.3f", h.fps)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        let frac = seconds - Double(s)
        return String(format: "%d:%02d:%05.2f", s / 3600, s / 60 % 60, Double(s % 60) + frac)
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func local(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return f.string(from: date)
    }
}
