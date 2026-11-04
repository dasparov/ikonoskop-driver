// The second copy. The offload writes the frames to both destinations as it reads the card; this
// copies the rest from the first destination once it is made: each take's WAV and clean DNGs (and
// the frames of takes an earlier run copied without a second copy), the ProRes movies and the
// colour profile files. Every file is read from the first copy, compared with its checksum where
// the take's ASC MHL history has one, written to the second destination under a temporary name,
// read back once everything is on the disk, compared, and renamed. The second take folder's
// history gets a generation listing what was copied.
import Foundation

struct SecondCopyResult {
    var files = 0
    var bytes: Int64 = 0
    var problems: [String] = []
    var warnings: [String] = []

    mutating func add(_ other: SecondCopyResult) {
        files += other.files
        bytes += other.bytes
        problems += other.problems
        warnings += other.warnings
    }
}

final class SecondCopy {
    /// The card folders in the first and the second destination.
    let first: URL
    let second: URL
    let stop: StopSignal
    var progress: (String) -> Void = { print($0) }
    private let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 8 << 20, alignment: 16_384)

    init(first: URL, second: URL, stop: StopSignal) {
        self.first = first
        self.second = second
        self.stop = stop
    }

    deinit {
        buffer.deallocate()
    }

    /// Copies what <first>/<take> lists in its checksum history and <second>/<take> lacks.
    /// Stopped, it removes the files it had not finished (and the take folder, if it made it).
    func take(_ name: String) throws -> SecondCopyResult {
        var result = SecondCopyResult()
        let source = first.appendingPathComponent(name)
        let target = second.appendingPathComponent(name)
        guard let mine = try TakeHistory.read(source) else {
            result.problems.append("\(name): the first copy has no checksum history to copy from")
            return result
        }
        let made = !FileManager.default.fileExists(atPath: target.path)
        let theirs = try TakeHistory.read(target)?.entries ?? [:]
        let missing = mine.entries.values.filter { theirs[$0.path] == nil }.sorted { $0.path < $1.path }
        guard !missing.isEmpty else {
            return result
        }
        do {
            let copied = try transfer(missing.map { ($0.path, $0.xxh64) }, from: source, to: target, label: name,
                                      result: &result)
            if !copied.isEmpty {
                try ASCMHL.addGeneration(folder: target, entries: copied, process: "transfer")
            }
        } catch let error as StoppedError {
            // What this run copied there and had not listed yet: a later run copies it again.
            if made {
                try? FileManager.default.removeItem(at: target)
            } else {
                for entry in missing {
                    unlink(target.appendingPathComponent(entry.path).path)
                }
            }
            throw error
        } catch {
            result.problems.append("\(name): \(error)")
        }
        return result
    }

    /// Copies the files below <first>/<folder> (prores/, colour/) that <second>/<folder> lacks,
    /// skipping those whose name matches `skip`.
    func folder(_ relative: String, skip: (String) -> Bool = { _ in false }) throws -> SecondCopyResult {
        var result = SecondCopyResult()
        let source = first.appendingPathComponent(relative)
        let target = second.appendingPathComponent(relative)
        guard let walker = FileManager.default.enumerator(atPath: source.path) else {
            return result
        }
        var wanted: [(String, UInt64?)] = []
        while let path = walker.nextObject() as? String {
            var isDir: ObjCBool = false
            let name = (path as NSString).lastPathComponent
            guard !name.hasPrefix("."), !skip(name),
                  FileManager.default.fileExists(atPath: source.appendingPathComponent(path).path, isDirectory: &isDir),
                  !isDir.boolValue, !FileManager.default.fileExists(atPath: target.appendingPathComponent(path).path) else {
                continue
            }
            wanted.append((path, nil))
        }
        guard !wanted.isEmpty else {
            return result
        }
        do {
            _ = try transfer(wanted.sorted { $0.0 < $1.0 }, from: source, to: target, label: relative, result: &result)
        } catch let error as StoppedError {
            throw error
        } catch {
            result.problems.append("\(relative): \(error)")
        }
        return result
    }

    /// Copies `files` (path relative to `source`, expected xxHash64 or nil) to `target`: first
    /// all of them under temporary names, then each read back and renamed. Returns the history
    /// entries of the files that arrived intact.
    private func transfer(_ files: [(path: String, expected: UInt64?)], from source: URL, to target: URL,
                          label: String, result: inout SecondCopyResult) throws -> [MHLEntry] {
        let fm = FileManager.default
        var written: [(path: String, hash: UInt64, size: Int64, modified: Date)] = []
        var partial: [String] = []
        defer {
            for path in partial {
                unlink(path)
            }
        }
        let started = Date()
        var bytes: Int64 = 0
        for (n, file) in files.enumerated() {
            try stop.check()
            let from = source.appendingPathComponent(file.path).path
            let to = target.appendingPathComponent(file.path)
            let tmp = to.path + ".acam-partial"
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            unlink(tmp) // left by a run that was stopped or crashed
            if fm.fileExists(atPath: to.path) {
                try FileIO.trash(to)
                result.warnings.append("\(label): \(file.path) in the second copy was not in its checksum history (left by a run that did not finish): it was moved to the Trash and copied again")
            }
            FileIO.evictCache(from)
            let modified = (try? fm.attributesOfItem(atPath: from)[.modificationDate] as? Date) ?? Date()
            var hasher = XXHash64()
            do {
                let writer = try FileIO.Writer(creating: tmp)
                partial.append(tmp)
                let size = try FileIO.stream(from, through: buffer) { chunk in
                    try stop.check()
                    hasher.update(chunk)
                    try writer.write(chunk)
                }
                try writer.close()
                let hash = hasher.digest()
                if let expected = file.expected, hash != expected {
                    result.problems.append("\(label): \(file.path) in the first copy no longer matches its checksum: not copied")
                    continue
                }
                written.append((file.path, hash, size, modified))
                bytes += size
            } catch let error as StoppedError {
                throw error
            } catch {
                result.problems.append("\(label): \(file.path): \(error)")
            }
            if (n + 1) % 200 == 0 || n + 1 == files.count {
                let mbps = Double(bytes) / 1_000_000 / max(Date().timeIntervalSince(started), 0.001)
                progress(String(format: "second %@  %5d/%d files  %.0f MB/s", label, n + 1, files.count, mbps))
            }
        }
        if let last = written.last {
            try FileIO.fullSync(target.appendingPathComponent(last.path).path + ".acam-partial")
        }
        var entries: [MHLEntry] = []
        for (n, file) in written.enumerated() {
            try stop.check()
            let to = target.appendingPathComponent(file.path)
            let tmp = to.path + ".acam-partial"
            FileIO.evictCache(tmp)
            var hasher = XXHash64()
            do {
                try FileIO.stream(tmp, through: buffer) { chunk in
                    hasher.update(chunk)
                }
                guard hasher.digest() == file.hash else {
                    result.problems.append("\(label): \(file.path): the second copy differs from the first")
                    continue
                }
                try fm.setAttributes([.modificationDate: file.modified], ofItemAtPath: tmp)
                guard rename(tmp, to.path) == 0 else {
                    throw FileIO.failure("rename", tmp)
                }
                partial.removeAll { $0 == tmp }
                entries.append(MHLEntry(path: file.path, size: Int(file.size), modified: file.modified,
                                        xxh64: file.hash, hashDate: Date()))
                result.files += 1
                result.bytes += file.size
            } catch {
                result.problems.append("\(label): \(file.path): \(error)")
            }
            if (n + 1) % 200 == 0 || n + 1 == written.count {
                progress(String(format: "second-check %@  %5d/%d files", label, n + 1, written.count))
            }
        }
        return entries
    }
}
