// One card, start to finish: verified offload, then the per-take outputs made from the verified
// copies (audio WAV, clean DNGs), then REPORT.md. `acam offload` and the Mac app both run this.
import Foundation

struct CardJobOptions {
    var offload: OffloadOptions
    /// <take>/<take>_Audio.wav
    var audio = true
    /// Clean DNGs in <take>/clean/.
    var clean = true
}

struct CardJobResult {
    var offload: OffloadResult
    var audio: [String: AudioResult] = [:]
    var clean: [String: CleanResult] = [:]

    var allVerified: Bool {
        offload.allVerified && !audio.values.contains { $0.failed } && !clean.values.contains { $0.failed }
    }
}

final class CardJob {
    let options: CardJobOptions
    let offload: Offload
    var progress: (String) -> Void = { print($0) } {
        didSet { offload.progress = progress }
    }

    init(_ options: CardJobOptions) {
        self.options = options
        offload = Offload(options.offload)
    }

    func run() throws -> CardJobResult {
        var result = CardJobResult(offload: try offload.run())
        // Later steps only read copies that passed verification.
        for take in result.offload.takes where !take.failed {
            let folder = result.offload.cardFolder.appendingPathComponent(take.name)
            if options.audio {
                progress("audio  \(take.name)")
                do {
                    result.audio[take.name] = try AudioTake.run(take: folder)
                } catch {
                    result.audio[take.name] = AudioResult(problems: ["\(error)"])
                }
            }
            if options.clean {
                do {
                    result.clean[take.name] = try CleanTake.run(take: folder, progress: progress)
                } catch {
                    result.clean[take.name] = CleanResult(problems: ["\(error)"])
                }
            }
        }
        result.offload.finished = Date()
        try Data(OffloadReport.markdown(result).utf8)
            .write(to: result.offload.cardFolder.appendingPathComponent("REPORT.md"), options: .withoutOverwriting)
        return result
    }
}
