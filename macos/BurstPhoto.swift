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
    // Some Photos exports contain multiple standard XMP APP1 segments. ExifTool
    // silently leaves those unchanged; -m would rewrite them but discard region
    // metadata. Add the two burst fields to every existing packet instead.
    let patched = try supplementBurstJPEGPackets(at: temporary, metadata: metadata, onlyMultiple: true)
    if !patched {
        _ = try await processOutput(exiftool, ["-overwrite_original", "-P",
            "-XMP-GCamera:BurstID=" + metadata.groupID,
            "-XMP-GCamera:BurstPrimary=" + (metadata.isPrimary ? "1" : "0"), "--", temporary.path])
    }
    var output = try await processOutput(exiftool, ["-j", "-G1", "-s",
        "-XMP-GCamera:BurstID", "-XMP-GCamera:BurstPrimary", "--", temporary.path])
    if !burstMetadataMatches(output, metadata: metadata) && !patched {
        if try supplementBurstJPEGPackets(at: temporary, metadata: metadata, onlyMultiple: false) {
            output = try await processOutput(exiftool, ["-j", "-G1", "-s",
                "-XMP-GCamera:BurstID", "-XMP-GCamera:BurstPrimary", "--", temporary.path])
        }
    }
    guard burstMetadataMatches(output, metadata: metadata) else {
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

private func burstMetadataMatches(_ output: String, metadata: BurstPhotoMetadata) -> Bool {
    guard let records = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]],
          let record = records.first else { return false }
    return record["XMP-GCamera:BurstID"] as? String == metadata.groupID &&
        record["XMP-GCamera:BurstPrimary"].map { String(describing: $0) } == (metadata.isPrimary ? "1" : "0")
}

// JPEG APP1 is length-prefixed. Replacing only the XMP packets preserves every
// existing EXIF, ICC and XMP byte, plus the compressed image data. The output
// is written to an independent delivery copy, never to the PhotoKit original.
private func supplementBurstJPEGPackets(at file: URL, metadata: BurstPhotoMetadata,
                                        onlyMultiple: Bool) throws -> Bool {
    guard ["jpg", "jpeg"].contains(file.pathExtension.lowercased()) else { return false }
    let bytes = try Data(contentsOf: file)
    guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { return false }
    let prefix = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
    let close = Data("</rdf:RDF>".utf8)
    let primary = metadata.isPrimary ? "1" : "0"
    let fragment = Data((" <rdf:Description rdf:about='' xmlns:GCamera='http://ns.google.com/photos/1.0/camera/'>\n" +
        "  <GCamera:BurstID>\(metadata.groupID)</GCamera:BurstID>\n" +
        "  <GCamera:BurstPrimary>\(primary)</GCamera:BurstPrimary>\n" +
        " </rdf:Description>\n").utf8)
    var replacements: [(Range<Int>, Data)] = []
    var offset = 2
    while offset + 4 <= bytes.count {
        guard bytes[offset] == 0xff else { throw fail(Message(.error_burst_metadata)) }
        let start = offset
        while offset < bytes.count && bytes[offset] == 0xff { offset += 1 }
        guard offset < bytes.count else { throw fail(Message(.error_burst_metadata)) }
        let marker = bytes[offset]
        offset += 1
        if marker == 0xda { break } // start of compressed image data
        if marker == 0xd8 || marker == 0xd9 || marker == 0x01 || (0xd0...0xd7).contains(marker) { continue }
        guard offset + 2 <= bytes.count else { throw fail(Message(.error_burst_metadata)) }
        let length = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
        guard length >= 2, length <= bytes.count - offset else { throw fail(Message(.error_burst_metadata)) }
        let end = offset + length
        let packetStart = offset + 2
        if marker == 0xe1 && end - packetStart >= prefix.count &&
           bytes.subdata(in: packetStart..<(packetStart + prefix.count)) == prefix {
            let packet = bytes.subdata(in: (packetStart + prefix.count)..<end)
            guard packet.range(of: Data("GCamera:BurstID".utf8)) == nil,
                  let closing = packet.range(of: close, options: .backwards) else {
                throw fail(Message(.error_burst_metadata))
            }
            var updated = Data()
            updated.append(prefix)
            updated.append(packet.subdata(in: 0..<closing.lowerBound))
            updated.append(fragment)
            updated.append(packet.subdata(in: closing.lowerBound..<packet.count))
            let newLength = updated.count + 2
            guard newLength <= Int(UInt16.max) else { throw fail(Message(.error_burst_metadata)) }
            var replacement = Data(bytes.subdata(in: start..<offset))
            replacement.append(UInt8(newLength >> 8))
            replacement.append(UInt8(newLength & 0xff))
            replacement.append(updated)
            replacements.append((start..<end, replacement))
        }
        offset = end
    }
    guard replacements.count >= (onlyMultiple ? 2 : 1) else { return false }
    let modificationDate = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    var output = Data()
    var copied = 0
    for (range, replacement) in replacements {
        output.append(bytes.subdata(in: copied..<range.lowerBound))
        output.append(replacement)
        copied = range.upperBound
    }
    output.append(bytes.subdata(in: copied..<bytes.count))
    try output.write(to: file, options: .atomic)
    if let modificationDate { try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: file.path) }
    return true
}
