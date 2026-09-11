import AppKit
import Photos
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class BridgeModel: ObservableObject {
    @Published var rows: [QueueRow] = [] {
        didSet { phases = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.phase) }) }
    }
    @Published private(set) var phases: [String: String] = [:]
    @Published private(set) var pendingRetryIDs: Set<String> = []
    @Published private(set) var taskMutationIDs: Set<String> = []
    @Published private(set) var pausing = false
    @Published private(set) var galleryRevision = 0
    @Published private(set) var lastLibraryRefresh: Date?
    @Published var library: [LibraryItem] = [] {
        didSet { libraryKinds = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0.kind) }) }
    }
    private(set) var libraryKinds: [String: String] = [:]
    @Published var gallery: [String: [LibraryItem]] = [:]
    @Published var totalAssets = 0
    @Published var libraryCounts = Message.empty
    @Published var devices: [DeviceInfo] = []
    @Published var adbPath = ""
    @Published var deviceMessage = Message(.device_setup_prompt)
    @Published var deviceMetrics = Message.empty
    @Published var status = Message(.status_ready)
    @Published var detail = Message(.backup_description)
    @Published var busy = false
    @Published var scanning = false
    @Published var installing = false
    @Published var currentName = ""
    @Published var currentItem: LibraryItem?
    @Published private(set) var activeTransfers: [String: ActiveTransfer] = [:]
    var activeIDs: Set<String> { Set(activeTransfers.keys) }
    private let preparationGate = PreparationGate()
    private var pixelReservations: [String: Int64] = [:]
    @Published var concurrentTasks = NumericPreference.concurrentTasks.read() {
        didSet {
            let bounded = NumericPreference.concurrentTasks.save(concurrentTasks)
            if concurrentTasks != bounded { concurrentTasks = bounded }
        }
    }
    @Published private(set) var pixelCleanupEnabled = UserDefaults.standard.bool(forKey: "pixelCleanupEnabled")
    @Published private(set) var cleanupMessage = Message(.cleanup_disabled)
    @Published private(set) var cleanupProgress: CleanupProgress?
    var activityDescription: String { cleanupProgress?.message.text ?? (currentName.isEmpty ? detail.text : currentName) }
    private var cleanupBinding = UserDefaults.standard.dictionary(forKey: "pixelCleanupBinding") as? [String: String] ?? [:]
    private var cleanupPendingDevice = UserDefaults.standard.string(forKey: "pixelCleanupPendingDevice") ?? ""
    private var cleanupTransferBytes = (UserDefaults.standard.object(forKey: "pixelCleanupTransferBytes") as? NSNumber)?.int64Value ?? 0
    private var cleanupHoldDevice = UserDefaults.standard.string(forKey: "pixelCleanupHoldDevice") ?? ""
    // Old attempt timestamps included failed preflight checks; do not migrate them.
    private var lastCleanupAction = UserDefaults.standard.object(forKey: "pixelCleanupLastAction") as? Date ?? .distantPast
    private var cleanupRequired = false
    @Published var completed = 0
    @Published var batchTotal = 0
    @Published var cacheBytes: Int64 = 0
    @Published var logs: [String] = []
    @Published private(set) var logStorageFailed = false
    @Published private(set) var exportingLogs = false
    private let activityLogger: ActivityLogger
    @Published var logRetentionDays = NumericPreference.logRetentionDays.read() {
        didSet {
            let bounded = NumericPreference.logRetentionDays.save(logRetentionDays)
            if logRetentionDays != bounded { logRetentionDays = bounded }
            updateLogPolicy()
        }
    }
    @Published var logStorageMB = NumericPreference.logStorageMB.read() {
        didSet {
            let bounded = NumericPreference.logStorageMB.save(logStorageMB)
            if logStorageMB != bounded { logStorageMB = bounded }
            updateLogPolicy()
        }
    }
    private func updateLogPolicy() {
        activityLogger.configure(days: logRetentionDays, totalBytes: logStorageMB * 1_000_000)
    }
    @Published var authorized = false
    @Published var autoRunning = UserDefaults.standard.bool(forKey: "automatic")
    @Published var nextRun: Date?
    @Published var selectedDevice = UserDefaults.standard.string(forKey: "pixelSerial") ?? "" {
        didSet { UserDefaults.standard.set(selectedDevice, forKey: "pixelSerial") }
    }
    @Published var batchLimit = max(1, UserDefaults.standard.integer(forKey: "batchLimit") == 0 ? 10 : UserDefaults.standard.integer(forKey: "batchLimit")) {
        didSet { UserDefaults.standard.set(batchLimit, forKey: "batchLimit") }
    }
    @Published var cacheGB = max(2, UserDefaults.standard.integer(forKey: "cacheGB") == 0 ? 10 : UserDefaults.standard.integer(forKey: "cacheGB")) {
        didSet { UserDefaults.standard.set(cacheGB, forKey: "cacheGB") }
    }
    @Published var autoReclaimCache = UserDefaults.standard.object(forKey: "autoReclaimCache") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoReclaimCache, forKey: "autoReclaimCache") }
    }
    @Published var intervalMinutes = NumericPreference.intervalMinutes.read() {
        didSet {
            let bounded = NumericPreference.intervalMinutes.save(intervalMinutes)
            // Published setters re-enter observers; only write back when clamping changed the value.
            if intervalMinutes != bounded { intervalMinutes = bounded }
            if autoRunning && !busy { nextRun = Date().addingTimeInterval(Double(intervalMinutes * 60)) }
        }
    }
    @Published var macReserveGB = NumericPreference.macReserveGB.read() {
        didSet {
            let bounded = NumericPreference.macReserveGB.save(macReserveGB)
            if macReserveGB != bounded { macReserveGB = bounded }
        }
    }
    @Published var pixelReserveGB = NumericPreference.pixelReserveGB.read() {
        didSet {
            let bounded = NumericPreference.pixelReserveGB.save(pixelReserveGB)
            if pixelReserveGB != bounded { pixelReserveGB = bounded }
        }
    }
    // One space floor for both transfer admission and automatic cleanup.
    private var cleanupMinimumBytes: Int64 { Int64(pixelReserveGB) * 1_000_000_000 + max(0, cleanupTransferBytes) }

    @Published var maxTemperatureC = NumericPreference.maxTemperatureC.read() {
        didSet {
            let bounded = NumericPreference.maxTemperatureC.save(maxTemperatureC)
            if maxTemperatureC != bounded { maxTemperatureC = bounded }
        }
    }
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    private var observer: LibraryObserver?
    private var observedAssets: PHFetchResult<PHAsset>?
    private var refreshTask: Task<Void, Never>?
    private var libraryRevision = 0
    private var scannedRevision = -1
    private var lastScan = Date.distantPast
    private var newAssetsPending = false
    private var started = false
    private var stopRequested = false
    private var timer: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    #if PIXELBRIDGE_TESTING
    var testBatchOperation: (() async -> Void)?
    var testPrepareBatch: (() async throws -> Void)?
    var testCoreURL: URL?
    func testReloadQueue() async throws { try await refreshQueue() }
    func testSetRetry(_ id: String, _ value: RetryInfo) { retries[id] = value }
    var testGuardDevice: (() async throws -> Void)?
    var testProcessItem: ((LibraryItem, QueueRow?) async throws -> Void)?
    var testPrepareItem: ((LibraryItem, QueueRow?) async throws -> PreparedDelivery)?
    var testDeliverItem: ((PreparedDelivery) async throws -> Void)?
    var testCleanup: (() async throws -> Void)?
    var testCleanupAdapter: PixelCleanup?
    var testCleanupDeviceStatus: (() async throws -> String)?
    var testSpaceGuard: ((Double) async throws -> Void)?
    var testReservedPixelBytes: Int64 { pixelReservations.values.reduce(0, +) }
    #endif
    private var retries: [String: RetryInfo] = [:]
    private let state: URL
    private let staging: URL
    init(root: URL = bridgeRoot) {
        state = root.appendingPathComponent("State"); staging = root.appendingPathComponent("Staging")
        activityLogger = ActivityLogger(state: state)
        if !cleanupPendingDevice.isEmpty { cleanupMessage = Message(.cleanup_pending) }
        else if !cleanupHoldDevice.isEmpty && pixelCleanupEnabled { cleanupMessage = Message(.cleanup_holding) }
        else if pixelCleanupEnabled { cleanupMessage = Message(.cleanup_enabled) }
    }
    private var core: URL {
        #if PIXELBRIDGE_TESTING
        if let testCoreURL { return testCoreURL }
        #endif
        return Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("pixelbridge-core")
    }
    private var exiftool: URL { Bundle.main.resourceURL!.appendingPathComponent("exiftool/exiftool") }
    var needsAttention: Bool { [.status_waiting, .status_attention].contains(status.key) }
    var delivered: Int { rows.filter(\.delivered).count }
    var failed: Int { rows.filter { $0.phase == "failed" }.count }
    var ready: Bool { authorized && !selectedDevice.isEmpty && !adbPath.isEmpty }
    var displayDevice: String { devices.first { $0.id == selectedDevice }?.label ?? tr(.device_unselected) }

    func launch() async {
        guard !started else { return }; started = true
        do {
            try ensureDirectory(state); try ensureDirectory(staging)
            do { logs = try await activityLogger.load() }
            catch { logStorageFailed = true }
            if let data = try? Data(contentsOf: state.appendingPathComponent("retry.json")) {
                retries = (try? JSONDecoder().decode([String: RetryInfo].self, from: data)) ?? [:]
            }
            try await refreshQueue()
            authorized = [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite))
            detectADB()
            await refreshDevice()
            if authorized { observeLibrary(); await scan() }
            if autoRunning { enqueueFailedTasks(); nextRun = Date() }
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                    guard let self else { return }
                    let access = [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite))
                    if self.authorized != access {
                        self.authorized = access
                        if access { self.observeLibrary(); self.libraryRevision += 1 }
                        else { self.library = []; self.gallery = [:]; self.totalAssets = 0; self.libraryCounts = Message(.photos_access_closed) }
                    }
                    if access && !self.scanning && !self.busy && (self.libraryRevision != self.scannedRevision || Date().timeIntervalSince(self.lastScan) >= 600) { await self.scan() }
                    if self.autoRunning && self.worker == nil && !self.busy && !self.scanning && (self.nextRun ?? .distantPast) <= Date() {
                        await self.batch()
                    }
                }
            }
        } catch { report(error) }
    }
    func requestPhotos() async {
        NSApp.activate(ignoringOtherApps: true)
        status = Message(.status_permission_pending)
        let result = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorized = [.authorized, .limited].contains(result)
        if authorized { observeLibrary(); status = Message(.status_library_connected); await scan() }
        else { status = Message(.status_permission_required); detail = Message(.photos_permission_help) }
    }
    private func observeLibrary() {
        guard observer == nil else { return }
        let observer = LibraryObserver { [weak self] change in
            Task { @MainActor [weak self] in self?.libraryChanged(change) }
        }
        self.observer = observer
        PHPhotoLibrary.shared().register(observer)
    }
    private func libraryChanged(_ change: PHChange) {
        if let observedAssets, change.changeDetails(for: observedAssets) == nil { return }
        libraryRevision += 1
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard let self, self.authorized, !self.scanning else { return }
            await self.scan()
        }
    }
    func scan(force: Bool = false) async {
        guard authorized, !scanning else { return }
        if !force && scannedRevision == libraryRevision && Date().timeIntervalSince(lastScan) < 600 { return }
        scanning = true
        let revision = libraryRevision
        let previousItems = library
        let hadSnapshot = observedAssets != nil
        let result = await Task.detached(priority: .utility) { () -> ([LibraryItem], Int, Message, PHFetchResult<PHAsset>, [String: [LibraryItem]], Int) in
            let options = libraryFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets = PHAsset.fetchAssets(with: options)
            await MainActor.run { self.totalAssets = assets.count }
            let previous = Dictionary(uniqueKeysWithValues: previousItems.map { ($0.id, $0) })
            var items: [LibraryItem] = []
            items.reserveCapacity(assets.count)
            var gallery: [String: [LibraryItem]] = [:]
            var added = 0
            var live = 0; var photos = 0; var videos = 0
            assets.enumerateObjects { asset, _, _ in
                guard asset.mediaType == .image || asset.mediaType == .video else { return }
                let kind = asset.mediaType == .video ? "video" : (asset.mediaSubtypes.contains(.photoLive) ? "motion" : "photo")
                if kind == "video" { videos += 1 } else if kind == "motion" { live += 1 } else { photos += 1 }
                // Avoid one Photos database round-trip per resource during a full-library scan.
                // Names are resolved only when an asset is actually exported.
                let date = asset.creationDate ?? .distantPast
                let id = asset.localIdentifier
                let item: LibraryItem
                if let old = previous[id], old.date == date, old.kind == kind, old.modified == asset.modificationDate { item = old }
                else { item = LibraryItem(id: id, name: date.formatted(date: .abbreviated, time: .shortened), date: date, kind: kind, modified: asset.modificationDate) }
                if previous[id] == nil { added += 1 }
                items.append(item)
                gallery["all", default: []].append(item)
                gallery[kind, default: []].append(item)
            }
            return (items, assets.count, Message(.library_counts, String(describing: photos.formatted()), String(describing: live.formatted()), String(describing: videos.formatted())), assets, gallery, added)
        }.value
        guard [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else {
            authorized = false; library = []; gallery = [:]; totalAssets = 0; libraryCounts = Message(.photos_access_closed)
            scanning = false
            return
        }
        if library != result.0 { library = result.0 }
        if gallery != result.4 { gallery = result.4; galleryRevision += 1 }
        if totalAssets != result.1 { totalAssets = result.1 }
        if libraryCounts != result.2 { libraryCounts = result.2 }
        observedAssets = result.3
        scannedRevision = revision; lastScan = Date(); lastLibraryRefresh = lastScan
        if hadSnapshot {
            let added = result.5
            if added > 0 {
                log(tr(.log_library_updated, String(describing: added)))
                if autoRunning { newAssetsPending = true; nextRun = Date() }
            }
        }
        scanning = false
    }
    func detectADB() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            UserDefaults.standard.string(forKey: "customADB") ?? "",
            bridgeRoot.appendingPathComponent("Tools/platform-tools/adb").path,
            home + "/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"
        ]
        adbPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
    func chooseADB() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = tr(.adb_choose_prompt)
        if panel.runModal() == .OK, let url = panel.url {
            guard url.lastPathComponent == "adb", FileManager.default.isExecutableFile(atPath: url.path) else { report(fail(Message(.error_adb_executable))); return }
            UserDefaults.standard.set(url.path, forKey: "customADB"); detectADB()
            Task { await refreshDevice() }
        }
    }
    func installADB() async {
        guard !installing, !busy else { return }
        installing = true; defer { installing = false }
        status = Message(.status_tools_downloading)
        let temp = bridgeRoot.appendingPathComponent("Tools/install-" + UUID().uuidString)
        do {
            try ensureDirectory(temp)
            defer { try? FileManager.default.removeItem(at: temp) }
            let url = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!
            let (download, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw fail(Message(.error_tools_download)) }
            let zip = temp.appendingPathComponent("tools.zip")
            try FileManager.default.moveItem(at: download, to: zip)
            _ = try await processOutput(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, temp.path], timeout: 120)
            let extracted = temp.appendingPathComponent("platform-tools")
            let version = try await processOutput(extracted.appendingPathComponent("adb"), ["version"], timeout: 30)
            guard version.contains("Android Debug Bridge") else { throw fail(Message(.error_tools_validation)) }
            let target = bridgeRoot.appendingPathComponent("Tools/platform-tools")
            // An existing managed install is retained. This action installs missing tools only.
            guard !FileManager.default.fileExists(atPath: target.path) else { throw fail(Message(.error_tools_existing)) }
            try FileManager.default.moveItem(at: extracted, to: target)
            detectADB(); status = Message(.status_tools_installed); log(tr(.log_tools_installed))
            await refreshDevice()
        } catch { report(error) }
    }
    func refreshDevice() async {
        detectADB()
        guard !adbPath.isEmpty else { deviceMessage = Message(.device_tools_required); return }
        do {
            let output = try await processOutput(URL(fileURLWithPath: adbPath), ["devices", "-l"], timeout: 30)
            devices = output.split(separator: "\n").compactMap { line in
                let bits = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard bits.count >= 2, ["device", "unauthorized", "offline"].contains(bits[1]) else { return nil }
                let model = bits.first { $0.hasPrefix("model:") }?.replacingOccurrences(of: "model:", with: "").replacingOccurrences(of: "_", with: " ") ?? bits[0]
                return DeviceInfo(id: bits[0], label: model, state: bits[1])
            }
            if selectedDevice.isEmpty, devices.count == 1, devices[0].label.contains("Pixel") { selectedDevice = devices[0].id }
            guard let device = devices.first(where: { $0.id == selectedDevice }) else { deviceMessage = Message(.device_waiting); deviceMetrics = .empty; return }
            guard device.state == "device" else { deviceMessage = device.state == "unauthorized" ? Message(.device_authorize) : Message(.device_offline); return }
            let json = try await invoke(["device-status", "--adb", adbPath, "--device", selectedDevice, "--max-temperature-c", "100", "--min-free-gb", "0"])
            if let values = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                deviceMetrics = Message(.device_metrics, String(format: "%.0f", values["battery_percent"] as? Double ?? 0), String(format: "%.1f", values["temperature_c"] as? Double ?? 0), String(format: "%.1f", values["free_gb"] as? Double ?? 0))
            }
            deviceMessage = Message(.device_connected, String(describing: device.label))
        } catch { deviceMessage = Message(.device_connection_failed); deviceMetrics = Message(error: error) }
    }
    func startAutomatic() {
        guard !pausing else { return }
        enqueueFailedTasks()
        autoRunning = true; UserDefaults.standard.set(true, forKey: "automatic"); nextRun = Date()
        Task { await batch() }
    }
    func pause() {
        stopRequested = true
        autoRunning = false; UserDefaults.standard.set(false, forKey: "automatic"); nextRun = nil
        pausing = worker != nil
        worker?.cancel()
        status = pausing ? Message(.status_pausing) : Message(.status_paused)
        if !pausing { detail = Message(.backup_paused) }
    }
    func retryNow() {
        guard !pausing else { return }
        guard failed > 0 else { return }
        startAutomatic()
    }
    private func enqueueFailedTasks() {
        let failedIDs = Set(rows.filter { $0.phase == "failed" }.map(\.id))
        pendingRetryIDs.formUnion(failedIDs)
        for id in failedIDs { retries[id] = nil }
        saveRetries()
    }
    func canSkipTask(_ row: QueueRow) -> Bool {
        !row.delivered && row.phase != "skipped" && !activeIDs.contains(row.id) && !taskMutationIDs.contains(row.id)
    }
    func skipTasks(_ selected: [QueueRow]) async {
        let ids = Set(selected.filter(canSkipTask).map(\.id))
        taskMutationIDs.formUnion(ids)
        defer { taskMutationIDs.subtract(ids) }
        for id in ids.sorted() {
            do {
                guard let row = rows.first(where: { $0.id == id }), !row.delivered, !activeIDs.contains(id) else { continue }
                try await transition(id, "skipped", message: tr(.tasks_skipped_by_user))
                pendingRetryIDs.remove(id); retries[id] = nil; saveRetries()
                log(tr(.tasks_skip_logged, row.filename))
            } catch { report(error); break }
        }
    }
    func restoreTask(_ row: QueueRow) async {
        guard row.phase == "skipped", !taskMutationIDs.contains(row.id) else { return }
        taskMutationIDs.insert(row.id)
        defer { taskMutationIDs.remove(row.id) }
        do {
            try await transition(row.id, "failed", message: tr(.tasks_restored))
            retries[row.id] = nil; pendingRetryIDs.insert(row.id); saveRetries()
            if autoRunning { nextRun = Date() }
        } catch { report(error) }
    }
    func taskStatus(_ row: QueueRow) -> TaskStatusFilter {
        TaskStatusFilter.status(of: row, requested: pendingRetryIDs, activeID: busy ? currentItem?.id : nil, activeIDs: activeIDs)
    }
    func taskLabel(_ row: QueueRow) -> String {
        if let active = activeTransfers[row.id], !row.delivered { return tr(active.stage.title) }
        switch taskStatus(row) {
        case .processing: return row.phase == "failed" ? tr(.gallery_processing) : row.label
        case .delivered: return row.label
        default: return tr(taskStatus(row).title)
        }
    }
    // Every entry point shares one owned task so pause cancels real work, and
    // a rapid resume cannot overlap the old worker or lose the batch lease.
    func batch() async {
        guard worker == nil, !busy, !scanning, !installing, !pausing else { return }
        let task = Task { await self.runBatch() }
        worker = task
        await task.value
        worker = nil; pausing = false
    }
    private func runBatch() async {
        #if PIXELBRIDGE_TESTING
        if let testBatchOperation {
            busy = true
            await testBatchOperation()
            busy = false
            return
        }
        #endif
        if Task.isCancelled { status = Message(.status_paused); return }
        let lease: BatchLease
        do {
            guard let acquired = try BatchLease.acquire(at: state.appendingPathComponent("batch.lock")) else {
                status = Message(.status_waiting); detail = Message(.backup_another_instance)
                nextRun = Date().addingTimeInterval(30)
                return
            }
            lease = acquired
        } catch { report(error); nextRun = Date().addingTimeInterval(Double(intervalMinutes * 60)); return }
        defer { lease.release() }
        busy = true; completed = 0; batchTotal = batchLimit
        stopRequested = false
        newAssetsPending = false
        cleanupRequired = false
        var madeAttempt = false
        var interrupted = false
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: tr(.backup_activity_reason))
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            busy = false; currentName = ""; currentItem = nil
            activeTransfers.removeAll(); pixelReservations.removeAll()
            if autoRunning {
                let available = Set(library.map(\.id)).subtracting(rows.filter { $0.delivered || $0.phase == "skipped" }.map(\.id))
                nextRun = nextBackupCheck(now: Date(), interval: Double(intervalMinutes * 60),
                    interrupted: interrupted, urgent: newAssetsPending || (madeAttempt && !pendingRetryIDs.isEmpty),
                    retries: retries, eligibleIDs: available)
            }
        }
        do {
            try await prepareBatch()
            pendingRetryIDs.subtract(rows.filter(\.delivered).map(\.id))
            try await checkPixelCleanup()
            if autoReclaimCache { await reclaimDeliveredCache() }
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let availableIDs = Set(library.map(\.id))
            pendingRetryIDs.formIntersection(availableIDs)
            let candidates = transferCandidates(library: library, rows: rows, retries: retries,
                requested: pendingRetryIDs, limit: batchLimit, now: Date())
            batchTotal = candidates.count
            var failures = 0
            madeAttempt = !candidates.isEmpty
            try await withThrowingTaskGroup(of: Bool.self) { group in
                var iterator = candidates.makeIterator()
                for _ in 0..<min(concurrentTasks, candidates.count) {
                    if let item = iterator.next() {
                        group.addTask { try await self.executeItem(item, prior: byID[item.id]) }
                    }
                }
                while let succeeded = try await group.next() {
                    if !succeeded { failures += 1 }
                    try Task.checkCancellation()
                    if let item = iterator.next() {
                        group.addTask { try await self.executeItem(item, prior: byID[item.id]) }
                    }
                }
            }
            cacheBytes = await measuredCacheBytes()
            status = stopRequested ? Message(.status_paused) : (autoRunning ? Message(.status_automatic) : Message(.status_batch_finished))
            detail = Message(.batch_summary, String(completed), String(failures))
            if candidates.isEmpty { detail = Message(.batch_empty, String(describing: intervalMinutes)) }
        } catch is CancellationError {
            status = Message(.status_paused); detail = Message(.backup_paused)
        } catch {
            interrupted = true
            var attemptedCleanup = false
            if cleanupRequired && pixelCleanupEnabled && !Task.isCancelled {
                attemptedCleanup = true
                do { try await checkPixelCleanup(force: true) }
                catch { cleanupMessage = cleanupFailure(error) }
            }
            status = stopRequested ? Message(.status_paused) : Message(.status_waiting)
            let cleanupError = error is CleanupIssue || (error as? BridgeFailure)?.message.key?.rawValue.hasPrefix("cleanup_") == true
            detail = stopRequested ? Message(.backup_paused) : (attemptedCleanup || cleanupError ? cleanupMessage : Message(error: error))
            if !stopRequested && !attemptedCleanup && !cleanupError { log(error.localizedDescription) }
        }
    }
    private func executeItem(_ item: LibraryItem, prior: QueueRow?) async throws -> Bool {
        try Task.checkCancellation()
        guard !taskMutationIDs.contains(item.id), !rows.contains(where: { $0.id == item.id && ($0.phase == "skipped" || $0.delivered) }) else { return false }
        activeTransfers[item.id] = ActiveTransfer(item: item, filename: item.name)
        updateFocus()
        pendingRetryIDs.remove(item.id)
        defer {
            activeTransfers[item.id] = nil
            pixelReservations[item.id] = nil
            updateFocus()
        }
        do {
            #if PIXELBRIDGE_TESTING
            if let testProcessItem {
                try await guardDevice()
                try await testProcessItem(item, prior)
            } else {
                try await process(item, prior: prior)
            }
            #else
            try await process(item, prior: prior)
            #endif
            retries[item.id] = nil; completed += 1
            saveRetries()
            log(tr(.log_delivered, activeTransfers[item.id]?.filename ?? item.name))
            return true
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let failure = error as? BridgeFailure, failure.message.key == .error_pixel_storage { cleanupRequired = true }
            if isTemporaryInterruption(error) {
                retries[item.id] = nil; saveRetries()
                throw error
            }
            let retry = nextRetry(previous: retries[item.id], now: Date())
            let stopped = shouldStopAutomaticRetry(error, attempts: retry.attempts)
            let name = activeTransfers[item.id]?.filename ?? item.name
            let reason = stopped ? tr(.tasks_stopped_reason, error.localizedDescription) : error.localizedDescription
            retries[item.id] = retry
            saveRetries()
            // If the durable queue write fails, stop the batch instead of silently
            // rediscovering an unrecorded failure on every scheduling pass.
            if prior == nil { _ = try await invoke(["queue-add", "--state-dir", state.path, "--asset-id", item.id, "--filename", name]) }
            try await transition(item.id, stopped ? "skipped" : "failed", message: reason)
            if stopped { retries[item.id] = nil; saveRetries() }
            log("\(name): \(reason)")
            return false
        }
    }
    private func updateStage(_ id: String, _ stage: TaskStage, filename: String? = nil) {
        guard activeTransfers[id] != nil else { return }
        activeTransfers[id]?.stage = stage
        if let filename { activeTransfers[id]?.filename = filename }
        updateFocus()
    }
    private func updateFocus() {
        let focus = currentItem.flatMap { activeTransfers[$0.id] }
            ?? activeTransfers.values.min { $0.started < $1.started }
        currentItem = focus?.item; currentName = focus?.filename ?? ""
        if let focus {
            status = Message(focus.stage == .waiting ? .status_automatic : focus.stage.title)
            detail = .raw(focus.filename)
        }
    }
    private func cleanupFailure(_ error: Error) -> Message {
        if let issue = error as? CleanupIssue { return Message(issue.key) }
        if error is CancellationError { return Message(.cleanup_paused) }
        if let failure = error as? BridgeFailure, failure.message.key != nil { return failure.message }
        return Message(.cleanup_connection_failed)
    }
    func disablePixelCleanup() {
        guard !busy else { return }
        pixelCleanupEnabled = false
        UserDefaults.standard.set(false, forKey: "pixelCleanupEnabled")
        clearCleanupHold()
        cleanupMessage = Message(cleanupPendingDevice.isEmpty ? .cleanup_disabled : .cleanup_pending)
    }
    func enablePixelCleanup() async {
        guard worker == nil, !busy, !scanning, !installing, !pausing else { return }
        let task = Task { @MainActor in
            busy = true; status = Message(.cleanup_checking); cleanupMessage = status
            defer { busy = false; cleanupProgress = nil }
            do {
                guard cleanupPendingDevice.isEmpty else { throw CleanupIssue.pending }
                try ensureDirectory(state)
                guard let lease = try BatchLease.acquire(at: state.appendingPathComponent("batch.lock")) else { throw CleanupIssue.waiting }
                defer { lease.release() }
                await refreshDevice()
                guard !adbPath.isEmpty, !selectedDevice.isEmpty else { throw CleanupIssue.waiting }
                let serial = selectedDevice
                let account = try await PixelCleanup(adb: adbPath, serial: serial).inspectAccount(progress: updateCleanupProgress)
                try Task.checkCancellation()
                guard serial == selectedDevice else { throw CleanupIssue.account }
                if cleanupBinding["device"] != serial || cleanupBinding["account"] != account { clearCleanupHold() }
                cleanupBinding = ["device": serial, "account": account]
                UserDefaults.standard.set(cleanupBinding, forKey: "pixelCleanupBinding")
                pixelCleanupEnabled = true
                UserDefaults.standard.set(true, forKey: "pixelCleanupEnabled")
                cleanupMessage = Message(.cleanup_enabled)
                status = Message(.cleanup_enabled)
            } catch {
                cleanupMessage = cleanupFailure(error); status = Message(.status_attention)
            }
            detail = cleanupMessage
        }
        worker = task; await task.value; worker = nil; pausing = false
    }
    private func holdForCleanup(extraBytes: Int64 = 0) {
        guard !selectedDevice.isEmpty, cleanupHoldDevice.isEmpty || cleanupHoldDevice == selectedDevice else { return }
        cleanupTransferBytes = max(cleanupTransferBytes, extraBytes)
        UserDefaults.standard.set(cleanupTransferBytes, forKey: "pixelCleanupTransferBytes")
        if cleanupHoldDevice.isEmpty {
            cleanupHoldDevice = selectedDevice
            UserDefaults.standard.set(selectedDevice, forKey: "pixelCleanupHoldDevice")
            log(tr(.cleanup_holding))
        }
    }
    private func clearCleanupHold() {
        cleanupHoldDevice = ""
        cleanupTransferBytes = 0
        UserDefaults.standard.removeObject(forKey: "pixelCleanupHoldDevice")
        UserDefaults.standard.removeObject(forKey: "pixelCleanupTransferBytes")
    }
    private func updateCleanupProgress(_ progress: CleanupProgress) {
        let previous = cleanupProgress
        cleanupProgress = progress
        status = Message(progress.isReleasing ? .cleanup_running : .cleanup_checking)
        detail = progress.message
        cleanupMessage = progress.message
        // Percentage refreshes update the UI, not the persistent log on every poll.
        if previous != progress && !(previous?.isReleasing == true && progress.isReleasing) { log(progress.message.text) }
    }
    private func cleanupNotice(_ message: Message) {
        cleanupMessage = message
        detail = message
        log(message.text)
    }
    private func checkPixelCleanup(force: Bool = false) async throws {
        defer { cleanupProgress = nil }
        #if PIXELBRIDGE_TESTING
        if let testCleanup { try await testCleanup(); return }
        #endif
        let pending = !cleanupPendingDevice.isEmpty
        guard pixelCleanupEnabled || pending else { return }
        do {
            guard activeTransfers.isEmpty, pixelReservations.isEmpty else { throw fail(Message(.cleanup_draining)) }
            guard cleanupBinding["device"] == selectedDevice,
                  let account = cleanupBinding["account"], !account.isEmpty,
                  cleanupHoldDevice.isEmpty || cleanupHoldDevice == selectedDevice,
                  !pending || cleanupPendingDevice == selectedDevice else { throw CleanupIssue.account }
            let serial = selectedDevice
            let adapter: PixelCleanup
            #if PIXELBRIDGE_TESTING
            adapter = testCleanupAdapter ?? PixelCleanup(adb: adbPath, serial: serial)
            #else
            adapter = PixelCleanup(adb: adbPath, serial: serial)
            #endif
            if force || pending { holdForCleanup() }
            let threshold = cleanupMinimumBytes
            let available = try await adapter.freeBytes()
            if available < threshold { holdForCleanup() }
            // External/manual cleanup may restore space. An uncertain Google Photos
            // operation must still be reconciled before any transfer is allowed.
            if !pending && available >= threshold {
                if !cleanupHoldDevice.isEmpty {
                    clearCleanupHold()
                    cleanupNotice(Message(.cleanup_space_restored, ByteCountFormatter.string(fromByteCount: available, countStyle: .file)))
                }
                return
            }
            let remaining = 600 - Date().timeIntervalSince(lastCleanupAction)
            if !pending && remaining > 0 {
                throw fail(Message(.cleanup_retry_after, String(Int(ceil(remaining / 60)))))
            }
            status = Message(.cleanup_checking)
            cleanupNotice(Message(.cleanup_check_space, ByteCountFormatter.string(fromByteCount: available, countStyle: .file), ByteCountFormatter.string(fromByteCount: threshold, countStyle: .file)))
            let metrics: String
            #if PIXELBRIDGE_TESTING
            if let testCleanupDeviceStatus { metrics = try await testCleanupDeviceStatus() }
            else { metrics = try await invoke(["device-status", "--adb", adbPath, "--device", serial, "--max-temperature-c", "100", "--min-free-gb", "0"]) }
            #else
            metrics = try await invoke(["device-status", "--adb", adbPath, "--device", serial, "--max-temperature-c", "100", "--min-free-gb", "0"])
            #endif
            guard let values = try JSONSerialization.jsonObject(with: Data(metrics.utf8)) as? [String: Any],
                  values["connected"] as? Bool == true,
                  let temperature = values["temperature_c"] as? Double, temperature.isFinite else {
                throw fail(Message(.cleanup_connection_failed))
            }
            guard temperature <= Double(maxTemperatureC) else {
                throw fail(Message(.cleanup_temperature, String(format: "%.1f", temperature), String(maxTemperatureC)))
            }
            let result = try await adapter.run(account: account, pending: pending, progress: updateCleanupProgress, started: {
                self.cleanupPendingDevice = serial
                UserDefaults.standard.set(serial, forKey: "pixelCleanupPendingDevice")
                // Persist immediately before the cleanup click, not during preflight.
                self.lastCleanupAction = Date()
                UserDefaults.standard.set(self.lastCleanupAction, forKey: "pixelCleanupLastAction")
                self.status = Message(.cleanup_running)
                self.cleanupNotice(Message(.cleanup_action_started))
            }, finished: {
                self.cleanupPendingDevice = ""
                UserDefaults.standard.removeObject(forKey: "pixelCleanupPendingDevice")
            })
            switch result {
            case .completed(let reclaimed):
                cleanupNotice(Message(.cleanup_finished, ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file)))
            case .reconciled:
                cleanupNotice(Message(.cleanup_reconciled))
            }
            updateCleanupProgress(.verifyingSpace)
            let after = try await adapter.freeBytes()
            guard after >= threshold else {
                throw fail(Message(.cleanup_space_low, ByteCountFormatter.string(fromByteCount: after, countStyle: .file), ByteCountFormatter.string(fromByteCount: threshold, countStyle: .file)))
            }
            clearCleanupHold()
            cleanupNotice(Message(.cleanup_space_restored, ByteCountFormatter.string(fromByteCount: after, countStyle: .file)))
            #if PIXELBRIDGE_TESTING
            if testCleanupAdapter == nil { await refreshDevice() }
            #else
            await refreshDevice()
            #endif
        } catch {
            let message = cleanupFailure(error)
            cleanupNotice(message)
            if error is CancellationError { throw CancellationError() }
            // Carry the same concrete reason into the overview and the log.
            throw fail(message)
        }
    }
    private func prepareBatch() async throws {
        #if PIXELBRIDGE_TESTING
        if let testPrepareBatch { try await testPrepareBatch(); return }
        #endif
        guard authorized else { throw fail(Message(.error_photos_permission)) }
        await refreshDevice()
        try Task.checkCancellation()
        guard ready else { throw fail(Message(.error_setup_required)) }
        await scan()
        try Task.checkCancellation()
        try await refreshQueue()
    }
    private func checkDeviceSpace(minimumGB: Double) async throws {
        #if PIXELBRIDGE_TESTING
        if let testSpaceGuard { try await testSpaceGuard(minimumGB); return }
        #endif
        let product = try await processOutput(URL(fileURLWithPath: adbPath), ["-s", selectedDevice, "shell", "getprop", "ro.product.device"], timeout: 30).trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["marlin", "sailfish"].contains(product) else { throw fail(Message(.error_pixel_generation)) }
        _ = try await invoke(["device-status", "--adb", adbPath, "--device", selectedDevice,
            "--max-temperature-c", String(maxTemperatureC), "--min-free-gb", String(minimumGB)])
    }
    private func guardDevice(extraBytes: Int64 = 0, cacheExtraBytes: Int64 = 0) async throws {
        try Task.checkCancellation()
        if (pixelCleanupEnabled && !cleanupHoldDevice.isEmpty) || !cleanupPendingDevice.isEmpty {
            cleanupRequired = true
            throw fail(Message(.cleanup_draining))
        }
        #if PIXELBRIDGE_TESTING
        if let testGuardDevice { try await testGuardDevice(); return }
        #endif
        guard !selectedDevice.isEmpty, !adbPath.isEmpty else { throw fail(Message(.error_pixel_waiting)) }
        let transferBytes = extraBytes + pixelReservations.values.reduce(0, +)
        let minimumGB = Double(pixelReserveGB) + Double(transferBytes) / 1_000_000_000
        do {
            try await checkDeviceSpace(minimumGB: minimumGB)
        } catch {
            let message = error.localizedDescription
            if message.contains("Pixel is too warm") {
                throw fail(Message(.error_pixel_temperature, String(describing: maxTemperatureC)))
            }
            if message.contains("below the batch reserve") {
                cleanupRequired = true
                if pixelCleanupEnabled { holdForCleanup(extraBytes: transferBytes) }
                throw fail(Message(.error_pixel_storage))
            }
            if message.contains("Pixel is not ready") || message.contains("device offline") || message.contains("not found") {
                throw fail(Message(.error_pixel_disconnected))
            }
            throw error
        }
        cacheBytes = await measuredCacheBytes()
        guard cacheBytes + cacheExtraBytes <= Int64(cacheGB) * 1_000_000_000 else { throw fail(Message(.error_cache_budget, String(describing: cacheGB))) }
        guard diskFree(state.deletingLastPathComponent()) > Int64(macReserveGB) * 1_000_000_000 + cacheExtraBytes else { throw fail(Message(.error_mac_storage, String(describing: macReserveGB))) }
    }
    private func process(_ item: LibraryItem, prior: QueueRow?) async throws {
        let delivery = try await preparationGate.withPermit {
            try await self.guardDevice()
            return try await self.prepareItem(item, prior: prior)
        }
        try await deliver(delivery)
    }
    private func prepareItem(_ item: LibraryItem, prior: QueueRow?) async throws -> PreparedDelivery {
        try Task.checkCancellation()
        updateStage(item.id, .exporting)
        #if PIXELBRIDGE_TESTING
        if let testPrepareItem { return try await testPrepareItem(item, prior) }
        #endif
        guard [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else { throw fail(Message(.error_photos_permission)) }
        let assetResult = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: libraryFetchOptions())
        guard let asset = assetResult.firstObject else { throw fail(Message(.error_asset_missing)) }
        let resources = PHAssetResource.assetResources(for: asset)
        let videoAsset = asset.mediaType == .video
        guard let primary = resources.first(where: { $0.type == (videoAsset ? .video : .photo) }) else { throw fail(Message(.error_original_missing)) }
        updateStage(item.id, .exporting, filename: primary.originalFilename)
        if prior == nil { _ = try await invoke(["queue-add", "--state-dir", state.path, "--asset-id", item.id, "--filename", primary.originalFilename]) }
        let live = asset.mediaSubtypes.contains(.photoLive)
        let ext = (primary.originalFilename as NSString).pathExtension.lowercased()
        guard ["heic", "heif", "jpg", "jpeg", "png", "gif", "webp", "tif", "tiff", "mov", "mp4", "m4v"].contains(ext) else { throw fail(Message(.error_format_unsupported, String(describing: ext))) }
        let jobDir = staging.appendingPathComponent(stableID(item.id))
        try ensureDirectory(jobDir)
        let source = jobDir.appendingPathComponent("original." + ext)
        let outputName = "PB_" + stableID(item.id) + (live ? "_MP." : ".") + ext
        let prepared = live ? jobDir.appendingPathComponent(outputName) : source
        var hash = prior?.sha256
        let canResumePrepared = prior?.phase == "prepared" && FileManager.default.fileExists(atPath: prepared.path) && hash != nil
        if canResumePrepared {
            guard try await hashFile(prepared) == hash else {
                // Preserve bad cache for inspection, but never reuse it on the next retry.
                let quarantined = staging.appendingPathComponent(stableID(item.id) + ".corrupt-" + UUID().uuidString)
                try FileManager.default.moveItem(at: jobDir, to: quarantined)
                throw fail(Message(.error_cache_corrupt))
            }
        } else {
            // A prepared state whose file disappeared needs an explicit failed/retry transition.
            if prior?.phase == "prepared" { try await transition(item.id, "failed", message: tr(.queue_prepared_missing)) }
            try await transition(item.id, "exporting")
            updateStage(item.id, .exporting)
            try await exportOriginal(primary, to: source, budget: await availableBudget())
            if live {
                guard let motion = resources.first(where: { $0.type == .pairedVideo }) else { throw fail(Message(.error_motion_missing)) }
                let movie = jobDir.appendingPathComponent("motion.mov")
                try await exportOriginal(motion, to: movie, budget: await availableBudget())
                let imageSize = Int64((try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
                let videoSize = Int64((try movie.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
                try await guardDevice(extraBytes: imageSize + videoSize * 8, cacheExtraBytes: imageSize + videoSize * 8)
                updateStage(item.id, .preparing)
                let text = try await invoke(["prepare", "--image", source.path, "--video", movie.path, "--output", prepared.path, "--exiftool", exiftool.path, "--force"])
                hash = value("sha256", text)
            } else { hash = try await hashFile(prepared) }
            guard let hash else { throw fail(Message(.error_hash_unavailable)) }
            try await transition(item.id, "prepared", hash: hash)
        }
        guard let hash else { throw fail(Message(.error_hash_missing)) }
        let size = Int64((try prepared.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        // Destination uses the stable Photos identity, not a reusable camera filename.
        let delivery = live ? prepared : jobDir.appendingPathComponent(outputName)
        if !live {
            if FileManager.default.fileExists(atPath: delivery.path), try await hashFile(delivery) != hash {
                try FileManager.default.moveItem(at: delivery, to: delivery.appendingPathExtension("corrupt-" + UUID().uuidString))
            }
            if !FileManager.default.fileExists(atPath: delivery.path) { try FileManager.default.linkItem(at: source, to: delivery) }
        }
        let output = try await invoke(["queue-set-size", "--state-dir", state.path, "--asset-id", item.id, "--bytes", String(size)])
        updateQueueRow(try JSONDecoder().decode(QueueRow.self, from: Data(output.utf8)))
        return PreparedDelivery(item: item, file: delivery, hash: hash, bytes: size)
    }
    private func deliver(_ delivery: PreparedDelivery) async throws {
        let item = delivery.item, hash = delivery.hash
        // Reserve before the first await: other workers include this file in their guard.
        pixelReservations[item.id] = delivery.bytes
        defer { pixelReservations[item.id] = nil }
        try await guardDevice()
        updateStage(item.id, .checking)
        #if PIXELBRIDGE_TESTING
        if let testDeliverItem { try await testDeliverItem(delivery); return }
        #endif
        let attemptID = activeTransfers[item.id]?.attemptID
        let output = try await processOutput(core,
            ["push", "--file", delivery.file.path, "--adb", adbPath, "--device", selectedDevice],
            onProgress: { [weak self] value in
                Task { @MainActor in
                    guard let self, self.activeTransfers[item.id]?.attemptID == attemptID else { return }
                    let stages: [String: TaskStage] = ["checking": .checking, "transferring": .transferring, "verifying": .verifying]
                    if let stage = stages[value] { self.updateStage(item.id, stage) }
                }
            })
        guard value("sha256", output) == hash, let remote = value("remote", output) else { throw fail(Message(.error_transfer_verification)) }
        try await transition(item.id, "transferred", hash: hash, remote: remote)
        // A cleanup error must never downgrade a durable, verified delivery to failed.
        if autoReclaimCache {
            do {
                let bytes = try await reclaimCache(item.id)
                log(tr(.log_cache_reclaimed, String(describing: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))))
            } catch { log(tr(.log_cache_retained, String(describing: error.localizedDescription))) }
        }
    }
    private func reclaimCache(_ assetID: String) async throws -> Int64 {
        let output = try await processOutput(core, ["reclaim-cache", "--bridge-root", bridgeRoot.path, "--asset-id", assetID, "--adb", adbPath, "--device", selectedDevice], timeout: 120)
        return Int64(value("reclaimed_bytes", output) ?? "0") ?? 0
    }
    private func reclaimDeliveredCache() async {
        // Only reconsider exact job directories with both a completed queue record and a current Photos asset.
        let folder = staging, snapshot = rows, photos = library
        let candidates = await Task.detached(priority: .utility) {
            let folders = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            let assets = Set(photos.map(\.id))
            return Array(snapshot.lazy.filter { $0.delivered && assets.contains($0.id) && folders.contains(stableID($0.id)) }.prefix(3))
        }.value
        guard !candidates.isEmpty else { return }
        status = Message(.status_reclaiming)
        var count = 0, failures = 0
        var bytes: Int64 = 0
        for (index, row) in candidates.prefix(3).enumerated() {
            if stopRequested || Task.isCancelled { break }
            detail = Message(.cache_verifying, String(describing: index + 1), String(describing: candidates.count), String(describing: row.filename))
            do { bytes += try await reclaimCache(row.id); count += 1 }
            catch {
                failures += 1
                log(tr(.log_cache_file_retained, String(describing: row.filename), String(describing: error.localizedDescription)))
                // Bound repeated verification failures (e.g. an unplugged Pixel); try again next round.
                if failures >= 3 { break }
            }
        }
        cacheBytes = await measuredCacheBytes()
        if count > 0 { log(tr(.log_cache_batch_reclaimed, String(describing: count), String(describing: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))) }
    }
    private func measuredCacheBytes() async -> Int64 {
        let folder = staging
        return await Task.detached(priority: .utility) { folderBytes(folder) }.value
    }
    private func availableBudget() async -> Int64 {
        max(0, min(Int64(cacheGB) * 1_000_000_000 - (await measuredCacheBytes()), diskFree(state.deletingLastPathComponent()) - Int64(macReserveGB) * 1_000_000_000))
    }
    private func hashFile(_ url: URL) async throws -> String {
        guard let hash = value("sha256", try await invoke(["hash", "--file", url.path])) else { throw fail(Message(.error_hash_failed)) }; return hash
    }
    private func value(_ key: String, _ output: String) -> String? { output.split(separator: "\n").first { $0.hasPrefix(key + ":") }.map { $0.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces) } }
    private func invoke(_ args: [String]) async throws -> String {
        let executable = core
        if args.first?.hasPrefix("queue-") == true {
            // Finish short durable queue transactions even if pause arrives.
            return try await Task.detached { try await processOutput(executable, args, timeout: 30) }.value
        }
        return try await processOutput(executable, args)
    }
    private func transition(_ id: String, _ phase: String, hash: String? = nil, remote: String? = nil, message: String? = nil) async throws {
        var args = ["queue-transition", "--state-dir", state.path, "--asset-id", id, "--phase", phase]
        if let hash { args += ["--sha256", hash] }; if let remote { args += ["--remote", remote] }; if let message { args += ["--message", message] }
        let output = try await invoke(args)
        updateQueueRow(try JSONDecoder().decode(QueueRow.self, from: Data(output.utf8)))
    }
    private func updateQueueRow(_ row: QueueRow) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) { rows.remove(at: index) }
        rows.insert(row, at: 0)
    }
    private func refreshQueue() async throws {
        let output = try await invoke(["queue-list", "--state-dir", state.path])
        rows = try await Task.detached(priority: .utility) {
            try JSONDecoder().decode([QueueRow].self, from: Data(output.utf8)).sorted { $0.timestamp_ms > $1.timestamp_ms }
        }.value
        cacheBytes = await measuredCacheBytes()
    }
    private func saveRetries() { if let data = try? JSONEncoder().encode(retries) { try? data.write(to: state.appendingPathComponent("retry.json"), options: .atomic) } }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginEnabled = SMAppService.mainApp.status == .enabled }
        catch { report(error) }
    }
    func showData() { NSWorkspace.shared.open(bridgeRoot) }
    func showSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!) }
    private func report(_ error: Error) { status = Message(.status_attention); detail = Message(error: error); log(error.localizedDescription) }
    func showLogHistory() {
        NSWorkspace.shared.open(activityLogger.directory)
    }
    func exportLogs() {
        guard !exportingLogs else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "PixelBridge-logs.txt"
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            self.exportingLogs = true
            Task { @MainActor in
                defer { self.exportingLogs = false }
                do {
                    try await self.activityLogger.export(to: destination)
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch {
                    let alert = NSAlert()
                    alert.messageText = tr(.logs_export_failed)
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
    private func log(_ text: String) {
        logs.insert(Date().formatted(date: .numeric, time: .standard) + "  " + text.replacingOccurrences(of: "\n", with: " "), at: 0)
        if logs.count > 200 { logs.removeLast() }
        activityLogger.append(logs[0]) { [weak self] success in
            Task { @MainActor in self?.logStorageFailed = !success }
        }
    }
}
