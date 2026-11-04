// ACam: a small Mac app over the same CardJob that `acam offload` runs. Pick a mounted card and a
// destination, choose the outputs, press Process card.
import AppKit
import CoreImage
import SwiftUI

@main
struct ACamApp: App {
    var body: some Scene {
        WindowGroup("ACam \(acamVersion)") {
            ContentView()
                .frame(minWidth: 820, minHeight: 640)
        }
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

    var frames: Int { files.count }
    var firstFrame: URL? { files.first }
    var start: String { startTimecode?.description ?? "?" }
    var duration: String { fps > 0 ? OffloadReport.duration(Double(frames) / fps) : "?" }

    /// The timecode of frame `index`, counted on from the first frame's.
    func timecode(at index: Int) -> String {
        startTimecode.map { Timecode(frameCount: $0.frameCount(fps: timecodeFPS) + index, fps: timecodeFPS).description } ?? "?"
    }
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

final class CardModel: ObservableObject {
    @Published var cards: [URL] = []
    @Published var selected: URL? {
        didSet { loadTakes() }
    }
    @Published var takes: [TakeRow] = []
    @Published var destination: URL?
    @Published var audio = true
    @Published var clean = true
    @Published var proresLog = false
    @Published var proresPreview = false
    @Published var checkTakeTable = true
    /// Colour profile id in the app's Resources/profiles/ (Phase 5); starts at the one picked.
    @Published var profileID = ColourProfile.defaultID {
        didSet { loadPreviews() }
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
    @Published var running = false
    @Published var fraction = 0.0
    @Published var status = ""
    @Published var verdict: CardJobResult.Verdict?
    @Published var headline = ""
    @Published var report = ""
    @Published var cardFolder: URL?
    /// Takes ticked for "Process selected takes"; cleared when another card is chosen.
    @Published var chosenTakes: Set<String> = []
    /// The card's flash and how much of it the takes use (CardSpace); nil until the card is read.
    @Published var cardSpace: (total: Int64, used: Int64)?
    /// Free space where the copy goes.
    @Published var destinationFree: Int64?

    private var observers: [NSObjectProtocol] = []
    // Frames done per "<stage> <take>", and the work units each stage costs per frame.
    private var done: [String: Int] = [:]
    private var totalUnits = 1.0
    private let weights = ["copy": 1.0, "verify": 1.0, "clean": 0.5, "prores": 2.0]

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshCards()
            })
        }
        refreshCards()
    }

    /// Mounted volumes that look like an A-Cam card (ACAM <n> with an IMAGE folder).
    func refreshCards() {
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        cards = volumes.filter { $0.hasPrefix("ACAM") }.sorted()
            .map { URL(fileURLWithPath: "/Volumes").appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("IMAGE").path) }
        if selected == nil || !cards.contains(selected!) {
            selected = cards.first
        }
    }

    /// Lists the selected card's takes in the background: reading the card (and the macOS prompt
    /// that asks to allow access to removable volumes) must not freeze the window.
    private func loadTakes() {
        takes = []
        previews = [:]
        chosenTakes = []
        cardSpace = nil
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
                               bytes: Int64(take.frames.reduce(0) { $0 + $1.size }))
            }
            let volume = (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity
            let space = volume.map { (total: CardSpace.flashBytes(volumeBytes: Int64($0)),
                                      used: CardSpace.usedBytes(takeFrames: card.takes.map { $0.frames.count })) }
            DispatchQueue.main.async {
                if self.selected == url {
                    self.takes = rows
                    self.cardSpace = space
                    self.status = ""
                    self.loadPreviews()
                }
            }
        }
    }

    /// Develops every take's first frame in the background, one at a time (3.4 MB read from the
    /// card each); not while the card is being copied. A newer pass, for another card or colour
    /// profile, makes older results stale.
    private func loadPreviews() {
        guard !running else {
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
        guard !running else {
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
        guard !running else {
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder for this card. A new folder named after the card is made inside it."
        if panel.runModal() == .OK {
            destination = panel.url
            refreshDestinationFree()
        }
    }

    /// Free space at the destination, shown next to it.
    private func refreshDestinationFree() {
        destinationFree = (try? destination?.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init)
    }

    /// Bytes of footage a run copies (every take, or the chosen ones), and about how much it writes
    /// with the chosen outputs.
    func runSize(takes chosen: Set<String>?) -> (footage: Int64, written: Int64) {
        let rows = takes.filter { chosen?.contains($0.id) ?? true }
        let frames = rows.reduce(0) { $0 + $1.frames }
        let footage = rows.reduce(Int64(0)) { $0 + $1.bytes }
        let looks = [proresLog ? ProResLook.log : nil, proresPreview ? ProResLook.preview : nil].compactMap { $0 }
        let written = CardSpace.estimatedRunBytes(frames: frames, frameFileBytes: frames > 0 ? footage / Int64(frames) : 0,
                                                  audio: audio, clean: clean, looks: looks)
        return (footage, written)
    }

    var canProcess: Bool {
        !running && selected != nil && destination != nil
    }

    /// Copies and checks every take of the card, or only `chosen` (the report then says PARTIAL).
    func process(takes chosen: Set<String>? = nil) {
        guard let source = selected, let destination = destination else {
            return
        }
        // A preview reads the card too: the copy gets the card to itself.
        if previewWindow != nil {
            closePreview()
            notice = Notice(title: "Preview closed",
                            message: "The card is being copied now. Previews are back when the copy has finished.")
        }
        running = true
        verdict = nil
        headline = ""
        report = ""
        cardFolder = nil
        fraction = 0
        done = [:]
        let frames = Double(takes.filter { chosen?.contains($0.id) ?? true }.reduce(0) { $0 + $1.frames })
        var perFrame = weights["copy"]! + weights["verify"]!
        perFrame += clean ? weights["clean"]! : 0
        perFrame += Double([proresLog, proresPreview].filter { $0 }.count) * weights["prores"]!
        totalUnits = max(frames * perFrame, 1)
        let looks = [proresLog ? ProResLook.log : nil, proresPreview ? ProResLook.preview : nil].compactMap { $0 }
        let options = (audio, clean, checkTakeTable)
        let profileFolder = Bundle.main.resourceURL?.appendingPathComponent("profiles").appendingPathComponent(profileID)
        status = checkTakeTable ? "Reading the take table (macOS asks for your password)…" : "Starting…"

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var eepromText: String?
                if options.2 {
                    eepromText = try Self.readEepromWithAdminPrompt()
                }
                let offload = OffloadOptions(source: source, destination: destination,
                                             eeprom: try eepromText.map(EepromImage.parseHexDump), eepromText: eepromText,
                                             takes: chosen)
                let profile = try profileFolder.map(ColourProfile.load)
                let job = CardJob(CardJobOptions(offload: offload, audio: options.0, clean: options.1,
                                                 profile: profile, prores: looks))
                job.progress = { [weak self] line in
                    DispatchQueue.main.async { self?.progressed(line) }
                }
                let result = try job.run()
                let reportURL = result.offload.cardFolder.appendingPathComponent("REPORT.md")
                let text = (try? String(contentsOf: reportURL, encoding: .utf8)) ?? ""
                DispatchQueue.main.async {
                    self.finish(verdict: result.verdict, headline: result.headline, report: text,
                                folder: result.offload.cardFolder)
                }
            } catch {
                DispatchQueue.main.async {
                    self.finish(verdict: .problems, headline: "PROBLEMS FOUND", report: "Could not process the card:\n\n\(error)",
                                folder: nil)
                }
            }
        }
    }

    /// Lines like "copy   AC102001    200/2763 frames  165 MB/s".
    private func progressed(_ line: String) {
        status = line.trimmingCharacters(in: .whitespaces)
        let words = line.split(separator: " ")
        guard let stage = words.first.map(String.init), weights[stage] != nil, words.count >= 3,
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

    private func finish(verdict: CardJobResult.Verdict, headline: String, report: String, folder: URL?) {
        running = false
        fraction = folder == nil ? 0 : 1
        self.verdict = verdict
        self.headline = headline
        self.report = report
        cardFolder = folder
        status = folder == nil ? "Stopped." : "Done."
        refreshDestinationFree()
    }

    func showInFinder() {
        if let folder = cardFolder {
            NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("REPORT.md")])
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardRow
            if !model.takes.isEmpty {
                cardSummary
            }
            takesView
            if model.running {
                Text("Previews are off while the card is being copied.").font(.caption).foregroundColor(.secondary)
            }
            destinationRow
            outputsRow
            Group {
                processRow
                runSizeLine
            }
            Text(model.status).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
            resultView
            Spacer(minLength: 0)
        }
        .padding(18)
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
            Text("Card").font(.headline).frame(width: 100, alignment: .leading)
            if model.cards.isEmpty {
                Text("No A-Cam card mounted. Connect the reader and insert a card.").foregroundColor(.secondary)
            } else {
                Picker("", selection: $model.selected) {
                    ForEach(model.cards, id: \.self) { Text($0.lastPathComponent).tag(Optional($0)) }
                }
                .labelsHidden()
                .frame(width: 220)
                .disabled(model.running)
            }
            Button("Refresh") { model.refreshCards() }.disabled(model.running)
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
            TableColumn("Select") { t in Toggle("", isOn: chosen(t.id)).labelsHidden().disabled(model.running) }
                .width(44)
            TableColumn("First frame") { t in previewButton(t).frame(width: 96) }
                .width(104)
            TableColumn("Take", value: \.id)
            TableColumn("Frames") { Text("\($0.frames)") }
            TableColumn("Duration") { Text($0.duration) }
            TableColumn("Size") { Text(Self.size($0.bytes)) }
            TableColumn("Frame rate") { t in Text(t.fps > 0 ? String(format: "%g fps", t.fps) : "?") }
            TableColumn("Start timecode", value: \.start)
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
            Toggle(isOn: chosen(t.id)) { Text(t.id).font(.headline) }
                .disabled(model.running)
                .help("Tick to include this take in Process selected takes")
            Text(Self.caption(t))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var destinationRow: some View {
        HStack {
            Text("Destination").font(.headline).frame(width: 100, alignment: .leading)
            Text(model.destination?.path ?? "none chosen")
                .foregroundColor(model.destination == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let free = model.destinationFree {
                Text(Self.size(free) + " free").foregroundColor(.secondary)
            }
            Spacer()
            Button("Choose…") { model.chooseDestination() }
        }
    }

    private var outputsRow: some View {
        HStack(alignment: .top) {
            Text("Outputs").font(.headline).frame(width: 100, alignment: .leading)
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
                .disabled(model.running)
            }
        }
    }

    private var processRow: some View {
        HStack {
            Button(action: { model.process() }) {
                Text("Process card").frame(minWidth: 140)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canProcess)
            .help("Copy and check every take on the card")
            Button(selectedButtonTitle) { confirmingSelection = true }
                .disabled(!model.canProcess || model.chosenTakes.isEmpty)
                .help("Copy and check only the ticked takes")
            ProgressView(value: model.fraction)
            Text(String(format: "%.0f%%", model.fraction * 100)).monospacedDigit().frame(width: 44)
        }
    }

    @ViewBuilder private var resultView: some View {
        if let verdict = model.verdict {
            HStack {
                Text(model.headline)
                    .font(.title2.bold())
                    .foregroundColor(Self.colour(verdict))
                Spacer()
                Button("Show in Finder") { model.showInFinder() }.disabled(model.cardFolder == nil)
            }
            ScrollView {
                Text(model.report)
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

    private var confirmTitle: String {
        "Copy only \(model.chosenTakes.count) of \(model.takes.count) takes?"
    }

    private var confirmButton: String {
        let n = model.chosenTakes.count
        return "Copy \(n) take\(n == 1 ? "" : "s")"
    }

    private var confirmMessage: String {
        let rest = model.takes.count - model.chosenTakes.count
        return "The other \(rest) take\(rest == 1 ? "" : "s") will stay only on the card: copy \(rest == 1 ? "it" : "them") too before the card is reused. The report will say PARTIAL."
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
        .help("Preview this take")
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
            Color.clear.frame(width: 100, height: 1)
            Text(footageText)
            if let full = cardFullFraction {
                ProgressView(value: full).frame(width: 90)
                Text(cardFullText)
            }
        }
        .font(.caption)
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

    /// What a run copies and about how much it writes, and whether that fits at the destination.
    @ViewBuilder private var runSizeLine: some View {
        if !model.takes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(runSizeText)
                if let warning = spaceWarning {
                    Text(warning).foregroundColor(.orange)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private var runSizeText: String {
        let all = model.runSize(takes: nil)
        var text = "Process card copies \(Self.size(all.footage)) and writes about \(Self.size(all.written)) with these outputs."
        if !model.chosenTakes.isEmpty {
            let picked = model.runSize(takes: model.chosenTakes)
            text += " The selected takes: \(Self.size(picked.footage)), about \(Self.size(picked.written)) written."
        }
        return text
    }

    /// When the destination is too small for the card, or for the selected takes.
    private var spaceWarning: String? {
        guard let free = model.destinationFree else {
            return nil
        }
        let all = model.runSize(takes: nil)
        if model.chosenTakes.isEmpty {
            return free < all.written ? "The destination has only \(Self.size(free)) free: not enough for this card." : nil
        }
        let picked = model.runSize(takes: model.chosenTakes)
        if free < picked.written {
            return "The destination has only \(Self.size(free)) free: not enough for the selected takes."
        }
        return free < all.written ? "The destination has \(Self.size(free)) free: enough for the selected takes, not for the whole card." : nil
    }

    static func colour(_ verdict: CardJobResult.Verdict) -> Color {
        switch verdict {
        case .allVerified:
            return .green
        case .partial:
            return .orange
        case .problems:
            return .red
        }
    }

    static func caption(_ t: TakeRow) -> String {
        "\(t.frames) frames · \(t.duration) · \(size(t.bytes)) · \(t.start)"
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func minutes(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
    }
}
