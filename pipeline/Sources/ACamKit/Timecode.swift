// SMPTE timecodes as the camera stores them in the DNG TimeCodes tag.
import Foundation

struct Timecode: Equatable, CustomStringConvertible {
    var hours: Int
    var minutes: Int
    var seconds: Int
    var frames: Int

    /// First 4 of the 8 SMPTE 12M bytes: BCD frames, seconds, minutes, hours (flag bits ignored).
    init(smpte b: [UInt8]) {
        func bcd(_ v: UInt8, tensMask: UInt8) -> Int {
            Int((v >> 4) & tensMask) * 10 + Int(v & 0x0f)
        }
        frames = bcd(b[0], tensMask: 3)
        seconds = bcd(b[1], tensMask: 7)
        minutes = bcd(b[2], tensMask: 7)
        hours = bcd(b[3], tensMask: 3)
    }

    init(hours: Int, minutes: Int, seconds: Int, frames: Int) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
    }

    init(frameCount: Int, fps: Int) {
        let total = max(frameCount, 0)
        frames = total % fps
        seconds = total / fps % 60
        minutes = total / fps / 60 % 60
        hours = total / fps / 3600 % 24
    }

    /// Frames since 00:00:00:00 at `fps` timecode frames per second (non-drop).
    func frameCount(fps: Int) -> Int {
        ((hours * 60 + minutes) * 60 + seconds) * fps + frames
    }

    /// SMPTE 12M bytes in the camera's layout (user bits zero).
    var smpte: [UInt8] {
        func bcd(_ v: Int) -> UInt8 {
            UInt8((v / 10) << 4 | v % 10)
        }
        return [bcd(frames), bcd(seconds), bcd(minutes), bcd(hours), 0, 0, 0, 0]
    }

    var description: String {
        String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }
}
