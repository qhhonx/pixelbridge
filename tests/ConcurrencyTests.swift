import Foundation

final class ProgressEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

@main struct ConcurrencyTests {
    @MainActor static func main() async throws {
        let defaults = UserDefaults.standard
        let keys = ["automatic", "autoReclaimCache", "concurrentTasks"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ensureDirectory(root.appendingPathComponent("State"))
        defer { try? FileManager.default.removeItem(at: root) }
        let model = BridgeModel(root: root)
        model.autoReclaimCache = false; model.autoRunning = false; model.concurrentTasks = 3
        let items = (0..<9).map { LibraryItem(id: "job-\($0)", name: "sample-\($0).jpg", date: .distantPast, kind: "photo") }
        model.library = items
        model.testPrepareBatch = {}; model.testGuardDevice = {}
        func row(_ id: String, _ phase: String) -> QueueRow {
            QueueRow(asset_id: id, filename: "sample.jpg", phase: phase, timestamp_ms: 0, sha256: "proof", remote: nil, message: nil, bytes: 100)
        }
        var preparing = 0, peakPreparing = 0, delivering = 0, peakDelivering = 0
        var delivered = Set<String>()
        model.testPrepareItem = { item, _ in
            preparing += 1; peakPreparing = max(peakPreparing, preparing)
            defer { preparing -= 1 }
            try await Task.sleep(nanoseconds: 10_000_000)
            model.rows.removeAll { $0.id == item.id }; model.rows.append(row(item.id, "prepared"))
            return PreparedDelivery(item: item, file: root.appendingPathComponent(item.id), hash: "proof", bytes: 100)
        }
        model.testDeliverItem = { delivery in
            delivering += 1; peakDelivering = max(peakDelivering, delivering)
            defer { delivering -= 1 }
            precondition(model.testReservedPixelBytes >= Int64(delivering * 100))
            try await Task.sleep(nanoseconds: 120_000_000)
            precondition(delivered.insert(delivery.item.id).inserted)
            model.rows.removeAll { $0.id == delivery.item.id }; model.rows.append(row(delivery.item.id, "transferred"))
        }
        await model.batch()
        precondition(peakPreparing == 1 && peakDelivering == 3 && delivered.count == 9)
        precondition(model.completed == 9 && model.activeIDs.isEmpty && model.testReservedPixelBytes == 0)
        await model.batch(); precondition(model.batchTotal == 0)
        print("PASS: three overlapping deliveries, serial preparation, aggregate space reservations, nine unique completions and no repeat deliveries")

        for limit in 1...2 {
            model.concurrentTasks = limit; model.rows = []; delivered.removeAll()
            peakPreparing = 0; peakDelivering = 0
            await model.batch()
            precondition(peakPreparing == 1 && peakDelivering == limit && delivered.count == 9)
        }
        model.concurrentTasks = 3
        print("PASS: concurrency settings 1, 2 and 3 enforce their exact limits")

        model.rows = []; model.library = Array(items.prefix(3))
        model.testDeliverItem = { _ in
            delivering += 1; defer { delivering -= 1 }
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let running = Task { await model.batch() }
        let deadline = Date().addingTimeInterval(5)
        while delivering < 3 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(delivering == 3 && model.activeIDs.count == 3)
        let filtered = filteredTasks(model.rows, status: .processing, kind: "all", kinds: [:], requested: [], activeID: nil, activeIDs: model.activeIDs)
        precondition(filtered.count == 3)
        model.pause(); await running.value
        precondition(delivering == 0 && !model.busy && !model.pausing && !model.autoRunning && model.nextRun == nil)
        precondition(model.activeIDs.isEmpty && model.testReservedPixelBytes == 0 && model.rows.allSatisfy { $0.phase == "prepared" })
        print("PASS: pause cancels all three workers, preserves prepared progress, releases reservations and keeps automation paused")

        model.autoRunning = true
        model.testDeliverItem = { delivery in
            delivering += 1; defer { delivering -= 1 }
            if delivery.item.id == "job-0" {
                let deadline = Date().addingTimeInterval(5)
                while delivering < 3 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
                precondition(delivering == 3)
                throw fail(Message(.error_pixel_temperature, "40"))
            }
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        await model.batch()
        precondition(model.status.key == .status_waiting && model.failed == 0 && model.autoRunning)
        precondition((model.nextRun?.timeIntervalSinceNow ?? 0) > 55 && delivering == 0 && model.activeIDs.isEmpty && model.testReservedPixelBytes == 0)
        model.testDeliverItem = { delivery in
            model.rows.removeAll { $0.id == delivery.item.id }; model.rows.append(row(delivery.item.id, "transferred"))
        }
        await model.batch(); precondition(model.completed == 3 && model.delivered == 3)
        model.pause()
        print("PASS: one temporary interruption cancels peers, schedules automatic recovery and resumes all prepared tasks")

        let gate = PreparationGate()
        var holding = false, entered = false
        let holder = Task { try await gate.withPermit { holding = true; defer { holding = false }; try await Task.sleep(nanoseconds: 60_000_000_000) } }
        while !holding { await Task.yield() }
        let waiter = Task { try await gate.withPermit { entered = true } }
        await Task.yield(); waiter.cancel()
        do { try await waiter.value; preconditionFailure("Cancelled waiter entered") } catch is CancellationError {}
        holder.cancel(); do { try await holder.value } catch is CancellationError {}
        try await gate.withPermit { entered = true }; precondition(entered && !holding)
        print("PASS: preparation permit cancellation does not leak or block later work")

        let events = ProgressEvents()
        _ = try await processOutput(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo 'progress: transferring'; sleep 0.3; echo 'progress: verifying'"], onProgress: { events.append($0) })
        precondition(events.values == ["transferring", "verifying"])
        let old = try JSONDecoder().decode(QueueRow.self, from: Data(#"{"asset_id":"old","filename":"old.jpg","phase":"transferred","timestamp_ms":0}"#.utf8))
        precondition(old.bytes == nil)
        let sized = try JSONDecoder().decode(QueueRow.self, from: Data(#"{"asset_id":"new","filename":"new.jpg","phase":"prepared","timestamp_ms":0,"bytes":12345678}"#.utf8))
        precondition(sized.bytes == 12345678)
        print("PASS: live subprocess stages and optional size decoding for old/new queue records")
    }
}
