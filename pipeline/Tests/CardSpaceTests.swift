import Foundation

func cardSpaceTests(_ t: TestContext) throws {
    // Card ACAM 102 (80 GB): the driver's volume has 196,176,947 sectors; the FPGA reports
    // FLASH_SIZE 0x12c0000 pages of 4 KiB.
    t.expectEqual(CardSpace.flashBytes(volumeBytes: 196_176_947 * 512) / 0x1000, 0x12c0000, "flash pages from the volume")

    // Its take table starts the 9 takes at these erase blocks: each take starts on a new block.
    let frames = [2763, 1984, 1975, 781, 720, 993, 4432, 420, 572]
    var starts: [Int64] = []
    var at: Int64 = 0
    for f in frames {
        starts.append(at)
        at += CardSpace.usedBytes(takeFrames: [f]) / CardSpace.eraseBlockBytes
    }
    t.expectEqual(starts, [0, 222, 382, 541, 604, 662, 742, 1098, 1132], "first blocks as in the take table")
    t.expectEqual(CardSpace.usedBytes(takeFrames: frames) / CardSpace.eraseBlockBytes, 1178, "blocks used")
}
