// Take preview: plays one take straight from the card, before it is copied, in its own window.
// Frames are developed like the Rec.709 ProRes preview in the chosen colour profile: 1024 pixels
// wide while playing, a batch at a time ahead of the playhead (reading the card at 3.4 MB per
// frame), and at full resolution (2048 pixels) when stopped on a frame. When developing falls
// behind real time, frames are skipped; the take never plays slower. Picture only. While the card
// is being copied, the app opens no previews and closes an open one (CardModel).
import AppKit
import CoreImage
import SwiftUI

final class TakePlayer: ObservableObject {
    /// Development width while playing (about 44 frames/s on the M1 Pro, enough for real time) and
    /// when stopped on a frame (full resolution, about 28 frames/s).
    static let playWidth = 1024
    static let stillWidth = Raw12.width
    static let batch = 8

    let take: TakeRow
    private let profile: ColourProfile?
    private let context = CIContext()
    private let work = DispatchQueue(label: "acam.preview", qos: .userInitiated)

    @Published private(set) var image: CGImage?
    @Published private(set) var shown = 0
    @Published private(set) var playing = false
    @Published private(set) var problem: String?

    // Every play, stop and seek starts a new generation; work for an older one is dropped.
    private let lock = NSLock()
    private var generation = 0
    // Main thread only: frames developed ahead of the playhead, and the playback clock.
    private var ready: [Int: CGImage] = [:]
    private var timer: Timer?
    private var clock = (start: Date(), from: 0)

    init(take: TakeRow, profile: ColourProfile?) {
        self.take = take
        self.profile = profile
    }

    private var fps: Double { take.fps > 0 ? take.fps : 24 }

    /// Shows frame `index`; stops playback.
    func seek(to index: Int) {
        guard !take.files.isEmpty else {
            return
        }
        stopClock()
        let i = min(max(index, 0), take.files.count - 1)
        shown = i
        let g = newGeneration()
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

    /// Plays in real time from the frame shown (from the start once the end was reached).
    func play() {
        guard !playing, !take.files.isEmpty else {
            return
        }
        let count = take.files.count
        if shown >= count - 1 {
            shown = 0
        }
        let g = newGeneration()
        let from = shown, start = Date(), fps = self.fps
        clock = (start, from)
        ready = [:]
        playing = true
        problem = nil
        // Develop ahead of the playhead, a batch at a time and at most one batch ahead (a frame is
        // 9 MB); frames the playhead has already passed are skipped.
        work.async { [self] in
            var next = from
            while isCurrent(g) {
                let head = from + Int(Date().timeIntervalSince(start) * fps)
                next = max(next, head)
                if next >= count {
                    break
                }
                if next > head + Self.batch {
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }
                let indices = Array(next..<min(next + Self.batch, count))
                var developed = [Result<CGImage, Error>?](repeating: nil, count: indices.count)
                let slots = NSLock()
                DispatchQueue.concurrentPerform(iterations: indices.count) { k in
                    let result = develop(indices[k], width: Self.playWidth)
                    slots.lock()
                    developed[k] = result
                    slots.unlock()
                }
                let batch = developed
                DispatchQueue.main.async { [self] in
                    guard isCurrent(g) else {
                        return
                    }
                    for (k, i) in indices.enumerated() {
                        switch batch[k] {
                        case .success(let frame)?:
                            ready[i] = frame
                        case .failure(let error)?:
                            stop()
                            report(error, frame: i)
                            return
                        case nil:
                            break
                        }
                    }
                }
                next += indices.count
            }
        }
        let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stops playback and developing; the frame shown stays.
    func stop() {
        stopClock()
        _ = newGeneration()
    }

    /// Shows the newest developed frame the playhead has reached; stops on the last frame.
    private func tick() {
        let count = take.files.count
        let position = Date().timeIntervalSince(clock.start) * fps
        let head = min(clock.from + Int(position), count - 1)
        if let i = ready.keys.filter({ $0 <= head }).max(), let frame = ready[i] {
            image = frame
            shown = i
            ready = ready.filter { $0.key > i }
        }
        let pastEnd = Double(clock.from) + position - Double(count - 1)
        if shown == count - 1 || pastEnd > fps / 2 {
            seek(to: count - 1)
        }
    }

    private func stopClock() {
        timer?.invalidate()
        timer = nil
        playing = false
        ready = [:]
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

    private func newGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        return generation
    }

    private func isCurrent(_ g: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return g == generation
    }
}

/// The preview window's content: the picture, play/pause, one-frame steps, a scrubber and the
/// timecode.
struct PreviewView: View {
    @ObservedObject var player: TakePlayer
    let close: () -> Void

    var body: some View {
        let take = player.take
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(take.id).font(.headline)
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
            }
            Text(player.problem ?? "Picture only, developed like the Rec.709 ProRes preview in the chosen colour profile. Space bar: play and pause. Arrow keys: one frame.")
                .font(.caption)
                .foregroundColor(player.problem == nil ? .secondary : .red)
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { player.seek(to: 0) }
    }

    /// The window's first size: about 90% of the screen, in the frame's shape plus room for the
    /// title and the controls.
    static var idealSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let chrome: CGFloat = 130
        let width = min(screen.width * 0.9, (screen.height * 0.9 - chrome) * CGFloat(Raw12.width) / CGFloat(Raw12.height))
        return CGSize(width: width, height: width * CGFloat(Raw12.height) / CGFloat(Raw12.width) + chrome)
    }
}
