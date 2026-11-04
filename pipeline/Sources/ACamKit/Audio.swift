// Camera audio: the 8 KiB block after each frame's image (the header's DNGPrivateData).
//
// Format (Phase 2, work/phase2/findings.md): 16-bit signed little-endian stereo PCM at 48 kHz,
// stored as pairs [channel 1][channel 2]. The first FF FF FF FF pair ends the frame's samples;
// it is never data because channel 2's lowest bit is always 0. 2,000 pairs per frame at 24 fps,
// 2,001 in about one frame in 100 (the audio clock runs ~5 ppm fast against the frame clock),
// continuous from frame to frame. The samples are written out unchanged, without resampling.
import Foundation

enum CameraAudio {
    static let blockOffset = 0x334000
    static let blockBytes = 0x2000
    static let sampleRate = 48_000

    /// Sample pairs per frame at `frameRate` (48000 * den / num).
    static func nominalPairs(_ frameRate: (Int64, Int64)) -> Double {
        frameRate.0 == 0 ? 0 : Double(sampleRate) * Double(frameRate.1) / Double(frameRate.0)
    }

    /// Sample pairs in a frame's audio block: up to the end marker (all 2,048 if there is none).
    static func pairCount(inBlock block: UnsafeRawBufferPointer) -> Int {
        var n = 0
        while n < block.count / 4 && block.loadUnaligned(fromByteOffset: 4 * n, as: UInt32.self) != 0xffff_ffff {
            n += 1
        }
        return n
    }

    /// Sample pairs kept from each frame at `nominal` pairs per frame: a frame with more than one
    /// pair over is cut, one with more than one pair short is padded with silence (1,999 to 2,001
    /// at 24 fps).
    static func pairLimits(nominal: Double) -> ClosedRange<Int> {
        Int((nominal - 1).rounded(.up))...Int((nominal + 1).rounded(.down))
    }

    /// Writes a frame's samples, cut or padded with silence to `limits`, as floats from -1 to 1
    /// (sample / 32,768): channel 1 to `left`, channel 2 to `right`. Both need room for
    /// `limits.upperBound` floats. Returns the pairs written.
    static func floatSamples(inBlock block: UnsafeRawBufferPointer, limits: ClosedRange<Int>,
                             left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Int {
        let kept = min(pairCount(inBlock: block), limits.upperBound)
        for k in 0..<kept {
            left[k] = Float(Int16(littleEndian: block.loadUnaligned(fromByteOffset: 4 * k, as: Int16.self))) / 32_768
            right[k] = Float(Int16(littleEndian: block.loadUnaligned(fromByteOffset: 4 * k + 2, as: Int16.self))) / 32_768
        }
        let total = max(kept, limits.lowerBound)
        for k in kept..<total {
            left[k] = 0
            right[k] = 0
        }
        return total
    }
}

/// RIFF/WAVE PCM with a Broadcast Wave `bext` chunk (EBU Tech 3285, version 1).
enum BroadcastWAV {
    static func file(pcm: Data, channels: Int, sampleRate: Int, bitsPerSample: Int, timeReference: UInt64,
                     description: String, originator: String, created: Date) -> Data {
        func ascii(_ s: String, _ size: Int) -> Data {
            var d = Data(s.utf8.prefix(size))
            d.append(Data(count: size - d.count))
            return d
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let date = f.string(from: created)
        f.dateFormat = "HH:mm:ss"
        let time = f.string(from: created)

        var bext = Data()
        bext.append(ascii(description, 256))
        bext.append(ascii(originator, 32))
        bext.append(ascii("", 32))              // OriginatorReference
        bext.append(ascii(date, 10))
        bext.append(ascii(time, 8))
        bext.append32(UInt32(timeReference & 0xffff_ffff))
        bext.append32(UInt32(timeReference >> 32))
        bext.append16(1)                        // version
        bext.append(Data(count: 64))            // UMID
        bext.append(Data(count: 190))           // loudness fields (version 2) and reserved
        bext.append(Data("A=PCM,F=\(sampleRate),W=\(bitsPerSample),M=stereo,T=\(originator)\r\n".utf8))

        var fmt = Data()
        fmt.append16(1)                         // PCM
        fmt.append16(UInt16(channels))
        fmt.append32(UInt32(sampleRate))
        fmt.append32(UInt32(sampleRate * channels * bitsPerSample / 8))
        fmt.append16(UInt16(channels * bitsPerSample / 8))
        fmt.append16(UInt16(bitsPerSample))

        var body = Data("WAVE".utf8)
        for (id, payload) in [("fmt ", fmt), ("bext", bext), ("data", pcm)] {
            body.append(Data(id.utf8))
            body.append32(UInt32(payload.count))
            body.append(payload)
            if payload.count & 1 == 1 {
                body.append(0)
            }
        }
        var out = Data("RIFF".utf8)
        out.append32(UInt32(body.count))
        out.append(body)
        return out
    }
}

struct AudioResult {
    var frames = 0
    var samplePairs = 0
    var frameRate: (Int64, Int64) = (0, 1)
    var startTimecode: Timecode?
    /// Audio duration minus picture duration, in seconds.
    var drift = 0.0
    var wav: URL?
    var manifest: URL?
    var warnings: [String] = []
    var problems: [String] = []

    var failed: Bool { !problems.isEmpty }
    var seconds: Double { Double(samplePairs) / Double(CameraAudio.sampleRate) }
}

enum AudioTake {
    /// <take>/<take>_Audio.wav from the verified copies in <take>/frames/. Stopped, it throws
    /// StoppedError before writing anything.
    static func run(take folder: URL, stop: StopSignal? = nil) throws -> AudioResult {
        let fm = FileManager.default
        let take = folder.lastPathComponent
        let out = folder.appendingPathComponent("\(take)_Audio.wav")
        guard !fm.fileExists(atPath: out.path) else {
            throw FileIOError(description: "\(out.path) already exists")
        }
        let framesDir = folder.appendingPathComponent("frames")
        let names = try fm.contentsOfDirectory(atPath: framesDir.path)
            .filter { !$0.hasPrefix(".") && $0.uppercased().hasSuffix(".DNG") }.sorted()
        var result = AudioResult()
        guard let firstName = names.first else {
            result.problems.append("no frames")
            return result
        }
        // One buffer for the first frame's header, then for each frame's audio block. Whole frames
        // are never read: holding them until the take was done used up the Mac's memory.
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: max(FrameHeader.headerBytes, CameraAudio.blockBytes), alignment: 16)
        defer { buffer.deallocate() }
        let headerLength = try FileIO.read(framesDir.appendingPathComponent(firstName).path, at: 0,
                                           into: UnsafeMutableRawBufferPointer(rebasing: buffer[0..<FrameHeader.headerBytes]))
        let header = try FrameHeader(Data(bytes: buffer.baseAddress!, count: headerLength))
        result.frameRate = header.frameRate
        result.startTimecode = header.timecode
        let nominal = CameraAudio.nominalPairs(header.frameRate)
        guard nominal > 0 else {
            result.problems.append("no frame rate in \(firstName)")
            return result
        }
        let limits = CameraAudio.pairLimits(nominal: nominal)
        let low = limits.lowerBound, high = limits.upperBound

        var pcm = Data()
        pcm.reserveCapacity(names.count * high * 4)
        let block = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<CameraAudio.blockBytes])
        for name in names {
            try stop?.check()
            let path = framesDir.appendingPathComponent(name).path
            guard try FileIO.read(path, at: CameraAudio.blockOffset, into: block) == block.count else {
                throw TIFFError("\(name) ends before its audio block")
            }
            let n = CameraAudio.pairCount(inBlock: UnsafeRawBufferPointer(block))
            if n > high {
                result.warnings.append("\(name): \(n) sample pairs, kept \(high)")
            } else if n < low {
                result.warnings.append("\(name): \(n) sample pairs, padded with silence to \(low)")
            }
            pcm.append(contentsOf: UnsafeRawBufferPointer(rebasing: block[0..<4 * min(n, high)]))
            if n < low {
                pcm.append(Data(count: 4 * (low - n)))
            }
        }
        result.frames = names.count
        result.samplePairs = pcm.count / 4
        result.drift = result.seconds - Double(names.count) * Double(header.frameRate.1) / Double(header.frameRate.0)

        // bext TimeReference: the take's start timecode in samples since midnight, counted at
        // the take's frame rate (as an editor reads the DNG sequence's timecode).
        let reference = UInt64(max(0, (Double(header.timecode?.frameCount(fps: header.timecodeFPS) ?? 0) * nominal).rounded()))
        let wav = BroadcastWAV.file(pcm: pcm, channels: 2, sampleRate: CameraAudio.sampleRate, bitsPerSample: 16,
                                    timeReference: reference,
                                    description: "\(take), \(header.reelName ?? take), start \(header.timecode?.description ?? "?")",
                                    originator: "acam \(acamVersion)", created: Date())
        try wav.write(to: out, options: .withoutOverwriting)
        result.wav = out
        result.manifest = try ASCMHL.addGeneration(
            folder: folder,
            entries: [MHLEntry(path: out.lastPathComponent, size: wav.count, modified: Date(),
                               xxh64: XXHash64.hash(wav), hashDate: Date())],
            process: "in-place")
        return result
    }
}
