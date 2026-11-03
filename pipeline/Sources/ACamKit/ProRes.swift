// acam prores: one take's DNGs to an Apple ProRes 4444 XQ QuickTime movie, with the take's WAV
// and its start timecode.
//
// Picture: every DNG (<take>/clean/, or <take>/frames/ when there is no clean/) is developed by
// Apple's RAW engine (Core Image's CIRAWFilter) from the DNG's own colour matrices and
// AsShotNeutral white balance, with sharpening, noise reduction, detail, moire reduction, local
// tone mapping and lens correction all off. Two looks:
//
//   ACEScct  for grading. Scene-linear development (boostAmount 0 = no tone curve, shadowBias 0,
//            no gamut mapping, exposure 0 and the DNG's BaselineExposure 0, so the sensor's
//            white level is linear 1.0 and nothing above it is clipped), converted by Core
//            Image's colour management from its linear working space to ACEScg (AP1 primaries,
//            linear), then encoded per channel with the ACEScct curve (Academy S-2016-001, a
//            Metal kernel compiled at run time). The movie carries the Rec. 709
//            Y'CbCr matrix only: there is no QuickTime tag for AP1 or ACEScct, so a grading
//            application has to be told "ACEScct" (DaVinci Resolve: input colour space ACEScct).
//   Rec709   a display-referred preview: CIRAWFilter's default tone curve (boostAmount 1,
//            boostShadowAmount 0.9, shadowBias and gamut mapping at their defaults) rendered
//            into ITU-R BT.709 (CGColorSpace.itur_709: BT.709 primaries, D65, BT.709 transfer
//            function), tagged BT.709 primaries, transfer function and matrix.
//
// Both are rendered into 16-bit RGB frames, which the ProRes encoder converts to 12-bit 4:4:4
// Y'CbCr without alpha (video range, BT.709 matrix). Frame duration from the DNG FrameRate tag
// (24/1 -> 1/24 s, 2997/100 -> 1001/30000 s). Audio: <take>/<take>_Audio.wav, if present, copied
// sample for sample as 16-bit little-endian LPCM starting at the first frame. Timecode: a
// QuickTime timecode track starting at the first frame's timecode (non-drop, counted at the
// timecode rate) with the reel name, referenced by the video track. An existing movie is never
// overwritten.
import AVFoundation
import CoreImage
import Foundation
import Metal
import VideoToolbox

enum ProResLook: String, CaseIterable {
    case log = "ACEScct"
    case preview = "Rec709"
}

struct ProResResult {
    var output: URL?
    var frames = 0
    var seconds = 0.0
    var problems: [String] = []
    var warnings: [String] = []

    var failed: Bool { !problems.isEmpty }
}

enum ProResTake {
    /// Frames rendered at the same time (the RAW decode runs on the CPU, the rest on the GPU).
    static let batch = 8

    /// Renders <take>/clean/*.DNG (or <take>/frames/*.DNG when there is no clean/) to
    /// <outputDir>/<take>_<look.rawValue>.mov.
    static func run(take folder: URL, look: ProResLook, outputDir: URL,
                    progress: @escaping (String) -> Void) throws -> ProResResult {
        let fm = FileManager.default
        let take = folder.lastPathComponent
        let name = "\(take)_\(look.rawValue)"
        let output = outputDir.appendingPathComponent("\(name).mov")
        guard !fm.fileExists(atPath: output.path) else {
            throw FileIOError(description: "\(output.path) already exists")
        }
        let clean = folder.appendingPathComponent("clean")
        let source = fm.fileExists(atPath: clean.path) ? clean : folder.appendingPathComponent("frames")
        let frames = try fm.contentsOfDirectory(atPath: source.path)
            .filter { !$0.hasPrefix(".") && $0.uppercased().hasSuffix(".DNG") }.sorted()
            .map { source.appendingPathComponent($0) }

        var result = ProResResult()
        guard let first = frames.first else {
            result.problems.append("no frames in \(source.path)")
            return result
        }
        let firstBytes = try readHeader(first)
        let header = try FrameHeader(firstBytes)
        guard let frameDuration = frameDuration(header.frameRate) else {
            result.problems.append("\(first.lastPathComponent): no frame rate")
            return result
        }
        let tiff = try TIFFHeader(firstBytes)
        let crop = tiff.uints(DNGTag.defaultCropSize) ?? tiff.rationals(DNGTag.defaultCropSize)?
            .map { UInt32($0.0 / max($0.1, 1)) }
        let width = Int(crop?.first ?? UInt32(Raw12.width))
        let height = Int(crop?.dropFirst().first ?? UInt32(Raw12.height))
        if header.timecode == nil {
            result.warnings.append("\(first.lastPathComponent) has no timecode: the timecode track starts at 00:00:00:00")
        }
        let startTimecode = header.timecode ?? Timecode(hours: 0, minutes: 0, seconds: 0, frames: 0)

        let wavURL = folder.appendingPathComponent("\(take)_Audio.wav")
        var audio: WAVAudio?
        if fm.fileExists(atPath: wavURL.path) {
            audio = try WAVAudio(Data(contentsOf: wavURL))
        } else {
            result.warnings.append("no \(wavURL.lastPathComponent): the movie has no sound")
        }

        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let movie = try MovieWriter(url: output, look: look, width: width, height: height,
                                    frameDuration: frameDuration, frames: frames.count, audio: audio,
                                    timecode: startTimecode, timecodeFPS: header.timecodeFPS,
                                    reel: header.reelName ?? take)
        let renderer = try FrameRenderer(look: look, width: width, height: height)

        let started = Date()
        var done = 0
        do {
            for start in stride(from: 0, to: frames.count, by: batch) {
                let urls = Array(frames[start..<min(start + batch, frames.count)])
                var buffers = [CVPixelBuffer?](repeating: nil, count: urls.count)
                var errors = [String?](repeating: nil, count: urls.count)
                let lock = NSLock()
                DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                    autoreleasepool {
                        do {
                            let pb = try movie.makePixelBuffer()
                            try renderer.render(urls[i], into: pb)
                            lock.lock()
                            buffers[i] = pb
                            lock.unlock()
                        } catch {
                            lock.lock()
                            errors[i] = "\(urls[i].lastPathComponent): \(error)"
                            lock.unlock()
                        }
                    }
                }
                if let error = errors.compactMap({ $0 }).first {
                    throw FileIOError(description: error)
                }
                for (i, pb) in buffers.enumerated() {
                    try movie.appendFrame(pb!, index: start + i)
                    done += 1
                    if done % 100 == 0 || done == frames.count {
                        let fps = Double(done) / max(Date().timeIntervalSince(started), 0.001)
                        progress(String(format: "prores %@  %5d/%d frames  %.1f fps", name, done, frames.count, fps))
                    }
                }
            }
            try movie.finish()
        } catch {
            movie.cancel()
            try? fm.removeItem(at: output)
            result.problems.append("\(error)")
            return result
        }
        result.output = output
        result.frames = frames.count
        result.seconds = Double(frames.count) * frameDuration.seconds
        return result
    }

    /// Duration of one frame for a DNG FrameRate: NTSC rates (2997/100, 23976/1000, ...) become
    /// exact 1001/(n * 1000) fractions.
    static func frameDuration(_ rate: (Int64, Int64)) -> CMTime? {
        let (num, den) = rate
        guard num > 0, den > 0 else {
            return nil
        }
        let fps = Double(num) / Double(den)
        let whole = fps.rounded()
        if den != 1, whole > 0, abs(fps - whole * 1000 / 1001) < 0.0005 {
            return CMTime(value: 1001, timescale: CMTimeScale(whole * 1000))
        }
        var a = num, b = den
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return CMTime(value: den / a, timescale: CMTimeScale(num / a))
    }

    /// The first 4 KiB of a DNG, which hold its tags.
    private static func readHeader(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: FrameHeader.headerBytes) ?? Data()
    }
}

/// The PCM samples of a RIFF/WAVE file (format 1, 16-bit).
private struct WAVAudio {
    let channels: Int
    let sampleRate: Int
    let pcm: Data

    var frameCount: Int { pcm.count / (2 * channels) }

    init(_ wav: Data) throws {
        guard wav.count >= 12, wav.prefix(4) == Data("RIFF".utf8), wav.subdata(in: 8..<12) == Data("WAVE".utf8) else {
            throw TIFFError("not a RIFF/WAVE file")
        }
        var fmt: Data?
        var data: Data?
        var at = 12
        while at + 8 <= wav.count {
            let id = String(decoding: wav.subdata(in: at..<at + 4), as: UTF8.self)
            let size = Int(wav.u32(at + 4))
            let payload = wav.subdata(in: at + 8..<min(at + 8 + size, wav.count))
            if id == "fmt " {
                fmt = payload
            } else if id == "data" {
                data = payload
            }
            at += 8 + size + (size & 1)
        }
        guard let f = fmt, f.count >= 16, let d = data else {
            throw TIFFError("the WAV file has no fmt or data chunk")
        }
        guard f.u16(0) == 1, f.u16(14) == 16, f.u16(2) > 0 else {
            throw TIFFError("the WAV file is not 16-bit PCM (format \(f.u16(0)), \(f.u16(14)) bits)")
        }
        channels = Int(f.u16(2))
        sampleRate = Int(f.u32(4))
        pcm = d.prefix(d.count / (2 * channels) * (2 * channels))
    }
}

/// Develops one DNG with CIRAWFilter into a 16-bit RGB pixel buffer.
private final class FrameRenderer {
    let look: ProResLook
    let width: Int
    let height: Int
    let context: CIContext
    let outputSpace: CGColorSpace?
    static let acescg = CGColorSpace(name: CGColorSpace.acescgLinear)!

    init(look: ProResLook, width: Int, height: Int) throws {
        self.look = look
        self.width = width
        self.height = height
        guard let device = ACEScctKernel.device else {
            throw FileIOError(description: "no Metal GPU")
        }
        // Float working format: the log look keeps scene-linear values above 1.0.
        context = CIContext(mtlDevice: device, options: [.workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        // Rec709: Core Image converts to BT.709 primaries and transfer function on output. ACEScct:
        // the values are already code values, written without colour matching.
        outputSpace = look == .preview ? CGColorSpace(name: CGColorSpace.itur_709)! : nil
    }

    func render(_ url: URL, into pb: CVPixelBuffer) throws {
        guard let raw = CIRAWFilter(imageURL: url) else {
            throw TIFFError("Core Image cannot open the DNG")
        }
        raw.sharpnessAmount = 0
        raw.detailAmount = 0
        raw.luminanceNoiseReductionAmount = 0
        raw.colorNoiseReductionAmount = 0
        raw.moireReductionAmount = 0
        raw.localToneMapAmount = 0
        raw.contrastAmount = 0
        raw.isLensCorrectionEnabled = false
        raw.exposure = 0
        if look == .log {
            raw.boostAmount = 0
            raw.boostShadowAmount = 0
            raw.shadowBias = 0
            raw.isGamutMappingEnabled = false
        }
        guard var image = raw.outputImage else {
            throw TIFFError("Core Image cannot develop the DNG")
        }
        guard Int(image.extent.width) == width, Int(image.extent.height) == height else {
            throw TIFFError("developed to \(Int(image.extent.width))x\(Int(image.extent.height)), not \(width)x\(height)")
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if look == .log {
            image = try ACEScctKernel.apply(withExtent: image.extent,
                                            inputs: [image.matchedFromWorkingSpace(to: Self.acescg)!],
                                            arguments: nil)
        }
        context.render(image, to: pb, bounds: image.extent, colorSpace: outputSpace)
    }
}

/// ACEScct (S-2016-001) encoding of each colour channel of ACEScg linear values, on the GPU:
/// lin <= 2^-7: 10.5402377416545 * lin + 0.0729055341958355, else (log2(lin) + 9.72) / 17.52.
final class ACEScctKernel: CIImageProcessorKernel {
    static let device = MTLCreateSystemDefaultDevice()
    static let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void acescct(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
            float3 lin = src.read(gid).rgb;
            float3 linear = 10.5402377416545 * lin + 0.0729055341958355;
            float3 log = (log2(max(lin, 0.0078125)) + 9.72) / 17.52;
            dst.write(float4(select(log, linear, lin <= 0.0078125), 1.0), gid);
        }
        """
    /// Compiled at run time by the system's Metal compiler (no Xcode needed).
    static let pipeline: Result<MTLComputePipelineState, Error> = Result {
        guard let device = device else {
            throw FileIOError(description: "no Metal GPU")
        }
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        let library = try device.makeLibrary(source: source, options: options)
        return try device.makeComputePipelineState(function: library.makeFunction(name: "acescct")!)
    }

    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        let pipeline = try pipeline.get()
        // Per-pixel kernel: the input region is the output region (the default region of interest).
        guard let input = inputs?.first, input.region == output.region, let src = input.metalTexture,
              let dst = output.metalTexture, let encoder = output.metalCommandBuffer?.makeComputeCommandEncoder() else {
            throw FileIOError(description: "the ACEScct kernel needs same-size Metal textures")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(src, index: 0)
        encoder.setTexture(dst, index: 1)
        let w = pipeline.threadExecutionWidth, h = pipeline.maxTotalThreadsPerThreadgroup / w
        encoder.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding()
    }
}

/// The QuickTime movie: ProRes 4444 XQ video, optional LPCM audio and a timecode track.
private final class MovieWriter {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let sound: AVAssetWriterInput?
    let audio: WAVAudio?
    let audioFormat: CMAudioFormatDescription?
    let frameDuration: CMTime
    var audioFrame = 0
    static let audioChunk = 24_000

    init(url: URL, look: ProResLook, width: Int, height: Int, frameDuration: CMTime, frames: Int,
         audio: WAVAudio?, timecode: Timecode, timecodeFPS: Int, reel: String) throws {
        self.frameDuration = frameDuration
        self.audio = audio
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let timescale = frameDuration.timescale < 1000 ? frameDuration.timescale * 1000 : frameDuration.timescale
        // Track edits are in movie time units: these must hold whole frames and whole audio samples,
        // or the sound's edit is cut short by up to a sample.
        writer.movieTimeScale = Self.lcm(timescale, CMTimeScale(audio?.sampleRate ?? Int(timescale)))

        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType(rawValue: "ap4x"),  // Apple ProRes 4444 XQ
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // The frames are opaque: no alpha channel in the movie.
            AVVideoCompressionPropertiesKey: [kVTCompressionPropertyKey_PreserveAlphaChannel as String: false],
        ]
        if look == .preview {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw FileIOError(description: "this Mac cannot encode Apple ProRes 4444 XQ")
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = false
        video.mediaTimeScale = timescale
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            // 16-bit RGBA, little-endian: a format Core Image renders to directly.
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBALE,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        writer.add(video)

        // Timecode: one sample, the first frame's number since midnight, lasting the whole take.
        var tcFormat: CMTimeCodeFormatDescription?
        let extensions = [kCMTimeCodeFormatDescriptionExtension_SourceReferenceName: [
            kCMTimeCodeFormatDescriptionKey_Value: reel,
            kCMTimeCodeFormatDescriptionKey_LangCode: 0,
        ] as [CFString: Any]] as CFDictionary
        var status = CMTimeCodeFormatDescriptionCreate(
            allocator: nil, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32, frameDuration: frameDuration,
            frameQuanta: UInt32(timecodeFPS), flags: kCMTimeCodeFlag_24HourMax, extensions: extensions,
            formatDescriptionOut: &tcFormat)
        guard status == noErr, let tcFormat = tcFormat else {
            throw FileIOError(description: "cannot describe the timecode track (\(status))")
        }
        let tcInput = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: tcFormat)
        tcInput.expectsMediaDataInRealTime = false
        writer.add(tcInput)
        video.addTrackAssociation(withTrackOf: tcInput, type: AVAssetTrack.AssociationType.timecode.rawValue)

        if let audio = audio {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(audio.sampleRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(2 * audio.channels), mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(2 * audio.channels), mChannelsPerFrame: UInt32(audio.channels),
                mBitsPerChannel: 16, mReserved: 0)
            var format: CMAudioFormatDescription?
            status = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                                    magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &format)
            guard status == noErr, let format = format else {
                throw FileIOError(description: "cannot describe the audio (\(status))")
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            sound = input
            audioFormat = format
        } else {
            sound = nil
            audioFormat = nil
        }

        guard writer.startWriting() else {
            throw FileIOError(description: "cannot start the movie: \(writer.error.map { "\($0)" } ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)

        var frameNumber = Int32(timecode.frameCount(fps: timecodeFPS)).bigEndian
        let block = try Self.blockBuffer(Data(bytes: &frameNumber, count: 4))
        var timing = CMSampleTimingInfo(duration: CMTimeMultiply(frameDuration, multiplier: Int32(frames)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: tcFormat,
                                           sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample = sample else {
            throw FileIOError(description: "cannot make the timecode sample (\(status))")
        }
        try wait(for: tcInput)
        guard tcInput.append(sample) else {
            throw writerError("timecode")
        }
        tcInput.markAsFinished()
    }

    func makePixelBuffer() throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else {
            throw writerError("pixel buffer pool")
        }
        var pb: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard status == kCVReturnSuccess, let pb = pb else {
            throw FileIOError(description: "cannot allocate a frame buffer (\(status))")
        }
        return pb
    }

    func appendFrame(_ pb: CVPixelBuffer, index: Int) throws {
        let time = CMTimeMultiply(frameDuration, multiplier: Int32(index))
        // Keep the audio up to a second ahead of the picture, so the writer can interleave.
        feedAudio(until: CMTimeAdd(time, CMTime(value: 1, timescale: 1)))
        try wait(for: video)
        guard adaptor.append(pb, withPresentationTime: time) else {
            throw writerError("frame \(index + 1)")
        }
    }

    func finish() throws {
        video.markAsFinished()
        if let sound = sound, let audio = audio {
            while audioFrame < audio.frameCount {
                try wait(for: sound)
                try appendAudioChunk()
            }
            if audio.frameCount == 0 {
                sound.markAsFinished()
            }
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw writerError("finishing the movie")
        }
    }

    func cancel() {
        if writer.status == .writing {
            writer.cancelWriting()
        }
    }

    private func feedAudio(until limit: CMTime) {
        guard let sound = sound, let audio = audio else {
            return
        }
        while audioFrame < audio.frameCount, sound.isReadyForMoreMediaData,
              CMTime(value: CMTimeValue(audioFrame), timescale: CMTimeScale(audio.sampleRate)) < limit {
            if (try? appendAudioChunk()) == nil {
                return
            }
        }
    }

    private func appendAudioChunk() throws {
        guard let audio = audio, let sound = sound, let format = audioFormat else {
            return
        }
        let count = min(Self.audioChunk, audio.frameCount - audioFrame)
        let bytesPerFrame = 2 * audio.channels
        let start = audio.pcm.startIndex + audioFrame * bytesPerFrame
        let block = try Self.blockBuffer(audio.pcm.subdata(in: start..<start + count * bytesPerFrame))
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(audioFrame), timescale: CMTimeScale(audio.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample = sample else {
            throw FileIOError(description: "cannot make an audio sample buffer (\(status))")
        }
        guard sound.append(sample) else {
            throw writerError("audio")
        }
        audioFrame += count
        // Finish the sound as soon as it is all in: until then the writer may hold the picture back.
        if audioFrame == audio.frameCount {
            sound.markAsFinished()
        }
    }

    /// Waits until `input` takes more data, feeding audio meanwhile: the writer may hold the
    /// picture back until it has the sound for the same stretch of time.
    private func wait(for input: AVAssetWriterInput) throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw writerError("writing")
            }
            if input !== sound, let sound = sound, let audio = audio, audioFrame < audio.frameCount,
               sound.isReadyForMoreMediaData {
                try appendAudioChunk()
                continue
            }
            usleep(500)
        }
    }

    private func writerError(_ what: String) -> FileIOError {
        FileIOError(description: "\(what): \(writer.error.map { "\($0.localizedDescription) (\($0))" } ?? "the movie writer failed")")
    }

    private static func lcm(_ a: CMTimeScale, _ b: CMTimeScale) -> CMTimeScale {
        var x = a, y = b
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return a / x * b
    }

    private static func blockBuffer(_ data: Data) throws -> CMBlockBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block = block else {
            throw FileIOError(description: "cannot allocate a sample buffer (\(status))")
        }
        status = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: data.count)
        }
        guard status == noErr else {
            throw FileIOError(description: "cannot fill a sample buffer (\(status))")
        }
        return block
    }
}
