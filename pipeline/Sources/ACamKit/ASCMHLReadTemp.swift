// TEMPORARY: replaced by ASCMHL.readGeneration from feature/verify-copy at merge.
import Foundation

extension ASCMHL {
    static func readGeneration(_ url: URL) throws -> [MHLEntry] {
        let doc = try XMLDocument(contentsOf: url)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return try doc.nodes(forXPath: "//*[local-name()='hash']").map { node in
            guard let path = try node.nodes(forXPath: "*[local-name()='path']").first as? XMLElement,
                  let hash = try node.nodes(forXPath: "*[local-name()='xxh64']").first as? XMLElement,
                  let value = hash.stringValue.flatMap({ UInt64($0, radix: 16) }),
                  let size = path.attribute(forName: "size")?.stringValue.flatMap(Int.init),
                  let modified = path.attribute(forName: "lastmodificationdate")?.stringValue.flatMap(f.date(from:)) else {
                throw FileIOError(description: "\(url.lastPathComponent): unreadable hash entry")
            }
            let hashDate = hash.attribute(forName: "hashdate")?.stringValue.flatMap(f.date(from:)) ?? modified
            return MHLEntry(path: path.stringValue ?? "", size: size, modified: modified, xxh64: value, hashDate: hashDate)
        }
    }
}
