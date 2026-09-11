import Foundation

@main struct TaskSkippingTests {
    @MainActor static func main() async throws {
        func check(_ value: Bool) { precondition(value) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pixelbridge-skip-\(UUID().uuidString)")
        try ensureDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("State")
        let core = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("target/debug/pixelbridge")
        func invoke(_ args: [String]) async throws {
            _ = try await processOutput(core, args + ["--state-dir", state.path])
        }
        for id in ["manual", "missing", "limit", "completed", "active", "first", "later"] {
            try await invoke(["queue-add", "--asset-id", id, "--filename", id + ".jpg"])
        }
        for phase in ["exporting", "prepared", "transferred"] {
            try await invoke(["queue-transition", "--asset-id", "completed", "--phase", phase, "--sha256", String(repeating: "a", count: 64), "--remote", "/sdcard/example.jpg"])
        }
        let model = BridgeModel(root: root)
        model.testCoreURL = core
        model.autoRunning = false
        model.autoReclaimCache = false
        model.testPrepareBatch = {}
        model.testGuardDevice = {}
        try await model.testReloadQueue()
        let now = Date()
        func item(_ id: String) -> LibraryItem { LibraryItem(id: id, name: id + ".jpg", date: now, kind: "photo") }
        model.library = [item("manual")]
        let manual = model.rows.first { $0.id == "manual" }!
        await model.skipTasks([manual])
        check(model.rows.first { $0.id == "manual" }?.phase == "skipped")
        check(!model.pendingRetryIDs.contains("manual"))
        model.testProcessItem = { _, _ in preconditionFailure("Skipped asset processed") }
        await model.batch()
        check(model.batchTotal == 0)
        model.startAutomatic()
        await Task.yield()
        check(!model.pendingRetryIDs.contains("manual"))
        model.pause()
        while model.busy || model.pausing { await Task.yield() }
        let restored = BridgeModel(root: root)
        restored.testCoreURL = core
        restored.autoRunning = false
        try await restored.testReloadQueue()
        let skipped = restored.rows.first { $0.id == "manual" }!
        check(skipped.phase == "skipped" && restored.taskStatus(skipped) == .skipped)
        check(transferCandidates(library: [item("manual")], rows: restored.rows, retries: [:], requested: ["manual"], limit: 10, now: now).isEmpty)
        await restored.restoreTask(skipped)
        check(restored.rows.first { $0.id == "manual" }?.phase == "failed")
        check(restored.pendingRetryIDs.contains("manual"))
        print("PASS: durable skip survives restart and resume, excludes manual bulk retry; explicit restore requeues")

        model.library = [item("missing")]
        model.testProcessItem = { _, _ in throw fail(Message(.error_asset_missing)) }
        await model.batch()
        check(model.rows.first { $0.id == "missing" }?.phase == "skipped")
        model.testProcessItem = { _, _ in preconditionFailure("Missing asset repeatedly processed") }
        await model.batch()
        check(model.batchTotal == 0)
        model.library = [item("limit")]
        model.testSetRetry("limit", RetryInfo(attempts: 4, next: .distantPast))
        model.testProcessItem = { _, _ in throw fail("A repeatable conversion error") }
        await model.batch()
        check(model.rows.first { $0.id == "limit" }?.phase == "skipped")
        let completed = model.rows.first { $0.id == "completed" }!
        await model.skipTasks([completed])
        check(model.rows.first { $0.id == "completed" }?.delivered == true)
        let active = model.rows.first { $0.id == "active" }!
        model.library = [item("active")]
        model.testProcessItem = { _, _ in
            await model.skipTasks([active])
            check(model.rows.first { $0.id == "active" }?.phase == "discovered")
        }
        await model.batch()
        print("PASS: missing assets stop once, fifth permanent failure stops; completed and active tasks cannot be skipped")

        model.library = [item("first"), item("later")]
        let oldConcurrency = model.concurrentTasks
        defer { model.concurrentTasks = oldConcurrency }
        model.concurrentTasks = 1
        var processed: [String] = []
        model.testProcessItem = { current, _ in
            processed.append(current.id)
            if current.id == "first" {
                await model.skipTasks([model.rows.first { $0.id == "later" }!])
            }
        }
        await model.batch()
        check(processed == ["first"] && model.rows.first { $0.id == "later" }?.phase == "skipped")
        print("PASS: skipping a waiting task prevents a stale batch snapshot from starting it")

        for key: TextKey in [.error_pixel_temperature, .error_pixel_storage, .error_photos_permission, .error_icloud_timeout] {
            check(!shouldStopAutomaticRetry(fail(Message(key)), attempts: 100))
        }
        check(!shouldStopAutomaticRetry(fail("conversion"), attempts: 4))
        check(shouldStopAutomaticRetry(fail("conversion"), attempts: 5))
        check(libraryFetchOptions().includeAllBurstAssets)
        check(photoDeliveryState(phase: "skipped", retry: true, active: false) == .queue_skipped)
        check(photoStatusSymbol(.queue_skipped) == "minus.circle")
        check(filteredTasks(model.rows, status: .skipped, kind: "all", kinds: [:], requested: [], activeID: nil).allSatisfy { $0.phase == "skipped" })
        print("PASS: environmental interruptions remain recoverable; burst lookup membership and skipped status agree")
    }
}
