// Whole-file reads and writes for the offload, bypassing the macOS file cache so that a
// verification read comes from the card or disk, not from memory.
import Foundation

struct FileIOError: Error, CustomStringConvertible {
    let description: String
}

enum FileIO {
    static func failure(_ what: String, _ path: String) -> FileIOError {
        FileIOError(description: "\(what) \(path): \(String(cString: strerror(errno)))")
    }

    /// Drops any cached pages of the file, so the next read goes to the device.
    static func evictCache(_ path: String) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            return
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0,
              let map = mmap(nil, Int(st.st_size), PROT_READ, MAP_SHARED, fd, 0), map != MAP_FAILED else {
            return
        }
        _ = msync(map, Int(st.st_size), MS_INVALIDATE)
        munmap(map, Int(st.st_size))
    }

    /// Reads the whole file into `buffer` (F_NOCACHE) and returns its length; fails if the file
    /// does not fit.
    static func read(_ path: String, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            throw failure("open", path)
        }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var total = 0
        while total < buffer.count {
            let n = Darwin.read(fd, buffer.baseAddress! + total, buffer.count - total)
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                throw failure("read", path)
            }
            if n == 0 {
                return total
            }
            total += n
        }
        var probe: UInt8 = 0
        if Darwin.read(fd, &probe, 1) > 0 {
            throw FileIOError(description: "\(path) is larger than \(buffer.count) bytes")
        }
        return total
    }

    /// Creates `path`, which must not exist, with `bytes` (F_NOCACHE). A partly written file is
    /// removed again.
    static func create(_ path: String, bytes: UnsafeRawBufferPointer) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else {
            throw failure("create", path)
        }
        _ = fcntl(fd, F_NOCACHE, 1)
        var done = 0
        while done < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress! + done, bytes.count - done)
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                let error = failure("write", path)
                close(fd)
                unlink(path)
                throw error
            }
            done += n
        }
        if close(fd) != 0 {
            let error = failure("close", path)
            unlink(path)
            throw error
        }
    }

    /// Asks the volume holding `path` to write everything to stable storage (F_FULLFSYNC).
    static func fullSync(_ path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            throw failure("open", path)
        }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) != 0 {
            throw failure("F_FULLFSYNC", path)
        }
    }
}
