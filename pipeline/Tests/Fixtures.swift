// Synthetic cards laid out like the driver's volume, and matching `ikctl eeprom` dumps.
import Foundation

struct FixtureTake {
    var frames: Int
    /// Seed of the frames' pseudo-random image data; equal seeds give equal frames.
    var seed: UInt64
    var fps = 24
    var start = Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0)
    /// Creation time in the take table: FAT time << 16 | FAT date (see `Fixture.fatTime`).
    var created: UInt32 = 0
}

enum Fixture {
    /// <dir>/ACAM <number>/IMAGE/AC<number><take>/<number><frame>.DNG, plus the empty folders.
    static func card(in dir: URL, number: Int, takes: [FixtureTake]) throws -> URL {
        let fm = FileManager.default
        let root = dir.appendingPathComponent(String(format: "ACAM %03d", number))
        for d in ["CLIP", "VIDEO", "AUDIO", "ICON", "PROXY", "IMAGE"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        var frameNumber = 1
        for (i, take) in takes.enumerated() {
            let reel = String(format: "AC%03d%03d", number, i + 1)
            let takeDir = root.appendingPathComponent("IMAGE").appendingPathComponent(reel)
            try fm.createDirectory(at: takeDir, withIntermediateDirectories: true)
            for f in 0..<take.frames {
                let tc = Timecode(frameCount: take.start.frameCount(fps: take.fps) + f, fps: take.fps)
                let data = frame(seed: take.seed &+ UInt64(f), fps: take.fps, timecode: tc, reel: reel)
                try data.write(to: takeDir.appendingPathComponent(String(format: "%03d%05d.DNG", number, frameNumber)))
                frameNumber += 1
            }
        }
        return root
    }

    /// A 0x336000-byte frame file as the driver serves it: the camera's header template (0 =
    /// monochrome, 1 = tungsten, 2 = daylight) with frame rate, timecodes and reel name set as
    /// createDngHeader() does, zero-padded to 4 KiB, then pseudo-random image data and 8 KiB block.
    /// `audio` (sample pairs) replaces the start of the block, the rest is 0xFF as on the card.
    static func frame(seed: UInt64, fps: Int, timecode: Timecode, reel: String, kind: Int = 2,
                      audio: Data? = nil) -> Data {
        var header = [UInt8](repeating: 0, count: 0x1000)
        precondition(acam_test_camera_header(Int32(kind), &header, header.count) > 0)
        let (rate, tc, reelAt) = kind == 0 ? (0x152, 0x162, 0x172) : (0x25a, 0x26a, 0x27a)
        for (i, b) in [UInt8(fps & 0xff), UInt8(fps >> 8), 0, 0, 1, 0, 0, 0].enumerated() {
            header[rate + i] = b
        }
        header.replaceSubrange(tc..<tc + 16, with: timecode.smpte + timecode.smpte)
        header.replaceSubrange(reelAt..<reelAt + 9, with: Array(reel.utf8.prefix(8)) + [0])
        var words = [UInt64](repeating: 0, count: 0x335000 / 8)
        var x = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        for i in words.indices {
            x ^= x << 13
            x ^= x >> 7
            x ^= x << 17
            words[i] = x
        }
        var file = Data(header) + words.withUnsafeBytes { Data($0) }
        if let audio = audio {
            let block = CameraAudio.blockOffset
            file.replaceSubrange(block..<block + CameraAudio.blockBytes,
                                 with: audio + Data(repeating: 0xff, count: CameraAudio.blockBytes - audio.count))
        }
        return file
    }

    /// `ikctl eeprom 0 0x2000` output for a card holding `takes` in entries 0, 1, ... An index in
    /// `invalid` leaves that entry invalid (the takes after it shift to later entries).
    static func eepromDump(number: Int, takes: [FixtureTake], invalid: Set<Int> = []) -> String {
        var b = [UInt8](repeating: 0xff, count: EepromImage.size)
        b[0] = 1
        b[1] = 0
        b[2] = UInt8(number & 0xff)
        b[3] = UInt8(number >> 8)
        var entry = 0
        for (i, take) in takes.enumerated() {
            while invalid.contains(entry) {
                b[EepromImage.takeTable + entry * EepromImage.entryBytes] = 0
                entry += 1
            }
            let e = EepromImage.takeTable + entry * EepromImage.entryBytes
            b[e] = 1
            b[e + 1] = UInt8(take.fps)
            b[e + 2] = UInt8(i * 16)
            b[e + 3] = 0
            b[e + 4] = UInt8(take.frames & 0xff)
            b[e + 5] = UInt8(take.frames >> 8)
            for k in 0..<4 {
                b[e + 10 + k] = UInt8(truncatingIfNeeded: take.created >> (8 * k))
            }
            entry += 1
        }
        return hexDump(b)
    }

    /// A creation time as the take table stores it.
    static func fatTime(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> UInt32 {
        let date = UInt32((year - 1980) << 9 | month << 5 | day)
        let time = UInt32(hour << 11 | minute << 5)
        return time << 16 | date
    }

    /// The format of tools/ikctl.c hexdump().
    static func hexDump(_ bytes: [UInt8]) -> String {
        var out = ""
        for row in stride(from: 0, to: bytes.count, by: 16) {
            out += String(format: "%06llx ", row)
            let chunk = bytes[row..<min(row + 16, bytes.count)]
            out += chunk.map { String(format: " %02x", $0) }.joined()
            out += "  |" + String(chunk.map { $0 >= 0x20 && $0 < 0x7f ? Character(UnicodeScalar($0)) : "." }) + "|\n"
        }
        return out
    }

    /// A driver session that started before the offload, without errors.
    static func cleanLog(number: Int, takes: Int, frames: Int) -> [KernelLogLine] {
        let t = Date(timeIntervalSinceNow: -60)
        return [
            KernelLogLine(date: t, text: "2026-01-01 00:00:00.000 Df kernel[0:1] (IkonoskopCardReader) IkonoskopCardReader: start (arm64e port of v1.2)"),
            KernelLogLine(date: t, text: "2026-01-01 00:00:00.000 Df kernel[0:1] (IkonoskopCardReader) IkonoskopCardReader[core]: card \(number): \(takes) takes, \(frames) frames, blockCount 0x1"),
        ]
    }
}
