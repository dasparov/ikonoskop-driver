import AVFoundation
import Foundation

/// Runs AVFoundation's asynchronous loading from the synchronous test harness.
private final class Outcome<T> {
    var value: Result<T, Error>?
}

private func blocking<T>(_ body: @escaping () async throws -> T) throws -> T {
    let outcome = Outcome<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            outcome.value = .success(try await body())
        } catch {
            outcome.value = .failure(error)
        }
        done.signal()
    }
    done.wait()
    return try outcome.value!.get()
}

/// Every sample of `track`, as stored in the file.
private func samples(of track: AVAssetTrack, in asset: AVAsset) throws -> [CMSampleBuffer] {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    guard reader.startReading() else {
        throw reader.error ?? FileIOError(description: "cannot read \(track.mediaType.rawValue)")
    }
    var out: [CMSampleBuffer] = []
    // The reader also hands out empty marker buffers; keep the ones holding samples.
    while let s = output.copyNextSampleBuffer() {
        if CMSampleBufferGetNumSamples(s) > 0 {
            out.append(s)
        }
    }
    return out
}

private func bytes(_ sample: CMSampleBuffer) -> Data {
    guard let block = CMSampleBufferGetDataBuffer(sample) else {
        return Data()
    }
    var data = Data(count: CMBlockBufferGetDataLength(block))
    data.withUnsafeMutableBytes {
        _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
    }
    return data
}

private func fourCC(_ s: String) -> FourCharCode {
    s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
}

/// Checks one movie: ProRes 4444 XQ picture with `frames` frames at 25 fps, a timecode track
/// starting at `start` that the picture refers to, and `pcm` as its sound (none when nil).
private func checkMovie(_ t: TestContext, _ url: URL, look: ProResLook, frames: Int, start: Timecode, pcm: Data?) throws {
    let asset = AVURLAsset(url: url)
    let video = try blocking { try await asset.loadTracks(withMediaType: .video) }
    t.expectEqual(video.count, 1, "\(look) one video track")
    guard let picture = video.first else {
        return
    }
    let format = try blocking { try await picture.load(.formatDescriptions) }.first
    t.expectEqual(format.map(CMFormatDescriptionGetMediaSubType), fourCC("ap4x"), "\(look) Apple ProRes 4444 XQ")
    let size = format.map(CMVideoFormatDescriptionGetDimensions)
    t.expect(size?.width == 2048 && size?.height == 1092, "\(look) 2048x1092: \(String(describing: size))")
    let primaries = format.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String }
    let transfer = format.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String }
    if look == .preview {
        t.expectEqual(primaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String, "Rec709 primaries tag")
        t.expectEqual(transfer, kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String, "Rec709 transfer tag")
    } else {
        t.expect(primaries == nil && transfer == nil, "ACEScct is not tagged as Rec. 709: \(String(describing: primaries))")
    }
    let pictures = try samples(of: picture, in: asset)
    t.expectEqual(pictures.count, frames, "\(look) frame count")
    t.expect(pictures.allSatisfy { CMSampleBufferGetDuration($0) == CMTime(value: 1, timescale: 25) }, "\(look) 1/25 s frames")
    t.expectEqual(pictures.first.map(CMSampleBufferGetPresentationTimeStamp), .zero, "\(look) picture starts at 0")
    let videoSeconds = try blocking { try await picture.load(.timeRange) }.duration.seconds

    let timecodes = try blocking { try await asset.loadTracks(withMediaType: .timecode) }
    t.expectEqual(timecodes.count, 1, "\(look) one timecode track")
    if let tc = timecodes.first, let sample = try samples(of: tc, in: asset).first {
        let number = bytes(sample).prefix(4).reduce(0) { $0 << 8 | Int($1) }
        t.expectEqual(number, start.frameCount(fps: 25), "\(look) timecode starts at \(start)")
        let quanta = CMSampleBufferGetFormatDescription(sample).map(CMTimeCodeFormatDescriptionGetFrameQuanta)
        t.expectEqual(quanta, 25, "\(look) timecode counts 25 frames per second")
        let linked = try blocking { try await picture.loadAssociatedTracks(ofType: .timecode) }
        t.expectEqual(linked.map(\.trackID), [tc.trackID], "\(look) picture refers to the timecode track")
    }

    let sound = try blocking { try await asset.loadTracks(withMediaType: .audio) }
    guard let pcm = pcm else {
        t.expect(sound.isEmpty, "\(look) has no sound track")
        return
    }
    t.expectEqual(sound.count, 1, "\(look) one sound track")
    guard let audio = sound.first else {
        return
    }
    let asbd = try blocking { try await audio.load(.formatDescriptions) }.first
        .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
    t.expect(asbd?.mFormatID == kAudioFormatLinearPCM && asbd?.mSampleRate == 48_000 && asbd?.mChannelsPerFrame == 2
             && asbd?.mBitsPerChannel == 16 && (asbd?.mFormatFlags ?? 0) & kAudioFormatFlagIsBigEndian == 0,
             "\(look) 48 kHz 16-bit stereo little-endian PCM: \(String(describing: asbd))")
    let stored = try samples(of: audio, in: asset)
    t.expect(stored.reduce(Data()) { $0 + bytes($1) } == pcm, "\(look) sound samples unchanged")
    t.expectEqual(stored.first.map(CMSampleBufferGetPresentationTimeStamp), .zero, "\(look) sound starts with the picture")
    let audioSeconds = try blocking { try await audio.load(.timeRange) }.duration.seconds
    t.expect(abs(audioSeconds - videoSeconds) < 1.0 / 25, "\(look) sound \(audioSeconds) s, picture \(videoSeconds) s")
}

func proResTests(_ t: TestContext) throws {
    // NTSC rates become exact 1001-based durations.
    for (rate, want) in [((24, 1), CMTime(value: 1, timescale: 24)), ((25, 1), CMTime(value: 1, timescale: 25)),
                         ((2997, 100), CMTime(value: 1001, timescale: 30000)),
                         ((23976, 1000), CMTime(value: 1001, timescale: 24000))] as [((Int64, Int64), CMTime)] {
        let got = ProResTake.frameDuration(rate)
        t.expect(got.map { $0.value == want.value && $0.timescale == want.timescale } ?? false,
                 "FrameRate \(rate): \(String(describing: got)), want \(want)")
    }
    t.expect(ProResTake.frameDuration((0, 1)) == nil, "no frame rate")

    // A take of 5 clean frames at 25 fps starting at 10:00:00:05, with 5 frames of sound plus one
    // extra sample pair, as the camera's audio clock runs slightly fast.
    let fm = FileManager.default
    let scratch = try t.scratchDirectory("prores")
    let start = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 5)
    let frames = 5
    let take = scratch.appendingPathComponent("AC042001")
    try fm.createDirectory(at: take.appendingPathComponent("clean"), withIntermediateDirectories: true)
    for i in 0..<frames {
        let tc = Timecode(frameCount: start.frameCount(fps: 25) + i, fps: 25)
        let original = Fixture.frame(seed: UInt64(i + 1), fps: 25, timecode: tc, reel: "AC042001")
        try CleanDNG.make(fromOriginal: original).dng
            .write(to: take.appendingPathComponent(String(format: "clean/042%05d.DNG", i + 1)))
    }
    var pcm = Data()
    for i in 0..<(1920 * frames + 1) {
        pcm.append16(UInt16(bitPattern: Int16(truncatingIfNeeded: i * 7 - 20_000)))
        pcm.append16(UInt16(bitPattern: Int16(truncatingIfNeeded: 20_000 - i * 3)))
    }
    try BroadcastWAV.file(pcm: pcm, channels: 2, sampleRate: 48_000, bitsPerSample: 16, timeReference: 0,
                          description: "AC042001", originator: "acam tests", created: Date())
        .write(to: take.appendingPathComponent("AC042001_Audio.wav"))

    let out = scratch.appendingPathComponent("out")
    var lines: [String] = []
    let r = try ProResTake.run(take: take, look: .log, outputDir: out, progress: { lines.append($0) })
    t.expect(!r.failed && r.warnings.isEmpty, "log look: \(r.problems) \(r.warnings)")
    let movie = out.appendingPathComponent("AC042001_ACEScct.mov")
    t.expectEqual(r.output, movie)
    t.expectEqual(r.frames, frames)
    t.expect(abs(r.seconds - 0.2) < 1e-9, "5 frames at 25 fps: \(r.seconds) s")
    t.expect(lines.last?.hasPrefix("prores AC042001_ACEScct      5/5 frames  ") ?? false && lines.last?.hasSuffix(" fps") ?? false,
             "final progress line: \(lines)")
    try checkMovie(t, movie, look: .log, frames: frames, start: start, pcm: pcm)

    // Never overwrite: a second run fails and leaves the movie as it was.
    let before = try Data(contentsOf: movie)
    t.expect((try? ProResTake.run(take: take, look: .log, outputDir: out, progress: { _ in })) == nil,
             "refuses an existing movie")
    t.expect(try Data(contentsOf: movie) == before, "existing movie unchanged")

    // The preview look, from a take with camera originals only (no clean/) and no WAV.
    let raw = scratch.appendingPathComponent("AC042002")
    try fm.createDirectory(at: raw.appendingPathComponent("frames"), withIntermediateDirectories: true)
    for i in 0..<frames {
        let tc = Timecode(frameCount: start.frameCount(fps: 25) + i, fps: 25)
        try Fixture.frame(seed: UInt64(i + 11), fps: 25, timecode: tc, reel: "AC042002")
            .write(to: raw.appendingPathComponent(String(format: "frames/042%05d.DNG", i + 1)))
    }
    let p = try ProResTake.run(take: raw, look: .preview, outputDir: out, progress: { _ in })
    t.expect(!p.failed, "preview look: \(p.problems)")
    t.expectEqual(p.warnings.count, 1, "the missing WAV is reported: \(p.warnings)")
    t.expectEqual(p.output, out.appendingPathComponent("AC042002_Rec709.mov"))
    if let preview = p.output {
        try checkMovie(t, preview, look: .preview, frames: frames, start: start, pcm: nil)
    }
}
