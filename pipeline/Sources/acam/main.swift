// acam: command-line entry point. Commands are added phase by phase (SPEC.md).
import Foundation

let version = "0.1.0"

let help = """
    acam \(version): A-Cam dII card pipeline (in development)

    Usage: acam <command> [options]

    Commands:
      none yet

    Options:
      -h, --help   Show this help
      --version    Show the version

    """

func usageError(_ message: String) -> Never {
    FileHandle.standardError.write(Data(message.utf8))
    exit(64) // EX_USAGE
}

switch CommandLine.arguments.dropFirst().first {
case "-h", "--help":
    print(help, terminator: "")
case "--version":
    print(version)
case nil:
    usageError(help)
case let command?:
    usageError("acam: unknown command '\(command)'. Run 'acam --help'.\n")
}
