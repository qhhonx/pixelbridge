import AppKit
import Foundation

@main struct RecoveryTests {
    @MainActor static func main() async throws {
        let suite = UserDefaults.standard
        let savedAutomatic = suite.object(forKey: "automatic")
        defer { if let savedAutomatic { suite.set(savedAutomatic, forKey: "automatic") } else { suite.removeObject(forKey: "automatic") } }
        let now = Date()
        let library = (0..<1100).map { LibraryItem(id: String($0), name: "sample-\($0)", date: now, kind: "photo") }
        func row(_ id: Int, _ phase: String) -> QueueRow {
            QueueRow(asset_id: String(id), filename: "sample", phase: phase, timestamp_ms: 0, sha256: nil, remote: nil, message: nil)
        }
        let rows = [row(1000, "failed"), row(1001, "prepared"), row(1002, "transferred"), row(1003, "backup_seen"), row(1004, "motion_verified")]
        let backoff = ["1000": RetryInfo(attempts: 5, next: now.addingTimeInterval(9999))]
        let manual = transferCandidates(library: library, rows: rows, retries: backoff, requested: ["1000", "1002", "1003", "1004"], limit: 2, now: now)
        precondition(manual.map(\.id) == ["1000", "1001"], "Manual retry must outrank 1,000 newer photos and exclude delivered IDs")
        let normal = transferCandidates(library: library, rows: rows, retries: backoff, requested: [], limit: 2, now: now)
        precondition(normal.map(\.id) == ["1001", "0"], "Automatic retry must respect cooldown and resume interrupted work")
        var requested = Set((800..<1000).map(String.init))
        let failures = (800..<1000).map { row($0, "failed") }
        var attempted = Set<String>()
        var queue = failures
        for _ in 0..<4 {
            let selected = transferCandidates(library: library, rows: queue, retries: [:], requested: requested, limit: 50, now: now)
            precondition(selected.count == 50)
            let ids = Set(selected.map(\.id)); precondition(attempted.isDisjoint(with: ids))
            attempted.formUnion(ids); requested.subtract(ids)
            queue = queue.map { ids.contains($0.id) ? row(Int($0.id)!, "transferred") : $0 }
        }
        precondition(requested.isEmpty && attempted.count == 200)
        precondition(photoDeliveryState(phase: nil, retry: false, active: false) == .gallery_not_transferred)
        precondition(photoDeliveryState(phase: "failed", retry: true, active: false) == .queue_retry_queued)
        precondition(photoDeliveryState(phase: "transferred", retry: true, active: true) == .metric_delivered)
        precondition(photoDeliveryState(phase: "backup_seen", retry: false, active: false) == .queue_backed_up)
        print("PASS: retry priority, cooldown, four-batch draining, completed deduplication and honest per-photo statuses")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ensureDirectory(directory); defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("partial")
        let sink = try ResourceSink(destination, budget: 100)
        var completions = 0
        sink.observeCompletion { error in precondition(error is CancellationError); completions += 1 }
        sink.receive(Data([1, 2, 3])); sink.abort(CancellationError())
        sink.receive(Data([4, 5])); sink.finish(nil); sink.abort(CancellationError())
        precondition(completions == 1)
        let bytes = try Data(contentsOf: destination); precondition(bytes.count == 3)
        let earlySink = try ResourceSink(directory.appendingPathComponent("early"), budget: 100)
        earlySink.abort(CancellationError())
        earlySink.observeCompletion { error in precondition(error is CancellationError); completions += 1 }
        precondition(completions == 2)
        print("PASS: stalled download cancellation resumes once, rejects late writes/callbacks, handles cancellation before registration")

        let childPID = directory.appendingPathComponent("child.pid")
        let shell = "sleep 60 & child=$!; echo $child > '" + childPID.path + "'; wait $child"
        let process = Task { try await processOutput(URL(fileURLWithPath: "/bin/sh"), ["-c", shell]) }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: childPID.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pid = Int32(try String(contentsOf: childPID, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        let start = Date(); process.cancel()
        do { _ = try await process.value; preconditionFailure("Cancellation must propagate") } catch is CancellationError {} catch { throw error }
        precondition(Date().timeIntervalSince(start) < 3)
        // A child may briefly be a reaped zombie; it must no longer run.
        let state = try await processOutput(URL(fileURLWithPath: "/bin/sh"), ["-c", "ps -o stat= -p \(pid) || true"])
        precondition(state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.contains("Z"))
        print("PASS: active subprocess and child cancelled in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")

        try ensureDirectory(directory.appendingPathComponent("State"))
        let model = BridgeModel(root: directory); model.autoRunning = false
        var starts = 0, finished = 0
        model.testBatchOperation = {
            starts += 1
            do { _ = try await processOutput(URL(fileURLWithPath: "/bin/sleep"), ["60"]) } catch {}
            finished += 1
        }
        let first = Task { await model.batch() }
        while !model.busy { await Task.yield() }
        await model.batch(); precondition(starts == 1, "Concurrent entry points must not overlap")
        model.pause(); precondition(model.pausing && !model.autoRunning && model.nextRun == nil)
        model.startAutomatic(); precondition(!model.autoRunning, "Resume must wait for cancellation to release the worker")
        await first.value
        precondition(!model.busy && !model.pausing && finished == 1)
        let second = Task { await model.batch() }
        while !model.busy { await Task.yield() }
        model.pause(); await second.value
        precondition(starts == 2 && finished == 2 && !model.busy)
        model.rows = failures
        model.retryNow()
        precondition(model.pendingRetryIDs.count == 200 && model.autoRunning)
        precondition(model.taskLabel(failures[0]) == tr(.queue_retry_queued))
        while !model.busy { await Task.yield() }
        model.pause()
        while model.pausing { await Task.yield() }
        precondition(!model.busy)
        print("PASS: real model worker ownership, pause, blocked rapid resume, subsequent restart and retry action enqueues 200 failures")
    }
}
