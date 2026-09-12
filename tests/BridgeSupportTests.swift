import Foundation
import Photos
@main struct SupportTests {
    static func main() async throws {
        precondition(libraryMediaKind(mediaType: .image, subtypes: [], burstIdentifier: nil) == "photo")
        precondition(libraryMediaKind(mediaType: .image, subtypes: [], burstIdentifier: "") == "photo")
        precondition(libraryMediaKind(mediaType: .image, subtypes: [], burstIdentifier: "group") == "burst")
        precondition(libraryMediaKind(mediaType: .image, subtypes: [.photoLive], burstIdentifier: "group") == "motion")
        precondition(libraryMediaKind(mediaType: .video, subtypes: [], burstIdentifier: nil) == "video")
        let burstRow = QueueRow(asset_id: "burst", filename: "burst.jpg", phase: "skipped", timestamp_ms: 0, sha256: nil, remote: nil, message: nil)
        let photoRow = QueueRow(asset_id: "photo", filename: "photo.jpg", phase: "skipped", timestamp_ms: 0, sha256: nil, remote: nil, message: nil)
        let kinds = ["burst": "burst", "photo": "photo"]
        precondition(filteredTasks([burstRow, photoRow], status: .skipped, kind: "burst", kinds: kinds, requested: [], activeID: nil).map(\.id) == ["burst"])
        precondition(filteredTasks([burstRow, photoRow], status: .all, kind: "photo", kinds: kinds, requested: [], activeID: nil).map(\.id) == ["photo"])
        print("PASS: burst classification and task filters separate burst frames from ordinary photos")
        let suite = "PixelBridge.PreferenceTests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        for key in NumericPreference.allCases {
            precondition(key.read(preferences) == key.fallback)
            key.save(key.range.upperBound, to: preferences)
            precondition(key.read(UserDefaults(suiteName: suite)!) == key.range.upperBound)
            key.save(-1, to: preferences)
            precondition(key.read(preferences) == key.range.lowerBound)
            key.save(9999, to: preferences)
            precondition(key.read(preferences) == key.range.upperBound)
        }
        print("PASS: configurable defaults, persistence, lower and upper bounds")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ensureDirectory(cache)
        defer { try? FileManager.default.removeItem(at: cache) }
        let original = cache.appendingPathComponent("original.mov")
        try Data(repeating: 1, count: 8192).write(to: original)
        try FileManager.default.linkItem(at: original, to: cache.appendingPathComponent("delivery.mov"))
        precondition(folderBytes(cache) == 8192, "Hard-linked delivery must not double cache usage")
        print("PASS: cache accounting counts hard-linked files once")
        let text = try await processOutput(URL(fileURLWithPath: "/usr/bin/printf"), ["hello"])
        precondition(text == "hello")
        let large = try await processOutput(URL(fileURLWithPath: "/usr/bin/head"), ["-c", "1048576", "/dev/zero"])
        precondition(large.utf8.count == 1048576, "Subprocess output must be drained without blocking")
        do {
            _ = try await processOutput(URL(fileURLWithPath: "/usr/bin/false"), [])
            fatalError("nonzero exit must propagate")
        } catch { }
        let start = Date()
        do {
            _ = try await processOutput(URL(fileURLWithPath: "/bin/sleep"), ["10"], timeout: 0.2)
            fatalError("timeout must propagate")
        } catch { precondition(Date().timeIntervalSince(start) < 5) }
        precondition(stableID("asset-a") == stableID("asset-a"))
        precondition(stableID("asset-a") != stableID("asset-b"))
        let now = Date()
        precondition(shouldTransfer(phase: nil, retryAt: nil, now: now), "New photos must be eligible")
        for phase in ["discovered", "exporting", "prepared", "failed"] {
            precondition(shouldTransfer(phase: phase, retryAt: now, now: now), "Interrupted jobs must resume")
        }
        for phase in ["transferred", "backup_seen", "motion_verified"] {
            precondition(!shouldTransfer(phase: phase, retryAt: nil, now: now), "Delivered photos must not repeat")
        }
        precondition(!shouldTransfer(phase: "failed", retryAt: now.addingTimeInterval(60), now: now), "Backoff must be respected")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sink = try ResourceSink(destination, budget: 4)
        sink.receive(Data([1, 2, 3])); sink.receive(Data([4, 5]))
        precondition(sink.finish(nil) != nil, "Over-budget downloads must fail")
        let written = try Data(contentsOf: destination)
        precondition(written.count == 3)
        try FileManager.default.removeItem(at: destination)
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = try BatchLease.acquire(at: lockURL)
        precondition(first != nil)
        let second = try BatchLease.acquire(at: lockURL)
        precondition(second == nil, "A second instance must not run a batch")
        first?.release()
        let third = try BatchLease.acquire(at: lockURL)
        precondition(third != nil, "Released leases must be reusable")
        third?.release()
        try FileManager.default.removeItem(at: lockURL)
        print("PASS: exclusive batch lease and recovery")
        print("PASS: scheduling, retry eligibility, completed deduplication, download budget")
        print("PASS: subprocess output, large output, exit errors, timeout, stable identities")
    }
}
