import Foundation

func losslessJPEGTests(_ t: TestContext) throws {
    try raw12Packing(t)
    try realFrames(t)
    try syntheticFrames(t)
    try edgeTiles(t)
    try codecCorners(t)
    try huffmanLengthLimit(t)
    try decoderRejectsBadInput(t)
}

/// Deterministic noise in 0..<limit.
private func noise(_ count: Int, limit: Int, seed: UInt64) -> [UInt16] {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt16(Int(state >> 33) % limit)
    }
}

private func roundTrip(_ samples: [UInt16], width: Int, height: Int, stride: Int? = nil, bitDepth: Int) throws -> [UInt16] {
    let encoded = samples.withUnsafeBufferPointer {
        LosslessJPEG.encode(samples: $0, width: width, height: height, stride: stride ?? width, bitDepth: bitDepth)
    }
    let decoded = try LosslessJPEG.decode(encoded)
    guard decoded.width == width && decoded.height == height else { return [] }
    return decoded.samples
}

private func tileRoundTrip(_ frame: [UInt16], width: Int, height: Int, bitDepth: Int,
                           geometry: LosslessJPEG.TileGeometry? = nil) throws -> (back: [UInt16], bytes: Int) {
    let (g, tiles) = frame.withUnsafeBufferPointer {
        LosslessJPEG.encodeTiles(frame: $0, width: width, height: height, bitDepth: bitDepth, geometry: geometry)
    }
    return (try LosslessJPEG.decodeTiles(tiles, geometry: g), tiles.reduce(0) { $0 + $1.count })
}

private func raw12Packing(_ t: TestContext) throws {
    t.expectEqual(Raw12.stripByteCount, 0x333000, "strip size")
    t.expectEqual(Raw12.unpack(Data([0xAB, 0xCD, 0xEF, 0x00, 0x0F, 0xFF])), [0xABC, 0xDEF, 0x000, 0xFFF], "MSB-first order")
    t.expectEqual(Raw12.pack([0xABC, 0xDEF, 0x000, 0xFFF]), Data([0xAB, 0xCD, 0xEF, 0x00, 0x0F, 0xFF]), "pack")
    let random = noise(10_000, limit: 4096, seed: 7)
    t.expectEqual(Raw12.unpack(Raw12.pack(random)), random, "pack/unpack random")
}

/// One frame from three takes of card 102 (bright, dark, mid-grey), found in work/samples of the
/// repository that contains the test binary.
private func sampleFrames() -> [URL] {
    var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    var card: URL?
    while dir.path != "/" && card == nil {
        let candidate = dir.appendingPathComponent("work/samples/ACAM102")
        if FileManager.default.fileExists(atPath: candidate.path) { card = candidate }
        dir = dir.deletingLastPathComponent()
    }
    guard let card else { return [] }
    return ["AC102005", "AC102007", "AC102008"].compactMap { take in
        let dir = card.appendingPathComponent(take)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".DNG") }.sorted().first.map { dir.appendingPathComponent($0) }
    }
}

private func realFrames(_ t: TestContext) throws {
    let frames = sampleFrames()
    if frames.isEmpty {
        print("  note: work/samples/ACAM102 not found, real-frame checks skipped")
        return
    }
    for url in frames {
        let name = url.lastPathComponent
        let file = try Data(contentsOf: url)
        t.expectEqual(file.count, 0x336000, "\(name) size")
        let strip = file.subdata(in: Raw12.stripOffset..<Raw12.stripOffset + Raw12.stripByteCount)
        let samples = Raw12.unpack(strip)
        t.expectEqual(Raw12.pack(samples), strip, "\(name) pack(unpack(strip))")

        // The bit order is right if the exposed area (columns 28...2019) has a black floor near
        // the header's 80-90 and same-colour neighbours are close; the wrong order is noise.
        var floor = 4095, diffSum = 0, diffCount = 0
        for y in Swift.stride(from: 100, to: 1000, by: 9) {
            for x in Swift.stride(from: 28, to: 2018, by: 1) {
                let v = Int(samples[y * 2048 + x])
                floor = min(floor, v)
                diffSum += abs(v - Int(samples[y * 2048 + x + 2]))
                diffCount += 1
            }
        }
        t.expect((60...120).contains(floor), "\(name) black floor \(floor)")
        t.expect(diffSum / diffCount < 64, "\(name) mean same-colour step \(diffSum / diffCount)")

        let (back, bytes) = try tileRoundTrip(samples, width: Raw12.width, height: Raw12.height, bitDepth: 12)
        t.expect(back == samples, "\(name) tiles decode to the original samples")
        t.expect(bytes < Raw12.stripByteCount * 7 / 10, "\(name) compressed to \(bytes) bytes")
    }
}

private func syntheticFrames(_ t: TestContext) throws {
    let w = Raw12.width, h = Raw12.height
    let g = LosslessJPEG.TileGeometry.dngDefault(width: w, height: h)
    t.expectEqual(g, LosslessJPEG.TileGeometry(imageWidth: w, imageHeight: h, tileWidth: 256, tileLength: 224),
                  "DNG SDK tile size for 2048x1092")
    t.expectEqual(g.tileCount, 40, "8 x 5 tiles")
    for (label, frame) in [("all 0", [UInt16](repeating: 0, count: w * h)),
                           ("all 4095", [UInt16](repeating: 4095, count: w * h)),
                           ("12-bit noise", noise(w * h, limit: 4096, seed: 1))] {
        let (back, bytes) = try tileRoundTrip(frame, width: w, height: h, bitDepth: 12)
        t.expect(back == frame, "\(label): exact round trip")
        if label != "12-bit noise" { t.expect(bytes < 40 * 30_000, "\(label): \(bytes) bytes") }
    }
}

private func edgeTiles(_ t: TestContext) throws {
    // Partial tiles on the right and bottom edges, with an explicit and the default geometry.
    let frame = noise(300 * 250, limit: 4096, seed: 3)
    let small = LosslessJPEG.TileGeometry(imageWidth: 300, imageHeight: 250, tileWidth: 64, tileLength: 48)
    t.expectEqual(small.tileCount, 5 * 6, "tile count")
    t.expect(try tileRoundTrip(frame, width: 300, height: 250, bitDepth: 12, geometry: small).back == frame,
             "300x250 in 64x48 tiles")
    t.expect(try tileRoundTrip(frame, width: 300, height: 250, bitDepth: 12).back == frame, "300x250 default tiles")

    // An edge tile decodes to the full tile with zero padding (DNG SDK edge_zero).
    let (g, tiles) = frame.withUnsafeBufferPointer {
        LosslessJPEG.encodeTiles(frame: $0, width: 300, height: 250, bitDepth: 12, geometry: small)
    }
    let corner = try LosslessJPEG.decode(tiles[tiles.count - 1])
    t.expectEqual(corner.width, 64, "corner tile width")
    t.expectEqual(corner.height, 48, "corner tile height")
    let validW = 300 - 4 * 64, validH = 250 - 5 * 48
    var expected = [UInt16](repeating: 0, count: 64 * 48)
    for y in 0..<validH {
        for x in 0..<validW { expected[y * 64 + x] = frame[(5 * 48 + y) * 300 + 4 * 64 + x] }
    }
    t.expect(corner.samples == expected, "corner tile = image data + zero padding")
    t.expectEqual(g.tilesAcross, 5, "tiles across")
}

private func codecCorners(_ t: TestContext) throws {
    // Odd width: one component. Tiny images. Sub-rectangle via stride.
    let odd = noise(7 * 5, limit: 4096, seed: 4)
    t.expect(try roundTrip(odd, width: 7, height: 5, bitDepth: 12) == odd, "7x5, one component")
    t.expect(try roundTrip([1234], width: 1, height: 1, bitDepth: 12) == [1234], "1x1")
    t.expect(try roundTrip([0, 4095], width: 2, height: 1, bitDepth: 12) == [0, 4095], "2x1")
    let wide = noise(40 * 10, limit: 4096, seed: 5)
    var sub: [UInt16] = []
    for y in 0..<6 { sub += wide[(y * 40 + 3)..<(y * 40 + 19)] }
    let viaStride = try wide.withUnsafeBufferPointer { p -> [UInt16] in
        let start = p.baseAddress! + 3
        let data = LosslessJPEG.encode(samples: UnsafeBufferPointer(start: start, count: 5 * 40 + 16),
                                       width: 16, height: 6, stride: 40, bitDepth: 12)
        return try LosslessJPEG.decode(data).samples
    }
    t.expect(viaStride == sub, "16x6 window with stride 40")

    // 16-bit: full-range noise and the -32768 difference (SSSS 16, no extra bits).
    let full = noise(64 * 32, limit: 65536, seed: 6)
    t.expect(try roundTrip(full, width: 64, height: 32, bitDepth: 16) == full, "16-bit noise")
    let extreme: [UInt16] = (0..<64).map { i in (i / 2) % 2 == 0 ? 0 : 32768 }
    t.expect(try roundTrip(extreme, width: 32, height: 2, bitDepth: 16) == extreme, "difference of 32768")
}

private func huffmanLengthLimit(_ t: TestContext) throws {
    // Fibonacci frequencies make an unconstrained Huffman code longer than 16 bits.
    var fib = [1, 1]
    while fib.count < 17 { fib.append(fib[fib.count - 1] + fib[fib.count - 2]) }
    let counts = Array(fib.reversed())                  // category 0 most frequent
    let table = counts.withUnsafeBufferPointer { LosslessJPEG.optimalTable($0.baseAddress!) }
    t.expectEqual(table.values.count, 17, "every used category gets a code")
    t.expectEqual(table.bits.map(Int.init).reduce(0, +), 17, "BITS adds up")
    let kraft = table.bits.enumerated().reduce(0) { $0 + Int($1.element) << (15 - $1.offset) }
    t.expect(kraft < 1 << 16, "no all-ones code (Kraft sum \(kraft))")

    // The same statistics through the codec: one column (one component, predictor = sample above)
    // whose differences fall into category s exactly counts[s] times.
    var column: [UInt16] = [32768]
    var value = 32768
    for (s, n) in counts.enumerated() {
        for k in 0..<n {
            let magnitude = s == 0 ? 0 : (s == 16 ? 32768 : 1 << (s - 1))
            value = (value + (k % 2 == 0 ? magnitude : 65536 - magnitude)) & 0xFFFF
            column.append(UInt16(value))
        }
    }
    t.expect(try roundTrip(column, width: 1, height: column.count, bitDepth: 16) == column,
             "length-limited table round trip (\(column.count) samples)")
}

private func decoderRejectsBadInput(_ t: TestContext) throws {
    let frame = noise(64 * 16, limit: 4096, seed: 8)
    let good = frame.withUnsafeBufferPointer {
        LosslessJPEG.encode(samples: $0, width: 64, height: 16, stride: 64, bitDepth: 12)
    }
    func fails(_ data: Data) -> Bool { (try? LosslessJPEG.decode(data)) == nil }
    t.expect(fails(good.prefix(good.count / 2)), "truncated data")
    t.expect(fails(good.prefix(20)), "truncated header")
    t.expect(fails(Data()), "empty")
    var baseline = good
    baseline[3] = 0xC0                                  // SOF3 -> SOF0
    t.expect(fails(baseline), "not lossless")
}
