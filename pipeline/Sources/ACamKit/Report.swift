// REPORT.md for one offloaded card.
import Foundation

let acamVersion = "0.1.0"

enum OffloadReport {
    static func markdown(_ r: OffloadResult) -> String {
        let verdict = r.allVerified ? "ALL VERIFIED" : "PROBLEMS FOUND"
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
        | Finished | \(local(r.finished)) (\(duration(seconds)), \(String(format: "%.0f", Double(bytes) / 1_000_000 / max(seconds, 0.001))) MB/s for copy and verification) |
        | Takes | \(r.takes.count) |
        | Frames | \(grouped(frames)) (\(String(format: "%.1f", Double(bytes) / 1e9)) GB) |
        | Checksums | xxHash64 of each file read twice from the card and once from the copy |
        | Take table (EEPROM) | \(r.takeTableSummary) |
        | Driver log | \(r.kernelLogSummary) |
        | First frames | \(r.firstFrameSummary) |
        | Tool | acam \(acamVersion) |

        ## Takes

        | Take | Frames | Duration | Frame rate | First timecode | Last timecode | Checksums | Manifest |
        |---|---:|---:|---:|---|---|---|---|

        """
        for t in r.takes {
            let fps = t.firstHeader?.fps ?? 0
            let dur = fps > 0 ? duration(Double(t.files.count) / fps) : "?"
            let checksums = t.verifiedCount == t.files.count && !t.files.isEmpty
                ? "OK (\(grouped(t.files.count)))" : "**FAILED** (\(grouped(t.verifiedCount)) of \(grouped(t.files.count)) OK)"
            let manifest = t.manifest.map { "`\($0.deletingLastPathComponent().lastPathComponent)/\($0.lastPathComponent)`" } ?? "none"
            md += "| \(t.failed ? "**\(t.name)**" : t.name) | \(grouped(t.files.count)) | \(dur) | \(fpsText(t.firstHeader)) | \(t.firstHeader?.timecode?.description ?? "?") | \(t.lastHeader?.timecode?.description ?? "?") | \(checksums) | \(manifest) |\n"
        }
        let problems = r.cardProblems + r.takes.flatMap { t in t.problems.map { "\(t.name): \($0)" } }
        let warnings = r.cardWarnings + r.takes.flatMap { t in t.warnings.map { "\(t.name): \($0)" } }
        md += "\n## Problems\n\n"
        md += problems.isEmpty ? "None.\n" : problems.prefix(200).map { "- \($0)\n" }.joined()
        if problems.count > 200 {
            md += "- … and \(problems.count - 200) more\n"
        }
        md += "\n## Warnings\n\n"
        md += warnings.isEmpty ? "None.\n" : warnings.map { "- \($0)\n" }.joined()
        md += "\n**\(verdict)**\n"
        return md
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
