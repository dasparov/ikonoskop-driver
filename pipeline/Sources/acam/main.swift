// acam: command-line entry point.
import Foundation

let help = """
    acam \(acamVersion): A-Cam dII card pipeline

    Usage:
      acam offload --source <card> --dest <folder> [--second-dest <folder>] [--add]
                   [--eeprom <file> | --read-eeprom] [--takes <take>,...]
                   [--profile <id>] [--prores log|preview|both] [--no-audio] [--no-clean]
          Copy every take of the mounted card into <folder>/<card name>/<take>/frames/,
          verify every copy with xxHash64 and write an ASC MHL history per take; then, from the
          verified copies, <take>_Audio.wav, clean DNGs in <take>/clean/ and optional ProRes
          4444 XQ files in <card>/prores/; then REPORT.md. Refuses to start when the
          destination has too little space for the copies and outputs. Ctrl-C stops: copies not
          yet verified are removed; once they are, the outputs not made yet are listed.
          The take-table check needs the card's EEPROM:
            --eeprom <file>  a dump made with: sudo tools/ikctl eeprom 0 0x2000 > <file>
            --read-eeprom    run that command now (asks for your password)
          --takes AC102001,AC102004  copy only these takes; the report then says PARTIAL and lists
                                     the takes left on the card
          --second-dest <folder>     a second copy of everything in <folder>/<card name>, on
                                     another drive; the frames are written to both as the card is
                                     read
          --add                      the card folder exists already (an earlier PARTIAL or stopped
                                     run): copy only the takes and make only the outputs it lacks.
                                     Takes it holds are kept as they are; unfinished copies are
                                     moved to the Trash

      acam audio <take folder>...                     <take>_Audio.wav from <take>/frames/
      acam clean [--profile <id>] <take folder>...    clean DNGs in <take>/clean/
      acam prores [--look log|preview|both] <take folder>...
                                                      ProRes 4444 XQ in <card>/prores/
          A card folder (made by offload) stands for all its takes.

      --profile <id>  colour profile for the clean DNGs: kai02150-ir665 (default, picked in Phase 5),
                      factory (Ikonoskop's matrices), kai02150-ir650 (pipeline/colour/profiles/),
                      or a folder with profile.json.
      log = ACEScct for grading, preview = Rec.709.

      acam verify <folder>...
          Check a copy made by offload, for example after moving it to another drive: every file
          the take's ASC MHL history (ascmhl/) lists is read again and compared with its
          xxHash64. A card folder stands for all its takes. Prints ALL MATCH (exit 0) or
          MISMATCH FOUND (exit 1).

    Options:
      -h, --help   Show this help
      --version    Show the version

    """

struct UsageError: Error, CustomStringConvertible {
    let description: String
}

/// `--name value` options, `--flag` switches and the remaining positional arguments.
struct Arguments {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []
    private(set) var positional: [String] = []

    init(_ args: ArraySlice<String>, values valueNames: Set<String>, flags flagNames: Set<String> = [],
         positional allowed: Bool = false) throws {
        var it = args.makeIterator()
        while let arg = it.next() {
            if valueNames.contains(arg) {
                guard let v = it.next() else {
                    throw UsageError(description: "\(arg) needs a value")
                }
                values[arg] = v
            } else if flagNames.contains(arg) {
                flags.insert(arg)
            } else if allowed && !arg.hasPrefix("--") {
                positional.append(arg)
            } else {
                throw UsageError(description: "unknown option '\(arg)'")
            }
        }
    }

    func value(_ name: String) -> String? {
        values[name]
    }

    func required(_ name: String) throws -> String {
        guard let v = values[name] else {
            throw UsageError(description: "\(name) is required")
        }
        return v
    }

    func flag(_ name: String) -> Bool {
        flags.contains(name)
    }
}

/// This checkout's directory `relative` to pipeline/build/, where acam lives.
func checkoutPath(_ relative: String) -> URL {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return exe.deletingLastPathComponent().appendingPathComponent(relative).standardized
}

/// Runs `sudo tools/ikctl eeprom 0 0x2000`; sudo asks for the password on this terminal.
func readEepromWithSudo() throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    p.arguments = [checkoutPath("../../tools/ikctl").path, "eeprom", "0", "0x2000"]
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw UsageError(description: "sudo ikctl eeprom failed (status \(p.terminationStatus))")
    }
    return String(decoding: data, as: UTF8.self)
}

/// A profile id from pipeline/colour/profiles/ (default: the one picked in Phase 5), or a folder
/// holding profile.json.
func profile(_ name: String?) throws -> (profile: ColourProfile, folder: URL) {
    let name = name ?? ColourProfile.defaultID
    let direct = URL(fileURLWithPath: name)
    if FileManager.default.fileExists(atPath: direct.appendingPathComponent("profile.json").path) {
        return try ColourProfile.load(direct)
    }
    let folder = checkoutPath("../colour/profiles").appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("profile.json").path) else {
        throw UsageError(description: "no colour profile '\(name)' (looked in \(folder.path))")
    }
    return try ColourProfile.load(folder)
}

func looks(_ value: String?) throws -> [ProResLook] {
    switch value {
    case nil: return []
    case "log": return [.log]
    case "preview": return [.preview]
    case "both": return [.log, .preview]
    case let v?: throw UsageError(description: "ProRes look must be log, preview or both, not '\(v)'")
    }
}

func offload(_ args: ArraySlice<String>) throws -> Int32 {
    let a = try Arguments(args, values: ["--source", "--dest", "--second-dest", "--eeprom", "--profile", "--prores", "--takes"],
                          flags: ["--read-eeprom", "--no-audio", "--no-clean", "--add"])
    var eepromText: String?
    if let path = a.value("--eeprom") {
        eepromText = try String(contentsOfFile: path, encoding: .utf8)
    } else if a.flag("--read-eeprom") {
        eepromText = try readEepromWithSudo()
    }
    let offload = OffloadOptions(source: URL(fileURLWithPath: try a.required("--source")),
                                 destination: URL(fileURLWithPath: try a.required("--dest")),
                                 eeprom: try eepromText.map(EepromImage.parseHexDump),
                                 eepromText: eepromText,
                                 takes: a.value("--takes").map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) },
                                 secondDestination: a.value("--second-dest").map { URL(fileURLWithPath: $0) },
                                 addToExisting: a.flag("--add"))
    let options = CardJobOptions(offload: offload, audio: !a.flag("--no-audio"), clean: !a.flag("--no-clean"),
                                 profile: try profile(a.value("--profile")), prores: try looks(a.value("--prores")))
    let job = CardJob(options)
    let result: CardJobResult
    do {
        result = try interruptible(job.stop) { try job.run() }
    } catch is StoppedError {
        print("\nstopped: the copies were not verified yet, so this run kept nothing; the card still has every take")
        return 130
    }
    print("")
    for t in result.offload.takes {
        var extra = [result.audio[t.name].map { $0.failed ? "audio FAILED" : "audio OK" },
                     result.clean[t.name].map { $0.failed ? "clean FAILED" : "clean OK" }].compactMap { $0 }
        for (look, p) in (result.prores[t.name] ?? [:]).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            extra.append("ProRes \(look.rawValue) \(p.failed ? "FAILED" : "OK")")
        }
        if t.copiedEarlier {
            extra.insert("copied earlier", at: 0)
        }
        if t.secondFailed {
            extra.append("second copy FAILED")
        }
        print("\(t.failed ? "FAILED  " : "verified") \(t.name)  \(t.verifiedCount)/\(t.files.count) frames  \(extra.joined(separator: ", "))")
    }
    for p in result.problems + result.offload.cardProblems + (result.second?.problems ?? []) {
        print("problem: \(p)")
    }
    for m in result.notMade {
        print("not made (stopped): \(m)")
    }
    print("\(result.headline): \(result.offload.cardFolder.appendingPathComponent("REPORT.md").path)")
    return result.allVerified ? 0 : 1
}

/// Take folders named on the command line; a card folder stands for the take folders in it.
func takeFolders(_ args: [String]) throws -> [URL] {
    guard !args.isEmpty else {
        throw UsageError(description: "name at least one take or card folder")
    }
    let fm = FileManager.default
    var out: [URL] = []
    for arg in args {
        let url = URL(fileURLWithPath: arg)
        if fm.fileExists(atPath: url.appendingPathComponent("frames").path) {
            out.append(url)
            continue
        }
        let takes = try fm.contentsOfDirectory(atPath: url.path).sorted()
            .map { url.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("frames").path) }
        guard !takes.isEmpty else {
            throw UsageError(description: "\(arg) is neither a take folder (with frames/) nor a card folder")
        }
        out += takes
    }
    return out
}

func audio(_ args: ArraySlice<String>) throws -> Int32 {
    var ok = true
    for folder in try takeFolders(Array(args)) {
        let r = try AudioTake.run(take: folder)
        ok = ok && !r.failed
        let status = r.failed ? "FAILED: \(r.problems.joined(separator: "; "))"
            : String(format: "%d frames, %.3f s, drift %+.2f ms, start %@", r.frames, r.seconds, r.drift * 1000,
                     r.startTimecode?.description ?? "?")
        print("audio  \(folder.lastPathComponent)  \(status)")
        r.warnings.forEach { print("       warning: \($0)") }
    }
    return ok ? 0 : 1
}

func clean(_ args: ArraySlice<String>) throws -> Int32 {
    let a = try Arguments(args, values: ["--profile"], positional: true)
    let chosen = try profile(a.value("--profile"))
    var ok = true
    for folder in try takeFolders(a.positional) {
        let r = try CleanTake.run(take: folder, profile: chosen.profile, progress: { print($0) })
        ok = ok && !r.failed
        print(r.failed ? "clean  \(folder.lastPathComponent)  FAILED: \(r.problems.prefix(5).joined(separator: "; "))"
              : String(format: "clean  %@  %d frames, %.0f%% of the size, every frame decoded and compared",
                       folder.lastPathComponent, r.frames, r.ratio * 100))
    }
    return ok ? 0 : 1
}

func prores(_ args: ArraySlice<String>) throws -> Int32 {
    let a = try Arguments(args, values: ["--look"], positional: true)
    let chosen = try looks(a.value("--look") ?? "both")
    var ok = true
    for folder in try takeFolders(a.positional) {
        let outputDir = folder.deletingLastPathComponent().appendingPathComponent("prores")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        for look in chosen {
            let r = try ProResTake.run(take: folder, look: look, outputDir: outputDir, progress: { print($0) })
            ok = ok && !r.failed
            print(r.failed ? "prores \(folder.lastPathComponent) \(look.rawValue) FAILED: \(r.problems.joined(separator: "; "))"
                  : "prores \(folder.lastPathComponent) \(look.rawValue): \(r.output?.path ?? "?") (\(r.frames) frames)")
            r.warnings.forEach { print("       warning: \($0)") }
        }
    }
    return ok ? 0 : 1
}

func verify(_ args: ArraySlice<String>) throws -> Int32 {
    let a = try Arguments(args, values: [], positional: true)
    guard !a.positional.isEmpty else {
        throw UsageError(description: "name at least one card or take folder")
    }
    var ok = true
    let stop = StopSignal()
    for path in a.positional {
        let r = try interruptible(stop) {
            try KeepAwake.during("Checking \(path)") {
                try CopyVerifier.verify(URL(fileURLWithPath: path), progress: { print($0) }, isCancelled: { stop.isSet })
            }
        }
        ok = ok && r.ok
        if r.stopped {
            print("stopped: not every file was checked")
        }
        for t in r.takes {
            if t.ok {
                print(String(format: "OK      %@  %d files  %.1f GB", t.name, t.files, Double(t.bytes) / 1e9))
            } else {
                let counts = [(t.mismatched.count, "changed"), (t.missing.count, "missing"),
                              (t.problems.count, t.problems.count == 1 ? "problem" : "problems")]
                    .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
                print("FAILED  \(t.name)  \(counts.joined(separator: ", "))")
                t.mismatched.forEach { print("        changed: \($0)") }
                t.missing.forEach { print("        missing: \($0)") }
                t.problems.forEach { print("        problem: \($0)") }
            }
            t.unlisted.forEach { print("        warning: not in the checksum history: \($0)") }
        }
    }
    print(ok ? "ALL MATCH" : "MISMATCH FOUND")
    return ok ? 0 : 1
}

/// Runs `body`; the first Ctrl-C sets `stop` (the job stops cleanly), a second one quits at once.
func interruptible<T>(_ stop: StopSignal, _ body: () throws -> T) rethrows -> T {
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler {
        if stop.isSet {
            exit(130)
        }
        FileHandle.standardError.write(Data("\nacam: stopping (Ctrl-C again quits at once)…\n".utf8))
        stop.set()
    }
    interrupt.resume()
    defer {
        interrupt.cancel()
        signal(SIGINT, SIG_DFL)
    }
    return try withExtendedLifetime(interrupt) { try body() }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("acam: \(message)\n".utf8))
    exit(64) // EX_USAGE
}

let arguments = CommandLine.arguments.dropFirst()
do {
    switch arguments.first {
    case "-h", "--help":
        print(help, terminator: "")
    case "--version":
        print(acamVersion)
    case "offload":
        exit(try offload(arguments.dropFirst()))
    case "audio":
        exit(try audio(arguments.dropFirst()))
    case "clean":
        exit(try clean(arguments.dropFirst()))
    case "prores":
        exit(try prores(arguments.dropFirst()))
    case "verify":
        exit(try verify(arguments.dropFirst()))
    case nil:
        FileHandle.standardError.write(Data(help.utf8))
        exit(64)
    case let command?:
        fail("unknown command '\(command)'. Run 'acam --help'.")
    }
} catch let error as UsageError {
    fail("\(error). Run 'acam --help'.")
} catch {
    FileHandle.standardError.write(Data("acam: \(error)\n".utf8))
    exit(2)
}
