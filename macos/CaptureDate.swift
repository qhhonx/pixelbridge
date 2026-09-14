import Foundation

struct CaptureDatePlan: Codable {
    let version: Int
    let epochMilliseconds: Int64?
    let supplementMissingDates: Bool
    init(_ date: Date?, supplementMissingDates: Bool = true) {
        self.supplementMissingDates = supplementMissingDates
        version = 1
        epochMilliseconds = date.flatMap { value in
            let ms = value.timeIntervalSince1970 * 1000
            let rounded = ms.rounded()
            return rounded.isFinite && rounded >= -62_135_596_800_000 && rounded < 253_402_300_800_000 ? Int64(rounded) : nil
        }
    }
    var date: Date? { epochMilliseconds.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
    var exifUTC: String? {
        guard let date else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"; return f.string(from: date)
    }
    var milliseconds: String? { epochMilliseconds.map { String(format: "%03lld", (($0 % 1000) + 1000) % 1000) } }
    var isoUTC: String? {
        guard let date else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0); return f.string(from: date)
    }
    // Snapshot once: a later Photos date edit must not alter a pending delivery's bytes.
    static func loadOrCreate(at url: URL, date: Date?, supplementMissingDates: Bool = true) throws -> CaptureDatePlan {
        if FileManager.default.fileExists(atPath: url.path) {
            let plan = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard plan.version == 1, plan.epochMilliseconds.map({ (-62_135_596_800_000..<253_402_300_800_000).contains($0) }) ?? true else { throw fail(Message(.error_capture_date)) }
            return plan
        }
        let plan = Self(date, supplementMissingDates: supplementMissingDates); try JSONEncoder().encode(plan).write(to: url, options: .atomic); return plan
    }
}

func validCaptureDate(_ value: String?) -> Bool {
    guard let value, value.count >= 19 else { return false }
    let prefix = String(value.prefix(19)).replacingOccurrences(of: "T", with: " ")
    let normalized = String(prefix.prefix(10)).replacingOccurrences(of: "-", with: ":") + String(prefix.dropFirst(10))
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.isLenient = false
    guard let date = f.date(from: normalized) else { return false }
    return f.string(from: date) == normalized && !normalized.hasPrefix("0000")
}

func captureMetadata(_ file: URL, exiftool: URL) async throws -> [String: String] {
    let output = try await processOutput(exiftool, ["-j", "-G1", "-s", "-EXIF:DateTimeOriginal", "-EXIF:OffsetTimeOriginal",
        "-EXIF:SubSecTimeOriginal", "-XMP-exif:DateTimeOriginal", "-XMP-photoshop:DateCreated",
        "-EXIF:CreateDate", "-EXIF:ModifyDate", "-XMP-xmp:CreateDate", "-PNG:CreationTime",
        "-QuickTime:CreateDate", "-QuickTime:MediaCreateDate", "-QuickTime:TrackCreateDate", "-Keys:CreationDate", "--", file.path])
    guard let records = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]], let record = records.first else {
        throw fail(Message(.error_capture_date))
    }
    return record.mapValues { String(describing: $0) }
}
func hasCaptureDate(_ metadata: [String: String]) -> Bool {
    ["ExifIFD:DateTimeOriginal", "XMP-exif:DateTimeOriginal", "XMP-photoshop:DateCreated"].contains { validCaptureDate(metadata[$0]) }
}

// Metadata-only annotation on an independent copy, never a hard link or a
// combined Motion Photo. Motion offsets are calculated AFTER this returns.
func prepareDatedPhoto(source: URL, delivery: URL, plan: CaptureDatePlan, exiftool: URL, budget: Int64) async throws -> Bool {
    let fm = FileManager.default
    guard source.standardizedFileURL != delivery.standardizedFileURL else { throw fail(Message(.error_capture_date)) }
    let bytes = Int64((try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
    guard budget >= 65_536, bytes <= (budget - 65_536) / 2 else { throw fail(Message(.error_date_cache_budget)) }
    let temporary = delivery.deletingLastPathComponent().appendingPathComponent(".date-" + UUID().uuidString + "." + source.pathExtension)
    defer { try? fm.removeItem(at: temporary) }
    try Task.checkCancellation()
    let metadata = try await captureMetadata(source, exiftool: exiftool)
    try fm.copyItem(at: source, to: temporary)
    let needsDate = plan.supplementMissingDates && !hasCaptureDate(metadata) && plan.date != nil
    if needsDate, let exif = plan.exifUTC, let subsec = plan.milliseconds, let iso = plan.isoUTC {
        var args = ["-overwrite_original", "-P", "-XMP-exif:DateTimeOriginal=" + iso]
        if source.pathExtension.lowercased() != "gif" {
            args += ["-EXIF:DateTimeOriginal=" + exif, "-EXIF:OffsetTimeOriginal=+00:00", "-EXIF:SubSecTimeOriginal=" + subsec]
        }
        // Preserve existing creation/editing tags; supplement only absent fields.
        if metadata["XMP-photoshop:DateCreated"] == nil { args += ["-XMP-photoshop:DateCreated=" + iso] }
        _ = try await processOutput(exiftool, args + ["--", temporary.path])
        let check = try await captureMetadata(temporary, exiftool: exiftool)
        guard hasCaptureDate(check) else { throw fail(Message(.error_capture_date)) }
        if source.pathExtension.lowercased() != "gif" {
            guard check["ExifIFD:DateTimeOriginal"] == exif, check["ExifIFD:SubSecTimeOriginal"] == subsec,
                  check["ExifIFD:OffsetTimeOriginal"] == "+00:00" else { throw fail(Message(.error_capture_date)) }
        }
    }
    if let date = plan.date { try fm.setAttributes([.modificationDate: date], ofItemAtPath: temporary.path) }
    try Task.checkCancellation()
    if fm.fileExists(atPath: delivery.path) { try fm.removeItem(at: delivery) }
    try fm.moveItem(at: temporary, to: delivery)
    return needsDate
}

// Kept in local State for historical audits; never changes a queue or cloud item.
func captureDateInventory(_ items: [LibraryItem]) throws -> Data {
    struct Entry: Encodable {
        let assetRef: String
        let captureTimeMilliseconds: Int64?
        let kind: String
    }
    struct Inventory: Encodable {
        let schema = 1
        let generatedAt = Date().timeIntervalSince1970
        let source = "PhotoKit.creationDate"
        let assets: [Entry]
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(Inventory(assets: items.map {
        Entry(assetRef: stableID($0.id), captureTimeMilliseconds: $0.captureTimeMilliseconds, kind: $0.kind)
    }))
}
