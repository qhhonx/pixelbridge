import Foundation
import Photos

// Export only an allowlisted snapshot; never serialize arbitrary NSError userInfo,
// account data, raw asset identifiers, image content or resource filenames.
enum DiagnosticPrivacy {
    private static let rules: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            (#"(?i)\bBearer\s+[^\s,;]+"#, "Bearer [redacted]"),
            (#"(?i)\b(password|token|secret|authorization|api[_-]?key)\s*[:=]\s*[^\s,;]+"#, "$1=[redacted]"),
            (#"(?i)\b(?:https?|file)://[^\s<>]+"#, "[url]"),
            (#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, "[email]"),
            (#"/(?:Users|home|private|var|tmp|Volumes|sdcard|storage)/[^\n\r]*"#, "[path]")
        ]
        return patterns.map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1) }
    }()
    static func text(_ value: String, secrets: [String] = []) -> String {
        var result = String(value.prefix(8192))
        for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: "[identifier]")
        }
        for (regex, replacement) in rules {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        return String(result.prefix(1024))
    }
}

struct DiagnosticError: Codable {
    let domain: String
    let code: Int
    let messageKey: String?
    let description: String
    let underlying: [DiagnosticError]
    init(_ error: Error, secrets: [String] = [], depth: Int = 0) {
        let ns = error as NSError
        domain = DiagnosticPrivacy.text(ns.domain, secrets: secrets)
        code = ns.code
        messageKey = (error as? BridgeFailure)?.message.key?.rawValue ?? (error as? CleanupIssue)?.key.rawValue
        description = DiagnosticPrivacy.text(ns.localizedDescription, secrets: secrets)
        if depth < 3, let next = (error as? BridgeFailure)?.underlying ?? (ns.userInfo[NSUnderlyingErrorKey] as? Error) {
            underlying = [DiagnosticError(next, secrets: secrets, depth: depth + 1)]
        } else { underlying = [] }
    }
}

struct DiagnosticRecord: Encodable {
    let schema = 1
    let timestamp: String
    let event: String
    let sessionID: String
    let batchID: String?
    let attemptID: String?
    let assetRef: String?
    let fields: [String: String]
    let error: DiagnosticError?
    init(event: String, sessionID: String, batchID: String? = nil, attemptID: String? = nil,
         assetID: String? = nil, fields: [String: String] = [:], error: Error? = nil,
         secrets: [String] = [], now: Date = Date()) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestamp = formatter.string(from: now)
        self.event = event; self.sessionID = sessionID; self.batchID = batchID; self.attemptID = attemptID
        assetRef = assetID.map(stableID)
        let protected = secrets + [assetID].compactMap { $0 }
        self.fields = Dictionary(fields.sorted { $0.key < $1.key }.prefix(96).map {
            (DiagnosticPrivacy.text($0.key), DiagnosticPrivacy.text($0.value, secrets: protected))
        }, uniquingKeysWith: { first, _ in first })
        self.error = error.map { DiagnosticError($0, secrets: protected) }
    }
    func data() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

// Compact scan-time metadata avoids resource database queries and per-asset dictionaries.
struct AssetDiagnosticSnapshot: Equatable {
    let mediaType: Int
    let subtypes: UInt
    let width: Int
    let height: Int
    let duration: Double
    let hidden: Bool
    let representsBurst: Bool
    let belongsToBurst: Bool
    init(_ asset: PHAsset) {
        mediaType = asset.mediaType.rawValue; subtypes = asset.mediaSubtypes.rawValue
        width = asset.pixelWidth; height = asset.pixelHeight; duration = asset.duration
        hidden = asset.isHidden; representsBurst = asset.representsBurst
        belongsToBurst = asset.burstIdentifier != nil
    }
    var fields: [String: String] {
        ["media_type": String(mediaType), "media_subtypes": String(subtypes),
         "width": String(width), "height": String(height), "duration_seconds": String(duration),
         "hidden": String(hidden), "represents_burst": String(representsBurst), "belongs_to_burst": String(belongsToBurst)]
    }
}
func resourceDiagnosticSnapshot(_ resources: [PHAssetResource]) -> [String: String] {
    var result = ["resource_count": String(resources.count)]
    for (index, resource) in resources.prefix(12).enumerated() {
        result["resource_\(index)_type"] = String(resource.type.rawValue)
        result["resource_\(index)_uti"] = resource.uniformTypeIdentifier
        result["resource_\(index)_extension"] = String((resource.originalFilename as NSString).pathExtension.lowercased().prefix(16))
    }
    return result
}
