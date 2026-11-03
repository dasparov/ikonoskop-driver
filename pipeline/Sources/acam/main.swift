// acam: command-line entry point.
import Foundation

let help = """
    acam \(acamVersion): A-Cam dII card pipeline

    Usage:
      acam offload --source <card> --dest <folder> [--eeprom <file> | --read-eeprom]
                   [--no-audio] [--no-clean]
          Copy every take of the mounted card into <folder>/<card name>/<take>/frames/,
          verify every copy with xxHash64 and write an ASC MHL history per take; then, from the
          verified copies, <take>_Audio.wav and clean DNGs in <take>/clean/; then REPORT.md.
          The take-table check needs the card's EEPROM:
            --eeprom <file>  a dump made with: sudo tools/ikctl eeprom 0 0x2000 > <file>
            --read-eeprom    run that command now (asks for your password)

      acam audio <take folder>...    <take>_Audio.wav from <take>/frames/
      acam clean <take folder>...    clean DNGs in <take>/clean/ from <take>/frames/
          A card folder (made by offload) stands for all its takes.

    Options:
      -h, --help   Show this help
      --version    Show the version

    """

struct UsageError: Error, CustomStringConvertible {
    let description: String
}

/// `--name value` options and `--flag` switches.
struct Arguments {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ args: ArraySlice<String>, values valueNames: Set<String>, flags flagNames: Set<String>) throws {
        var it = args.makeIterator()
        while let arg = it.next() {
            if valueNames.contains(arg) {
                guard let v = it.next() else {
                    throw UsageError(description: "\(arg) needs a value")
                }
                values[arg] = v
            } else if flagNames.contains(arg) {
                flags.insert(arg)
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

/// tools/ikctl of this checkout (acam lives in pipeline/build/).
func ikctlPath() -> String {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return exe.deletingLastPathComponent().appendingPathComponent("../../tools/ikctl").standardized.path
}

/// Runs `sudo tools/ikctl eeprom 0 0x2000`; sudo asks for the password on this terminal.
func readEepromWithSudo() throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    p.arguments = [ikctlPath(), "eeprom", "0", "0x2000"]
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

func offload(_ args: ArraySlice<String>) throws -> Int32 {
    let a = try Arguments(args, values: ["--source", "--dest", "--eeprom"],
                          flags: ["--read-eeprom", "--no-audio", "--no-clean"])
    var eepromText: String?
    if let path = a.value("--eeprom") {
        eepromText = try String(contentsOfFile: path, encoding: .utf8)
    } else if a.flag("--read-eeprom") {
        eepromText = try readEepromWithSudo()
    }
    let offload = OffloadOptions(source: URL(fileURLWithPath: try a.required("--source")),
                                 destination: URL(fileURLWithPath: try a.required("--dest")),
                                 eeprom: try eepromText.map(EepromImage.parseHexDump),
                                 eepromText: eepromText)
    let result = try CardJob(CardJobOptions(offload: offload, audio: !a.flag("--no-audio"),
                                            clean: !a.flag("--no-clean"))).run()
    print("")
    for t in result.offload.takes {
        let extra = [result.audio[t.name].map { $0.failed ? "audio FAILED" : "audio OK" },
                     result.clean[t.name].map { $0.failed ? "clean FAILED" : "clean OK" }].compactMap { $0 }
        print("\(t.failed ? "FAILED  " : "verified") \(t.name)  \(t.verifiedCount)/\(t.files.count) frames  \(extra.joined(separator: ", "))")
    }
    for p in result.offload.cardProblems {
        print("problem: \(p)")
    }
    print("\(result.allVerified ? "ALL VERIFIED" : "PROBLEMS FOUND"): \(result.offload.cardFolder.appendingPathComponent("REPORT.md").path)")
    return result.allVerified ? 0 : 1
}

/// Take folders named on the command line; a card folder stands for the take folders in it.
func takeFolders(_ args: ArraySlice<String>) throws -> [URL] {
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
    for folder in try takeFolders(args) {
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
    var ok = true
    for folder in try takeFolders(args) {
        let r = try CleanTake.run(take: folder, progress: { print($0) })
        ok = ok && !r.failed
        print(r.failed ? "clean  \(folder.lastPathComponent)  FAILED: \(r.problems.prefix(5).joined(separator: "; "))"
              : String(format: "clean  %@  %d frames, %.0f%% of the size, every frame decoded and compared",
                       folder.lastPathComponent, r.frames, r.ratio * 100))
    }
    return ok ? 0 : 1
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
