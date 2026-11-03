// One card, start to finish: verified offload, then the per-take outputs made from the verified
// copies (audio WAV, clean DNGs, ProRes), then REPORT.md. `acam offload` and the Mac app run this.
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
    var problems: [String] = []

    var allVerified: Bool {
        offload.allVerified && problems.isEmpty && !audio.values.contains { $0.failed }
            && !clean.values.contains { $0.failed } && !prores.values.contains { $0.values.contains { $0.failed } }
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
        var result = CardJobResult(offload: try offload.run(), profile: options.profile?.profile)
        let cardFolder = result.offload.cardFolder
        if let (profile, folder) = options.profile {
            let dest = cardFolder.appendingPathComponent("colour").appendingPathComponent(profile.id)
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: folder, to: dest)
                result.profileFolder = dest
            } catch {
                result.problems.append("Could not copy the colour profile files: \(error)")
            }
        }
        let proresDir = cardFolder.appendingPathComponent("prores")
        // Later steps only read copies that passed verification.
        for take in result.offload.takes where !take.failed {
            let folder = cardFolder.appendingPathComponent(take.name)
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
                    result.clean[take.name] = try CleanTake.run(take: folder, profile: options.profile?.profile,
                                                                progress: progress)
                } catch {
                    result.clean[take.name] = CleanResult(problems: ["\(error)"])
                }
            }
            for look in options.prores {
                do {
                    try FileManager.default.createDirectory(at: proresDir, withIntermediateDirectories: true)
                    result.prores[take.name, default: [:]][look] = try ProResTake.run(
                        take: folder, look: look, outputDir: proresDir, progress: progress)
                } catch {
                    result.prores[take.name, default: [:]][look] = ProResResult(problems: ["\(error)"])
                }
            }
        }
        result.offload.finished = Date()
        try Data(OffloadReport.markdown(result).utf8)
            .write(to: cardFolder.appendingPathComponent("REPORT.md"), options: .withoutOverwriting)
        return result
    }
}
