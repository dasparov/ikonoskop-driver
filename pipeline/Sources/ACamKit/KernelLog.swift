// Driver messages in the macOS log (`log show`, no root needed), checked for card errors.
import Foundation

struct KernelLogLine {
    let date: Date
    let text: String
}

struct KernelLogFinding: Equatable {
    enum Scope: Equatable {
        case card
        case take(Int)   // 0-based take index (EEPROM entry)
        case frame(Int)  // 0-based frame index over the whole card
    }
    let scope: Scope
    let message: String
    let isWarning: Bool
}

enum KernelLog {
    static let predicate = "senderImagePath CONTAINS \"IkonoskopCardReader\""
    static let driverStart = "IkonoskopCardReader: start ("

    // Messages of core/ik_core.cpp and kext/IkonoskopCardReader.cpp that mean the served data or
    // the card may be wrong, and ones worth reporting without failing the offload.
    static let cardErrors = ["Reading EEPROM failed", "No Flashcard detected", "cr_eeprom_init returns",
                             "flash_eeprom_read returns", "eeprom_read: Failed", "Error in input",
                             "directory clusters exhausted", "no DMA interrupt", "device gone",
                             "device removed", "card init failed", "DMA buffer", "gen32IOVMSegments failed",
                             "SG table overflow", "device not responding"]
    static let cardWarnings = ["flash geometry not reported", "no flash geometry within",
                               "interrupt status not cleared"]

    /// Driver lines since boot (`log show --last boot`).
    static func linesSinceBoot() throws -> [KernelLogLine] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["show", "--last", "boot", "--style", "compact", "--predicate", predicate]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw TIFFError("`log show` exited with status \(p.terminationStatus)")
        }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Compact-style lines: "2026-11-03 20:50:05.406 Df kernel[0:146a9c] (IkonoskopCardReader) ...".
    static func parse(_ text: String) -> [KernelLogLine] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return text.split(separator: "\n").compactMap { line in
            guard line.count > 23, let date = f.date(from: String(line.prefix(23))) else {
                return nil
            }
            return KernelLogLine(date: date, text: String(line))
        }
    }

    /// The driver session serving the card when the offload started (from its last start line
    /// before `start`), and whether the driver started again after `start` (reader reconnected).
    static func session(_ lines: [KernelLogLine], offloadStart start: Date) -> (lines: [KernelLogLine], found: Bool, restarted: Bool) {
        guard let first = lines.lastIndex(where: { $0.date <= start && $0.text.contains(driverStart) }) else {
            return ([], false, lines.contains { $0.date > start && $0.text.contains(driverStart) })
        }
        let session = Array(lines[first...])
        let restarted = session.dropFirst().contains { $0.text.contains(driverStart) }
        return (session, true, restarted)
    }

    static func findings(_ lines: [KernelLogLine]) -> [KernelLogFinding] {
        var out: [KernelLogFinding] = []
        for line in lines {
            let t = line.text
            let message = t.components(separatedBy: "IkonoskopCardReader[core]: ").dropFirst().first
                ?? t.components(separatedBy: "IkonoskopCardReader: ").dropFirst().first ?? t
            if let n = number(after: "corrupted data take ", in: t) ?? number(after: "eeprom_get_take_array:, take ", in: t) {
                out.append(KernelLogFinding(scope: .take(n), message: message, isWarning: false))
            } else if let n = number(after: "corrupted data frame ", in: t) ?? number(after: "bad frame_nr, ", in: t)
                        ?? number(after: "fpga_read_dma ERROR: frame ", in: t) {
                out.append(KernelLogFinding(scope: .frame(n), message: message, isWarning: false))
            } else if cardErrors.contains(where: { t.contains($0) }) {
                out.append(KernelLogFinding(scope: .card, message: message, isWarning: false))
            } else if cardWarnings.contains(where: { t.contains($0) }) {
                out.append(KernelLogFinding(scope: .card, message: message, isWarning: true))
            }
        }
        return out
    }

    private static func number(after prefix: String, in text: String) -> Int? {
        guard let r = text.range(of: prefix) else {
            return nil
        }
        return Int(text[r.upperBound...].prefix { $0.isNumber })
    }
}
