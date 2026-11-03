// xxHash64 (XXH64) through the official implementation (pipeline/Vendor/xxhash, v0.8.3).
import Foundation

struct XXHash64 {
    private var state = XXH64_state_t()

    init(seed: UInt64 = 0) {
        XXH64_reset(&state, seed)
    }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        XXH64_update(&state, bytes.baseAddress, bytes.count)
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    func digest() -> UInt64 {
        withUnsafePointer(to: state) { XXH64_digest($0) }
    }

    static func hash(_ bytes: UnsafeRawBufferPointer, seed: UInt64 = 0) -> UInt64 {
        XXH64(bytes.baseAddress, bytes.count, seed)
    }

    static func hash(_ data: Data, seed: UInt64 = 0) -> UInt64 {
        data.withUnsafeBytes { hash($0, seed: seed) }
    }

    /// Canonical (big-endian) hex form, as xxhsum and ASC MHL write it.
    static func hex(_ value: UInt64) -> String {
        String(format: "%016llx", value)
    }
}
