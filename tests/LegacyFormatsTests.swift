import Foundation
import AppKit
import ImageIO
import CryptoKit

@main struct LegacyFormatsTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pixelbridge-legacy-formats-" + UUID().uuidString)
        try ensureDirectory(root)
        defer { try? fm.removeItem(at: root) }
        func check(_ value: Bool, _ message: String) { precondition(value, message) }
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for i in 0..<(64 * 64) {
            pixels[i * 4] = UInt8((i % 64) * 4)
            pixels[i * 4 + 1] = UInt8((i / 64) * 4)
            pixels[i * 4 + 2] = 128
            pixels[i * 4 + 3] = 255
        }
        let image = CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let source = root.appendingPathComponent("original.jp2")
        let jp2 = CGImageDestinationCreateWithURL(source as CFURL, "public.jpeg-2000" as CFString, 1, nil)!
        CGImageDestinationAddImage(jp2, image, nil)
        check(CGImageDestinationFinalize(jp2), "Could not create JPEG 2000 fixture")
        let original = try Data(contentsOf: source)
        let delivery = root.appendingPathComponent("converted.png")
        try prepareJP2PNG(source: source, delivery: delivery, budget: 20_000_000)
        check(try Data(contentsOf: source) == original, "JP2 original changed")
        let converted = try Data(contentsOf: delivery)
        check(converted.starts(with: [137, 80, 78, 71]), "Output is not PNG")
        let decoded = CGImageSourceCreateWithURL(delivery as CFURL, nil)!
        check(CGImageSourceCreateImageAtIndex(decoded, 0, nil)!.width == 64, "PNG dimensions changed")
        let repeatDelivery = root.appendingPathComponent("repeat.png")
        try prepareJP2PNG(source: source, delivery: repeatDelivery, budget: 20_000_000)
        check(try Data(contentsOf: repeatDelivery) == converted, "JP2 conversion changed on retry")
        let exiftool = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build-cache/exiftool/exiftool")
        let captureDate = Date(timeIntervalSince1970: 1_786_761_701.123)
        let plan = CaptureDatePlan(captureDate)
        let datedPNG = root.appendingPathComponent("dated.png")
        _ = try await prepareDatedPhoto(source: delivery, delivery: datedPNG, plan: plan, exiftool: exiftool, budget: 20_000_000)
        let tags = try await captureMetadata(datedPNG, exiftool: exiftool)
        check(tags["ExifIFD:DateTimeOriginal"] == plan.exifUTC, "JP2-derived PNG lost capture date")
        let modified = try datedPNG.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        check(abs(modified.timeIntervalSince(captureDate)) < 0.01, "JP2-derived PNG lost file time")
        print("PASS: JP2 source preserved, PNG pixels, capture time and retry bytes verified")
        let fake = root.appendingPathComponent("misnamed.jpg")
        try Data("GIF89a".utf8).write(to: fake)
        check(try isGIFFile(fake), "Missed GIF content under JPEG filename")
        check(try !isGIFFile(source), "Detected JP2 as GIF")
        let jpeg = root.appendingPathComponent("misnamed.heic")
        try Data([0xff, 0xd8, 0xff, 0xe0]).write(to: jpeg)
        check(try isJPEGFile(jpeg), "Missed JPEG content under HEIC filename")
        check(try !isJPEGFile(source), "Detected JP2 as JPEG")
        let same = compareFirstFrameImages(image, image)
        check(same.matched && same.normalizedDifference == 0 && same.correlation > 0.999, "Identical first frame did not match")
        var inversePixels = pixels
        for index in stride(from: 0, to: inversePixels.count, by: 4) {
            inversePixels[index] = 255 - inversePixels[index]
            inversePixels[index + 1] = 255 - inversePixels[index + 1]
            inversePixels[index + 2] = 255 - inversePixels[index + 2]
        }
        let inverse = CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(inversePixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        check(!compareFirstFrameImages(image, inverse).matched, "Different first frame was accepted")
        if let sample = ProcessInfo.processInfo.environment["PIXELBRIDGE_JP2_SAMPLE"] {
            let realSource = URL(fileURLWithPath: sample)
            let realDelivery = root.appendingPathComponent("real-converted.png")
            let realBefore = SHA256.hash(data: try Data(contentsOf: realSource))
            try prepareJP2PNG(source: realSource, delivery: realDelivery, budget: 3_000_000_000)
            check(SHA256.hash(data: try Data(contentsOf: realSource)) == realBefore, "Real JP2 original changed")
            check(try Data(contentsOf: realDelivery).starts(with: [137, 80, 78, 71]), "Real JP2 output is not PNG")
            print("PASS: real large JP2 conversion and full rendered-pixel verification")
        }
        if let sample = ProcessInfo.processInfo.environment["PIXELBRIDGE_GIF_SAMPLE"] {
            let originalGIF = URL(fileURLWithPath: sample)
            let copy = root.appendingPathComponent("live-sample.gif")
            try fm.copyItem(at: originalGIF, to: copy)
            let before = try Data(contentsOf: copy)
            let dated = root.appendingPathComponent("dated.gif")
            let plan = CaptureDatePlan(Date(timeIntervalSince1970: 1_503_683_449))
            _ = try await prepareDatedPhoto(source: copy, delivery: dated, plan: plan, exiftool: exiftool, budget: 10_000_000)
            check(try Data(contentsOf: copy) == before, "GIF source changed")
            let beforeFrames = CGImageSourceCreateWithURL(copy as CFURL, nil)!
            let afterFrames = CGImageSourceCreateWithURL(dated as CFURL, nil)!
            check(CGImageSourceGetCount(beforeFrames) == CGImageSourceGetCount(afterFrames), "GIF frame count changed")
            for index in 0..<CGImageSourceGetCount(beforeFrames) {
                let a = CGImageSourceCreateImageAtIndex(beforeFrames, index, nil)!
                let b = CGImageSourceCreateImageAtIndex(afterFrames, index, nil)!
                check(a.dataProvider!.data! as Data == b.dataProvider!.data! as Data, "GIF frame pixels changed")
            }
            print("PASS: real GIF frame count, pixels and original bytes preserved")
        }
        if let still = ProcessInfo.processInfo.environment["PIXELBRIDGE_MISSING_MARKER_STILL"],
           let video = ProcessInfo.processInfo.environment["PIXELBRIDGE_MISSING_MARKER_VIDEO"] {
            let match = try await firstVideoFrameMatch(still: URL(fileURLWithPath: still), video: URL(fileURLWithPath: video))
            check(match.matched, "Real missing-marker first frame did not match")
            print("PASS: real missing-marker pair verified from first-frame pixels")
        }
    }
}
