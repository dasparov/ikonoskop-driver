// ACam: a small Mac app over the same CardJob that `acam offload` runs. Pick a mounted card and a
// destination (and, if you like, a second drive for a second copy), choose the outputs, press
// Process card. Verify a copy reads a finished copy again and compares it with its checksums.
import AppKit
import CoreImage
import SwiftUI
import UserNotifications

@main
struct ACamApp: App {
    var body: some Scene {
        WindowGroup("ACam \(acamVersion)") {
            ContentView()
                .frame(minWidth: 1000, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .help) { HelpCommand() }
        }
        Window("ACam Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 660, height: 760)
    }
}

/// One take of the selected card: its frame files and its first frame's header.
struct TakeRow: Identifiable {
    let id: String
    let files: [URL]
    let fps: Double
    let startTimecode: Timecode?
    let timecodeFPS: Int
    /// Size of the take's files on the card.
    let bytes: Int64
    /// When the camera recorded the first frame (the date of its file on the card).
    let recorded: Date?
    /// The camera's COL. TEMP setting, from the first frame.
    let whiteBalance: WhiteBalance?

    var frames: Int { files.count }
    var firstFrame: URL? { files.first }
    var start: String { startTimecode?.description ?? "?" }
    var duration: String { fps > 0 ? OffloadReport.duration(Double(frames) / fps) : "?" }
    var recordedText: String { recorded.map { TakeRow.dates.string(from: $0) } ?? "?" }
    var colourTemperature: String { whiteBalance?.label ?? "?" }

    /// The timecode of frame `index`, counted on from the first frame's.
    func timecode(at index: Int) -> String {
        startTimecode.map { Timecode(frameCount: $0.frameCount(fps: timecodeFPS) + index, fps: timecodeFPS).description } ?? "?"
    }

    static let dates: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

/// How the takes are shown: a table, or a grid of their first frames.
enum TakeLayout: String {
    case list, grid
}

/// A message for the user, shown in an alert.
struct Notice {
    let title: String
    let message: String
}

/// The result of the last run or check, shown under the buttons.
struct Outcome {
    enum Tone {
        case good, partial, bad
    }

    let headline: String
    let tone: Tone
    let text: String
    /// What Show in Finder selects.
    let reveal: URL?
}

/// What a run would do, worked out in the background before it starts (CardPlan).
enum PlanState {
    case none
    case ready(CardPlan, shortfall: String?)
    case refused(String)

    /// The run cannot start: refused, too little space, or nothing to add.
    var blocks: Bool {
        switch self {
        case .none: return false
        case .refused: return true
        case .ready(let plan, let shortfall): return shortfall != nil || (plan.adding && plan.isEmpty)
        }
    }
}

/// Tells the user that a long run has finished: a notification, a sound, and the Dock icon
/// bouncing until ACam is brought to the front.
enum Announce {
    /// Asks once for permission to show notifications; macOS remembers the answer.
    static func prepare() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func finished(title: String, body: String) {
        NSSound(named: "Glass")?.play()
        if !NSApp.isActive {
            NSApp.requestUserAttention(.criticalRequest)
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

final class CardModel: ObservableObject {
    enum Activity {
        /// A card run; verifying a copy; making the outputs of a copy without the card.
        case processing, verifying, outputs
    }

    @Published var cards: [URL] = []
    @Published var selected: URL? {
        didSet { loadTakes() }
    }
    @Published var takes: [TakeRow] = []
    /// The selected card as read, for planning runs.
    private var card: CardVolume?
    // The choices below are remembered between launches.
    @Published var destination: URL? {
        didSet { remember(destination, "destination") }
    }
    /// A second drive that gets the same files; left out of a run when it is not connected.
    @Published var secondDestination: URL? {
        didSet { remember(secondDestination, "secondDestination") }
    }
    @Published var audio: Bool {
        didSet { remember(audio, "audio") }
    }
    @Published var clean: Bool {
        didSet { remember(clean, "clean") }
    }
    @Published var proresLog: Bool {
        didSet { remember(proresLog, "proresLog") }
    }
    @Published var proresPreview: Bool {
        didSet { remember(proresPreview, "proresPreview") }
    }
    @Published var checkTakeTable: Bool {
        didSet { remember(checkTakeTable, "checkTakeTable") }
    }
    /// Colour profile id in the app's Resources/profiles/ (Phase 5); starts at the one picked.
    @Published var profileID: String {
        didSet {
            UserDefaults.standard.set(profileID, forKey: "profileID")
            loadPreviews()
        }
    }
    /// Each take's first frame, developed like the Rec.709 ProRes preview in the chosen profile.
    @Published var previews: [String: CGImage] = [:]
    private var previewPass = 0
    /// The open take preview: its player and window.
    private var player: TakePlayer?
    private var previewWindow: NSWindow?
    private var previewObserver: NSObjectProtocol?
    /// A message for the user, shown in an alert.
    @Published var notice: Notice?
    let profiles: [(id: String, name: String)] = {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("profiles"),
              let ids = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return ids.sorted().compactMap { id in
            (try? ColourProfile.load(dir.appendingPathComponent(id))).map { (id, $0.profile.name) }
        }
    }()
    @Published var activity: Activity?
    var running: Bool { activity != nil }
    /// The card is being copied: previews and ejecting wait.
    var copying: Bool { activity == .processing }
    /// The run has verified its copies and is making the outputs (Stop keeps the copies).
    @Published var verifiedYet = false
    @Published var fraction = 0.0
    @Published var status = ""
    @Published var outcome: Outcome?
    /// Takes ticked for "Process selected takes"; cleared when another card is chosen.
    @Published var chosenTakes: Set<String> = [] {
        didSet { replan() }
    }
    /// The card's flash and how much of it the takes use (CardSpace); nil until the card is read.
    @Published var cardSpace: (total: Int64, used: Int64)?
    /// Free space where the copies go.
    @Published var destinationFree: Int64?
    @Published var secondFree: Int64?
    /// What Process card and Process selected takes would do.
    @Published var cardPlan = PlanState.none
    @Published var selectionPlan = PlanState.none

    private var observers: [NSObjectProtocol] = []
    private var job: CardJob?
    /// Stops Verify a copy and Make outputs from a copy.
    private var taskStop: StopSignal?
    private var stopRequested = false
    private var started = Date()
    private var planPass = 0
    /// Take folders in the order Verify a copy checks them.
    private var verifyOrder: [String] = []
    // Frames done per "<stage> <take>", and the work units each stage costs per frame.
    private var done: [String: Int] = [:]
    private var totalUnits = 1.0
    private let weights = ["copy": 1.0, "verify": 1.0, "clean": 0.5, "prores": 2.0, "second": 0.3, "second-check": 0.3]

    init() {
        let defaults = UserDefaults.standard
        destination = defaults.string(forKey: "destination").map { URL(fileURLWithPath: $0) }
        secondDestination = defaults.string(forKey: "secondDestination").map { URL(fileURLWithPath: $0) }
        audio = defaults.object(forKey: "audio") as? Bool ?? true
        clean = defaults.object(forKey: "clean") as? Bool ?? true
        proresLog = defaults.object(forKey: "proresLog") as? Bool ?? false
        proresPreview = defaults.object(forKey: "proresPreview") as? Bool ?? false
        checkTakeTable = defaults.object(forKey: "checkTakeTable") as? Bool ?? true
        profileID = defaults.string(forKey: "profileID") ?? ColourProfile.defaultID
        if !profiles.contains(where: { $0.id == profileID }) {
            profileID = ColourProfile.defaultID
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshCards()
            })
        }
        // Folders may have changed in Finder meanwhile: look again when ACam comes to the front.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.refreshFree()
            self?.replan()
        })
        refreshCards()
    }

    private func remember(_ url: URL?, _ key: String) {
        UserDefaults.standard.set(url?.path, forKey: key)
        refreshFree()
        replan()
    }

    private func remember(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        replan()
    }

    /// Whether the folder can be reached now: its drive is connected.
    static func connected(_ url: URL?) -> Bool {
        url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Mounted volumes that look like an A-Cam card (ACAM <n> with an IMAGE folder); the free
    /// space and the run plan are worked out again too.
    func refreshCards() {
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        cards = volumes.filter { $0.hasPrefix("ACAM") }.sorted()
            .map { URL(fileURLWithPath: "/Volumes").appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("IMAGE").path) }
        if selected == nil || !cards.contains(selected!) {
            selected = cards.first
        }
        refreshFree()
        replan()
    }

    /// Lists the selected card's takes in the background: reading the card (and the macOS prompt
    /// that asks to allow access to removable volumes) must not freeze the window.
    private func loadTakes() {
        takes = []
        card = nil
        previews = [:]
        chosenTakes = []
        cardSpace = nil
        replan()
        guard let url = selected else {
            return
        }
        status = "Reading \(url.lastPathComponent)…"
        DispatchQueue.global().async {
            guard let card = try? CardVolume.open(url) else {
                DispatchQueue.main.async {
                    self.status = "Could not read \(url.lastPathComponent). If macOS asked, allow ACam to access removable volumes."
                }
                return
            }
            let rows = card.takes.map { take -> TakeRow in
                let header = take.frames.first.flatMap { f -> FrameHeader? in
                    guard let h = FileHandle(forReadingAtPath: f.url.path) else {
                        return nil
                    }
                    defer { h.closeFile() }
                    return try? FrameHeader(h.readData(ofLength: FrameHeader.headerBytes))
                }
                return TakeRow(id: take.name, files: take.frames.map(\.url), fps: header?.fps ?? 0,
                               startTimecode: header?.timecode, timecodeFPS: header?.timecodeFPS ?? 24,
                               bytes: Int64(take.frames.reduce(0) { $0 + $1.size }), recorded: take.frames.first?.modified,
                               whiteBalance: header?.whiteBalance)
            }
            let volume = (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity
            let space = volume.map { (total: CardSpace.flashBytes(volumeBytes: Int64($0)),
                                      used: CardSpace.usedBytes(takeFrames: card.takes.map { $0.frames.count })) }
            DispatchQueue.main.async {
                if self.selected == url {
                    self.takes = rows
                    self.card = card
                    self.cardSpace = space
                    self.status = ""
                    self.loadPreviews()
                    self.replan()
                }
            }
        }
    }

    /// Develops every take's first frame in the background, one at a time (3.4 MB read from the
    /// card each); not while the card is being copied. A newer pass, for another card or colour
    /// profile, makes older results stale.
    private func loadPreviews() {
        guard !copying else {
            return
        }
        previewPass += 1
        let pass = previewPass
        let jobs = takes.compactMap { t in t.firstFrame.map { (take: t.id, url: $0) } }
        let folder = Bundle.main.resourceURL?.appendingPathComponent("profiles").appendingPathComponent(profileID)
        DispatchQueue.global(qos: .userInitiated).async {
            let profile = folder.flatMap { try? ColourProfile.load($0).profile }
            let context = CIContext()
            for job in jobs {
                let image = autoreleasepool {
                    try? FramePreview.image(ofOriginal: Data(contentsOf: job.url), profile: profile, width: 512,
                                            context: context)
                }
                DispatchQueue.main.async {
                    if pass == self.previewPass, let image = image {
                        self.previews[job.take] = image
                    }
                }
            }
        }
    }

    /// Opens the preview of `take` in its own window, read straight from the card; not while the
    /// card is being copied. An open preview of another take closes.
    func openPreview(_ take: TakeRow) {
        guard !copying else {
            notice = Notice(title: "Preview is off",
                            message: "The card is being copied. Previews are off until the copy has finished: a preview reads the card too, which would slow the copy down.")
            return
        }
        closePreview()
        let folder = Bundle.main.resourceURL?.appendingPathComponent("profiles").appendingPathComponent(profileID)
        let player = TakePlayer(take: take, profile: folder.flatMap { try? ColourProfile.load($0).profile })
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: PreviewView.idealSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(take.id): preview from the card"
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        let content = NSHostingView(rootView: PreviewView(player: player, close: { [weak window] in window?.close() }))
        content.sizingOptions = [.minSize]
        window.contentView = content
        window.center()
        previewObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                 queue: .main) { [weak self] _ in
            self?.previewClosed()
        }
        self.player = player
        previewWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the take preview window, if one is open.
    private func closePreview() {
        previewWindow?.close()
    }

    private func previewClosed() {
        player?.stop()
        player = nil
        if let observer = previewObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        previewObserver = nil
        previewWindow = nil
    }

    /// Ejects the selected card as Finder does (unmount, then eject), so it can be taken out of the
    /// reader; not while it is being copied. An open preview closes first, since it reads the card.
    func eject() {
        guard let card = selected else {
            return
        }
        let name = card.lastPathComponent
        guard !copying else {
            notice = Notice(title: "\(name) is being copied",
                            message: "Eject the card when the copy has finished. Taking it out now would stop the copy.")
            return
        }
        closePreview()
        previewPass += 1
        status = "Ejecting \(name)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try NSWorkspace.shared.unmountAndEjectDevice(at: card) }
            DispatchQueue.main.async {
                // Unmounted but not ejected is just as safe for taking the card out. The answer is an
                // alert: the status line is cleared when the card list reloads.
                self.status = ""
                if case .failure(let error) = result, FileManager.default.fileExists(atPath: card.path) {
                    self.notice = Notice(title: "Could not eject \(name)",
                                         message: "\(error.localizedDescription) If another app is using the card, quit it and try again.")
                } else {
                    self.notice = Notice(title: "\(name) is ejected", message: "You can take the card out of the reader.")
                }
                self.refreshCards()
            }
        }
    }

    func chooseDestination() {
        if let url = chooseFolder(message: "Choose the folder for this card. A new folder named after the card is made inside it.",
                                  from: destination) {
            destination = url
        }
    }

    func chooseSecondDestination() {
        if let url = chooseFolder(message: "Choose a folder on another drive for the second copy. A folder named after the card is made inside it, with the same files as the first copy.",
                                  from: secondDestination) {
            secondDestination = url
        }
    }

    private func chooseFolder(message: String, from: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = message
        panel.directoryURL = from
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Free space at the destinations, shown next to them.
    private func refreshFree() {
        destinationFree = Self.connected(destination) ? destination.flatMap(CardPlan.freeBytes) : nil
        secondFree = Self.connected(secondDestination) ? secondDestination.flatMap(CardPlan.freeBytes) : nil
    }

    /// The run as set up in the window; the take table and colour profile are added when it starts.
    private func jobOptions(source: URL, destination: URL, takes: Set<String>?) -> CardJobOptions {
        var offload = OffloadOptions(source: source, destination: destination)
        offload.takes = takes
        offload.secondDestination = Self.connected(secondDestination) ? secondDestination : nil
        offload.addToExisting = true
        let looks = [proresLog ? ProResLook.log : nil, proresPreview ? ProResLook.preview : nil].compactMap { $0 }
        return CardJobOptions(offload: offload, audio: audio, clean: clean, prores: looks)
    }

    /// Works out Process card and Process selected takes in the background (CardPlan), a moment
    /// after the last change. With a card folder from an earlier run at the destination, this reads
    /// the first frame of each take it holds from the card and from the copy.
    private func replan() {
        planPass += 1
        let pass = planPass
        guard !copying else {
            return
        }
        guard let card = card, let source = selected, let destination = destination, Self.connected(destination) else {
            cardPlan = .none
            selectionPlan = .none
            return
        }
        let options = jobOptions(source: source, destination: destination, takes: nil)
        let chosen = chosenTakes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard pass == self.planPass else {
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let whole = Self.plan(options, card: card)
                var selection = PlanState.none
                if !chosen.isEmpty {
                    var some = options
                    some.offload.takes = chosen
                    selection = Self.plan(some, card: card)
                }
                DispatchQueue.main.async {
                    if pass == self.planPass {
                        self.cardPlan = whole
                        self.selectionPlan = selection
                    }
                }
            }
        }
    }

    private static func plan(_ options: CardJobOptions, card: CardVolume) -> PlanState {
        do {
            let plan = try CardPlan.make(options, card: card)
            let o = options.offload
            return .ready(plan, shortfall: plan.shortfall(free: CardPlan.freeBytes(o.destination),
                                                          secondFree: o.secondDestination.flatMap(CardPlan.freeBytes)))
        } catch {
            return .refused("\(error)")
        }
    }

    var canProcess: Bool {
        !running && card != nil && Self.connected(destination) && !cardPlan.blocks
    }

    var canProcessSelection: Bool {
        !running && card != nil && Self.connected(destination) && !chosenTakes.isEmpty && !selectionPlan.blocks
    }

    /// Copies and checks every take of the card, or only `chosen` (the report then says PARTIAL).
    /// Takes an earlier run copied to the destination are kept; the run adds the rest.
    func process(takes chosen: Set<String>? = nil) {
        guard let source = selected, let destination = destination, let card = card else {
            return
        }
        // A preview reads the card too: the copy gets the card to itself.
        if previewWindow != nil {
            closePreview()
            notice = Notice(title: "Preview closed",
                            message: "The card is being copied now. Previews are back when the copy has finished.")
        }
        var options = jobOptions(source: source, destination: destination, takes: chosen)
        if let wanted = secondDestination, options.offload.secondDestination == nil {
            options.notes.append("No second copy was made: `\(wanted.path)` was not connected.")
        }
        let plan = chosen == nil ? cardPlan : selectionPlan
        if case .ready(let ready, _) = plan {
            totalUnits = units(ready)
        } else {
            let frames = Double(takes.filter { chosen?.contains($0.id) ?? true }.reduce(0) { $0 + $1.frames })
            totalUnits = max(frames * 2, 1)
        }
        activity = .processing
        verifiedYet = false
        stopRequested = false
        outcome = nil
        fraction = 0
        done = [:]
        started = Date()
        let readTable = checkTakeTable
        let profileFolder = Bundle.main.resourceURL?.appendingPathComponent("profiles").appendingPathComponent(profileID)
        status = readTable ? "Reading the take table (macOS asks for your password)…" : "Starting…"
        Announce.prepare()

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Outcome
            do {
                let job: CardJob
                let plan: CardPlan
                do {
                    if readTable {
                        let text = try Self.readEepromWithAdminPrompt()
                        options.offload.eepromText = text
                        options.offload.eeprom = try EepromImage.parseHexDump(text)
                    }
                    options.profile = try profileFolder.map(ColourProfile.load)
                    job = CardJob(options)
                    job.progress = { [weak self] line in
                        DispatchQueue.main.async { self?.progressed(line) }
                    }
                    plan = try job.plan(card: card)
                } catch {
                    throw NotStarted(error: error)
                }
                let stopped = DispatchQueue.main.sync { () -> Bool in
                    self.job = job
                    return self.stopRequested
                }
                if stopped {
                    throw NotStarted(error: StoppedError())
                }
                outcome = Self.outcome(try job.run(plan))
            } catch let error as NotStarted {
                outcome = error.error is StoppedError
                    ? Outcome(headline: "STOPPED", tone: .partial, text: "Stopped before anything was copied.", reveal: nil)
                    : Outcome(headline: "NOT STARTED", tone: .bad, text: "Nothing was copied:\n\n\(error.error)", reveal: nil)
            } catch is StoppedError {
                outcome = Outcome(headline: "STOPPED", tone: .partial,
                                  text: "Stopped before the copies were verified, so ACam kept nothing of this run. The card still has every take: process it again when you are ready.",
                                  reveal: nil)
            } catch {
                outcome = Outcome(headline: "PROBLEMS FOUND", tone: .bad, text: "Could not process the card:\n\n\(error)", reveal: nil)
            }
            DispatchQueue.main.async { self.finish(outcome, subject: card.name) }
        }
    }

    private struct NotStarted: Error {
        let error: Error
    }

    /// Work units for the progress bar: per frame, as in `weights`.
    private func units(_ plan: CardPlan) -> Double {
        let frames = Dictionary(uniqueKeysWithValues: plan.card.takes.map { ($0.name, Double($0.frames.count)) })
        var units = plan.copy.reduce(0.0) { $0 + (frames[$1.name] ?? 0) * 2 }
        for (name, outputs) in plan.outputs {
            let n = frames[name] ?? 0
            for output in outputs {
                switch output {
                case .audio: break
                case .clean: units += n * (plan.secondFolder == nil ? 0.5 : 1.1)
                case .prores: units += n * 2
                }
            }
        }
        if plan.secondFolder != nil {
            for name in plan.kept.keys where plan.secondExisting?.copied[name] == nil {
                units += (frames[name] ?? 0) * 1.2
            }
        }
        return max(units, 1)
    }

    static func outcome(_ result: CardJobResult) -> Outcome {
        let report = result.offload.cardFolder.appendingPathComponent("REPORT.md")
        let tone: Outcome.Tone
        switch result.verdict {
        case .allVerified: tone = .good
        case .partial, .stopped: tone = .partial
        case .problems: tone = .bad
        }
        return Outcome(headline: result.headline, tone: tone,
                       text: (try? String(contentsOf: report, encoding: .utf8)) ?? "", reveal: report)
    }

    /// Makes the ticked outputs that a copy made earlier still lacks, from the copies alone: the
    /// card is not needed.
    func makeOutputs() {
        let looks = [proresLog ? ProResLook.log : nil, proresPreview ? ProResLook.preview : nil].compactMap { $0 }
        guard audio || clean || !looks.isEmpty else {
            notice = Notice(title: "No outputs ticked",
                            message: "Tick the outputs you want under Outputs first: Audio as WAV, Clean DNGs or ProRes.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Make outputs"
        panel.message = "Choose a card folder that ACam made (or one take folder in it). The ticked outputs it lacks are made from the copies; the card is not needed."
        panel.directoryURL = destination
        guard panel.runModal() == .OK, let folder = panel.url else {
            return
        }
        var options = CopyOutputsOptions(audio: audio, clean: clean, prores: looks)
        let profileFolder = Bundle.main.resourceURL?.appendingPathComponent("profiles").appendingPathComponent(profileID)
        let stop = StopSignal()
        taskStop = stop
        activity = .outputs
        stopRequested = false
        outcome = nil
        fraction = 0
        done = [:]
        totalUnits = 1
        started = Date()
        status = "Making outputs for \(folder.lastPathComponent)…"
        Announce.prepare()
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Outcome
            do {
                options.profile = try profileFolder.map(ColourProfile.load)
                let units = try CopyOutputs.plan(folder, options).takes.reduce(0.0) { sum, take in
                    sum + Double(take.frames) * take.missing.reduce(0.0) { w, output in
                        switch output {
                        case .audio: return w
                        case .clean: return w + 0.5
                        case .prores: return w + 2
                        }
                    }
                }
                DispatchQueue.main.async { self.totalUnits = max(units, 1) }
                let r = try CopyOutputs.make(folder, options, stop: stop, progress: { [weak self] line in
                    DispatchQueue.main.async { self?.progressed(line) }
                })
                let report = r.folder.appendingPathComponent("REPORT.md")
                let text = r.madeAny || r.failed
                    ? r.lines + ["", "Added to the end of \(report.path)."]
                    : ["\(r.folder.path) already has these outputs for every take."]
                outcome = Outcome(headline: r.headline, tone: r.failed ? .bad : r.stopped ? .partial : .good,
                                  text: text.joined(separator: "\n"), reveal: r.madeAny ? report : r.folder)
            } catch {
                outcome = Outcome(headline: "NOT STARTED", tone: .bad, text: "Nothing was made:\n\n\(error)", reveal: nil)
            }
            DispatchQueue.main.async { self.finish(outcome, subject: folder.lastPathComponent) }
        }
    }

    /// Reads a copy that ACam made again and compares every file with its ASC MHL checksums.
    func verifyCopy() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Verify"
        panel.message = "Choose a card folder that ACam made (or one take folder in it). Every file is read again and compared with its checksums."
        panel.directoryURL = destination
        guard panel.runModal() == .OK, let folder = panel.url else {
            return
        }
        do {
            verifyOrder = try CopyVerifier.takeFolders(folder).map { $0.lastPathComponent }
        } catch {
            notice = Notice(title: "Nothing to verify", message: "\(error)")
            return
        }
        let stop = StopSignal()
        taskStop = stop
        activity = .verifying
        stopRequested = false
        outcome = nil
        fraction = 0
        started = Date()
        status = "Checking \(folder.lastPathComponent)…"
        Announce.prepare()
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Outcome
            do {
                let r = try KeepAwake.during("Checking \(folder.lastPathComponent)") {
                    try CopyVerifier.verify(folder, progress: { [weak self] line in
                        DispatchQueue.main.async { self?.verifyProgressed(line) }
                    }, isCancelled: { stop.isSet })
                }
                outcome = Outcome(headline: r.headline, tone: r.ok ? .good : r.headline == "STOPPED" ? .partial : .bad,
                                  text: (["Checked \(folder.path) against its ASC MHL checksums.", ""] + r.lines).joined(separator: "\n"),
                                  reveal: folder)
            } catch {
                outcome = Outcome(headline: "NOT CHECKED", tone: .bad, text: "\(error)", reveal: nil)
            }
            DispatchQueue.main.async { self.finish(outcome, subject: folder.lastPathComponent) }
        }
    }

    /// Stops the run or check (the window asks first).
    func stop() {
        stopRequested = true
        job?.stop.set()
        taskStop?.set()
        status = "Stopping…"
    }

    /// Lines like "copy   AC102001    200/2763 frames  165 MB/s".
    private func progressed(_ line: String) {
        status = line.trimmingCharacters(in: .whitespaces)
        let words = line.split(separator: " ")
        guard let stage = words.first.map(String.init) else {
            return
        }
        if ["audio", "clean", "prores", "second", "second-check"].contains(stage) {
            verifiedYet = true
        }
        guard weights[stage] != nil, words.count >= 3,
              let slash = words.first(where: { $0.contains("/") }),
              let n = Int(slash.split(separator: "/").first ?? "") else {
            return
        }
        done["\(stage) \(words[1])"] = n
        let units = done.reduce(0.0) { sum, kv in
            sum + Double(kv.value) * (weights[String(kv.key.split(separator: " ")[0])] ?? 0)
        }
        fraction = min(units / totalUnits, 1)
    }

    /// "verify-copy AC102001    200/2765 files  180 MB/s"
    private func verifyProgressed(_ line: String) {
        status = line
        let words = line.split(separator: " ")
        guard words.count >= 3, let i = verifyOrder.firstIndex(of: String(words[1])),
              let slash = words.first(where: { $0.contains("/") }) else {
            return
        }
        let parts = slash.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] > 0 {
            fraction = (Double(i) + parts[0] / parts[1]) / Double(verifyOrder.count)
        }
    }

    private func finish(_ outcome: Outcome, subject: String) {
        let took = Date().timeIntervalSince(started)
        activity = nil
        job = nil
        taskStop = nil
        self.outcome = outcome
        fraction = outcome.tone == .good ? 1 : fraction
        status = ""
        refreshFree()
        replan()
        if previews.isEmpty {
            loadPreviews()
        }
        Announce.finished(title: "\(subject): \(outcome.headline)", body: "Finished after \(ContentView.minutes(took)).")
    }

    func showInFinder() {
        if let url = outcome?.reveal {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// `ikctl eeprom 0 0x2000` as root through the standard macOS administrator prompt.
    static func readEepromWithAdminPrompt() throws -> String {
        guard let ikctl = Bundle.main.path(forResource: "ikctl", ofType: nil) else {
            throw FileIOError(description: "ikctl is missing from the app bundle (build it with `make` in the repo first)")
        }
        let script = "do shell script (quoted form of \"\(ikctl)\") & \" eeprom 0 0x2000\" with administrator privileges without altering line endings"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw FileIOError(description: "reading the take table failed: \(String(decoding: errors, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

struct ContentView: View {
    @StateObject private var model = CardModel()
    @AppStorage("takeLayout") private var layout = TakeLayout.list
    @State private var confirmingSelection = false
    @State private var confirmingStop = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardRow
            if !model.takes.isEmpty {
                cardSummary
            }
            takesView
            if model.copying {
                Text("Previews are off while the card is being copied.").font(Brand.caption).foregroundColor(.secondary)
            }
            Group {
                destinationRow
                secondRow
            }
            outputsRow
            Group {
                processRow
                planLines
            }
            Text(model.status).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
            resultView
            Spacer(minLength: 0)
        }
        .padding(18)
        .font(Brand.body)
        .alert(model.notice?.title ?? "", isPresented: noticeShown, presenting: model.notice) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        .confirmationDialog(confirmTitle, isPresented: $confirmingSelection) {
            Button(confirmButton) { model.process(takes: model.chosenTakes) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var cardRow: some View {
        HStack {
            Brand.label("Card").frame(width: 110, alignment: .leading)
            if model.cards.isEmpty {
                Text("No A-Cam card mounted. Connect the reader and insert a card.").foregroundColor(.secondary)
            } else {
                Picker("", selection: $model.selected) {
                    ForEach(model.cards, id: \.self) { Text($0.lastPathComponent).tag(Optional($0)) }
                }
                .labelsHidden()
                .frame(width: 220)
                .disabled(model.copying)
            }
            Button("Refresh") { model.refreshCards() }.disabled(model.copying)
            Button { model.eject() } label: { Label("Eject", systemImage: "eject") }
                .disabled(model.selected == nil)
                .help("Eject the card, then take it out of the reader")
            Spacer()
            Picker("Show takes as", selection: $layout) {
                Text("List").tag(TakeLayout.list)
                Text("Grid").tag(TakeLayout.grid)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
            Button { openWindow(id: "help") } label: {
                Image(systemName: "questionmark.circle").font(.title3)
            }
            .buttonStyle(.borderless)
            .help("ACam Help: how it works, copying fast, the first and the second run")
        }
    }

    @ViewBuilder private var takesView: some View {
        switch layout {
        case .list:
            takesTable
        case .grid:
            takesGrid
        }
    }

    private var takesTable: some View {
        Table(model.takes) {
            TableColumn("Select") { t in Toggle("", isOn: chosen(t.id)).labelsHidden().disabled(model.copying) }
                .width(44)
            TableColumn("First frame") { t in previewButton(t).frame(width: 96) }
                .width(104)
            TableColumn("Take", value: \.id)
                .width(min: 70, ideal: 80)
            TableColumn("Recorded", value: \.recordedText)
                .width(min: 105, ideal: 115)
            TableColumn("Frames") { Text("\($0.frames)") }
                .width(min: 44, ideal: 50)
            TableColumn("Duration") { Text($0.duration) }
                .width(min: 70, ideal: 75)
            TableColumn("Size") { Text(Self.size($0.bytes)) }
                .width(min: 55, ideal: 65)
            TableColumn("Frame rate") { t in Text(t.fps > 0 ? String(format: "%g fps", t.fps) : "?") }
                .width(min: 50, ideal: 60)
            TableColumn("Colour temp.", value: \.colourTemperature)
                .width(min: 85, ideal: 100)
            TableColumn("Start timecode", value: \.start)
                .width(min: 80, ideal: 100)
        }
        .frame(minHeight: 150)
    }

    private var takesGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(model.takes) { t in
                    gridCell(t)
                }
            }
        }
        .frame(minHeight: 150)
    }

    private func gridCell(_ t: TakeRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            previewButton(t)
            Toggle(isOn: chosen(t.id)) { Text(t.id).font(Brand.heading) }
                .disabled(model.copying)
                .help("Tick to include this take in Process selected takes")
            Text(Self.caption(t))
                .font(Brand.caption)
                .foregroundColor(.secondary)
        }
    }

    private var destinationRow: some View {
        HStack {
            Brand.label("Destination").frame(width: 110, alignment: .leading)
            folderText(model.destination, none: "none chosen")
            if model.destination != nil && !CardModel.connected(model.destination) {
                Text("not connected").foregroundColor(.orange)
            } else if let free = model.destinationFree {
                Text(Self.size(free) + " free").foregroundColor(.secondary)
            }
            Spacer()
            Button("Choose…") { model.chooseDestination() }.disabled(model.copying)
        }
    }

    private var secondRow: some View {
        HStack {
            Brand.label("Second copy").frame(width: 110, alignment: .leading)
            folderText(model.secondDestination, none: "none (optional: a second drive gets the same files)")
            if model.secondDestination != nil && !CardModel.connected(model.secondDestination) {
                Text("not connected: runs make one copy, at the destination").foregroundColor(.orange)
            } else if let free = model.secondFree {
                Text(Self.size(free) + " free").foregroundColor(.secondary)
            }
            Spacer()
            if model.secondDestination != nil {
                Button("None") { model.secondDestination = nil }
                    .disabled(model.copying)
                    .help("Make one copy only")
            }
            Button("Choose…") { model.chooseSecondDestination() }.disabled(model.copying)
        }
    }

    private func folderText(_ url: URL?, none: String) -> some View {
        Text(url?.path ?? none)
            .foregroundColor(url == nil ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var outputsRow: some View {
        HStack(alignment: .top) {
            Brand.label("Outputs").frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text("Verified copies, checksums (ASC MHL) and a report: always")
                Toggle("Audio as WAV", isOn: $model.audio)
                Toggle("Clean DNGs (corrected, losslessly compressed)", isOn: $model.clean)
                Toggle("ProRes 4444 XQ, ACEScct log (for grading)", isOn: $model.proresLog)
                Toggle("ProRes 4444 XQ, Rec.709 preview", isOn: $model.proresPreview)
                Toggle("Check the card's take table (asks for your password)", isOn: $model.checkTakeTable)
                Picker("Colour profile", selection: $model.profileID) {
                    ForEach(model.profiles, id: \.id) { Text($0.name).tag($0.id) }
                }
                .frame(width: 460)
            }
            .disabled(model.copying)
        }
    }

    private var processRow: some View {
        HStack {
            if model.running {
                Button(role: .destructive) { confirmingStop = true } label: {
                    Text("Stop").frame(minWidth: 140)
                }
                .keyboardShortcut(".", modifiers: .command)
                .help(model.activity == .processing ? "Stop the run" : model.activity == .verifying ? "Stop checking" : "Stop making the outputs")
                .confirmationDialog(stopTitle, isPresented: $confirmingStop) {
                    Button("Stop", role: .destructive) { model.stop() }
                    Button("Keep going", role: .cancel) {}
                } message: {
                    Text(stopMessage)
                }
            } else {
                Button(action: { model.process() }) {
                    Text("Process card").frame(minWidth: 140)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canProcess)
                .help("Copy and check every take on the card")
                Button(selectedButtonTitle) { confirmingSelection = true }
                    .disabled(!model.canProcessSelection)
                    .help("Copy and check only the ticked takes")
                Button("Verify a copy…") { model.verifyCopy() }
                    .help("Read a finished copy again and compare every file with its checksums")
                Button("Make outputs from a copy…") { model.makeOutputs() }
                    .help("Make the ticked outputs that a copy made earlier still lacks, from the copies alone: the card is not needed")
            }
            ProgressView(value: model.fraction)
            Text(String(format: "%.0f%%", model.fraction * 100)).monospacedDigit().frame(width: 44)
        }
    }

    @ViewBuilder private var resultView: some View {
        if let outcome = model.outcome {
            HStack {
                Text(outcome.headline)
                    .font(Brand.title)
                    .foregroundColor(Self.colour(outcome.tone))
                Spacer()
                Button("Show in Finder") { model.showInFinder() }.disabled(outcome.reveal == nil)
            }
            ScrollView {
                Text(outcome.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .border(Color.secondary.opacity(0.3))
        }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }

    private var selectedButtonTitle: String {
        let n = model.chosenTakes.count
        return n == 0 ? "Process selected takes…" : "Process \(n) selected take\(n == 1 ? "" : "s")…"
    }

    /// Takes that stay only on the card when just the selected ones are processed.
    private var leftOnCard: Int {
        if case .ready(let plan, _) = model.selectionPlan {
            return plan.notCopied.count
        }
        return model.takes.count - model.chosenTakes.count
    }

    private var confirmTitle: String {
        "Copy only \(model.chosenTakes.count) of \(model.takes.count) takes?"
    }

    private var confirmButton: String {
        let n = model.chosenTakes.count
        return "Copy \(n) take\(n == 1 ? "" : "s")"
    }

    private var confirmMessage: String {
        let rest = leftOnCard
        guard rest > 0 else {
            return "The other takes are already at the destination, so the card will be completely copied."
        }
        return "The other \(rest) take\(rest == 1 ? "" : "s") will stay only on the card: copy \(rest == 1 ? "it" : "them") too before the card is reused. The report will say PARTIAL."
    }

    private var stopTitle: String {
        switch model.activity {
        case .verifying: return "Stop checking?"
        case .outputs: return "Stop making the outputs?"
        default: return model.verifiedYet ? "Stop making the outputs?" : "Stop copying?"
        }
    }

    private var stopMessage: String {
        switch model.activity {
        case .verifying:
            return "The takes checked so far are listed; the others are not checked."
        case .outputs:
            return "The output being made is removed; what is already made stays, and so do the copies. Make the outputs again later to finish."
        default:
            return model.verifiedYet
                ? "The copied takes are verified and stay. The outputs not made yet are listed in the report: process the card into the same destination again to make them."
                : "The copies are not verified yet, so ACam removes what this run has copied. The card keeps every take: process it again later."
        }
    }

    /// A take's first frame, or a grey box of the frame's shape until it is developed.
    @ViewBuilder private func preview(_ take: String) -> some View {
        if let image = model.previews[take] {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
        } else {
            Rectangle().fill(Color.secondary.opacity(0.15))
                .aspectRatio(CGFloat(Raw12.width) / CGFloat(Raw12.height), contentMode: .fit)
        }
    }

    /// A take's first frame as a button that opens the take's preview.
    private func previewButton(_ take: TakeRow) -> some View {
        Button { model.openPreview(take) } label: {
            preview(take.id).overlay(
                Image(systemName: "play.circle.fill").font(.title2).foregroundColor(.white.opacity(0.85)).shadow(radius: 2)
            )
        }
        .buttonStyle(.plain)
        .help("Preview this take, with its sound")
    }

    /// Whether a take is ticked for "Process selected takes".
    private func chosen(_ take: String) -> Binding<Bool> {
        Binding(get: { model.chosenTakes.contains(take) },
                set: { on in
                    if on {
                        model.chosenTakes.insert(take)
                    } else {
                        model.chosenTakes.remove(take)
                    }
                })
    }

    /// "9 takes · 10 min 10 s · 49.3 GB of footage", and how full the card is.
    private var cardSummary: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 110, height: 1)
            Text(footageText)
            if let full = cardFullFraction {
                ProgressView(value: full).frame(width: 90)
                Text(cardFullText)
            }
        }
        .font(Brand.caption)
        .foregroundColor(.secondary)
    }

    private var footageText: String {
        let footage = model.takes.reduce(Int64(0)) { $0 + $1.bytes }
        let seconds = model.takes.reduce(0.0) { $0 + ($1.fps > 0 ? Double($1.frames) / $1.fps : 0) }
        let n = model.takes.count
        return "\(n) take\(n == 1 ? "" : "s") · \(Self.minutes(seconds)) · \(Self.size(footage)) of footage"
    }

    private var cardFullFraction: Double? {
        guard let space = model.cardSpace, space.total > 0 else {
            return nil
        }
        return min(Double(space.used) / Double(space.total), 1)
    }

    private var cardFullText: String {
        guard let space = model.cardSpace, let full = cardFullFraction else {
            return ""
        }
        let fps = model.takes.first.map { $0.fps > 0 ? $0.fps : 24 } ?? 24
        let left = Double(max(space.total - space.used, 0)) / Double(CardSpace.flashFrameBytes) / fps
        let percent = Int((full * 100).rounded())
        return "card \(percent)% full (\(Self.size(space.used)) of \(Self.size(space.total))), about \(Self.minutes(left)) of recording left at \(String(format: "%g", fps)) fps"
    }

    /// What the runs would copy and write, what an earlier run left at the destination, and
    /// anything in the way.
    @ViewBuilder private var planLines: some View {
        if !model.takes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(planMessages.enumerated()), id: \.offset) { _, line in
                    Text(line.text).foregroundColor(line.warning ? .orange : .secondary)
                }
            }
            .font(Brand.caption)
        }
    }

    private var planMessages: [(text: String, warning: Bool)] {
        var out: [(text: String, warning: Bool)] = []
        switch model.cardPlan {
        case .none:
            if model.destination == nil {
                out.append(("Choose a destination for the copies.", false))
            }
        case .refused(let why):
            out.append(("Process card cannot start: \(why)", true))
        case .ready(let plan, let shortfall):
            out += Self.describe(plan, shortfall: shortfall, run: "Process card")
        }
        if !model.chosenTakes.isEmpty {
            switch model.selectionPlan {
            case .none:
                break
            case .refused(let why):
                out.append(("The selected takes cannot be processed: \(why)", true))
            case .ready(let plan, let shortfall):
                out += Self.describe(plan, shortfall: shortfall, run: "The selected takes").filter { !$0.text.contains("is already at") }
            }
        }
        return out
    }

    static func describe(_ plan: CardPlan, shortfall: String?, run: String) -> [(text: String, warning: Bool)] {
        var out: [(text: String, warning: Bool)] = []
        if plan.adding {
            if plan.isEmpty {
                return [("\(plan.card.name) is already at the destination with every take and these outputs: nothing to add.", false)]
            }
            let n = plan.copy.count
            let outputs = plan.outputs.contains { plan.kept[$0.key] != nil && !$0.value.isEmpty }
            var text = "\(plan.card.name) is already at the destination with \(plan.kept.count) of \(plan.card.takes.count) takes. "
            if n > 0 {
                text += "\(run) adds \(n) take\(n == 1 ? "" : "s")" + (outputs ? " and the outputs the others lack" : "")
            } else if outputs {
                text += "\(run) makes the outputs they lack"
            } else {
                text += "\(run) finishes \(plan.secondFolder == nil ? "it" : "the second copy")"
            }
            text += "; what is there stays as it is."
            if !plan.unfinished.isEmpty {
                text += " \(plan.unfinished.count) unfinished cop\(plan.unfinished.count == 1 ? "y" : "ies") from an earlier run go to the Trash first."
            }
            out.append((text, false))
        }
        let footage = plan.copy.reduce(Int64(0)) { $0 + Int64($1.frames.reduce(0) { $0 + $1.size }) }
        var text = footage > 0 ? "\(run) copies \(size(footage)) from the card and writes about \(size(plan.bytes)) with these outputs"
            : "\(run) writes about \(size(plan.bytes)) with these outputs"
        if plan.secondFolder != nil {
            text += ", and about \(size(plan.secondBytes)) to the second drive"
        }
        out.append((text + ".", false))
        if let shortfall = shortfall {
            out.append((shortfall, true))
        }
        return out
    }

    static func colour(_ tone: Outcome.Tone) -> Color {
        switch tone {
        case .good:
            return .green
        case .partial:
            return .orange
        case .bad:
            return .red
        }
    }

    static func caption(_ t: TakeRow) -> String {
        "\(t.frames) frames · \(t.duration) · \(size(t.bytes)) · \(t.start)\n\(t.recordedText) · \(t.colourTemperature)"
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func minutes(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
    }
}
