// Minimal test runner: the Command Line Tools ship without XCTest.
//
//   build/acam-tests            run every suite
//   build/acam-tests <suite>... run the named suites
import Foundation

final class TestContext {
    let suite: String
    private(set) var failures: [String] = []
    private let scratchRoot: URL

    init(suite: String, scratchRoot: URL) {
        self.suite = suite
        self.scratchRoot = scratchRoot
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String,
                file: StaticString = #fileID, line: UInt = #line) {
        if !condition {
            failures.append("\(file):\(line): \(message())")
        }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String = "",
                                   file: StaticString = #fileID, line: UInt = #line) {
        if actual != expected {
            failures.append("\(file):\(line): \(message()) got \(actual), want \(expected)")
        }
    }

    /// A new, empty directory for this test under build/test-scratch/<suite>/.
    func scratchDirectory(_ name: String) throws -> URL {
        let url = scratchRoot.appendingPathComponent(suite).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct TestSuite {
    let name: String
    let run: (TestContext) throws -> Void
}

func runTests(_ suites: [TestSuite]) -> Int32 {
    let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let scratch = binary.deletingLastPathComponent().appendingPathComponent("test-scratch")
    if FileManager.default.fileExists(atPath: scratch.path) {
        try? FileManager.default.removeItem(at: scratch)
    }
    let selected = Set(CommandLine.arguments.dropFirst())
    var failed = 0
    for suite in suites where selected.isEmpty || selected.contains(suite.name) {
        let t = TestContext(suite: suite.name, scratchRoot: scratch)
        let start = Date()
        do {
            try suite.run(t)
        } catch {
            t.expect(false, "threw \(error)")
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        if t.failures.isEmpty {
            print("PASS \(suite.name) (\(ms) ms)")
        } else {
            failed += 1
            print("FAIL \(suite.name) (\(ms) ms)")
            t.failures.forEach { print("  \($0)") }
        }
    }
    print(failed == 0 ? "all tests passed" : "\(failed) suite(s) failed")
    return failed == 0 ? 0 : 1
}
