import Foundation
import Photos

struct BurstPhotoMetadata: Equatable {
    let groupID: String
    let isPrimary: Bool

    init(identifier: String, isPrimary: Bool) {
        // Stable across sessions; never put PhotoKit's raw identifier in exported files.
        groupID = stableID("pixelbridge-burst-v1:" + identifier)
        self.isPrimary = isPrimary
    }
    init?(_ asset: PHAsset) {
        guard let identifier = asset.burstIdentifier, !identifier.isEmpty else { return nil }
        self.init(identifier: identifier, isPrimary: asset.representsBurst)
    }
    var fields: [String: String] {
        ["burst_group_ref": groupID, "burst_primary": String(isPrimary), "burst_metadata_version": "1"]
    }
    static func supports(_ ext: String) -> Bool {
        ["jpg", "jpeg", "heic", "heif"].contains(ext.lowercased())
    }
}

// An existing queue proof can refer to either a pre-feature original or an annotated
// delivery. Preserve those exact bytes after an uncertain transfer, even if the
// library's representative frame has since changed.
func resumableBurstPhoto(source: URL, delivery: URL, expectedHash: String?,
                         hash: (URL) async throws -> String) async throws -> URL? {
    guard let expectedHash else { return nil }
    for file in [delivery, source] where FileManager.default.fileExists(atPath: file.path) {
        try Task.checkCancellation()
        if try await hash(file) == expectedHash { return file }
    }
    return nil
}

func prepareBurstPhoto(source: URL, delivery: URL, metadata: BurstPhotoMetadata,
                       exiftool: URL, budget: Int64, expectedHash: String? = nil,
                       hash: (URL) async throws -> String) async throws -> String {
    let fm = FileManager.default
    guard source.standardizedFileURL != delivery.standardizedFileURL,
          BurstPhotoMetadata.supports(source.pathExtension) else {
        throw fail(Message(.error_format_unsupported, source.pathExtension))
    }
    let bytes = Int64((try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
    // ExifTool writes a second temporary copy; budget both copies plus XMP overhead.
    guard budget >= 65_536, bytes <= (budget - 65_536) / 2 else { throw fail(Message(.error_burst_cache_budget)) }
    let temporary = delivery.deletingLastPathComponent()
        .appendingPathComponent(".burst-" + UUID().uuidString + "." + source.pathExtension)
    defer { try? fm.removeItem(at: temporary) }
    try Task.checkCancellation()
    try fm.copyItem(at: source, to: temporary)
    _ = try await processOutput(exiftool, ["-overwrite_original", "-P",
        "-XMP-GCamera:BurstID=" + metadata.groupID,
        "-XMP-GCamera:BurstPrimary=" + (metadata.isPrimary ? "1" : "0"), "--", temporary.path])
    let output = try await processOutput(exiftool, ["-j", "-G1", "-s",
        "-XMP-GCamera:BurstID", "-XMP-GCamera:BurstPrimary", "--", temporary.path])
    guard let records = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]],
          let record = records.first,
          record["XMP-GCamera:BurstID"] as? String == metadata.groupID,
          record["XMP-GCamera:BurstPrimary"].map({ String(describing: $0) }) == (metadata.isPrimary ? "1" : "0") else {
        throw fail(Message(.error_burst_metadata))
    }
    let digest = try await hash(temporary)
    if let expectedHash, digest != expectedHash {
        // Never overwrite a possibly uploaded file with different bytes on retry.
        throw fail(Message(.error_burst_resume_changed))
    }
    try Task.checkCancellation()
    if fm.fileExists(atPath: delivery.path) {
        try fm.moveItem(at: delivery, to: delivery.appendingPathExtension("superseded-" + UUID().uuidString))
    }
    try fm.moveItem(at: temporary, to: delivery)
    return digest
}
