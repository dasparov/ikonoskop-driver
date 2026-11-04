// Stopping a long job, and keeping the Mac awake while it runs.
import Foundation

/// Set by the app's Stop button or Ctrl-C in `acam`; each step checks it between frames and
/// files, removes what it had not finished and throws StoppedError.
final class StopSignal {
    private let lock = NSLock()
    private var requested = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func set() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    func check() throws {
        if isSet {
            throw StoppedError()
        }
    }
}

struct StoppedError: Error, CustomStringConvertible {
    var description: String { "stopped" }
}

enum KeepAwake {
    /// Runs `body` with idle sleep turned off: the display may still turn off, but the Mac keeps
    /// working. Closing a laptop's lid still puts it to sleep.
    static func during<T>(_ reason: String, _ body: () throws -> T) rethrows -> T {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: reason)
        defer { ProcessInfo.processInfo.endActivity(activity) }
        return try body()
    }
}
