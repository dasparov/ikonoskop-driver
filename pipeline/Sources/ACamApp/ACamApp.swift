// ACam: a small Mac app over the same CardJob that `acam offload` runs. Pick a mounted card and a
// destination, choose the outputs, press Process card.
import AppKit
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

/// One take of the selected card, read from its first and last frame headers.
struct TakeRow: Identifiable {
    let id: String
    let frames: Int
    let fps: Double
    let start: String
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
    @Published var profileID = ColourProfile.defaultID
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
    @Published var verdict: Bool?
    @Published var report = ""
    @Published var cardFolder: URL?

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
                return TakeRow(id: take.name, frames: take.frames.count, fps: header?.fps ?? 0,
                               start: header?.timecode?.description ?? "?")
            }
            DispatchQueue.main.async {
                if self.selected == url {
                    self.takes = rows
                    self.status = ""
                }
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
        }
    }

    var canProcess: Bool {
        !running && selected != nil && destination != nil
    }

    func process() {
        guard let source = selected, let destination = destination else {
            return
        }
        running = true
        verdict = nil
        report = ""
        cardFolder = nil
        fraction = 0
        done = [:]
        let frames = Double(takes.reduce(0) { $0 + $1.frames })
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
                                             eeprom: try eepromText.map(EepromImage.parseHexDump), eepromText: eepromText)
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
                    self.finish(verdict: result.allVerified, report: text, folder: result.offload.cardFolder)
                }
            } catch {
                DispatchQueue.main.async {
                    self.finish(verdict: false, report: "Could not process the card:\n\n\(error)", folder: nil)
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

    private func finish(verdict: Bool, report: String, folder: URL?) {
        running = false
        fraction = folder == nil ? 0 : 1
        self.verdict = verdict
        self.report = report
        cardFolder = folder
        status = folder == nil ? "Stopped." : "Done."
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                }
                Button("Refresh") { model.refreshCards() }
                Spacer()
            }
            Table(model.takes) {
                TableColumn("Take", value: \.id)
                TableColumn("Frames") { Text("\($0.frames)") }
                TableColumn("Duration") { t in Text(t.fps > 0 ? OffloadReport.duration(Double(t.frames) / t.fps) : "?") }
                TableColumn("Frame rate") { t in Text(t.fps > 0 ? String(format: "%g fps", t.fps) : "?") }
                TableColumn("Start timecode", value: \.start)
            }
            .frame(minHeight: 150)

            HStack {
                Text("Destination").font(.headline).frame(width: 100, alignment: .leading)
                Text(model.destination?.path ?? "none chosen").foregroundColor(model.destination == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { model.chooseDestination() }
            }
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
                }
            }
            HStack {
                Button(action: model.process) {
                    Text("Process card").frame(minWidth: 140)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canProcess)
                ProgressView(value: model.fraction)
                Text(String(format: "%.0f%%", model.fraction * 100)).monospacedDigit().frame(width: 44)
            }
            Text(model.status).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)

            if let ok = model.verdict {
                HStack {
                    Text(ok ? "ALL VERIFIED" : "PROBLEMS FOUND")
                        .font(.title2.bold())
                        .foregroundColor(ok ? .green : .red)
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
            Spacer(minLength: 0)
        }
        .padding(18)
    }
}
