import Foundation

// Runs independently of the main actor, including while an OS call blocks it.
final class TransferWatchdog: @unchecked Sendable {
    struct Snapshot: Sendable {
        let operation: String
        let idleSeconds: Double
        let elapsedSeconds: Double
    }
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var lastProgress = ProcessInfo.processInfo.systemUptime
    private var operation = "starting"
    private var waitingForPermit = false
    private var stopped = false
    private var timedOutAt: Double?
    private var reportedUnresponsive = false
    private var cancel: (@Sendable () -> Void)?
    private let idleLimit: Double
    private let totalLimit: Double
    private let grace: Double
    private let onTimeout: @Sendable (Snapshot) -> Void
    private let onUnresponsive: @Sendable (Snapshot) -> Void
    private let onStop: @Sendable () -> Void
    private var timer: DispatchSourceTimer?
    init(idleLimit: Double = 900, totalLimit: Double = 21_600, grace: Double = 30,
         onTimeout: @escaping @Sendable (Snapshot) -> Void,
         onUnresponsive: @escaping @Sendable (Snapshot) -> Void, onStop: @escaping @Sendable () -> Void = {}) {
        self.idleLimit = idleLimit; self.totalLimit = totalLimit; self.grace = grace
        self.onTimeout = onTimeout; self.onUnresponsive = onUnresponsive; self.onStop = onStop
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "org.pixelbridge.transfer-watchdog", qos: .utility))
        timer.schedule(deadline: .now() + min(1, idleLimit), repeating: min(1, idleLimit))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume()
    }
    func attach(_ cancel: @escaping @Sendable () -> Void) {
        lock.lock(); self.cancel = cancel; let expired = timedOutAt != nil; lock.unlock()
        if expired { DispatchQueue.global(qos: .utility).async(execute: cancel) }
    }
    func progress(operation: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, timedOutAt == nil else { return }
        if let operation { self.operation = operation }
        lastProgress = ProcessInfo.processInfo.systemUptime
    }
    func waitingForPreparation(_ waiting: Bool) {
        lock.lock(); waitingForPermit = waiting; lastProgress = ProcessInfo.processInfo.systemUptime; lock.unlock()
    }
    var expired: Bool { lock.lock(); defer { lock.unlock() }; return timedOutAt != nil }
    func stop() {
        lock.lock(); let wasStopped = stopped; stopped = true; cancel = nil; lock.unlock()
        timer?.cancel()
        if !wasStopped { onStop() }
    }
    deinit { timer?.cancel() }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let snapshot = Snapshot(operation: operation, idleSeconds: now - lastProgress, elapsedSeconds: now - started)
        if let timeout = timedOutAt {
            guard !reportedUnresponsive, now - timeout >= grace else { lock.unlock(); return }
            reportedUnresponsive = true; lock.unlock(); onUnresponsive(snapshot)
        } else if (!waitingForPermit && now - lastProgress >= idleLimit) || now - started >= totalLimit {
            timedOutAt = now; let cancel = cancel; lock.unlock()
            // A blocking cancellation handler must not block the watchdog.
            if let cancel { DispatchQueue.global(qos: .utility).async(execute: cancel) }
            onTimeout(snapshot)
        } else { lock.unlock() }
    }
}

enum TransferActivity {
    @TaskLocal static var watchdog: TransferWatchdog?
}

// Keep ownership until cancellation unwinds. Abandoning the old operation could
// allow late callbacks to overwrite the next attempt's cache or queue records.
func watchedTransfer<T>(watchdog: TransferWatchdog, operation: @escaping @MainActor () async throws -> T) async throws -> T {
    let task = Task { @MainActor in
        try await TransferActivity.$watchdog.withValue(watchdog) { try await operation() }
    }
    watchdog.attach { task.cancel() }
    defer { watchdog.stop() }
    return try await withTaskCancellationHandler {
        do { return try await task.value }
        catch {
            if Task.isCancelled { throw CancellationError() }
            if watchdog.expired { throw fail(Message(.error_item_stalled)) }
            throw error
        }
    } onCancel: { task.cancel() }
}

struct StalledTransferRecovery: Codable, Sendable {
    let assetID: String
    let filename: String
    let attemptID: String
    let operation: String
    let timestamp: Date
}

// Serializes receipt creation with completion, so a late timeout callback cannot
// leave a recovery request behind after the operation has returned.
final class StalledTransferTicket: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var finished = false
    init(directory: URL, attemptID: UUID) { url = directory.appendingPathComponent(attemptID.uuidString + ".json") }
    func persist(_ record: StalledTransferRecovery) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        try ensureDirectory(url.deletingLastPathComponent())
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        return true
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        finished = true
        try? FileManager.default.removeItem(at: url)
    }
}

// A persisted rate limit also applies after relaunch. Never restart repeatedly
// because of a library-wide problem, or launch more than one helper per hour.
final class StallRestartPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private let receipt: URL
    init(state: URL) { receipt = state.appendingPathComponent("last-stall-restart.json") }
    func claim(enabled: Bool, now: Date = Date()) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return false }
        if FileManager.default.fileExists(atPath: receipt.path) {
            let previous = try JSONDecoder().decode(Date.self, from: Data(contentsOf: receipt))
            guard now.timeIntervalSince(previous) >= 3600 else { return false }
        }
        try JSONEncoder().encode(now).write(to: receipt, options: .atomic)
        return true
    }
}

func launchStallRecovery(app: URL, receipt: URL, onFailure: @escaping @Sendable (Int32) -> Void) throws {
    let helper = Process()
    helper.executableURL = app.appendingPathComponent("Contents/MacOS/PixelBridgeRecovery")
    helper.arguments = [app.path, receipt.path]
    helper.terminationHandler = { process in if process.terminationStatus != 0 { onFailure(process.terminationStatus) } }
    helper.standardInput = FileHandle.nullDevice
    helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
    try helper.run()
}
