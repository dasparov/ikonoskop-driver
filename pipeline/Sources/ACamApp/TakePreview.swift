// Take preview: plays one take straight from the card, before it is copied, in its own window,
// with its sound. While playing, every frame is read from the card in order (3.4 MB each, a batch
// at a time); its sound, the 8 KiB block after the image, goes to the Mac's sound output, and the
// sound keeps the time: the picture shows the frame whose sound is being heard. Pictures are
// developed from the same bytes, like the Rec.709 ProRes preview in the chosen colour profile:
// 1024 pixels wide while playing, beside the reading, and at full resolution (2048 pixels) when
// stopped on a frame. When developing falls behind, pictures are skipped; the sound never is. Only
// when reading the card falls behind does the sound wait, in silence (never playing old sound).
// While the card is being copied, the app opens no previews and closes an open one (CardModel).
import AVFoundation
import AppKit
import CoreImage
import SwiftUI

final class TakePlayer: ObservableObject {
    /// Development width while playing (about 44 frames/s on the M1 Pro, enough for real time) and
    /// when stopped on a frame (full resolution, about 28 frames/s).
    static let playWidth = 1024
    static let stillWidth = Raw12.width
    /// Frames read from the card at once, in parallel (the card delivers about 51 frames/s with 8
    /// reads at a time), and developed at once. The sound starts once a batch is read and developed.
    static let batch = 8
    /// Reading stays at most this many frames ahead of the sound heard.
    static let readAhead = 2 * batch
    /// Sound read after its turn is scheduled this many seconds after the sound output's position:
    /// about the time developing a batch takes, so the picture is back in step when the sound goes
    /// on.
    static let lateMargin = 0.2

    let take: TakeRow
    private let profile: ColourProfile?
    private let context = CIContext()
    /// Reading while playing; developing stills.
    private let work = DispatchQueue(label: "acam.preview", qos: .userInitiated)
    /// One thread per read of a batch, even while developing keeps every core busy.
    private let reads = DispatchQueue(label: "acam.preview.read", qos: .userInitiated, attributes: .concurrent)
    private let developing = DispatchQueue(label: "acam.preview.develop", qos: .userInitiated)

    /// The sound: one player node into the engine's mixer, 48 kHz stereo.
    let engine = AVAudioEngine()
    let speaker = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(CameraAudio.sampleRate), channels: 2)!
    private var configurationObserver: NSObjectProtocol?

    @Published private(set) var image: CGImage?
    @Published private(set) var shown = 0
    @Published private(set) var playing = false
    @Published private(set) var problem: String?
    /// Silences the sound output; the sound still keeps the time.
    var muted = false {
        didSet { engine.mainMixerNode.outputVolume = muted ? 0 : 1 }
    }

    /// Where each frame's sound of the current play sits on the player node's timeline (in
    /// samples since the sound started).
    struct Schedule {
        /// The frame the play started from.
        var from = 0
        /// The first sample of frame `from + k`.
        var starts: [Int64] = []
        /// The end of the last frame's sound scheduled.
        var end: Int64 = 0
        /// The take's last frame is scheduled.
        var complete = false
        /// Frames whose sound was read after its turn, each after a moment of silence.
        var late = 0

        /// The frame whose sound plays at `sample`: the last one started by then.
        func frame(at sample: Double) -> Int {
            var low = 0, high = starts.count
            while low < high {
                let mid = (low + high) / 2
                if Double(starts[mid]) <= sample {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            return from + max(low - 1, 0)
        }
    }

    // Every play, stop and seek starts a new generation; work for an older one is dropped. The
    // lock also guards the current play's schedule and the frames read but not yet developed.
    private let lock = NSLock()
    private var generation = 0
    private var schedule = Schedule()
    private var undeveloped: [(index: Int, file: Data)] = []
    private var developerRunning = false
    // Main thread only: frames developed ahead of the playhead, the frame timer, and whether the
    // sound has started.
    private var ready: [Int: CGImage] = [:]
    private var timer: Timer?
    private var soundStarted = false

    init(take: TakeRow, profile: ColourProfile?) {
        self.take = take
        self.profile = profile
        engine.attach(speaker)
        engine.connect(speaker, to: engine.mainMixerNode, format: format)
        // A change of sound output (headphones in or out) stops the engine: pause on the frame.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            if self?.playing == true {
                self?.pause()
            }
        }
    }

    deinit {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        engine.stop()
    }

    private var fps: Double { take.fps > 0 ? take.fps : 24 }

    /// Shows frame `index` at full resolution, without sound; stops playback.
    func seek(to index: Int) {
        guard !take.files.isEmpty else {
            return
        }
        let g = stopClock()
        let i = min(max(index, 0), take.files.count - 1)
        shown = i
        work.async { [self] in
            guard isCurrent(g) else {
                return
            }
            let result = develop(i, width: Self.stillWidth)
            DispatchQueue.main.async { [self] in
                guard isCurrent(g) else {
                    return
                }
                switch result {
                case .success(let frame):
                    image = frame
                    problem = nil
                case .failure(let error):
                    report(error, frame: i)
                }
            }
        }
    }

    func step(_ frames: Int) {
        seek(to: shown + frames)
    }

    func togglePlay() {
        playing ? pause() : play()
    }

    /// Stops playing and shows the frame at full resolution.
    func pause() {
        seek(to: shown)
    }

    /// Plays with sound from the frame shown (from the start once the end was reached).
    func play() {
        guard !playing, !take.files.isEmpty else {
            return
        }
        let count = take.files.count
        if shown >= count - 1 {
            shown = 0
        }
        let g = newGeneration(from: shown)
        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            problem = "The preview cannot play: the Mac's sound output does not start (\(error))."
            return
        }
        let from = shown
        ready = [:]
        soundStarted = false
        playing = true
        problem = nil
        // Read every frame in order, a batch at a time and at most `readAhead` frames ahead of the
        // sound heard; schedule each frame's sound and hand the frames to developing.
        work.async { [self] in
            var next = from
            while isCurrent(g) && next < count {
                if next > heardFrame() + Self.readAhead {
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }
                let indices = Array(next..<min(next + Self.batch, count))
                var files = [Result<Data, Error>?](repeating: nil, count: indices.count)
                let slots = NSLock(), group = DispatchGroup()
                for (k, i) in indices.enumerated() {
                    reads.async(group: group) { [self] in
                        let result = autoreleasepool { Result { try Data(contentsOf: take.files[i]) } }
                        slots.lock()
                        files[k] = result
                        slots.unlock()
                    }
                }
                group.wait()
                var frames: [(index: Int, file: Data)] = []
                for (k, i) in indices.enumerated() {
                    do {
                        let file = try files[k]!.get()
                        guard enqueue(try sound(of: file), frame: i, generation: g) else {
                            return
                        }
                        frames.append((i, file))
                    } catch {
                        DispatchQueue.main.async { [self] in
                            if isCurrent(g) {
                                stop()
                                report(error, frame: i)
                            }
                        }
                        return
                    }
                }
                handOver(frames, generation: g)
                next += indices.count
            }
        }
        let t = Timer(timeInterval: 1 / (4 * fps), repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stops playback, sound and developing; the frame shown stays.
    func stop() {
        _ = stopClock()
        engine.stop()
    }

    /// The current play's schedule (a copy).
    var soundSchedule: Schedule {
        lock.lock()
        defer { lock.unlock() }
        return schedule
    }

    /// The player node's timeline now, in samples: the position being sent to the sound output,
    /// and the one being heard (later by the output's latency). Nil until the sound has started.
    func soundTime() -> (output: Double, heard: Double)? {
        guard let render = speaker.lastRenderTime, render.isHostTimeValid,
              let time = speaker.playerTime(forNodeTime: render), time.isSampleTimeValid else {
            return nil
        }
        let since = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: render.hostTime)
        let output = Double(time.sampleTime) + since * time.sampleRate
        return (output, output - engine.outputNode.presentationLatency * time.sampleRate)
    }

    /// The frame whose sound is being heard (the frame the play started from until the sound starts).
    private func heardFrame() -> Int {
        let s = soundSchedule
        return soundTime().map { s.frame(at: $0.heard) } ?? s.from
    }

    /// Shows the newest developed frame the sound has reached; starts the sound once a batch is
    /// read and developed; stops on the last frame once its sound has been heard.
    private func tick() {
        let s = soundSchedule
        if !soundStarted {
            // The engine stops by itself when the sound output changes (then playing pauses).
            if s.starts.count >= min(Self.batch, take.files.count - s.from) && !ready.isEmpty && engine.isRunning {
                speaker.play()
                soundStarted = true
            }
            return
        }
        guard let time = soundTime() else {
            return
        }
        let head = s.frame(at: time.heard)
        if let i = ready.keys.filter({ $0 <= head }).max(), let frame = ready[i] {
            image = frame
            shown = i
            ready = ready.filter { $0.key > i }
        }
        if s.complete && time.heard >= Double(s.end) {
            seek(to: take.files.count - 1)
        }
    }

    /// Ends playing: the sound stops at once (with the current generation), then the engine.
    private func stopClock() -> Int {
        let g = newGeneration()
        timer?.invalidate()
        timer = nil
        playing = false
        ready = [:]
        soundStarted = false
        if engine.isRunning {
            engine.pause()
        }
        return g
    }

    /// A frame's sound as a buffer for the player node, cut or padded to the take's frame rate.
    private func sound(of file: Data) throws -> AVAudioPCMBuffer {
        let limits = CameraAudio.pairLimits(nominal: Double(CameraAudio.sampleRate) / fps)
        guard file.count >= CameraAudio.blockOffset + CameraAudio.blockBytes else {
            throw TIFFError("the frame ends before its sound")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(limits.upperBound)),
              let channels = buffer.floatChannelData else {
            throw TIFFError("no memory for the frame's sound")
        }
        buffer.frameLength = AVAudioFrameCount(file.withUnsafeBytes {
            CameraAudio.floatSamples(inBlock: UnsafeRawBufferPointer(rebasing: $0[CameraAudio.blockOffset..<CameraAudio.blockOffset + CameraAudio.blockBytes]),
                                     limits: limits, left: channels[0], right: channels[1])
        })
        return buffer
    }

    /// Schedules frame `index`'s sound right after the previous frame's, or, if it was read after
    /// its turn, a moment after the sound output's position. False if the play is over.
    private func enqueue(_ sound: AVAudioPCMBuffer, frame index: Int, generation g: Int) -> Bool {
        let output = soundTime()?.output
        lock.lock()
        defer { lock.unlock() }
        guard g == generation else {
            return false
        }
        var at = schedule.end
        if let output, Double(at) < output + Self.lateMargin * format.sampleRate {
            at = Int64((output + Self.lateMargin * format.sampleRate).rounded(.up))
            schedule.late += 1
        }
        speaker.scheduleBuffer(sound, at: AVAudioTime(sampleTime: at, atRate: format.sampleRate))
        schedule.starts.append(at)
        schedule.end = at + Int64(sound.frameLength)
        schedule.complete = index == take.files.count - 1
        return true
    }

    /// Gives frames read to developing.
    private func handOver(_ frames: [(index: Int, file: Data)], generation g: Int) {
        lock.lock()
        guard g == generation else {
            lock.unlock()
            return
        }
        undeveloped += frames
        let start = !developerRunning
        developerRunning = true
        lock.unlock()
        if start {
            developing.async { [self] in
                developFrames(generation: g)
            }
        }
    }

    /// Develops the frames handed over, a batch at a time, until none wait. Frames whose sound has
    /// already been heard are dropped undeveloped: developing fell behind.
    private func developFrames(generation g: Int) {
        while true {
            let heard = heardFrame()
            lock.lock()
            guard g == generation else {
                lock.unlock()
                return
            }
            undeveloped.removeAll { $0.index < heard }
            guard !undeveloped.isEmpty else {
                developerRunning = false
                lock.unlock()
                return
            }
            let frames = Array(undeveloped.prefix(Self.batch))
            undeveloped.removeFirst(frames.count)
            lock.unlock()
            var developed = [Result<CGImage, Error>?](repeating: nil, count: frames.count)
            let slots = NSLock()
            DispatchQueue.concurrentPerform(iterations: frames.count) { k in
                let result = autoreleasepool {
                    Result { try FramePreview.image(ofOriginal: frames[k].file, profile: profile, width: Self.playWidth, context: context) }
                }
                slots.lock()
                developed[k] = result
                slots.unlock()
            }
            let batch = developed
            DispatchQueue.main.async { [self] in
                guard isCurrent(g) else {
                    return
                }
                for (k, frame) in frames.enumerated() {
                    switch batch[k] {
                    case .success(let picture)?:
                        ready[frame.index] = picture
                    case .failure(let error)?:
                        stop()
                        report(error, frame: frame.index)
                        return
                    case nil:
                        break
                    }
                }
            }
        }
    }

    private func develop(_ index: Int, width: Int) -> Result<CGImage, Error> {
        autoreleasepool {
            Result {
                try FramePreview.image(ofOriginal: Data(contentsOf: take.files[index]), profile: profile,
                                       width: width, context: context)
            }
        }
    }

    private func report(_ error: Error, frame: Int) {
        problem = "Could not read frame \(frame + 1) from the card (\(error)). Is the card still in the reader?"
    }

    /// Ends the current generation: silences the sound at once and drops its scheduled sound and
    /// the frames waiting to be developed. A play starts its schedule at frame `from`.
    private func newGeneration(from: Int = 0) -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        speaker.stop()
        schedule = Schedule(from: from)
        undeveloped = []
        developerRunning = false
        return generation
    }

    private func isCurrent(_ g: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return g == generation
    }
}

/// The preview window's content: the picture, play/pause, one-frame steps, a scrubber, the
/// timecode and the sound on or off.
struct PreviewView: View {
    @ObservedObject var player: TakePlayer
    let close: () -> Void
    @AppStorage("previewMuted") private var muted = false

    var body: some View {
        let take = player.take
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(take.id).font(Brand.heading)
                Text("\(take.frames) frames · \(take.duration) · from the card, not copied yet").foregroundColor(.secondary)
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
            ZStack {
                Color.black
                if let image = player.image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else if player.problem == nil {
                    ProgressView()
                }
            }
            .aspectRatio(CGFloat(Raw12.width) / CGFloat(Raw12.height), contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 10) {
                Button { player.togglePlay() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(player.playing ? "Pause (space bar)" : "Play (space bar)")
                Button { player.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("One frame back (left arrow)")
                Button { player.step(1) } label: { Image(systemName: "forward.frame.fill") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("One frame on (right arrow)")
                Slider(value: Binding(get: { Double(player.shown) }, set: { player.seek(to: Int($0.rounded())) }),
                       in: 0...Double(max(take.frames - 1, 1)))
                Text("\(take.timecode(at: player.shown))   frame \(player.shown + 1) of \(take.frames)")
                    .font(.system(.body, design: .monospaced))
                Button { muted.toggle() } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 22)
                }
                .keyboardShortcut("m", modifiers: [])
                .help(muted ? "Sound on (M)" : "Sound off (M)")
            }
            Text(player.problem ?? "Plays with the camera's sound; the picture follows it. Stopped on a frame, it shows the frame at full resolution, without sound. Developed like the Rec.709 ProRes preview in the chosen colour profile. Space bar: play and pause. Arrow keys: one frame. M: sound off and on.")
                .font(Brand.caption)
                .foregroundColor(player.problem == nil ? .secondary : .red)
        }
        .padding(16)
        .font(Brand.body)
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            player.muted = muted
            player.seek(to: 0)
        }
        .onChange(of: muted) { player.muted = $0 }
    }

    /// The window's first size: half the screen's width (never taller than 90% of the screen), in
    /// the frame's shape plus room for the title and the controls.
    static var idealSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let chrome: CGFloat = 130
        let width = min(screen.width * 0.5, (screen.height * 0.9 - chrome) * CGFloat(Raw12.width) / CGFloat(Raw12.height))
        return CGSize(width: width, height: width * CGFloat(Raw12.height) / CGFloat(Raw12.width) + chrome)
    }
}
