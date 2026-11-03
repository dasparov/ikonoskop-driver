import Foundation

func xxhash64Tests(_ t: TestContext) throws {
    // Published reference values (xxhsum; python-xxhash README).
    t.expectEqual(XXHash64.hex(XXHash64.hash(Data())), "ef46db3751d8e999", "empty input")
    let phrase = Data("Nobody inspects the spammish repetition".utf8)
    t.expectEqual(XXHash64.hex(XXHash64.hash(phrase)), "fbcea83c8a378bf1", "reference phrase")

    // Streaming in uneven chunks must equal hashing in one go.
    var bytes = [UInt8](repeating: 0, count: 1_000_003)
    for i in bytes.indices {
        bytes[i] = UInt8(truncatingIfNeeded: (i &* 2_654_435_761) >> 13)
    }
    let whole = Data(bytes)
    var streaming = XXHash64()
    var offset = 0
    for size in [1, 31, 32, 33, 4_096, 65_537] + Array(repeating: 300_000, count: 4) where offset < whole.count {
        let end = min(offset + size, whole.count)
        streaming.update(whole.subdata(in: offset..<end))
        offset = end
    }
    t.expectEqual(offset, whole.count, "chunks cover the input")
    t.expectEqual(streaming.digest(), XXHash64.hash(whole), "streaming vs one-shot")
}
