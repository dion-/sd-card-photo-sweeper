import Foundation

struct CardFile: Sendable {
    let url: URL
    let key: FileKey
}

/// One Photos asset: a RAW, plus its JPEG if pairing is on.
struct ImportItem: Sendable {
    let raw: CardFile
    let jpeg: CardFile?
    var bytes: Int64 { raw.key.size + (jpeg?.key.size ?? 0) }
    var files: [CardFile] { [raw] + (jpeg.map { [$0] } ?? []) }
}

enum Scanner {
    static let rawExtensions: Set<String> = ["raf", "dng", "arw", "cr3", "nef"]
    static let jpegExtensions: Set<String> = ["jpg", "jpeg"]

    /// A removable or ejectable volume with a top-level DCIM folder.
    static func isCard(_ volume: URL) -> Bool {
        let v = try? volume.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey])
        guard (v?.volumeIsRemovable ?? false) || (v?.volumeIsEjectable ?? false) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: volume.appendingPathComponent("DCIM").path, isDirectory: &isDir)
            && isDir.boolValue
    }

    /// Walks DCIM and returns RAWs in path order, with their JPEG twins if `pairJPEG` is set.
    /// The scan only reads directory metadata. It opens no files.
    static func scan(dcim: URL, pairJPEG: Bool) -> [ImportItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: dcim, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) // hidden also drops AppleDouble "._" files
        else { return [] }

        var raws: [String: CardFile] = [:]
        var jpegs: [String: CardFile] = [:]

        for case let url as URL in walker {
            let ext = url.pathExtension.lowercased()
            let isRaw = rawExtensions.contains(ext)
            guard isRaw || (pairJPEG && jpegExtensions.contains(ext)) else { continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let size = v.fileSize, let date = v.contentModificationDate else { continue }
            let file = CardFile(url: url, key: FileKey(
                name: url.lastPathComponent,
                size: Int64(size),
                mtime: Int64(date.timeIntervalSince1970.rounded())))
            let stem = url.deletingPathExtension().path.lowercased()
            if isRaw { raws[stem] = file } else { jpegs[stem] = file }
        }

        return raws.keys.sorted().map { stem in
            ImportItem(raw: raws[stem]!, jpeg: pairJPEG ? jpegs[stem] : nil)
        }
    }
}
