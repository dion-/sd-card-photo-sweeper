import CryptoKit
import Foundation
import Photos

/// Proves a card file and its copy in the Photos library are byte-identical before the card file is deleted.
enum Verifier {
    /// SHA-256 of a file, read in 4 MB chunks. Opens the file read-only.
    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    /// SHA-256 of the original that Photos stored for `filename` in the asset.
    /// nil if the asset or the resource is gone, or if the original isn't on this Mac.
    static func libraryHash(assetId: String, filename: String) async -> String? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject,
              let resource = PHAssetResource.assetResources(for: asset).first(where: {
                  $0.originalFilename == filename && ($0.type == .photo || $0.type == .alternatePhoto)
              })
        else { return nil }

        final class Box: @unchecked Sendable { var hasher = SHA256() } // handler calls arrive one at a time
        let box = Box()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false // only the local original counts
        let ok: Bool = await withCheckedContinuation { done in
            PHAssetResourceManager.default().requestData(
                for: resource, options: options,
                dataReceivedHandler: { box.hasher.update(data: $0) },
                completionHandler: { error in done.resume(returning: error == nil) })
        }
        return ok ? hex(box.hasher.finalize()) : nil
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
