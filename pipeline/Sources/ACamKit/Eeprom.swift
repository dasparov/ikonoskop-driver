// The card's metadata EEPROM (take table), read with `sudo tools/ikctl eeprom 0 0x2000`.
//
// Layout (core/ik_core.cpp, eeprom_*): u16 version at 0 (0xffff: blank, 0: no card), u16 card
// number at 2, take entries of 0x14 bytes from 0x18, at most 0x198. Entry: [0] 1 = valid,
// [1] frame-rate code (bits 0-6) | tungsten (bit 7), u16 first erase block at 2, u16 frames at 4,
// u32 timecode at 6, u32 creation time at 10, u16 sensor word at 14, u32 aux timecode at 16.
// All little-endian. The driver lists only the consecutive valid entries from the first one.
import Foundation

struct EepromTake: Equatable {
    /// Entry index in the table (0-based); the driver names take i+1's folder AC<card><i+1>.
    let index: Int
    let frames: Int
    let firstBlock: Int
    let frameRateCode: Int
    let tungsten: Bool
    let monochrome: Bool
    /// Creation time as stored: FAT time << 16 | FAT date.
    let created: UInt32

    /// Orders takes by creation time (FAT date before time).
    var createdKey: UInt32 { (created & 0xffff) << 16 | created >> 16 }

    /// "2019-12-04 13:16"
    var createdText: String {
        let t = created >> 16, d = created & 0xffff
        return String(format: "%04d-%02d-%02d %02d:%02d", 1980 + Int(d >> 9), Int((d >> 5) & 15), Int(d & 31),
                      Int(t >> 11), Int((t >> 5) & 63))
    }
}

struct EepromImage {
    static let size = 0x2000
    static let takeTable = 0x18
    static let entryBytes = 0x14
    static let maxTakes = 0x198

    let bytes: [UInt8]

    init(bytes: [UInt8]) throws {
        guard bytes.count == EepromImage.size else {
            throw TIFFError("EEPROM image has \(bytes.count) bytes, want \(EepromImage.size)")
        }
        self.bytes = bytes
    }

    /// Parses the hex dump printed by `ikctl eeprom 0 0x2000`: "000010  0a 0b ...  |....|".
    static func parseHexDump(_ text: String) throws -> EepromImage {
        var bytes = [UInt8](repeating: 0, count: size)
        var seen = Set<Int>()
        for line in text.split(separator: "\n") {
            let hexPart = line.split(separator: "|", maxSplits: 1).first ?? ""
            let fields = hexPart.split(separator: " ")
            guard let first = fields.first, first.count == 6, let base = Int(first, radix: 16) else {
                continue
            }
            for (i, field) in fields.dropFirst().enumerated() {
                guard field.count == 2, let v = UInt8(field, radix: 16) else {
                    throw TIFFError("bad hex byte '\(field)' at 0x\(String(base + i, radix: 16))")
                }
                guard base + i < size else {
                    throw TIFFError("hex dump goes past 0x\(String(size, radix: 16))")
                }
                bytes[base + i] = v
                seen.insert(base + i)
            }
        }
        guard seen.count == size else {
            throw TIFFError("hex dump covers \(seen.count) of \(size) EEPROM bytes")
        }
        return try EepromImage(bytes: bytes)
    }

    private func u16(_ at: Int) -> Int {
        Int(bytes[at]) | Int(bytes[at + 1]) << 8
    }

    var version: Int { u16(0) }
    var cardNumber: Int { u16(2) % 1000 }

    /// Every valid entry in the table, including any after a gap (which the driver skips).
    var validTakes: [EepromTake] {
        (0..<EepromImage.maxTakes).compactMap { i in
            let e = EepromImage.takeTable + i * EepromImage.entryBytes
            guard bytes[e] == 1 else {
                return nil
            }
            return EepromTake(index: i, frames: u16(e + 4), firstBlock: u16(e + 2),
                              frameRateCode: Int(bytes[e + 1] & 0x7f), tungsten: bytes[e + 1] & 0x80 != 0,
                              monochrome: u16(e + 14) & 0xf == 0xe,
                              created: UInt32(u16(e + 10)) | UInt32(u16(e + 12)) << 16)
        }
    }

    /// Number of valid entries before the first invalid one: the takes the driver lists.
    var listedCount: Int {
        (0..<EepromImage.maxTakes).first { bytes[EepromImage.takeTable + $0 * EepromImage.entryBytes] != 1 }
            ?? EepromImage.maxTakes
    }

    /// Folder name the driver gives the take of entry `index`.
    func folderName(index: Int) -> String {
        String(format: "AC%03d%03d", cardNumber, index + 1)
    }
}
