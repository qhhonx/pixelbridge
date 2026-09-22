import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

@main struct BurstPhotoTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let keep = ProcessInfo.processInfo.environment["PIXELBRIDGE_BURST_FIXTURES"]
        let root = keep.map { URL(fileURLWithPath: $0) } ?? fm.temporaryDirectory.appendingPathComponent("pixelbridge-burst-tests-" + UUID().uuidString)
        try ensureDirectory(root)
        defer { if keep == nil { try? fm.removeItem(at: root) } }
        let exiftool = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build-cache/exiftool/exiftool")
        func hash(_ file: URL) async throws -> String {
            SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        }
        func check(_ condition: Bool, _ message: String = "Burst assertion failed") { precondition(condition, message) }
        let metadata = BurstPhotoMetadata(identifier: "synthetic-burst", isPrimary: false)
        check(metadata.groupID == BurstPhotoMetadata(identifier: "synthetic-burst", isPrimary: true).groupID)
        check(metadata.groupID != BurstPhotoMetadata(identifier: "another-burst", isPrimary: false).groupID)
        check(metadata.groupID.count == 64 && !metadata.groupID.contains("synthetic"))
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for i in 0..<(64 * 64) {
            pixels[i * 4] = UInt8((i % 64) * 4)
            pixels[i * 4 + 1] = UInt8((i / 64) * 4)
            pixels[i * 4 + 2] = 128
        }
        let sample = CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
        for (ext, type) in [("jpg", UTType.jpeg), ("heic", UTType.heic)] {
            let source = root.appendingPathComponent("original." + ext)
            let destination = CGImageDestinationCreateWithURL(source as CFURL, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, sample, nil)
            check(CGImageDestinationFinalize(destination))
            let original = try Data(contentsOf: source)
            let delivery = root.appendingPathComponent("PB_fixture." + ext)
            // Simulate the old pipeline's hard link. Annotation must not mutate it.
            try fm.linkItem(at: source, to: delivery)
            let digest = try await prepareBurstPhoto(source: source, delivery: delivery, metadata: metadata,
                exiftool: exiftool, budget: 10_000_000, hash: hash)
            check(try Data(contentsOf: source) == original, "Original changed")
            check(try await hash(delivery) == digest)
            check(digest != (try await hash(source)))
            let decodedSource = CGImageSourceCreateWithURL(source as CFURL, nil)!
            let decodedCopy = CGImageSourceCreateWithURL(delivery as CFURL, nil)!
            let a = CGImageSourceCreateImageAtIndex(decodedSource, 0, nil)!
            let b = CGImageSourceCreateImageAtIndex(decodedCopy, 0, nil)!
            check(a.width == b.width && a.height == b.height)
            check(a.dataProvider!.data! as Data == b.dataProvider!.data! as Data, "Image pixels changed")
            let selected = try await resumableBurstPhoto(source: source, delivery: delivery, expectedHash: digest, hash: hash)
            check(selected == delivery)
            let legacy = try await resumableBurstPhoto(source: source, delivery: delivery, expectedHash: hash(source), hash: hash)
            check(legacy == source)
            let regenerated = root.appendingPathComponent("regenerated." + ext)
            let again = try await prepareBurstPhoto(source: source, delivery: regenerated, metadata: metadata,
                exiftool: exiftool, budget: 10_000_000, expectedHash: digest, hash: hash)
            check(again == digest, "Retry changed bytes")
            let before = try Data(contentsOf: delivery)
            do {
                _ = try await prepareBurstPhoto(source: source, delivery: delivery,
                    metadata: BurstPhotoMetadata(identifier: "synthetic-burst", isPrimary: true),
                    exiftool: exiftool, budget: 10_000_000, expectedHash: digest, hash: hash)
                preconditionFailure("Accepted changed cloud identity")
            } catch let error as BridgeFailure { check(error.message.key == .error_burst_resume_changed) }
            check(try Data(contentsOf: delivery) == before)
            print("PASS: \(ext) metadata verified, source bytes and image pixels preserved, legacy/new retries deterministic, changed proof rejected")
        }
        // Real Photos exports can contain several standard XMP APP1 packets.
        // ExifTool may report success without updating them; rewriting with -m
        // drops region metadata. Keep both packets and the image data intact.
        let duplicate = root.appendingPathComponent("duplicate-xmp.jpg")
        let rawJPEG = try Data(contentsOf: root.appendingPathComponent("original.jpg"))
        let disguisedHEIC = root.appendingPathComponent("misnamed.jpg")
        try Data([0, 0, 0, 24] + Array("ftypheic".utf8) + [0, 0, 0, 0]).write(to: disguisedHEIC)
        check(try isHEICFile(disguisedHEIC), "Missed HEIC content under JPEG filename")
        check(try !isHEICFile(root.appendingPathComponent("original.jpg")), "JPEG detected as HEIC")
        let packetText = """
            <x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'><rdf:Description rdf:about='' xmlns:mwg-rs='http://www.metadataworkinggroup.com/schemas/regions/' xmlns:stDim='http://ns.adobe.com/xap/1.0/sType/Dimensions#'><mwg-rs:Regions><mwg-rs:AppliedToDimensions rdf:parseType='Resource'><stDim:unit>pixel</stDim:unit></mwg-rs:AppliedToDimensions></mwg-rs:Regions></rdf:Description></rdf:RDF></x:xmpmeta>
            """
        let packet = Data(packetText.utf8)
        let xmpPrefix = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
        let segmentLength = packet.count + xmpPrefix.count + 2
        check(segmentLength <= Int(UInt16.max))
        var segment = Data([0xff, 0xe1, UInt8(segmentLength >> 8), UInt8(segmentLength & 0xff)])
        segment.append(xmpPrefix)
        segment.append(packet)
        var duplicated = Data(rawJPEG.prefix(2))
        duplicated.append(segment)
        duplicated.append(segment)
        duplicated.append(rawJPEG.dropFirst(2))
        try duplicated.write(to: duplicate)
        let captureTime = Date(timeIntervalSince1970: 1_786_761_701.123)
        try fm.setAttributes([.modificationDate: captureTime], ofItemAtPath: duplicate.path)
        let duplicateDelivery = root.appendingPathComponent("PB_duplicate-xmp.jpg")
        let duplicateHash = try await prepareBurstPhoto(source: duplicate, delivery: duplicateDelivery,
            metadata: metadata, exiftool: exiftool, budget: 10_000_000, hash: hash)
        let prepared = try Data(contentsOf: duplicateDelivery)
        check(try Data(contentsOf: duplicate) == duplicated, "Duplicate-XMP source changed")
        let deliveredTime = try duplicateDelivery.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        check(abs(deliveredTime.timeIntervalSince(captureTime)) < 0.01, "Capture file time changed")
        check(prepared.suffix(rawJPEG.count - 2) == rawJPEG.dropFirst(2), "Image bytes changed")
        check(prepared.range(of: packet) == nil, "Burst fields were not added to each XMP packet")
        check(try await hash(duplicateDelivery) == duplicateHash)
        let originalImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(duplicate as CFURL, nil)!, 0, nil)!
        let deliveredImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(duplicateDelivery as CFURL, nil)!, 0, nil)!
        let originalPixels = originalImage.dataProvider!.data! as Data
        let deliveredPixels = deliveredImage.dataProvider!.data! as Data
        check(originalPixels == deliveredPixels, "Duplicate-XMP pixels changed")
        let repeated = root.appendingPathComponent("PB_duplicate-xmp-retry.jpg")
        check(try await prepareBurstPhoto(source: duplicate, delivery: repeated, metadata: metadata,
            exiftool: exiftool, budget: 10_000_000, expectedHash: duplicateHash, hash: hash) == duplicateHash)
        print("PASS: duplicate XMP packets preserve image pixels and retry bytes")
        if let paths = ProcessInfo.processInfo.environment["PIXELBRIDGE_BURST_SAMPLES"] {
            for (index, path) in paths.split(separator: ":").enumerated() {
                let sample = URL(fileURLWithPath: String(path))
                let delivery = root.appendingPathComponent("real-burst-\(index)." + sample.pathExtension)
                let sourceBytes = try Data(contentsOf: sample)
                let digest = try await prepareBurstPhoto(source: sample, delivery: delivery,
                    metadata: metadata, exiftool: exiftool, budget: 20_000_000, hash: hash)
                check(try Data(contentsOf: sample) == sourceBytes, "Real burst source changed")
                check(try await hash(delivery) == digest, "Real burst hash mismatch")
                let a = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(sample as CFURL, nil)!, 0, nil)!
                let b = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(delivery as CFURL, nil)!, 0, nil)!
                let originalPixels = a.dataProvider!.data! as Data
                let deliveryPixels = b.dataProvider!.data! as Data
                check(originalPixels == deliveryPixels, "Real burst pixels changed")
                print("PASS: real burst profile \(index) source and pixels preserved")
            }
        }
        let source = root.appendingPathComponent("original.jpg"), delivery = root.appendingPathComponent("failure.jpg")
        let fake = root.appendingPathComponent("fake-exiftool")
        try "#!/bin/sh\nprintf '[{}]\\n'\n".write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        do {
            _ = try await prepareBurstPhoto(source: source, delivery: delivery, metadata: metadata,
                exiftool: fake, budget: 10_000_000, hash: hash)
            preconditionFailure("Accepted missing metadata")
        } catch let error as BridgeFailure { check(error.message.key == .error_burst_metadata) }
        check(!fm.fileExists(atPath: delivery.path))
        do {
            _ = try await prepareBurstPhoto(source: source, delivery: delivery, metadata: metadata,
                exiftool: exiftool, budget: 1, hash: hash)
            preconditionFailure("Ignored copy budget")
        } catch let error as BridgeFailure { check(error.message.key == .error_burst_cache_budget) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await prepareBurstPhoto(source: source, delivery: delivery, metadata: metadata,
                exiftool: exiftool, budget: 10_000_000, hash: hash)
        }
        do { try await task.value; preconditionFailure("Ignored cancellation") } catch is CancellationError {}
        check(!fm.fileExists(atPath: delivery.path))
        check(try !fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".burst-") })
        check(shouldStopAutomaticRetry(fail(Message(.error_burst_resume_changed)), attempts: 1))
        check(isTemporaryInterruption(fail(Message(.error_burst_cache_budget))))
        print("PASS: failed writes never publish, temporary files are cleaned, copy budget and cancellation enforced")
    }
}
