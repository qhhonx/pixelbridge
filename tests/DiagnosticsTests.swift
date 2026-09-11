import Foundation

@main struct DiagnosticsTests {
    @MainActor static func main() async throws {
        func check(_ value: Bool) { precondition(value) }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pixelbridge-diagnostics-\(UUID().uuidString)")
        try ensureDirectory(root)
        defer { try? fm.removeItem(at: root) }
        let rawID = "private-asset/L0/001", serial = "test-private-device"
        let privatePath = "/" + ["Users", "example", "Pictures", "private.jpg"].joined(separator: "/")
        let cause = NSError(domain: "PHPhotosErrorDomain", code: 3303,
            userInfo: [NSLocalizedDescriptionKey: "Failed \(rawID) \(serial) person@example.com https://example.com/private?token=abc \(privatePath)",
                       "NeverExportThisUserInfo": "unrelated-private-data"])
        let error = BridgeFailure(underlying: cause, message: Message(.error_original_missing))
        let record = DiagnosticRecord(event: "attempt_failed", sessionID: "session", batchID: "batch", attemptID: "attempt",
            assetID: rawID, fields: ["operation": "primary_download", "decision": "skip", "test": "Bearer abc password=hidden"],
            error: error, secrets: [serial])
        let data = try record.data(), text = String(decoding: data, as: UTF8.self)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        check(object["schema"] as? Int == 1 && record.assetRef == stableID(rawID))
        check(record.error?.messageKey == "error_original_missing")
        check(record.error?.underlying.first?.domain == "PHPhotosErrorDomain" && record.error?.underlying.first?.code == 3303)
        for secret in [rawID, serial, "person@example.com", "https://example.com", "Users/example", "private.jpg", "unrelated-private-data", "Bearer abc", "password=hidden"] {
            check(!text.contains(secret))
        }
        let another = DiagnosticRecord(event: "attempt_failed", sessionID: "session", batchID: "batch2", attemptID: "attempt2", assetID: rawID)
        check(another.assetRef == record.assetRef && another.attemptID != record.attemptID)
        check(DiagnosticRecord(event: "attempt_failed", sessionID: "session", assetID: "other").assetRef != record.assetRef)
        print("PASS: stable pseudonymous task identity, distinct attempts, original error chain and secret redaction")

        var date = ISO8601DateFormatter().date(from: "2026-09-12T00:00:00Z")!
        let store = ActivityLogStore(state: root.appendingPathComponent("Storage"), now: { date })
        try store.append("Friendly activity message")
        try store.appendDiagnostic(data)
        let large = DiagnosticRecord(event: "large", sessionID: "session", fields: Dictionary(uniqueKeysWithValues: (0..<40).map { ("field_\($0)", String(repeating: "x", count: 800)) }))
        let largeData = try large.data()
        check(largeData.count > 16_384)
        try store.appendDiagnostic(largeData)
        check(try store.recent() == ["Friendly activity message"])
        let files = try fm.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
        let lines = try String(contentsOf: files[0], encoding: .utf8).split(separator: "\n")
        check(lines.count == 2)
        for line in lines { _ = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
        for invalid in [Data("{\n\"a\":1\n}".utf8), Data("[]".utf8), Data(repeating: 120, count: 128_001)] {
            do { try store.appendDiagnostic(invalid); preconditionFailure("Invalid JSONL accepted") } catch {}
        }
        let exported = root.appendingPathComponent("diagnostics.txt")
        try store.append("File failed at " + privatePath)
        try store.export(to: exported)
        let export = try String(contentsOf: exported, encoding: .utf8)
        check(export.contains("attempt_failed") && export.contains("Friendly activity message") && !export.contains("Users/example"))
        date = date.addingTimeInterval(7 * 86400)
        try store.append("new-day")
        check(try fm.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).allSatisfy { $0.pathExtension == "log" })
        print("PASS: JSONL stays complete above 16 KB, preview excludes diagnostics, export includes both streams and retention expires both")

        let small = ActivityLogStore(state: root.appendingPathComponent("Small"), segmentBytes: 256, totalBytes: 600)
        for i in 0..<30 {
            try small.append("human-\(i) " + String(repeating: "x", count: 90))
            try small.appendDiagnostic(Data("{\"sequence\":\(i),\"context\":\"\(String(repeating: "y", count: 120))\"}".utf8))
        }
        let retained = try fm.contentsOfDirectory(at: small.directory, includingPropertiesForKeys: [.fileSizeKey])
        check(try retained.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! } <= 600)
        check(try small.recent().first!.contains("human-29"))
        let latestJSON = try retained.filter { $0.pathExtension == "jsonl" }.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        check(latestJSON.contains("\"sequence\":29"))
        let logger = ActivityLogger(state: root.appendingPathComponent("Async"))
        logger.diagnostic(record) { precondition($0) }
        logger.append("after-diagnostic") { precondition($0) }
        try await logger.export(to: exported)
        check(try String(contentsOf: exported, encoding: .utf8).contains("attempt_failed"))
        check(try await logger.load() == ["after-diagnostic"])
        print("PASS: both streams share rotation budget; serialized export includes accepted diagnostic writes")

        do {
            _ = try await processOutput(URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 37"])
            preconditionFailure("Expected subprocess failure")
        } catch {
            check(DiagnosticError(error).underlying.first?.domain == "PixelBridge.Process")
            check(DiagnosticError(error).underlying.first?.code == 37)
        }
        let defaults = UserDefaults.standard
        let keys = ["autoReclaimCache", "automatic", "pixelSerial", "concurrentTasks"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let model = BridgeModel(root: root.appendingPathComponent("Model"))
        try ensureDirectory(root.appendingPathComponent("Model/State"))
        model.testCoreURL = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("target/debug/pixelbridge")
        model.autoReclaimCache = false; model.autoRunning = false; model.selectedDevice = serial; model.concurrentTasks = 1
        model.testPrepareBatch = {}; model.testGuardDevice = {}
        let item = LibraryItem(id: rawID, name: "same-name.jpg", date: .distantPast, kind: "motion")
        model.library = [item]
        var events: [DiagnosticRecord] = []
        model.testDiagnostic = { events.append($0) }
        model.testProcessItem = { _, _ in throw cause }
        await model.batch()
        let failure = events.first { $0.event == "attempt_failed" }!
        check(failure.assetRef == stableID(rawID) && failure.batchID != nil && failure.attemptID != nil)
        check(failure.fields["operation"] == "device_check" && failure.fields["kind"] == "motion")
        check(failure.fields["attempt_number"] == "1" && failure.fields["decision"] == "retry_scheduled")
        check(failure.error?.code == 3303 && failure.fields["elapsed_ms"] != nil)
        check(model.rows.first?.phase == "failed")
        check(model.logs.contains { $0.contains(String(stableID(rawID).prefix(12))) })
        model.testSetRetry(rawID, RetryInfo(attempts: 4, next: .distantPast))
        await model.batch()
        let stopped = events.last { $0.event == "attempt_failed" }!
        check(stopped.fields["attempt_number"] == "5" && stopped.fields["decision"] == "skip")
        check(stopped.attemptID != failure.attemptID && stopped.batchID != failure.batchID)
        check(model.rows.first?.phase == "skipped")
        print("PASS: real queue writes retain failure context, correlation IDs, backoff and fifth-failure skip decisions")

        let deferred = LibraryItem(id: "temporary", name: "same-name.jpg", date: .distantPast, kind: "photo")
        model.library = [deferred]
        model.testProcessItem = { _, _ in throw NSError(domain: NSURLErrorDomain, code: -1009) }
        await model.batch()
        let pending = events.last { $0.event == "attempt_deferred" }!
        check(pending.fields["decision"] == "wait_for_user" && pending.error?.code == -1009)
        check(!events.contains { $0.event == "attempt_failed" && $0.assetRef == stableID(deferred.id) })
        model.testProcessItem = { _, _ in throw CancellationError() }
        await model.batch()
        check(events.last { $0.event == "attempt_cancelled" }?.fields["decision"] == "cancelled")
        model.testProcessItem = { _, _ in }
        await model.batch()
        check(events.last { $0.event == "attempt_completed" }?.fields["cloud_backup"] == "not_verified")
        print("PASS: network deferral and cancellation remain distinct from failed retries; delivery does not claim cloud backup")
        model.library = [LibraryItem(id: "queue-write-error", name: "same-name.jpg", date: .distantPast, kind: "photo")]
        model.testCoreURL = root.appendingPathComponent("missing-executable")
        model.testProcessItem = { _, _ in throw cause }
        await model.batch()
        let original = events.last { $0.event == "attempt_failed" }!
        let persistence = events.last { $0.event == "queue_write_failed" }!
        check(original.error?.code == 3303 && persistence.fields["decision"] == "stop_batch")
        check(original.attemptID == persistence.attemptID && original.assetRef == persistence.assetRef)
        check(persistence.error?.domain != original.error?.domain)
        print("PASS: queue persistence failure retains the original failure and adds its own correlated cause")
    }
}
