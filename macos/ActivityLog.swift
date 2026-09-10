import Foundation

// All file access is serialized off the main thread. UI history stays bounded.
final class ActivityLogger: @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "app.pixelbridge.activity-log", qos: .utility)
    private let store: ActivityLogStore
    init(state: URL) {
        directory = state.appendingPathComponent("Logs")
        store = ActivityLogStore(state: state, days: NumericPreference.logRetentionDays.read(), totalBytes: NumericPreference.logStorageMB.read() * 1_000_000)
    }
    func configure(days: Int, totalBytes: Int) {
        queue.async { self.store.configure(days: days, totalBytes: totalBytes) }
    }
    func load() async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.store.recent()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func append(_ line: String, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            do { try self.store.append(line); completion(true) }
            catch { completion(false) }
        }
    }
    func export(to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.store.export(to: destination); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

// Kept independent of the UI so retention, migration and export can be tested on disk.
final class ActivityLogStore {
    let directory: URL
    private let legacy: URL
    private let fm = FileManager.default
    private var days: Int
    private let segmentBytes: Int
    private var totalBytes: Int
    private let now: () -> Date
    private var prepared = false
    private let formatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(secondsFromGMT: 0)
        value.dateFormat = "yyyy-MM-dd"
        return value
    }()
    init(state: URL, days: Int = 7, segmentBytes: Int = 5_000_000, totalBytes: Int = 50_000_000,
         now: @escaping () -> Date = Date.init) {
        precondition(days > 0 && segmentBytes > 32 && totalBytes >= segmentBytes)
        directory = state.appendingPathComponent("Logs")
        legacy = state.appendingPathComponent("activity.log")
        self.days = days; self.segmentBytes = segmentBytes; self.totalBytes = totalBytes; self.now = now
    }
    func configure(days: Int, totalBytes: Int) {
        precondition(days > 0 && totalBytes >= segmentBytes)
        self.days = days; self.totalBytes = totalBytes
    }
    private func files() throws -> [URL] {
        try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            .filter {
                guard $0.lastPathComponent.range(of: #"^activity-\d{4}-\d{2}-\d{2}-(\d{6}|legacy)\.log$"#, options: .regularExpression) != nil else { return false }
                let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values.isRegularFile == true && values.isSymbolicLink != true
            }.sorted { $0.lastPathComponent.replacingOccurrences(of: "legacy", with: "!") < $1.lastPathComponent.replacingOccurrences(of: "legacy", with: "!") }
    }
    private func size(_ file: URL) throws -> Int {
        try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }
    private func prepare() throws {
        if !prepared {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: legacy.path) {
                // A deterministic destination makes a crash between copy and removal safe.
                let importedDate = try legacy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? now()
                let target = directory.appendingPathComponent("activity-\(formatter.string(from: importedDate))-legacy.log")
                if !fm.fileExists(atPath: target.path) {
                    let data = try Data(contentsOf: legacy)
                    try data.write(to: target, options: .atomic)
                }
                try fm.removeItem(at: legacy)
            }
            prepared = true
        }
        try prune()
    }
    private func prune() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cutoff = formatter.string(from: calendar.date(byAdding: .day, value: -(days - 1), to: now())!)
        var retained: [(URL, Int)] = []
        for file in try files() {
            let day = String(file.lastPathComponent.dropFirst("activity-".count).prefix(10))
            if day < cutoff { try fm.removeItem(at: file) }
            else { retained.append((file, try size(file))) }
        }
        var bytes = retained.reduce(0) { $0 + $1.1 }
        for (file, count) in retained where bytes > totalBytes {
            try fm.removeItem(at: file); bytes -= count
        }
    }
    func append(_ line: String) throws {
        try prepare()
        let dayPrefix = "activity-" + formatter.string(from: now()) + "-"
        let today = try files().filter { $0.lastPathComponent.hasPrefix(dayPrefix) && !$0.lastPathComponent.contains("legacy") }
        var data = Data(line.replacingOccurrences(of: "\n", with: " ").utf8)
        let limit = min(16_384, segmentBytes - 1)
        if data.count > limit {
            data = data.prefix(limit - 16)
            while String(data: data, encoding: .utf8) == nil { data.removeLast() }
            data.append(Data("… [truncated]".utf8))
        }
        data.append(10)
        let target: URL
        if let last = today.last, try size(last) + data.count <= segmentBytes { target = last }
        else {
            let index = today.last.flatMap { Int($0.deletingPathExtension().lastPathComponent.suffix(6)) }.map { $0 + 1 } ?? 0
            target = directory.appendingPathComponent(dayPrefix + String(format: "%06d", index) + ".log")
            guard fm.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
        try prune()
    }
    func recent(limit: Int = 200) throws -> [String] {
        try prepare()
        var result: [String] = []
        for file in try files().reversed() {
            let text = try String(contentsOf: file, encoding: .utf8)
            result.append(contentsOf: text.split(separator: "\n").suffix(max(0, limit - result.count)).reversed().map(String.init))
            if result.count >= limit { break }
        }
        return result
    }
    func export(to destination: URL) throws {
        try prepare()
        // Write beside the selected destination, then atomically replace it only on success.
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".pixelbridge-logs-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? fm.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        for file in try files() {
            try output.write(contentsOf: Data(("=== " + file.lastPathComponent + " ===\n").utf8))
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty { try output.write(contentsOf: data) }
            try output.write(contentsOf: Data("\n".utf8))
        }
        try output.close()
        if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: temporary) }
        else { try fm.moveItem(at: temporary, to: destination) }
    }
}
