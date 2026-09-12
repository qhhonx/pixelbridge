import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

@main struct BurstPhotoTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pixelbridge-burst-tests-" + UUID().uuidString)
        try ensureDirectory(root)
        defer { try? fm.removeItem(at: root) }
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
