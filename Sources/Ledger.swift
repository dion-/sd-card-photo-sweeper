import Foundation

/// Identity of a file on a card: name, size, and modification time (whole seconds).
struct FileKey: Hashable, Sendable {
    let name: String
    let size: Int64
    let mtime: Int64
}

struct LedgerEntry: Codable {
    let name: String
    let size: Int64
    let mtime: Int64
    let assetId: String
    let importedAt: String
    /// SHA-256 of the card file, if it was hashed (only when "remove from card" is on).
    var sha256: String? = nil
}

/// Append-only JSON-lines record of every file imported so far.
/// The app only uses it from the main actor.
final class Ledger {
    static let defaultURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SDImport/ledger.jsonl")

    let url: URL
    /// name+size → known mtimes and the asset each became. Usually one per name+size.
    private var known: [NameSize: [(mtime: Int64, assetId: String)]] = [:]
    private(set) var count = 0

    private struct NameSize: Hashable { let name: String; let size: Int64 }

    init(url: URL = Ledger.defaultURL) {
        self.url = url
        load()
    }

    /// FAT and exFAT cards store local time, so the mtime macOS reports moves when the Mac's time zone changes.
    /// It counts as a match if the difference is within 2 s (FAT's resolution) of a whole number of
    /// 15-minute steps, up to 26 h. A different photo with the same name and byte count is still told apart.
    func contains(_ key: FileKey) -> Bool { assetId(for: key) != nil }

    /// The Photos asset a matching file was imported as.
    func assetId(for key: FileKey) -> String? {
        guard let known = known[NameSize(name: key.name, size: key.size)] else { return nil }
        for k in known {
            let d = abs(key.mtime - k.mtime)
            if d <= 2 { return k.assetId }
            if d <= 26 * 3600 {
                let r = d % 900
                if r <= 2 || r >= 898 { return k.assetId }
            }
        }
        return nil
    }

    func append(_ entries: [LedgerEntry]) throws {
        guard !entries.isEmpty else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for e in entries {
            out.append(try enc.encode(e))
            out.append(0x0A)
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: out)
        try h.synchronize()

        entries.forEach(insert)
    }

    private func insert(_ e: LedgerEntry) {
        known[NameSize(name: e.name, size: e.size), default: []].append((e.mtime, e.assetId))
        count += 1
    }

    private func load() {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let dec = JSONDecoder()
        for line in data.split(separator: 0x0A) {
            // A torn last line from a crash is skipped; the file it named gets imported again.
            if let e = try? dec.decode(LedgerEntry.self, from: Data(line)) {
                insert(e)
            }
        }
        // Start the next append on a fresh line, so it can't merge with a torn line.
        if data.last != 0x0A, let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data([0x0A]))
            try? h.close()
        }
    }
}
