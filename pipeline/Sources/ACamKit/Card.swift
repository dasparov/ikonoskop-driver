// A mounted A-Cam dII card as the driver presents it: IMAGE/<take>/<frame>.DNG.
import Foundation

struct FrameFile {
    let name: String
    let url: URL
    let size: Int
}

struct TakeFolder {
    let name: String
    let url: URL
    let frames: [FrameFile]
}

struct CardVolume {
    let url: URL
    /// Volume name, e.g. "ACAM 102".
    let name: String
    let takes: [TakeFolder]
    /// Files found outside IMAGE/ (the driver creates CLIP, VIDEO, AUDIO, ICON, PROXY empty).
    let unexpectedFiles: [String]

    static func open(_ url: URL) throws -> CardVolume {
        let fm = FileManager.default
        let image = url.appendingPathComponent("IMAGE")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: image.path, isDirectory: &isDir), isDir.boolValue else {
            throw TIFFError("\(url.path) has no IMAGE folder: not an A-Cam card")
        }
        var takes: [TakeFolder] = []
        for takeName in try visibleNames(in: image) {
            let takeURL = image.appendingPathComponent(takeName)
            guard fm.fileExists(atPath: takeURL.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            var frames: [FrameFile] = []
            for name in try visibleNames(in: takeURL) where name.uppercased().hasSuffix(".DNG") {
                let fileURL = takeURL.appendingPathComponent(name)
                let size = try fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int ?? 0
                frames.append(FrameFile(name: name, url: fileURL, size: size))
            }
            takes.append(TakeFolder(name: takeName, url: takeURL, frames: frames))
        }
        var unexpected: [String] = []
        for top in try visibleNames(in: url) where top != "IMAGE" {
            let topURL = url.appendingPathComponent(top)
            if fm.fileExists(atPath: topURL.path, isDirectory: &isDir), isDir.boolValue {
                unexpected += try visibleNames(in: topURL).map { "\(top)/\($0)" }
            } else {
                unexpected.append(top)
            }
        }
        return CardVolume(url: url, name: url.lastPathComponent, takes: takes, unexpectedFiles: unexpected)
    }

    private static func visibleNames(in url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }
}

/// Per-frame metadata from a DNG header.
struct FrameHeader {
    /// FrameRate tag, e.g. 24/1, 2997/100.
    let frameRate: (Int64, Int64)
    let timecode: Timecode?
    let reelName: String?
    let monochrome: Bool

    static let headerBytes = 0x1000

    init(_ header: Data) throws {
        let tiff = try TIFFHeader(header.prefix(FrameHeader.headerBytes))
        frameRate = tiff.rationals(DNGTag.frameRate)?.first ?? (0, 1)
        if let e = tiff.entry(DNGTag.timeCodes), e.count >= 8, let v = tiff.value(e) {
            timecode = Timecode(smpte: [UInt8](v.prefix(8)))
        } else {
            timecode = nil
        }
        reelName = tiff.ascii(DNGTag.reelName)
        monochrome = tiff.uint(DNGTag.photometricInterpretation) == 34892
    }

    var fps: Double {
        frameRate.1 == 0 ? 0 : Double(frameRate.0) / Double(frameRate.1)
    }

    /// Timecode frames per second: 24 for 23.976, 30 for 29.97.
    var timecodeFPS: Int {
        max(Int(fps.rounded()), 1)
    }
}
