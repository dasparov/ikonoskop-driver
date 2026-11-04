// What a run will do, worked out before anything is written: which takes it copies, which takes
// a card folder from an earlier run already holds, which outputs those still lack, unfinished
// leftovers, and whether each destination has room. CardJob.run refuses a run that does not fit;
// the app shows the same plan before the run starts.
import Foundation

/// The outputs a run makes from each take's verified copies.
enum Output: Hashable {
    case audio, clean, prores(ProResLook)
}

/// A take folder's ASC MHL history: the newest entry of every file any generation lists.
struct TakeHistory {
    let entries: [String: MHLEntry]

    /// nil when the folder has no history (no ascmhl/ascmhl_chain.xml, or an empty one).
    static func read(_ takeFolder: URL) throws -> TakeHistory? {
        let dir = takeFolder.appendingPathComponent("ascmhl")
        let chainURL = dir.appendingPathComponent("ascmhl_chain.xml")
        guard FileManager.default.fileExists(atPath: chainURL.path) else {
            return nil
        }
        let chain = try ASCMHL.readChain(chainURL).sorted { $0.sequence < $1.sequence }
        guard !chain.isEmpty else {
            return nil
        }
        var entries: [String: MHLEntry] = [:]
        for generation in chain {
            for e in try ASCMHL.readGeneration(dir.appendingPathComponent(generation.path)) {
                entries[e.path] = e
            }
        }
        return TakeHistory(entries: entries)
    }

    /// Whether frames/ holds exactly the card take's files, by name and size.
    func lists(_ take: TakeFolder) -> Bool {
        entries.keys.filter { $0.hasPrefix("frames/") }.count == take.frames.count
            && take.frames.allSatisfy { entries["frames/\($0.name)"]?.size == $0.size }
    }

    /// The WAV and clean DNGs are listed once they were finished and checked.
    func has(_ output: Output, take: String) -> Bool {
        switch output {
        case .audio: return entries["\(take)_Audio.wav"] != nil
        case .clean: return entries.keys.contains { $0.hasPrefix("clean/") }
        case .prores: return false
        }
    }
}

/// A take that an earlier run copied and verified, as found in its card folder.
struct KeptTake {
    let history: TakeHistory
    let firstHeader: FrameHeader?
    let lastHeader: FrameHeader?
    /// xxHash64 of the copy's first frame without its 4 KiB header (for the first-frames check).
    let firstFrameRawHash: UInt64?
    /// The copy's first frame no longer matching its checksum, and the like.
    let problems: [String]
}

/// A card folder that an earlier run left at a destination, compared with the card.
struct ExistingCopy {
    enum State {
        /// A verified copy of the card's take: kept as it is.
        case copied(KeptTake)
        /// A take folder without checksum history: a copy that never finished. It goes to the
        /// Trash and the take is copied again.
        case unfinished
        /// Something else: another recording under the same name, or an unreadable history.
        case conflict(String)
    }

    let folder: URL
    /// Take folders found in it, by take name.
    let takes: [String: State]
    /// Take folders in it that are not on the card (from an earlier recording on this card).
    let foreign: [String]

    var copied: [String: KeptTake] {
        takes.compactMapValues { if case .copied(let k) = $0 { return k } else { return nil } }
    }

    /// nil when `folder` does not exist. Reads each copied take's first frame from the card and
    /// from the copy: a copy of the same recording has the same header and nearly all the same
    /// image bytes (the card sometimes returns a few bytes differently, see Offload), another
    /// recording only a fraction of them.
    static func survey(_ folder: URL, card: CardVolume) throws -> ExistingCopy? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir) else {
            return nil
        }
        guard isDir.boolValue else {
            throw FileIOError(description: "\(folder.path) is a file, not a card folder")
        }
        let size = max(card.takes.flatMap { $0.frames.map { $0.size } }.max() ?? 0, FrameHeader.headerBytes)
        let a = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 16_384)
        let b = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 16_384)
        defer {
            a.deallocate()
            b.deallocate()
        }
        var takes: [String: State] = [:]
        for take in card.takes {
            let url = folder.appendingPathComponent(take.name)
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                continue
            }
            guard isDir.boolValue else {
                takes[take.name] = .conflict("\(take.name) there is a file, not a take folder")
                continue
            }
            let history: TakeHistory?
            do {
                history = try TakeHistory.read(url)
            } catch {
                takes[take.name] = .conflict("the checksum history of \(take.name) cannot be read (\(error))")
                continue
            }
            guard let history = history else {
                takes[take.name] = .unfinished
                continue
            }
            guard history.lists(take), let first = take.frames.first, let last = take.frames.last,
                  let expected = history.entries["frames/\(first.name)"]?.xxh64 else {
                takes[take.name] = .conflict("\(take.name) there holds other frames than the card's \(take.name)")
                continue
            }
            let frames = url.appendingPathComponent("frames")
            let copyFirst = frames.appendingPathComponent(first.name).path
            let cardLength = try FileIO.read(first.url.path, into: a)
            FileIO.evictCache(copyFirst)
            let copyLength: Int
            do {
                copyLength = try FileIO.read(copyFirst, into: b)
            } catch {
                takes[take.name] = .conflict("the copy of \(take.name)'s first frame cannot be read (\(error))")
                continue
            }
            let copy = UnsafeRawBufferPointer(rebasing: b[0..<copyLength])
            guard sameRecording(UnsafeRawBufferPointer(rebasing: a[0..<cardLength]), copy) else {
                takes[take.name] = .conflict("\(take.name) there is another recording than the card's \(take.name)")
                continue
            }
            var problems: [String] = []
            if XXHash64.hash(copy) != expected {
                problems.append("The copy of its first frame no longer matches its checksum: check the copy with Verify a copy (`acam verify`).")
            }
            let header = UnsafeMutableRawBufferPointer(rebasing: a[0..<FrameHeader.headerBytes])
            let lastLength = try? FileIO.read(frames.appendingPathComponent(last.name).path, at: 0, into: header)
            takes[take.name] = .copied(KeptTake(
                history: history,
                firstHeader: try? FrameHeader(Data(copy.prefix(FrameHeader.headerBytes))),
                lastHeader: lastLength.flatMap { try? FrameHeader(Data(bytes: header.baseAddress!, count: $0)) },
                firstFrameRawHash: copyLength > FrameHeader.headerBytes
                    ? XXHash64.hash(UnsafeRawBufferPointer(rebasing: copy[FrameHeader.headerBytes...])) : nil,
                problems: problems))
        }
        let onCard = Set(card.takes.map { $0.name })
        let foreign = try fm.contentsOfDirectory(atPath: folder.path).filter { name in
            !onCard.contains(name) && name.range(of: #"^AC[0-9]{6}$"#, options: .regularExpression) != nil
                && fm.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
        }.sorted()
        return ExistingCopy(folder: folder, takes: takes, foreign: foreign)
    }

    /// Same header (the driver writes it, it never reads differently) and more than half of the
    /// image bytes equal: two recordings share almost none, as sensor noise differs.
    static func sameRecording(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Bool {
        guard a.count == b.count, a.count > FrameHeader.headerBytes,
              memcmp(a.baseAddress!, b.baseAddress!, FrameHeader.headerBytes) == 0 else {
            return false
        }
        var equal = 0
        for i in FrameHeader.headerBytes..<a.count where a[i] == b[i] {
            equal += 1
        }
        return equal * 2 > a.count - FrameHeader.headerBytes
    }

    /// Why a run cannot add to this folder, or nil.
    func refusal(where label: String) -> String? {
        if let name = foreign.first {
            return "\(folder.path) (\(label)) holds \(name), which is not on this card: it is from another recording. Choose another folder."
        }
        for (_, state) in takes.sorted(by: { $0.key < $1.key }) {
            if case .conflict(let why) = state {
                return "\(folder.path) (\(label)): \(why). Choose another folder."
            }
        }
        return nil
    }
}

/// One run, before it starts.
struct CardPlan {
    let card: CardVolume
    /// <destination>/<card name>, and the same in the second destination.
    let cardFolder: URL
    let secondFolder: URL?
    /// The card folders an earlier run left (nil: the run makes the folder).
    let existing: ExistingCopy?
    let secondExisting: ExistingCopy?
    /// Takes copied from the card in this run, in card order.
    let copy: [TakeFolder]
    /// Of `copy`, the takes written to the second destination as they are copied (all of them,
    /// unless it already holds a verified copy).
    let copyToSecond: Set<String>
    /// Takes the destination already holds verified copies of; kept as they are.
    let kept: [String: KeptTake]
    /// The takes chosen, nil for all: outputs are made for these only.
    let chosen: Set<String>?
    /// Card takes neither copied in this run nor before.
    let notCopied: [String]
    /// Take folders of copies that never finished, moved to the Trash before copying.
    let unfinished: [URL]
    /// Outputs the run makes, per take (copied now: all; kept: those missing).
    let outputs: [String: [Output]]
    /// About how many bytes the run writes to each destination.
    let bytes: Int64
    let secondBytes: Int64

    var adding: Bool { existing != nil }

    /// Whether the run has anything to do.
    var isEmpty: Bool {
        copy.isEmpty && outputs.values.allSatisfy { $0.isEmpty } && secondBytes == 0 && unfinished.isEmpty
    }

    /// Works the run out. `card`: the card as already read (the app keeps it), or nil to read it.
    static func make(_ options: CardJobOptions, card known: CardVolume? = nil) throws -> CardPlan {
        let o = options.offload
        let card = try known ?? CardVolume.open(o.source)
        if let chosen = o.takes {
            let unknown = chosen.subtracting(card.takes.map { $0.name })
            guard !chosen.isEmpty, unknown.isEmpty else {
                throw FileIOError(description: chosen.isEmpty ? "no takes chosen"
                                  : "not on \(card.name): \(unknown.sorted().joined(separator: ", "))")
            }
        }
        let cardFolder = o.destination.appendingPathComponent(card.name)
        let secondFolder = o.secondDestination?.appendingPathComponent(card.name)
        guard let first = volumeID(o.destination) else {
            throw FileIOError(description: "\(o.destination.path) is not connected")
        }
        if let second = o.secondDestination {
            guard let other = volumeID(second) else {
                throw FileIOError(description: "\(second.path) (second copy) is not connected")
            }
            guard other != first else {
                throw FileIOError(description: "the second copy must go to another drive than the first: \(o.destination.path) and \(second.path) are on the same one")
            }
        }
        let existing = try ExistingCopy.survey(cardFolder, card: card)
        let secondExisting = try secondFolder.flatMap { try ExistingCopy.survey($0, card: card) }
        for (found, label) in [(existing, "destination"), (secondExisting, "second copy")] {
            guard let found = found else {
                continue
            }
            guard o.addToExisting else {
                throw FileIOError(description: "\(found.folder.path) already exists; choose a new destination folder, or add the missing takes to it (acam offload --add)")
            }
            if let why = found.refusal(where: label) {
                throw FileIOError(description: why)
            }
        }

        let kept = existing?.copied ?? [:]
        let secondKept = secondExisting?.copied ?? [:]
        let wanted = card.takes.filter { o.takes?.contains($0.name) ?? true }
        let copy = wanted.filter { kept[$0.name] == nil }
        let unfinished = [existing, secondExisting].compactMap { $0 }.flatMap { found in
            found.takes.compactMap { name, state -> URL? in
                if case .unfinished = state {
                    return found.folder.appendingPathComponent(name)
                }
                return nil
            }
        }.sorted { $0.path < $1.path }
        let looks = options.prores.map { Output.prores($0) }
        let all = (options.audio ? [Output.audio] : []) + (options.clean ? [.clean] : []) + looks
        var outputs: [String: [Output]] = [:]
        for take in wanted {
            guard let k = kept[take.name] else {
                outputs[take.name] = all
                continue
            }
            outputs[take.name] = all.filter { output in
                if case .prores(let look) = output {
                    return !FileManager.default.fileExists(atPath: proresURL(cardFolder, take.name, look).path)
                }
                return !k.history.has(output, take: take.name)
            }
        }

        // Bytes: the copies exactly, outputs estimated (CardSpace). The second destination also
        // gets everything the first already holds and it lacks.
        func frameBytes(_ take: TakeFolder) -> Int64 {
            Int64(take.frames.reduce(0) { $0 + $1.size })
        }
        var bytes: Int64 = 0
        for take in wanted {
            let frames = take.frames.count
            if kept[take.name] == nil {
                bytes += frameBytes(take)
            }
            let made = outputs[take.name] ?? []
            bytes += CardSpace.estimatedOutputBytes(
                frames: frames, frameFileBytes: frames > 0 ? frameBytes(take) / Int64(frames) : 0,
                audio: made.contains(.audio), clean: made.contains(.clean),
                looks: made.compactMap { if case .prores(let l) = $0 { return l } else { return nil } })
        }
        var secondBytes: Int64 = 0
        var copyToSecond: Set<String> = []
        if let secondFolder = secondFolder {
            secondBytes = bytes
            for take in copy where secondKept[take.name] != nil {
                secondBytes -= frameBytes(take)
            }
            copyToSecond = Set(copy.map { $0.name }.filter { secondKept[$0] == nil })
            for (name, k) in kept {
                let theirs = secondKept[name]?.history.entries ?? [:]
                secondBytes += k.history.entries.filter { theirs[$0.key] == nil }.reduce(Int64(0)) { $0 + Int64($1.value.size) }
                for look in ProResLook.allCases {
                    let mine = proresURL(cardFolder, name, look), other = proresURL(secondFolder, name, look)
                    if !FileManager.default.fileExists(atPath: other.path),
                       let size = try? FileManager.default.attributesOfItem(atPath: mine.path)[.size] as? Int {
                        secondBytes += Int64(size)
                    }
                }
            }
        }
        let done = Set(copy.map { $0.name }).union(kept.keys)
        return CardPlan(card: card, cardFolder: cardFolder, secondFolder: secondFolder, existing: existing,
                        secondExisting: secondExisting, copy: copy, copyToSecond: copyToSecond, kept: kept,
                        chosen: o.takes, notCopied: card.takes.map { $0.name }.filter { !done.contains($0) },
                        unfinished: unfinished, outputs: outputs, bytes: bytes, secondBytes: secondBytes)
    }

    /// Why the destinations cannot take the run, or nil. `free`, `secondFree`: free bytes on the
    /// first and second destination (nil: unknown).
    func shortfall(free: Int64?, secondFree: Int64?) -> String? {
        let what = chosen == nil ? "the card needs" : "the chosen takes need"
        if let free = free, free < bytes {
            return "Not enough space: \(cardFolder.deletingLastPathComponent().path) has \(CardPlan.size(free)) free, \(what) about \(CardPlan.size(bytes)) with these outputs."
        }
        if let second = secondFolder, let free = secondFree, free < secondBytes {
            return "Not enough space for the second copy: \(second.deletingLastPathComponent().path) has \(CardPlan.size(free)) free, it needs about \(CardPlan.size(secondBytes))."
        }
        return nil
    }

    /// <card folder>/prores/<take>_<look>.mov
    static func proresURL(_ cardFolder: URL, _ take: String, _ look: ProResLook) -> URL {
        cardFolder.appendingPathComponent("prores").appendingPathComponent("\(take)_\(look.rawValue).mov")
    }

    /// Free bytes on the volume holding `url`.
    static func freeBytes(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// The device the folder is on; nil when it does not exist (a drive not connected). Tests
    /// replace it to put two folders on "different drives".
    static var volumeID: (URL) -> dev_t? = { url in
        var st = stat()
        return stat(url.path, &st) == 0 ? st.st_dev : nil
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
