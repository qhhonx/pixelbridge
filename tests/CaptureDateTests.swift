import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import AVFoundation

@main struct CaptureDateTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let keep = ProcessInfo.processInfo.environment["PIXELBRIDGE_DATE_FIXTURES"]
        let root = keep.map { URL(fileURLWithPath: $0) } ?? fm.temporaryDirectory.appendingPathComponent("pixelbridge-dates-" + UUID().uuidString)
        try ensureDirectory(root)
        defer { if keep == nil { try? fm.removeItem(at: root) } }
        let exiftool = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build-cache/exiftool/exiftool")
        func check(_ condition: Bool, _ message: String = "Date assertion failed") { precondition(condition, message) }
        func digest(_ file: URL) async throws -> String { SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined() }
        let instant = Date(timeIntervalSince1970: 1786761701.123)
        let plan = CaptureDatePlan(instant)
        check(plan.epochMilliseconds == 1786761701123 && plan.exifUTC == "2026:08:15 02:41:41" && plan.milliseconds == "123")
        check(CaptureDatePlan(Date(timeIntervalSince1970: -0.001)).milliseconds == "999")
        check(CaptureDatePlan(nil).date == nil)
        for invalid in ["0000:00:00 00:00:00", "2026:02:30 12:00:00", "2026:01:01 25:00:00", ""] { check(!validCaptureDate(invalid)) }
        let snapshot = root.appendingPathComponent("snapshot.json")
        try? fm.removeItem(at: snapshot)
        _ = try CaptureDatePlan.loadOrCreate(at: snapshot, date: instant)
        check(try CaptureDatePlan.loadOrCreate(at: snapshot, date: Date()).epochMilliseconds == plan.epochMilliseconds)
        print("PASS: absolute UTC milliseconds, invalid dates, nil dates, and stable retry snapshot")
        let legacy = root.appendingPathComponent("legacy-plan.json")
        try? fm.removeItem(at: legacy)
        _ = try CaptureDatePlan.loadOrCreate(at: legacy, date: instant, supplementMissingDates: false)
        check(try !CaptureDatePlan.loadOrCreate(at: legacy, date: Date()).supplementMissingDates)
        let video = root.appendingPathComponent("motion.mov")
        let identifier = "12345678-1234-1234-1234-123456789ABC"
        try? fm.removeItem(at: video)
        try await makeMotion(video, identifier: identifier)
        let videoOriginal = try Data(contentsOf: video)
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for i in 0..<(64 * 64) { pixels[i*4] = UInt8((i%64)*4); pixels[i*4+1] = UInt8((i/64)*4); pixels[i*4+2] = 128 }
        let sample = CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        for (ext, type) in [("jpg",UTType.jpeg),("heic",UTType.heic),("png",UTType.png)] {
            let source = root.appendingPathComponent("original."+ext), delivery = root.appendingPathComponent("PB_DATE_"+ext+"."+ext)
            let dst = CGImageDestinationCreateWithURL(source as CFURL, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dst, sample, nil); check(CGImageDestinationFinalize(dst))
            let original = try Data(contentsOf: source)
            try? fm.removeItem(at: delivery); try fm.linkItem(at: source, to: delivery)
            let added = try await prepareDatedPhoto(source: source, delivery: delivery, plan: plan, exiftool: exiftool, budget: 10_000_000)
            check(try added && Data(contentsOf: source) == original, "Source changed")
            let a = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(source as CFURL,nil)!,0,nil)!
            let b = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(delivery as CFURL,nil)!,0,nil)!
            check(a.dataProvider!.data! as Data == b.dataProvider!.data! as Data, "Pixels changed")
            let tags = try await captureMetadata(delivery, exiftool: exiftool)
            check(tags["ExifIFD:DateTimeOriginal"] == plan.exifUTC && tags["ExifIFD:OffsetTimeOriginal"] == "+00:00")
            let second = root.appendingPathComponent("retry."+ext)
            _ = try await prepareDatedPhoto(source: source, delivery: second, plan: plan, exiftool: exiftool, budget: 10_000_000)
            check(try await digest(delivery) == digest(second), "Rebuild changed bytes")
            let third = root.appendingPathComponent("existing."+ext)
            let existing = try await prepareDatedPhoto(source: delivery, delivery: third, plan: CaptureDatePlan(Date()), exiftool: exiftool, budget: 10_000_000)
            check(try !existing && Data(contentsOf: third) == Data(contentsOf: delivery), "Existing metadata replaced")
            print("PASS: \(ext) missing EXIF filled, offset/milliseconds verified, original and pixels unchanged, deterministic retries and existing date preserved")
            if ext != "png" {
                for frame in 0..<2 {
                    let framePlan = CaptureDatePlan(instant.addingTimeInterval(Double(frame)/10))
                    let dated = root.appendingPathComponent("frame-\(frame)."+ext)
                    _ = try await prepareDatedPhoto(source: source, delivery: dated, plan: framePlan, exiftool: exiftool, budget: 10_000_000)
                    let burst = root.appendingPathComponent("PB_DATE_BURST_\(frame)."+ext)
                    _ = try await prepareBurstPhoto(source: dated, delivery: burst, metadata: BurstPhotoMetadata(identifier: "date-fixture",isPrimary: frame==0),exiftool:exiftool,budget:10_000_000,hash:digest)
                    check(try await captureMetadata(burst,exiftool:exiftool)["ExifIFD:SubSecTimeOriginal"] == framePlan.milliseconds)
                }
                print("PASS: \(ext) burst frames retain distinct capture milliseconds")
                let still = root.appendingPathComponent("live-original." + ext)
                let writer = CGImageDestinationCreateWithURL(still as CFURL, type.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(writer, sample, [kCGImagePropertyMakerAppleDictionary: ["17": identifier]] as CFDictionary)
                check(CGImageDestinationFinalize(writer))
                let stillOriginal = try Data(contentsOf: still)
                let dated = root.appendingPathComponent("live-dated." + ext)
                _ = try await prepareDatedPhoto(source: still, delivery: dated, plan: plan, exiftool: exiftool, budget: 10_000_000)
                let motion = root.appendingPathComponent("PB_DATE_MOTION." + ext)
                let core = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("target/debug/pixelbridge")
                let args = ["prepare", "--image", dated.path, "--video", video.path, "--output", motion.path, "--exiftool", exiftool.path, "--force"]
                _ = try await processOutput(core, args)
                check(try Data(contentsOf: still) == stillOriginal && Data(contentsOf: video) == videoOriginal)
                check(try await captureMetadata(motion, exiftool: exiftool)["ExifIFD:SubSecTimeOriginal"] == "123")
                let originalPixels = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(still as CFURL,nil)!,0,nil)!
                let motionPixels = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(motion as CFURL,nil)!,0,nil)!
                check(originalPixels.dataProvider!.data! as Data == motionPixels.dataProvider!.data! as Data)
                let firstBytes = try Data(contentsOf: motion)
                let xmp = try await processOutput(exiftool, ["-b", "-XMP", motion.path])
                let pattern = #"Item:Length="([0-9]+)""#
                let regex = try NSRegularExpression(pattern: pattern)
                let lengths = regex.matches(in: xmp, range: NSRange(xmp.startIndex..., in: xmp)).compactMap { Range($0.range(at: 1), in: xmp).flatMap { Int(xmp[$0]) } }
                let length = lengths.last!
                let start = firstBytes.count - length
                // HEIC places an 8-byte mpvd header before the declared motion item.
                check(firstBytes.subdata(in: start..<(start + videoOriginal.count)) == videoOriginal, "Motion offset invalid")
                _ = try await processOutput(core, args)
                check(try Data(contentsOf: motion) == firstBytes, "Motion retry bytes changed")
                print("PASS: \(ext) Motion Photo date, pixels, original hashes, XMP video offset and deterministic retry")
            }
        }
        let jpeg = root.appendingPathComponent("original.jpg")
        let edge = root.appendingPathComponent("edge.jpg")
        let edgePlan = CaptureDatePlan(Date(timeIntervalSince1970: 1786761701.007))
        _ = try await prepareDatedPhoto(source: jpeg, delivery: edge, plan: edgePlan, exiftool: exiftool, budget: 10_000_000)
        check(try await captureMetadata(edge, exiftool: exiftool)["ExifIFD:SubSecTimeOriginal"] == "007")
        let legacyCopy = root.appendingPathComponent("legacy.jpg")
        _ = try await prepareDatedPhoto(source: jpeg, delivery: legacyCopy, plan: CaptureDatePlan(instant, supplementMissingDates: false), exiftool: exiftool, budget: 10_000_000)
        check(try Data(contentsOf: jpeg) == Data(contentsOf: legacyCopy), "Legacy retry changed bytes")
        let created = root.appendingPathComponent("created-only.jpg")
        try? fm.removeItem(at: created); try fm.copyItem(at: jpeg, to: created)
        _ = try await processOutput(exiftool, ["-overwrite_original", "-EXIF:CreateDate=2018:01:02 03:04:05", "-EXIF:ModifyDate=2019:01:02 03:04:05", created.path])
        _ = try await prepareDatedPhoto(source: created, delivery: edge, plan: plan, exiftool: exiftool, budget: 10_000_000)
        let tags = try await captureMetadata(edge, exiftool: exiftool)
        check(tags["ExifIFD:CreateDate"] == "2018:01:02 03:04:05" && tags["IFD0:ModifyDate"] == "2019:01:02 03:04:05")
        _ = try await processOutput(exiftool, ["-overwrite_original", "-EXIF:DateTimeOriginal=2020:04:05 06:07:08", "-EXIF:OffsetTimeOriginal=+05:30", "-EXIF:SubSecTimeOriginal=456", created.path])
        _ = try await prepareDatedPhoto(source: created, delivery: edge, plan: plan, exiftool: exiftool, budget: 10_000_000)
        check(try Data(contentsOf: edge) == Data(contentsOf: created), "Existing local time/offset replaced")
        let inventory = try JSONSerialization.jsonObject(with: captureDateInventory([LibraryItem(id: "test", name: "name", date: .distantPast, kind: "photo")])) as! [String: Any]
        check((inventory["assets"] as! [[String: Any]])[0]["captureTimeMilliseconds"] == nil, "Unknown source date invented")
        print("PASS: leading-zero milliseconds, legacy-byte replay, valid non-UTC dates, creation/edit tags and unknown audit dates")
    }
    static func makeMotion(_ url: URL, identifier: String) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let id = AVMutableMetadataItem(); id.keySpace = .quickTimeMetadata
        id.key = "com.apple.quicktime.content.identifier" as NSString
        id.value = identifier as NSString; id.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [id]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        var desc: CMFormatDescription?
        let spec = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time", kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.int8"]
        precondition(CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &desc) == noErr)
        let metadata = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: desc)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadata)
        writer.add(metadata)
        precondition(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        let time = AVMutableMetadataItem(); time.keySpace = .quickTimeMetadata
        time.key = "com.apple.quicktime.still-image-time" as NSString; time.value = NSNumber(value: Int8(-1))
        time.dataType = "com.apple.metadata.datatype.int8"
        precondition(adaptor.append(AVTimedMetadataGroup(items: [time], timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 15, timescale: 30)))))
        metadata.markAsFinished()
        for frame in 0..<30 {
            let deadline = Date().addingTimeInterval(30)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else { throw writer.error ?? fail("Synthetic video writer stalled") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            precondition(CVPixelBufferPoolCreatePixelBuffer(nil, pixels.pixelBufferPool!, &buffer) == kCVReturnSuccess)
            CVPixelBufferLockBaseAddress(buffer!, []); memset(CVPixelBufferGetBaseAddress(buffer!), Int32(frame * 3), CVPixelBufferGetDataSize(buffer!)); CVPixelBufferUnlockBaseAddress(buffer!, [])
            precondition(pixels.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting(); precondition(writer.status == .completed)
    }
}
