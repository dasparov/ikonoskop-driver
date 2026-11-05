// Checks an existing copy, for example after it was moved to another drive, against the ASC MHL
// history that `a-card offload` (and later `a-card audio` / `a-card clean`) wrote into each take folder:
// every manifest must still match its C4 id in the chain, and every file the history lists must
// still hash to the xxHash64 of the latest generation that lists it.
import Foundation

/// The outcome for one take folder.
struct VerifiedTake {
    let name: String
    /// Listed files that were read and hashed, and their bytes.
    var files = 0
    var bytes: Int64 = 0
    /// Listed, present, hash differs.
    var mismatched: [String] = []
    /// Listed in the history, not on disk.
    var missing: [String] = []
    /// On disk, in no generation (a warning only).
    var unlisted: [String] = []
    /// For example no checksum history, or a manifest that changed or cannot be read.
    var problems: [String] = []
    var ok: Bool { mismatched.isEmpty && missing.isEmpty && problems.isEmpty }
}

struct CopyVerifyResult {
    let folder: URL
    var takes: [VerifiedTake] = []
    /// Cancelled before every take was checked.
    var stopped = false
    var ok: Bool { !stopped && !takes.isEmpty && takes.allSatisfy { $0.ok } }

    /// ALL MATCH, MISMATCH FOUND or STOPPED.
    var headline: String {
        ok ? "ALL MATCH" : takes.contains { !$0.ok } ? "MISMATCH FOUND" : "STOPPED"
    }

    /// One line per take ("OK      AC102001  2765 files  9.3 GB", or FAILED with the files),
    /// as `a-card verify` prints it and the app shows it.
    var lines: [String] {
        var out: [String] = []
        for t in takes {
            if t.ok {
                out.append(String(format: "OK      %@  %d files  %.1f GB", t.name, t.files, Double(t.bytes) / 1e9))
            } else {
                let counts = [(t.mismatched.count, "changed"), (t.missing.count, "missing"),
                              (t.problems.count, t.problems.count == 1 ? "problem" : "problems")]
                    .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
                out.append("FAILED  \(t.name)  \(counts.joined(separator: ", "))")
                out += t.mismatched.map { "        changed: \($0)" } + t.missing.map { "        missing: \($0)" }
                    + t.problems.map { "        problem: \($0)" }
            }
            out += t.unlisted.map { "        warning: not in the checksum history: \($0)" }
        }
        if stopped {
            out.append("stopped: not every file was checked")
        }
        return out
    }
}

struct CopyVerifyError: Error, CustomStringConvertible {
    let description: String
}

enum CopyVerifier {
    /// Size of the one read buffer shared by every file.
    static let chunkBytes = 8 << 20
    static let noHistory = "no checksum history (not a verified copy)"

    /// `folder`: a card folder made by `a-card offload` (take folders inside) or a single take folder.
    static func verify(_ folder: URL, progress: @escaping (String) -> Void = { _ in },
                       isCancelled: @escaping () -> Bool = { false }) throws -> CopyVerifyResult {
        let takes = try takeFolders(folder)
        var result = CopyVerifyResult(folder: folder)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkBytes, alignment: 4096)
        defer { buffer.deallocate() }
        for take in takes {
            if isCancelled() {
                result.stopped = true
                break
            }
            guard isDirectory(take.appendingPathComponent("ascmhl")) else {
                result.takes.append(VerifiedTake(name: take.lastPathComponent, problems: [noHistory]))
                continue
            }
            let (checked, stopped) = verifyTake(take, buffer: buffer, progress: progress, isCancelled: isCancelled)
            result.takes.append(checked)
            if stopped {
                result.stopped = true
                break
            }
        }
        return result
    }

    /// `folder` itself when it has an ascmhl/ history or is named like a take, otherwise its
    /// subfolders that have one or are named like a take (AC + 6 digits), sorted by name.
    static func takeFolders(_ folder: URL) throws -> [URL] {
        guard isDirectory(folder) else {
            throw CopyVerifyError(description: "\(folder.path) is not a folder")
        }
        if isDirectory(folder.appendingPathComponent("ascmhl")) || looksLikeTake(folder.lastPathComponent) {
            return [folder]
        }
        let takes = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            .filter { !$0.hasPrefix(".") }
            .map { folder.appendingPathComponent($0) }
            .filter { isDirectory($0) && (isDirectory($0.appendingPathComponent("ascmhl")) || looksLikeTake($0.lastPathComponent)) }
        guard !takes.isEmpty else {
            throw CopyVerifyError(description: "\(folder.path) holds no take folder: neither it nor any folder in it has an ascmhl/ checksum history")
        }
        return takes
    }

    /// AC + 6 digits, as the camera names takes.
    static func looksLikeTake(_ name: String) -> Bool {
        name.count == 8 && name.hasPrefix("AC") && name.dropFirst(2).allSatisfy { ("0"..."9").contains($0) }
    }

    /// Checks one take folder with an ascmhl/ subfolder; `stopped` when cancelled part-way.
    static func verifyTake(_ folder: URL, buffer: UnsafeMutableRawBufferPointer,
                           progress: (String) -> Void, isCancelled: () -> Bool) -> (take: VerifiedTake, stopped: Bool) {
        var take = VerifiedTake(name: folder.lastPathComponent)
        let expected = expectedHashes(folder, problems: &take.problems)
        let paths = expected.keys.sorted()
        let started = Date()
        var lastReport = Date.distantPast
        for (i, path) in paths.enumerated() {
            if isCancelled() {
                return (take, true)
            }
            let full = folder.appendingPathComponent(path).path
            var st = stat()
            if lstat(full, &st) != 0 && errno == ENOENT {
                take.missing.append(path)
                continue
            }
            do {
                let (hash, length) = try hashFile(full, buffer: buffer)
                take.files += 1
                take.bytes += length
                if hash != expected[path] {
                    take.mismatched.append(path)
                }
            } catch {
                take.problems.append("\(path) could not be read: \(error)")
            }
            if i + 1 == paths.count || Date().timeIntervalSince(lastReport) >= 1 {
                lastReport = Date()
                let mbps = Double(take.bytes) / 1_000_000 / max(Date().timeIntervalSince(started), 0.001)
                progress(String(format: "verify-copy %@  %5d/%d files  %.0f MB/s", take.name, i + 1, paths.count, mbps))
            }
        }
        take.unlisted = filesOnDisk(folder).filter { expected[$0] == nil }.sorted()
        return (take, false)
    }

    /// Path → xxHash64 from the latest generation listing it. Generations come from the chain in
    /// sequence order; a manifest that is missing, changed (C4), unreadable or not in the chain is
    /// a problem.
    static func expectedHashes(_ folder: URL, problems: inout [String]) -> [String: UInt64] {
        let ascmhl = folder.appendingPathComponent("ascmhl")
        let chainURL = ascmhl.appendingPathComponent("ascmhl_chain.xml")
        var chain: [(sequence: Int, path: String, c4: String)] = []
        if !FileManager.default.fileExists(atPath: chainURL.path) {
            problems.append("ascmhl/ascmhl_chain.xml is missing")
        } else {
            do {
                chain = try ASCMHL.readChain(chainURL).sorted { $0.sequence < $1.sequence }
                if chain.isEmpty {
                    problems.append("ascmhl/ascmhl_chain.xml lists no generation")
                }
            } catch {
                problems.append("ascmhl/ascmhl_chain.xml is unreadable: \(error.localizedDescription)")
            }
        }
        let onDisk = Set(((try? FileManager.default.contentsOfDirectory(atPath: ascmhl.path)) ?? [])
            .filter { $0.hasSuffix(".mhl") })
        for name in onDisk.subtracting(chain.map { $0.path }).sorted() {
            problems.append("ascmhl/\(name) is not in the chain")
        }
        var expected: [String: UInt64] = [:]
        for generation in chain {
            let name = "ascmhl/\(generation.path)"
            let url = ascmhl.appendingPathComponent(generation.path)
            autoreleasepool {
                guard let data = try? Data(contentsOf: url) else {
                    problems.append("\(name) is missing or unreadable")
                    return
                }
                if ASCMHL.c4(data) != generation.c4 {
                    problems.append("\(name) changed since it was written (its C4 id differs from the chain)")
                }
                do {
                    for entry in try ASCMHL.readGeneration(url) {
                        expected[entry.path] = entry.xxh64
                    }
                } catch {
                    problems.append("\(error)")
                }
            }
        }
        return expected
    }

    /// xxHash64 and length of the file, read in chunks into `buffer` past the file cache, so the
    /// bytes come from the disk.
    static func hashFile(_ path: String, buffer: UnsafeMutableRawBufferPointer) throws -> (hash: UInt64, length: Int64) {
        var hasher = XXHash64()
        let length = try FileIO.stream(path, through: buffer) { hasher.update($0) }
        return (hasher.digest(), length)
    }

    /// Regular files under `folder`, relative and '/'-separated, without ascmhl/ and hidden files.
    static func filesOnDisk(_ folder: URL) -> [String] {
        guard let walk = FileManager.default.enumerator(atPath: folder.path) else {
            return []
        }
        var out: [String] = []
        while let relative = walk.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            if relative == "ascmhl" || name.hasPrefix(".") {
                walk.skipDescendants()
                continue
            }
            if walk.fileAttributes?[.type] as? FileAttributeType == .typeRegular {
                out.append(relative)
            }
        }
        return out
    }

    static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }
}
