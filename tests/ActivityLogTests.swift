import Foundation

@main struct ActivityLogTests {
    static func main() async throws {
        func check(_ value: Bool) { precondition(value) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pixelbridge-log-tests-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var date = ISO8601DateFormatter().date(from: "2026-09-11T12:00:00Z")!
        let state = root.appendingPathComponent("State")
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        try "old-one\nold-two".write(to: state.appendingPathComponent("activity.log"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: state.appendingPathComponent("activity.log").path)
        let store = ActivityLogStore(state: state, now: { date })
        check(try store.recent() == ["old-two", "old-one"])
        precondition(!fm.fileExists(atPath: state.appendingPathComponent("activity.log").path))
        for i in 0..<500 { try store.append("entry-\(i)") }
        let recent = try store.recent()
        precondition(recent.count == 200 && recent.first == "entry-499" && recent.last == "entry-300")
        let restarted = ActivityLogStore(state: state, now: { date })
        check(try restarted.recent() == recent)
        let exported = root.appendingPathComponent("history.txt")
        try restarted.export(to: exported)
        var text = try String(contentsOf: exported, encoding: .utf8)
        precondition(text.contains("entry-0\n") && text.contains("entry-499\n"))
        precondition(text.components(separatedBy: "old-one").count == 2)
        precondition(text.range(of: "old-one")!.lowerBound < text.range(of: "entry-0")!.lowerBound)
        try store.append("导出包含最后一条 😀")
        try store.export(to: exported)
        text = try String(contentsOf: exported, encoding: .utf8)
        precondition(text.contains("导出包含最后一条 😀"))
        print("PASS: legacy migration once, all 500 entries retained, bounded preview, restart and atomic export replacement")

        let today = date
        date = date.addingTimeInterval(6 * 86400)
        try store.append("day-seven")
        check(try store.recent(limit: 1000).contains("old-one"))
        date = date.addingTimeInterval(86400)
        try store.append("day-eight")
        check(try store.recent(limit: 1000) == ["day-eight", "day-seven"])
        store.configure(days: 1, totalBytes: 50_000_000)
        check(try store.recent() == ["day-eight"])
        print("PASS: seven UTC calendar days retained; day eight expires old files; reduced retention takes effect")

        let small = ActivityLogStore(state: root.appendingPathComponent("Small"), segmentBytes: 128, totalBytes: 300, now: { today })
        for i in 0..<100 { try small.append("\(i)-" + String(repeating: "x", count: 60)) }
        let files = try fm.contentsOfDirectory(at: small.directory, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
        precondition(bytes.reduce(0, +) <= 300 && bytes.allSatisfy { $0 <= 128 })
        check(try small.recent().first!.hasPrefix("99-"))
        try small.append(String(repeating: "照片😀", count: 1000))
        check(try small.recent().first!.contains("truncated"))
        small.configure(days: 7, totalBytes: 128)
        _ = try small.recent()
        let remaining = try fm.contentsOfDirectory(at: small.directory, includingPropertiesForKeys: [.fileSizeKey])
        check(try remaining.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! } <= 128)
        print("PASS: same-day rotation, total-byte cap, latest entries, valid UTF-8 truncation and reduced space limit")

        // The queue guarantees export includes all earlier accepted writes in order.
        let logger = ActivityLogger(state: root.appendingPathComponent("Async"))
        for i in 0..<300 { logger.append("async-\(i)") { precondition($0) } }
        let asyncExport = root.appendingPathComponent("async.txt")
        try await logger.export(to: asyncExport)
        let asyncText = try String(contentsOf: asyncExport, encoding: .utf8)
        precondition(asyncText.contains("async-0\n") && asyncText.contains("async-299\n"))
        let lines = try await logger.load()
        precondition(lines.count == 200 && lines.first == "async-299")
        do { try await logger.export(to: root.appendingPathComponent("missing/out.txt")); preconditionFailure("Missing destination accepted") } catch {}
        check(try await logger.load() == lines)
        print("PASS: serialized background writes, export flushes accepted entries, failed export leaves logs intact")
    }
}
