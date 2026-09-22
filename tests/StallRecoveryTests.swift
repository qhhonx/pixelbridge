import Foundation

@main struct StallRecoveryTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pixelbridge-stall-" + UUID().uuidString)
        try ensureDirectory(root)
        try ensureDirectory(root.appendingPathComponent("State"))
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults.standard
        let keys = ["automatic", "autoReclaimCache", "concurrentTasks", "batchLimit"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let core = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("target/debug/pixelbridge")
        let model = BridgeModel(root: root)
        model.testCoreURL = core; model.testPrepareBatch = {}; model.testGuardDevice = {}
        model.autoRunning = false; model.autoReclaimCache = false; model.concurrentTasks = 1; model.batchLimit = 10
        model.testStallTimeout = 0.2; model.testStallGrace = 0.1
        func item(_ id: String) -> LibraryItem { LibraryItem(id: id, name: id + ".jpg", date: Date(), kind: "photo") }
        model.library = [item("stuck"), item("good")]
        var completed: [String] = []
        model.testProcessItem = { current, _ in
            if current.id == "stuck" { try await Task.sleep(nanoseconds: 60_000_000_000) }
            completed.append(current.id)
        }
        let start = Date()
        await model.batch()
        precondition(Date().timeIntervalSince(start) < 5)
        precondition(completed == ["good"] && model.failed == 1)
        precondition(model.rows.first?.message == tr(.error_item_stalled))
        // The cooled-down failed asset must not immediately take the first slot.
        completed = []
        await model.batch()
        precondition(completed == ["good"])
        print("PASS: a stalled photo cancels, enters cooldown, and a single-worker batch continues with the next photo")

        model.library = [item("download-timeout"), item("good")]
        model.testProcessItem = { current, _ in
            if current.id == "download-timeout" { throw fail(Message(.error_icloud_timeout)) }
            completed.append(current.id)
        }
        completed = []; await model.batch()
        precondition(completed == ["good"] && model.rows.contains { $0.id == "download-timeout" && $0.phase == "failed" })
        precondition(!isTemporaryInterruption(fail(Message(.error_icloud_timeout))))
        print("PASS: PhotoKit download timeout affects one asset rather than interrupting the entire batch")

        model.library = [item("committed"), item("good")]
        model.testProcessItem = { current, _ in
            if current.id == "committed" {
                model.rows.append(QueueRow(asset_id: current.id, filename: current.name, phase: "transferred",
                    timestamp_ms: 0, sha256: "verified", remote: "Camera/verified.jpg", message: nil))
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
            completed.append(current.id)
        }
        completed = []; await model.batch()
        precondition(completed == ["good"] && model.completed == 2)
        precondition(model.rows.contains { $0.id == "committed" && $0.delivered })
        print("PASS: timeout after a verified queue commit preserves successful delivery")

        let waiting = TransferWatchdog(idleLimit: 0.1, totalLimit: 3, onTimeout: { _ in preconditionFailure("Permit wait timed out") }, onUnresponsive: { _ in preconditionFailure() })
        try await watchedTransfer(watchdog: waiting) {
            waiting.waitingForPreparation(true)
            try await Task.sleep(nanoseconds: 350_000_000)
            waiting.waitingForPreparation(false)
        }
        let bounded = TransferWatchdog(idleLimit: 1, totalLimit: 0.75, onTimeout: { _ in }, onUnresponsive: { _ in preconditionFailure() })
        do {
            try await watchedTransfer(watchdog: bounded) {
                while true {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    bounded.progress()
                }
            }
            preconditionFailure("Total deadline was not enforced")
        } catch let error as BridgeFailure { precondition(error.message.key == .error_item_stalled) }
        print("PASS: preparation waits do not consume the idle deadline; ongoing activity still has an absolute deadline")

        // Continuous real work resets the inactivity deadline.
        let active = TransferWatchdog(idleLimit: 1, totalLimit: 5, grace: 1, onTimeout: { _ in preconditionFailure("Progressing task timed out") }, onUnresponsive: { _ in preconditionFailure() })
        try await watchedTransfer(watchdog: active) {
            for _ in 0..<12 {
                try await Task.sleep(nanoseconds: 100_000_000)
                TransferActivity.watchdog?.progress()
            }
        }
        print("PASS: progress extends the inactivity window")

        // Simulate an OS callback that ignores task cancellation, then arrives late.
        // The watchdog must report it, but must not release ownership early.
        let report = root.appendingPathComponent("unresponsive")
        let unresponsive = TransferWatchdog(idleLimit: 0.5, grace: 0.5, onTimeout: { _ in }, onUnresponsive: { snapshot in
            try! Data(snapshot.operation.utf8).write(to: report)
        })
        let unresponsiveStart = Date()
        try await watchedTransfer(watchdog: unresponsive) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 3) { c.resume() }
            }
        }
        precondition(Date().timeIntervalSince(unresponsiveStart) >= 2.8 && FileManager.default.fileExists(atPath: report.path))
        print("PASS: cancellation-resistant work is detected without abandoning a still-writing operation")

        let ticketDirectory = root.appendingPathComponent("ticket-test")
        let finishedTicket = StalledTransferTicket(directory: ticketDirectory, attemptID: UUID())
        finishedTicket.finish()
        let ticketRecord = StalledTransferRecovery(assetID: "ticket", filename: "ticket.jpg", attemptID: UUID().uuidString, operation: "test", timestamp: Date())
        let accepted = try finishedTicket.persist(ticketRecord)
        precondition(!accepted && !FileManager.default.fileExists(atPath: finishedTicket.url.path))
        let liveTicket = StalledTransferTicket(directory: ticketDirectory, attemptID: UUID())
        let written = try liveTicket.persist(ticketRecord); precondition(written)
        liveTicket.finish(); precondition(!FileManager.default.fileExists(atPath: liveTicket.url.path))
        let policy = StallRestartPolicy(state: root)
        let now = Date()
        let disabled = try policy.claim(enabled: false, now: now); precondition(!disabled)
        let first = try policy.claim(enabled: true, now: now); precondition(first)
        let duplicate = try policy.claim(enabled: true, now: now.addingTimeInterval(1)); precondition(!duplicate)
        let relaunchedPolicy = StallRestartPolicy(state: root)
        let tooSoon = try relaunchedPolicy.claim(enabled: true, now: now.addingTimeInterval(3599)); precondition(!tooSoon)
        let later = try relaunchedPolicy.claim(enabled: true, now: now.addingTimeInterval(3600)); precondition(later)
        print("PASS: finished attempts cannot create restart tickets; opt-in and hourly limit survive relaunch")

        let records = root.appendingPathComponent("State/Stalled")
        try ensureDirectory(records)
        let recovery = StalledTransferRecovery(assetID: "stuck", filename: "stuck.jpg", attemptID: UUID().uuidString,
            operation: "motion_download", timestamp: Date())
        try JSONEncoder().encode(recovery).write(to: records.appendingPathComponent("stuck.json"))
        let relaunched = BridgeModel(root: root)
        relaunched.testCoreURL = core; relaunched.testPrepareBatch = {}; relaunched.testGuardDevice = {}
        relaunched.autoRunning = false; relaunched.autoReclaimCache = false
        try await relaunched.testReloadQueue(); try await relaunched.recoverStalledTransfers()
        relaunched.library = [item("stuck"), item("good")]
        completed = []; relaunched.testProcessItem = { current, _ in completed.append(current.id) }
        await relaunched.batch()
        precondition(completed == ["good"])
        let remaining = try FileManager.default.contentsOfDirectory(atPath: records.path)
        precondition(remaining.isEmpty)
        print("PASS: restart recovery respects cooldown and removes the recovery receipt after durable queue update")
    }
}
