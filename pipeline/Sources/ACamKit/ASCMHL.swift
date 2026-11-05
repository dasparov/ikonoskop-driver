// ASC MHL v2.0 (https://github.com/ascmitc/mhl, schema xsd/ASCMHL.xsd): each folder keeps its
// history in <folder>/ascmhl/: one manifest per generation, NNNN_<folder>_<UTC time>Z.mhl, and
// ascmhl_chain.xml listing them with the C4 id of each manifest.
import CommonCrypto
import Foundation

struct MHLEntry {
    /// Relative to the folder, '/'-separated.
    let path: String
    let size: Int
    let modified: Date
    let xxh64: UInt64
    let hashDate: Date
}

struct MHLError: Error, CustomStringConvertible {
    let description: String
}

enum ASCMHL {
    static let toolName = "a-card"

    /// Writes the next generation for `folder` and adds it to the chain. `process` is "transfer"
    /// for copies, "in-place" for files created in the folder.
    @discardableResult
    static func addGeneration(folder: URL, entries: [MHLEntry], process: String, created: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let dir = folder.appendingPathComponent("ascmhl")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let chainURL = dir.appendingPathComponent("ascmhl_chain.xml")
        var chain = fm.fileExists(atPath: chainURL.path) ? try readChain(chainURL) : []
        let generation = (chain.map { $0.sequence }.max() ?? 0) + 1
        let name = String(format: "%04d_%@_%@Z.mhl", generation, folder.lastPathComponent, fileStamp(created))
        let manifestURL = dir.appendingPathComponent(name)
        let manifest = Data(manifestXML(entries: entries, process: process, created: created).utf8)
        try manifest.write(to: manifestURL, options: .withoutOverwriting)
        chain.append((generation, name, c4(manifest)))
        try Data(chainXML(chain).utf8).write(to: chainURL, options: .atomic)
        return manifestURL
    }

    static func manifestXML(entries: [MHLEntry], process: String, created: Date) -> String {
        var x = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">
          <creatorinfo>
            <creationdate>\(dateTime(created))</creationdate>
            <hostname>\(escape(hostName))</hostname>
            <tool version="\(acamVersion)">\(toolName)</tool>
          </creatorinfo>
          <processinfo>
            <process>\(process)</process>
            <ignore>
              <pattern>.DS_Store</pattern>
              <pattern>ascmhl</pattern>
              <pattern>ascmhl/</pattern>
            </ignore>
          </processinfo>
          <hashes>

        """
        for e in entries {
            x += """
                <hash>
                  <path size="\(e.size)" lastmodificationdate="\(dateTime(e.modified))">\(escape(e.path))</path>
                  <xxh64 action="original" hashdate="\(dateTime(e.hashDate))">\(XXHash64.hex(e.xxh64))</xxh64>
                </hash>

            """
        }
        x += """
          </hashes>
        </hashlist>

        """
        return x
    }

    /// Every <hash> of one generation file, in file order: path, size, lastmodificationdate (as
    /// `modified`), xxh64 and its hashdate.
    static func readGeneration(_ url: URL) throws -> [MHLEntry] {
        let name = url.lastPathComponent
        let doc: XMLDocument
        do {
            doc = try XMLDocument(contentsOf: url)
        } catch {
            throw MHLError(description: "\(name) is unreadable: \(error.localizedDescription)")
        }
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.timeZone = TimeZone(identifier: "UTC")
        dates.dateFormat = dateTimeFormat
        return try doc.nodes(forXPath: "//*[local-name()='hash']").map { hash in
            guard let pathNode = try hash.nodes(forXPath: "*[local-name()='path']").first as? XMLElement,
                  let path = pathNode.stringValue, !path.isEmpty else {
                throw MHLError(description: "\(name) has an entry without a path")
            }
            guard let size = pathNode.attribute(forName: "size")?.stringValue.flatMap(Int.init),
                  let modified = pathNode.attribute(forName: "lastmodificationdate")?.stringValue.flatMap({ dates.date(from: $0) }) else {
                throw MHLError(description: "\(name): missing or invalid size or lastmodificationdate for \(path)")
            }
            guard let xxh64 = try hash.nodes(forXPath: "*[local-name()='xxh64']").first as? XMLElement,
                  let hex = xxh64.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), hex.count == 16,
                  let value = UInt64(hex, radix: 16) else {
                throw MHLError(description: "\(name): missing or invalid xxh64 for \(path)")
            }
            guard let hashDate = xxh64.attribute(forName: "hashdate")?.stringValue.flatMap({ dates.date(from: $0) }) else {
                throw MHLError(description: "\(name): missing or invalid hashdate for \(path)")
            }
            return MHLEntry(path: path, size: size, modified: modified, xxh64: value, hashDate: hashDate)
        }
    }

    // ---- chain -----------------------------------------------------------------------------

    static func readChain(_ url: URL) throws -> [(sequence: Int, path: String, c4: String)] {
        let doc = try XMLDocument(contentsOf: url)
        return try doc.nodes(forXPath: "//*[local-name()='hashlist']").compactMap { node in
            guard let element = node as? XMLElement,
                  let seq = element.attribute(forName: "sequencenr")?.stringValue.flatMap(Int.init),
                  let path = try element.nodes(forXPath: "*[local-name()='path']").first?.stringValue,
                  let c4 = try element.nodes(forXPath: "*[local-name()='c4']").first?.stringValue else {
                return nil
            }
            return (seq, path, c4)
        }
    }

    static func chainXML(_ chain: [(sequence: Int, path: String, c4: String)]) -> String {
        var x = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ascmhldirectory xmlns="urn:ASC:MHL:DIRECTORY:v2.0">

        """
        for g in chain.sorted(by: { $0.sequence < $1.sequence }) {
            x += """
              <hashlist sequencenr="\(g.sequence)">
                <path>\(escape(g.path))</path>
                <c4>\(g.c4)</c4>
              </hashlist>

            """
        }
        x += "</ascmhldirectory>\n"
        return x
    }

    /// C4 id (SMPTE ST 2114): "c4" + base58 of the SHA-512 digest, left-padded with '1' to 90 chars.
    static func c4(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA512($0.baseAddress, CC_LONG($0.count), &digest) }
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        var number = digest // big-endian base-256 digits
        var out: [Character] = []
        while number.contains(where: { $0 != 0 }) {
            var remainder = 0
            for i in number.indices {
                let acc = remainder * 256 + Int(number[i])
                number[i] = UInt8(acc / 58)
                remainder = acc % 58
            }
            out.append(alphabet[remainder])
        }
        let encoded = String(out.reversed())
        return "c4" + String(repeating: "1", count: max(88 - encoded.count, 0)) + encoded
    }

    // ---- formatting ------------------------------------------------------------------------

    /// How `dateTime(_:)` writes dates, in UTC.
    static let dateTimeFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"

    static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = dateTimeFormat
        return f.string(from: date)
    }

    static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: date)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static var hostName: String {
        var buf = [CChar](repeating: 0, count: 256)
        gethostname(&buf, buf.count)
        return String(cString: buf)
    }
}
