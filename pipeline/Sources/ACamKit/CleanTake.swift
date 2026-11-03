// Clean DNGs for one offloaded take: <take>/frames/*.DNG -> <take>/clean/*.DNG, each one read
// back from disk and decoded to check it holds exactly the original's raw samples.
import Foundation

struct CleanResult {
    var frames = 0
    var originalBytes = 0
    var cleanBytes = 0
    var problems: [String] = []
    var manifest: URL?

    var failed: Bool { !problems.isEmpty }
    var ratio: Double { originalBytes == 0 ? 0 : Double(cleanBytes) / Double(originalBytes) }
}

enum CleanTake {
    static func run(take folder: URL, progress: @escaping (String) -> Void) throws -> CleanResult {
        let fm = FileManager.default
        let framesDir = folder.appendingPathComponent("frames")
        let cleanDir = folder.appendingPathComponent("clean")
        guard !fm.fileExists(atPath: cleanDir.path) else {
            throw FileIOError(description: "\(cleanDir.path) already exists")
        }
        let names = try fm.contentsOfDirectory(atPath: framesDir.path)
            .filter { !$0.hasPrefix(".") && $0.uppercased().hasSuffix(".DNG") }.sorted()
        try fm.createDirectory(at: cleanDir, withIntermediateDirectories: false)

        let lock = NSLock()
        var result = CleanResult()
        var entries: [MHLEntry?] = Array(repeating: nil, count: names.count)
        var done = 0
        let started = Date()
        DispatchQueue.concurrentPerform(iterations: names.count) { i in
            let name = names[i]
            let out = cleanDir.appendingPathComponent(name)
            do {
                let original = try Data(contentsOf: framesDir.appendingPathComponent(name))
                let made = try CleanDNG.make(fromOriginal: original)
                try made.dng.withUnsafeBytes { try FileIO.create(out.path, bytes: $0) }
                FileIO.evictCache(out.path)
                let readBack = try Data(contentsOf: out, options: .uncached)
                let decoded = try CleanDNG.samples(ofClean: readBack)
                lock.lock()
                defer { lock.unlock() }
                if decoded != made.samples {
                    result.problems.append("\(name): the clean DNG does not decode to the original pixels")
                } else if readBack != made.dng {
                    result.problems.append("\(name): the clean DNG on disk differs from what was written")
                } else {
                    result.originalBytes += original.count
                    result.cleanBytes += readBack.count
                    entries[i] = MHLEntry(path: "clean/\(name)", size: readBack.count, modified: Date(),
                                          xxh64: XXHash64.hash(readBack), hashDate: Date())
                }
                done += 1
                if done % 200 == 0 || done == names.count {
                    progress(String(format: "clean  %@  %5d/%d frames  %.0f frames/s", folder.lastPathComponent,
                                    done, names.count, Double(done) / max(Date().timeIntervalSince(started), 0.001)))
                }
            } catch {
                lock.lock()
                result.problems.append("\(name): \(error)")
                done += 1
                lock.unlock()
            }
        }
        result.frames = names.count
        if names.isEmpty {
            result.problems.append("no frames to clean")
        }
        if !result.failed {
            result.manifest = try ASCMHL.addGeneration(folder: folder, entries: entries.compactMap { $0 },
                                                       process: "in-place")
        }
        return result
    }
}
