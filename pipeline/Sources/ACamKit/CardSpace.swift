// How full a card is and about how much a run's outputs take, for the run plan (CardPlan).
import Foundation

enum CardSpace {
    /// Flash one frame takes: 821 pages of 4 KiB (core/ik_core.cpp, kPagesPerFrame).
    static let flashFrameBytes: Int64 = 0x335 * 0x1000
    /// One erase block: 0x2800 pages of 4 KiB. Every take starts on a new one.
    static let eraseBlockBytes: Int64 = 0x2800 * 0x1000

    /// The card's flash, from its volume's size: the driver makes the volume 1024 sectors of 512
    /// bytes for every 821 flash pages, rounded down (core/ik_core.cpp, sectorCount), so this rounds
    /// up. The volume itself looks bigger than the card (100.4 GB for an 80 GB card).
    static func flashBytes(volumeBytes: Int64) -> Int64 {
        (volumeBytes / 512 * 0x335 + 1023) / 1024 * 512
    }

    /// Flash taken by takes of these frame counts, each starting on a new erase block.
    static func usedBytes(takeFrames: [Int]) -> Int64 {
        takeFrames.reduce(0) { sum, frames in
            let bytes = Int64(frames) * flashFrameBytes
            return sum + (bytes + eraseBlockBytes - 1) / eraseBlockBytes * eraseBlockBytes
        }
    }

    /// About how much the outputs of `frames` frames of `frameFileBytes` each take: the WAV (8 KB
    /// a frame), clean DNGs (about 53% of a frame) and ProRes 4444 XQ (measured on take
    /// AC000001: 2.1 MB a frame ACEScct, 2.3 MB Rec.709). The copies themselves are not included.
    static func estimatedOutputBytes(frames: Int, frameFileBytes: Int64, audio: Bool, clean: Bool,
                                     looks: [ProResLook]) -> Int64 {
        let n = Int64(frames)
        var total: Int64 = 0
        if audio {
            total += n * 8_000
        }
        if clean {
            total += n * frameFileBytes * 53 / 100
        }
        for look in looks {
            total += n * (look == .log ? 2_103_000 : 2_318_000)
        }
        return total
    }
}
