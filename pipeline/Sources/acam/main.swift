// acam: command-line entry point.
import Foundation

let help = """
    acam \(acamVersion): A-Cam dII card pipeline

    Usage:
      acam offload --source <card> --dest <folder> [--eeprom <file> | --read-eeprom]
          Copy every take of the mounted card into <folder>/<card name>/<take>/frames/,
          verify every copy with xxHash64, write an ASC MHL manifest per take and REPORT.md.
          The take-table check needs the card's EEPROM:
            --eeprom <file>  a dump made with: sudo tools/ikctl eeprom 0 0x2000 > <file>
            --read-eeprom    run that command now (asks for your password)

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
    let a = try Arguments(args, values: ["--source", "--dest", "--eeprom"], flags: ["--read-eeprom"])
    var eepromText: String?
    if let path = a.value("--eeprom") {
        eepromText = try String(contentsOfFile: path, encoding: .utf8)
    } else if a.flag("--read-eeprom") {
        eepromText = try readEepromWithSudo()
    }
    let options = OffloadOptions(source: URL(fileURLWithPath: try a.required("--source")),
                                 destination: URL(fileURLWithPath: try a.required("--dest")),
                                 eeprom: try eepromText.map(EepromImage.parseHexDump),
                                 eepromText: eepromText)
    let result = try Offload(options).run()
    print("")
    for t in result.takes {
        print("\(t.failed ? "FAILED  " : "verified") \(t.name)  \(t.verifiedCount)/\(t.files.count) frames")
    }
    for p in result.cardProblems {
        print("problem: \(p)")
    }
    print("\(result.allVerified ? "ALL VERIFIED" : "PROBLEMS FOUND"): \(result.cardFolder.appendingPathComponent("REPORT.md").path)")
    return result.allVerified ? 0 : 1
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
