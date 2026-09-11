import AppKit
import Photos
import Foundation
import CryptoKit

struct QueueRow: Decodable, Identifiable {
    let asset_id: String
    let filename: String
    let phase: String
    let timestamp_ms: Double
    let sha256: String?
    let remote: String?
    let message: String?
    var bytes: Int64? = nil
    var id: String { asset_id }
    var delivered: Bool { ["transferred", "backup_seen", "motion_verified"].contains(phase) }
    var label: String {
        ["discovered": tr(.queue_discovered), "exporting": tr(.queue_exporting), "prepared": tr(.queue_prepared), "transferred": tr(.metric_delivered), "backup_seen": tr(.queue_backed_up), "motion_verified": tr(.queue_motion_verified), "failed": tr(.queue_failed), "skipped": tr(.queue_skipped)][phase] ?? phase
    }
}
struct LibraryItem: Identifiable, Equatable {
    let id: String
    let name: String
    let date: Date
    let kind: String
    var modified: Date? = nil
    var diagnosticSnapshot: AssetDiagnosticSnapshot? = nil
}
struct DeviceInfo: Identifiable {
    let id: String
    let label: String
    let state: String
}
struct RetryInfo: Codable {
    var attempts: Int
    var next: Date
}
struct BridgeFailure: LocalizedError {
    var underlying: Error? = nil
    let message: Message
    var errorDescription: String? { message.text }
}
func fail(_ text: String) -> BridgeFailure { BridgeFailure(message: .raw(text)) }
func fail(_ message: Message) -> BridgeFailure { BridgeFailure(message: message) }
func stableID(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
let bridgeRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PixelBridge")
func ensureDirectory(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
func diskFree(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
}
func folderBytes(_ url: URL) -> Int64 {
    guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .fileResourceIdentifierKey]) else { return 0 }
    var seen = Set<AnyHashable>()
    return iterator.compactMap { $0 as? URL }.reduce(Int64(0)) { total, url in
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .fileResourceIdentifierKey])
        // Ordinary deliveries are hard links to originals, not another disk allocation.
        if let identity = values?.fileResourceIdentifier as? AnyHashable, !seen.insert(identity).inserted { return total }
        return total + (values?.isRegularFile == true ? Int64(values?.fileSize ?? 0) : 0)
    }
}
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

// Stop only this invocation and its descendants, never the shared ADB server.
private func terminateProcessTree(_ process: Process) {
    guard process.isRunning else { return }
    let root = process.processIdentifier
    kill(root, SIGSTOP)
    let snapshot = Process(), pipe = Pipe()
    snapshot.executableURL = URL(fileURLWithPath: "/bin/ps")
    snapshot.arguments = ["-axo", "pid=,ppid="]
    snapshot.standardOutput = pipe
    var descendants: [Int32] = []
    if (try? snapshot.run()) != nil {
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        snapshot.waitUntilExit()
        let pairs = text.split(separator: "\n").compactMap { line -> (Int32, Int32)? in
            let numbers = line.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
            return numbers.count == 2 ? (numbers[0], numbers[1]) : nil
        }
        var parents: Set<Int32> = [root]
        while true {
            let children = pairs.filter { parents.contains($0.1) && !parents.contains($0.0) }.map { $0.0 }
            if children.isEmpty { break }
            descendants += children; parents.formUnion(children)
        }
    }
    for pid in descendants.reversed() { kill(pid, SIGTERM) }
    kill(root, SIGTERM); kill(root, SIGCONT)
    Thread.sleep(forTimeInterval: 0.2)
    for pid in descendants.reversed() { kill(pid, SIGKILL) }
    if process.isRunning { kill(root, SIGKILL) }
}

func processOutput(_ executable: URL, _ arguments: [String], timeout: Double = 1800, onProgress: (@Sendable (String) -> Void)? = nil) async throws -> String {
    let cancellation = CancellationFlag()
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("pixelbridge-process-" + UUID().uuidString)
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                defer { try? FileManager.default.removeItem(at: logURL) }
                do {
                    if cancellation.isCancelled { throw CancellationError() }
                    let handle = try FileHandle(forWritingTo: logURL)
                    defer { try? handle.close() }
                    p.executableURL = executable; p.arguments = arguments
                    p.standardOutput = handle; p.standardError = handle
                    var environment = ProcessInfo.processInfo.environment
                    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
                    p.environment = environment
                    try p.run()
                    let progressReader = onProgress == nil ? nil : try FileHandle(forReadingFrom: logURL)
                    defer { try? progressReader?.close() }
                    var progressBuffer = ""
                    var lastProgressRead = Date.distantPast
                    func reportProgress() {
                        guard let progressReader, let data = try? progressReader.readToEnd(), !data.isEmpty else { return }
                        progressBuffer += String(decoding: data, as: UTF8.self)
                        while let end = progressBuffer.firstIndex(of: "\n") {
                            let line = String(progressBuffer[..<end])
                            progressBuffer.removeSubrange(...end)
                            if line.hasPrefix("progress: ") { onProgress?(String(line.dropFirst(10))) }
                        }
                        if progressBuffer.count > 4096 { progressBuffer = String(progressBuffer.suffix(4096)) }
                    }
                    let deadline = Date().addingTimeInterval(timeout)
                    var timedOut = false, cancelled = false
                    while p.isRunning {
                        cancelled = cancellation.isCancelled
                        timedOut = Date() >= deadline
                        if cancelled || timedOut { terminateProcessTree(p); break }
                        if Date().timeIntervalSince(lastProgressRead) >= 0.25 { reportProgress(); lastProgressRead = Date() }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    p.waitUntilExit()
                    reportProgress()
                    if cancelled { throw CancellationError() }
                    if timedOut { throw fail(Message(.error_timeout)) }
                    try handle.synchronize()
                    let output = String(decoding: try Data(contentsOf: logURL), as: UTF8.self)
                    if p.terminationStatus == 0 { continuation.resume(returning: output) }
                    else {
                        let reason = output.isEmpty ? tr(.error_exit_code, String(p.terminationStatus)) : String(output.suffix(2000)).trimmingCharacters(in: .whitespacesAndNewlines)
                        let cause = NSError(domain: "PixelBridge.Process", code: Int(p.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: "Subprocess exited with status \(p.terminationStatus)"])
                        continuation.resume(throwing: BridgeFailure(underlying: cause, message: .raw(reason)))
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    } onCancel: { cancellation.cancel() }
}

// Cancellation closes the partial file and resumes the waiter immediately, even
// if PhotoKit never delivers its completion after a stalled network request.
final class ResourceSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    let budget: Int64
    private var bytes: Int64 = 0
    private var failure: Error?
    private var request: PHAssetResourceDataRequestID?
    private var finished = false
    private var completion: ((Error?) -> Void)?
    init(_ url: URL, budget: Int64) throws {
        self.budget = budget
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }
    func receive(_ data: Data) {
        lock.lock()
        guard !finished, failure == nil else { lock.unlock(); return }
        do {
            guard bytes + Int64(data.count) <= budget else { throw fail(Message(.error_download_budget)) }
            try handle.write(contentsOf: data); bytes += Int64(data.count)
            lock.unlock()
        } catch { failure = error; lock.unlock(); abort(error) }
    }
    func register(_ id: PHAssetResourceDataRequestID) {
        lock.lock(); request = id; let cancel = finished; lock.unlock()
        if cancel { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
    func observeCompletion(_ callback: @escaping (Error?) -> Void) {
        lock.lock()
        if finished { let error = failure; lock.unlock(); callback(error) }
        else { completion = callback; lock.unlock() }
    }
    func abort(_ error: Error) {
        _ = finish(error)
        lock.lock(); let pending = request; lock.unlock()
        if let pending { PHAssetResourceManager.default().cancelDataRequest(pending) }
    }
    @discardableResult func finish(_ error: Error?) -> Error? {
        lock.lock()
        if finished { let result = failure; lock.unlock(); return result }
        finished = true; if failure == nil { failure = error }
        do { try handle.synchronize(); try handle.close() } catch { if failure == nil { failure = error } }
        let result = failure, callback = completion; completion = nil
        lock.unlock()
        callback?(result)
        return result
    }
}
func exportOriginal(_ resource: PHAssetResource, to destination: URL, budget: Int64) async throws {
    try Task.checkCancellation()
    if FileManager.default.fileExists(atPath: destination.path) { return }
    let partial = destination.appendingPathExtension("partial")
    let sink = try ResourceSink(partial, budget: budget)
    let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
    let deadline = DispatchWorkItem { sink.abort(fail(Message(.error_icloud_timeout))) }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 900, execute: deadline)
    defer { deadline.cancel() }
    do {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                sink.observeCompletion { error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
                if Task.isCancelled { sink.abort(CancellationError()); return }
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options,
                    dataReceivedHandler: { sink.receive($0) }, completionHandler: { sink.finish($0) })
                sink.register(id)
            }
        } onCancel: { sink.abort(CancellationError()) }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: partial, to: destination)
    } catch { try? FileManager.default.removeItem(at: partial); throw error }
}

// Retry/interrupted work has priority over new photos, independently of library
// order. Delivered identities remain excluded even when manually requested.
func transferCandidates(library: [LibraryItem], rows: [QueueRow], retries: [String: RetryInfo], requested: Set<String>, limit: Int, now: Date) -> [LibraryItem] {
    let phases = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.phase) })
    let eligible = library.filter { shouldTransfer(phase: phases[$0.id], retryAt: requested.contains($0.id) ? nil : retries[$0.id]?.next, now: now) }
    let manual = eligible.filter { requested.contains($0.id) }
    let resumed = eligible.filter { !requested.contains($0.id) && phases[$0.id] != nil }
    let fresh = eligible.filter { !requested.contains($0.id) && phases[$0.id] == nil }
    return Array((manual + resumed + fresh).prefix(max(0, limit)))
}

// PhotoKit calls this on an arbitrary queue; the owner dispatches to MainActor.
final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let changed: (PHChange) -> Void
    init(changed: @escaping (PHChange) -> Void) { self.changed = changed; super.init() }
    func photoLibraryDidChange(_ changeInstance: PHChange) { changed(changeInstance) }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
}

func shouldTransfer(phase: String?, retryAt: Date?, now: Date) -> Bool {
    guard !["transferred", "backup_seen", "motion_verified", "skipped"].contains(phase ?? "") else { return false }
    return (retryAt ?? .distantPast) <= now
}

// The OS releases this lease after a crash, unlike a sentinel lock file.
final class BatchLease {
    private let handle: FileHandle
    private init(_ handle: FileHandle) { self.handle = handle }
    static func acquire(at url: URL) throws -> BatchLease? {
        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw fail(Message(.error_lock_create)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            try? handle.close()
            if code == EWOULDBLOCK { return nil }
            throw fail(Message(.error_lock_acquire, String(describing: code)))
        }
        return BatchLease(handle)
    }
    func release() { try? handle.close() }
}

enum NumericPreference: String, CaseIterable {
    case intervalMinutes, macReserveGB, pixelReserveGB, maxTemperatureC, concurrentTasks, logRetentionDays, logStorageMB
    var fallback: Int {
        switch self { case .logRetentionDays: return 7; case .logStorageMB: return 50; case .concurrentTasks: return 1; case .intervalMinutes: return 5; case .macReserveGB: return 8; case .pixelReserveGB: return 4; case .maxTemperatureC: return 40 }
    }
    var range: ClosedRange<Int> {
        switch self { case .logRetentionDays: return 1...90; case .logStorageMB: return 10...500; case .concurrentTasks: return 1...3; case .intervalMinutes: return 1...60; case .macReserveGB: return 2...100; case .pixelReserveGB: return 1...32; case .maxTemperatureC: return 35...45 }
    }
    func clamp(_ value: Int) -> Int { min(range.upperBound, max(range.lowerBound, value)) }
    func read(_ defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: rawValue) != nil else { return fallback }
        return clamp(defaults.integer(forKey: rawValue))
    }
    @discardableResult func save(_ value: Int, to defaults: UserDefaults = .standard) -> Int {
        let bounded = clamp(value); defaults.set(bounded, forKey: rawValue); return bounded
    }
}

func photoDeliveryState(phase: String?, retry: Bool, active: Bool) -> TextKey {
    if phase == "skipped" { return .queue_skipped }
    if ["backup_seen", "motion_verified"].contains(phase ?? "") { return .queue_backed_up }
    if phase == "transferred" { return .metric_delivered }
    if active { return .gallery_processing }
    if retry { return .queue_retry_queued }
    if phase == "failed" { return .queue_failed }
    return .gallery_not_transferred
}

// Shared infrastructure failures suspend the batch without penalizing an asset.
func isTemporaryInterruption(_ error: Error, depth: Int = 0) -> Bool {
    guard depth < 8 else { return false }
    if let failure = error as? BridgeFailure,
       [.error_photos_permission, .cleanup_draining, .error_pixel_temperature, .error_pixel_storage, .error_pixel_disconnected,
        .error_pixel_waiting, .error_pixel_generation, .error_cache_budget, .error_mac_storage,
        .error_download_budget, .error_icloud_timeout, .error_timeout].contains(failure.message.key) { return true }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain { return true }
    if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
    if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error,
       isTemporaryInterruption(underlying, depth: depth + 1) { return true }
    // ADB and the Rust helper expose transport failures through stderr.
    let text = ns.localizedDescription.lowercased()
    return ["device offline", "device not found", "no devices/emulators", "device disconnected",
            "no space left on device", "network connection was lost", "internet connection appears to be offline",
            "connection reset", "broken pipe", "transport error", "pixel is not ready",
            "pixel is too warm", "below the batch reserve"].contains { text.contains($0) }
}

// Keep scan, export and thumbnail membership identical, including burst siblings.
func libraryFetchOptions() -> PHFetchOptions {
    let options = PHFetchOptions()
    options.includeAllBurstAssets = true
    return options
}
func shouldStopAutomaticRetry(_ error: Error, attempts: Int) -> Bool {
    if isTemporaryInterruption(error) { return false }
    if let key = (error as? BridgeFailure)?.message.key,
       [.error_asset_missing, .error_original_missing, .error_motion_missing, .error_format_unsupported].contains(key) { return true }
    return attempts >= 5
}

func nextRetry(previous: RetryInfo?, now: Date) -> RetryInfo {
    let attempts = min(30, (previous?.attempts ?? 0) + 1)
    return RetryInfo(attempts: attempts, next: now.addingTimeInterval(min(300, 30 * pow(2, Double(min(attempts - 1, 4))))))
}

func nextBackupCheck(now: Date, interval: TimeInterval, interrupted: Bool,
                     urgent: Bool, retries: [String: RetryInfo], eligibleIDs: Set<String>) -> Date {
    if interrupted { return now.addingTimeInterval(60) }
    if urgent { return now.addingTimeInterval(2) }
    let earliest = retries.filter { eligibleIDs.contains($0.key) }.map { $0.value.next }.min()
    return min(now.addingTimeInterval(interval), max(now.addingTimeInterval(2), earliest ?? now.addingTimeInterval(interval)))
}

enum TaskStatusFilter: String, CaseIterable {
    case all, failed, queued, waiting, processing, delivered, skipped
    var title: TextKey {
        switch self {
        case .skipped: return .queue_skipped
        case .all: return .tasks_status_all
        case .failed: return .queue_failed
        case .queued: return .queue_retry_queued
        case .waiting: return .queue_discovered
        case .processing: return .gallery_processing
        case .delivered: return .metric_delivered
        }
    }
    static func status(of row: QueueRow, requested: Set<String>, activeID: String?, activeIDs: Set<String> = []) -> Self {
        if row.delivered { return .delivered }
        if row.phase == "skipped" { return .skipped }
        if activeID == row.id || activeIDs.contains(row.id) { return .processing }
        if requested.contains(row.id) { return .queued }
        if row.phase == "failed" { return .failed }
        return .waiting
    }
    var symbol: String {
        switch self {
        case .skipped: return "minus.circle"
        case .all: return "line.3.horizontal.decrease.circle"
        case .failed: return "exclamationmark.circle"
        case .queued: return "arrow.clockwise.circle"
        case .waiting: return "clock"
        case .processing: return "arrow.triangle.2.circlepath"
        case .delivered: return "checkmark.circle.fill"
        }
    }
}

func filteredTasks(_ rows: [QueueRow], status: TaskStatusFilter, kind: String,
                   kinds: [String: String], requested: Set<String>, activeID: String?, activeIDs: Set<String> = []) -> [QueueRow] {
    rows.filter { row in
        (status == .all || TaskStatusFilter.status(of: row, requested: requested, activeID: activeID, activeIDs: activeIDs) == status)
            && (kind == "all" || (kinds[row.id] ?? "unknown") == kind)
    }
}

struct PreparedDelivery {
    let item: LibraryItem
    let file: URL
    let hash: String
    let bytes: Int64
}
enum TaskStage: Int {
    case waiting, exporting, preparing, transferring, verifying, checking
    var step: Int { self == .checking ? 2 : rawValue }
    var title: TextKey {
        switch self {
        case .checking: return .tasks_checking
        case .waiting: return .queue_discovered
        case .exporting: return .queue_exporting
        case .preparing: return .tasks_preparing
        case .transferring: return .status_transferring
        case .verifying: return .tasks_verifying
        }
    }
}
struct ActiveTransfer {
    let attemptID = UUID()
    let item: LibraryItem
    var filename: String
    var stage: TaskStage = .waiting
    let started = Date()
}

// Serialize memory-heavy preparation; cancellation removes waiters immediately.
@MainActor final class PreparationGate {
    private var occupied = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    func withPermit<T>(_ operation: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
    private func acquire() async throws {
        try Task.checkCancellation()
        if !occupied { occupied = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { @MainActor in
                if let index = self.waiters.firstIndex(where: { $0.0 == id }) {
                    self.waiters.remove(at: index).1.resume(throwing: CancellationError())
                }
            }
        }
    }
    private func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().1.resume() }
    }
}
