import Foundation

// Capability-based adapter for the recognized Google Photos device-cleanup flow.
// Unknown pages fail closed, regardless of version. Never infer cloud backup from the queue.
enum CleanupIssue: Error {
    case unsupported, locked, page, account, waiting, nothing, timeout, pending, unstable, foreground, backup
    var key: TextKey {
        switch self {
        case .unsupported: return .cleanup_unsupported
        case .locked: return .cleanup_locked
        case .page, .unstable: return .cleanup_page_unknown
        case .account: return .cleanup_account_changed
        case .waiting: return .cleanup_waiting
        case .foreground: return .cleanup_foreground
        case .backup: return .cleanup_backup_wait
        case .nothing: return .cleanup_nothing
        case .timeout: return .cleanup_timeout
        case .pending: return .cleanup_pending
        }
    }
}

struct CleanupNode {
    let attributes: [String: String]
    var text: String { attributes["text"] ?? "" }
    var description: String { attributes["content-desc"] ?? "" }
    var id: String { attributes["resource-id"] ?? "" }
    var point: (Int, Int)? {
        guard attributes["enabled"] == "true", attributes["clickable"] == "true",
              let bounds = attributes["bounds"] else { return nil }
        let numbers = bounds.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 4, numbers[2] > numbers[0], numbers[3] > numbers[1],
              numbers.allSatisfy({ $0 >= 0 && $0 < 20_000 }) else { return nil }
        return ((numbers[0] + numbers[2]) / 2, (numbers[1] + numbers[3]) / 2)
    }
}

final class CleanupXML: NSObject, XMLParserDelegate {
    var nodes: [CleanupNode] = []
    var parents: [Int?] = []
    private var stack: [Int] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "node" {
            parents.append(stack.last); stack.append(nodes.count); nodes.append(CleanupNode(attributes: attributes))
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "node" { _ = stack.popLast() }
    }
    static func read(_ xml: String) throws -> CleanupXML {
        guard xml.utf8.count < 2_000_000, !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else { throw CleanupIssue.page }
        let result = CleanupXML(), parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false; parser.delegate = result
        guard parser.parse(), !result.nodes.isEmpty else { throw CleanupIssue.page }
        let packages = Set(result.nodes.compactMap { $0.attributes["package"] }.filter { !$0.isEmpty })
        guard packages.contains(PixelCleanup.package), packages.isSubset(of: [PixelCleanup.package, "com.android.systemui"]) else { throw CleanupIssue.page }
        return result
    }
    func node(_ suffix: String) -> CleanupNode? {
        let found = nodes.filter { $0.id == PixelCleanup.package + ":id/" + suffix }
        return found.count == 1 ? found[0] : nil
    }
    func menuButton() -> CleanupNode? {
        let found = nodes.indices.filter { nodes[$0].id == PixelCleanup.package + ":id/og_bento_card_title" && ["释放此设备的空间", "Free up space on this device"].contains(nodes[$0].text) }
        guard found.count == 1 else { return nil }
        var index: Int? = found[0]
        while let current = index {
            if nodes[current].point != nil { return nodes[current] }
            index = parents[current]
        }
        return nil
    }
    var account: String? {
        guard let disc = node("selected_account_disc") else { return nil }
        let text = disc.description
        let regex = try! NSRegularExpression(pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: .caseInsensitive)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let range = Range(matches[0].range, in: text) else { return nil }
        return stableID(String(text[range]).lowercased())
    }
    var completed: Bool {
        guard let title = node("free_up_space_completed_title"), node("done_button")?.point != nil else { return false }
        return title.text.hasPrefix("您已释放 ") || title.text.hasPrefix("You freed up ")
    }
    var empty: Bool {
        guard let title = node("title"), node("close_button")?.point != nil else { return false }
        return ["没有可释放的空间", "Nothing to free up"].contains(title.text)
    }
    var progress: Bool { node("free_up_space_progress_text") != nil }
    var progressPercent: Double? {
        guard let label = node("free_up_space_progress_text")?.text else { return nil }
        let regex = try! NSRegularExpression(pattern: #"(?<![\d.\-])(\d{1,3}(?:\.\d+)?)\s*[%％]"#)
        let matches = regex.matches(in: label, range: NSRange(label.startIndex..., in: label))
        guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: label),
              let value = Double(label[range]), (0...100).contains(value) else { return nil }
        return value
    }
    var confirmation: CleanupNode? {
        guard let tip = node("safetyTip"), let button = node("free_up_button"), button.point != nil,
              tip.text.hasPrefix("这些内容已按照您选择的画质安全备份。") || tip.text.hasPrefix("These items have been safely backed up"),
              button.text.hasPrefix("释放 ") || button.text.hasPrefix("Free up "),
              button.text.contains(where: { $0.isNumber }) else { return nil }
        return button
    }
}

enum CleanupProgress: Equatable {
    case checkingDevice, openingPhotos, checkingAccount, openingCleanup, confirming, releasing(Double?), verifyingSpace, returningHome, returnHomeFailed, restartingPhotos, waitingForPage
    var message: Message {
        switch self {
        case .checkingDevice: return Message(.cleanup_stage_device)
        case .openingPhotos: return Message(.cleanup_stage_open)
        case .checkingAccount: return Message(.cleanup_stage_account)
        case .openingCleanup: return Message(.cleanup_stage_offer)
        case .confirming: return Message(.cleanup_stage_confirm)
        case .releasing(let percent):
            if let percent { return Message(.cleanup_stage_percent, String(format: "%.0f", percent)) }
            return Message(.cleanup_stage_release)
        case .verifyingSpace: return Message(.cleanup_stage_verify)
        case .returningHome: return Message(.cleanup_stage_home)
        case .returnHomeFailed: return Message(.cleanup_home_failed)
        case .restartingPhotos: return Message(.cleanup_restart_photos)
        case .waitingForPage: return Message(.cleanup_wait_page)
        }
    }
    var fraction: Double? {
        if case .releasing(let percent) = self, let percent { return percent / 100 }
        return nil
    }
    var isReleasing: Bool { if case .releasing = self { return true }; return false }
}

enum CleanupResult {
    case completed(reclaimed: Int64)
    case reconciled
}

@MainActor final class PixelCleanup {
    nonisolated static let package = "com.google.android.apps.photos"
    typealias Command = ([String], Double) async throws -> String
    let command: Command
    let sleep: (UInt64) async throws -> Void
    init(command: @escaping Command, sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.command = command; self.sleep = sleep
    }
    convenience init(adb: String, serial: String) {
        self.init(command: { args, timeout in
            try await processOutput(URL(fileURLWithPath: adb), ["-s", serial] + args, timeout: timeout)
        })
    }
    func preflight() async throws {
        let product = try await command(["shell", "getprop", "ro.product.device"], 20).trimmingCharacters(in: .whitespacesAndNewlines)
        let android = try await command(["shell", "getprop", "ro.build.version.release"], 20).trimmingCharacters(in: .whitespacesAndNewlines)
        let versions = try await command(["shell", "dumpsys", "package", Self.package], 20)
        let version = versions.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("versionName=") }?.trimmingCharacters(in: .whitespaces)
        // Keep the device/OS baseline; a Photos version identifies the installation,
        // not its compatibility. Fresh UI checks gate every cleanup action.
        guard ["marlin", "sailfish"].contains(product), android == "10",
              let version, !version.dropFirst("versionName=".count).trimmingCharacters(in: .whitespaces).isEmpty else { throw CleanupIssue.unsupported }
        try await wakeScreen()
        let activity = try await command(["shell", "dumpsys", "activity", "activities"], 20)
        guard let foreground = activity.split(separator: "\n").first(where: { $0.contains("mResumedActivity:") }),
              [Self.package + "/", "com.google.android.apps.nexuslauncher/", "com.android.launcher3/"].contains(where: { foreground.contains($0) }) else { throw CleanupIssue.foreground }
    }
    private func wakeScreen() async throws {
        _ = try await command(["shell", "input", "keyevent", "KEYCODE_WAKEUP"], 10)
        try await sleep(300_000_000)
        let policy = try await command(["shell", "dumpsys", "window", "policy"], 20)
        let lines = Set(policy.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        if lines.contains("showing=true") {
            // Dismiss only Android's non-secure swipe screen; never a PIN/password lock.
            guard lines.contains("secure=false"), lines.contains("inputRestricted=false") else { throw CleanupIssue.locked }
            _ = try await command(["shell", "wm", "dismiss-keyguard"], 10)
            try await sleep(300_000_000)
        }
        try await unlocked()
    }
    private func unlocked() async throws {
        let policy = try await command(["shell", "dumpsys", "window", "policy"], 20)
        let lines = Set(policy.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        guard lines.contains("inputRestricted=false"), lines.contains("showing=false"), !lines.contains("showing=true") else { throw CleanupIssue.locked }
    }
    func snapshot() async throws -> CleanupXML {
        try Task.checkCancellation()
        try await wakeScreen()
        // A new path for every read prevents an idle-timeout from reusing stale XML.
        let path = "/data/local/tmp/pixelbridge-cleanup-\(UUID().uuidString).xml"
        do {
            let output = try await command(["shell", "uiautomator", "dump", path], 20)
            guard output.contains("UI hierchary dumped to: " + path), !output.contains("ERROR") else { throw CleanupIssue.unstable }
            let xml = try await command(["exec-out", "cat", path], 10)
            _ = try? await command(["shell", "rm", "-f", path], 10)
            return try CleanupXML.read(xml)
        } catch {
            _ = try? await command(["shell", "rm", "-f", path], 10)
            throw error
        }
    }
    private func tap(_ node: CleanupNode) async throws {
        try Task.checkCancellation(); try await unlocked()
        guard let point = node.point else { throw CleanupIssue.page }
        _ = try await command(["shell", "input", "tap", String(point.0), String(point.1)], 10)
        try await sleep(500_000_000)
    }
    private func open(progress: (CleanupProgress) -> Void) async throws -> CleanupXML {
        _ = try await command(["shell", "input", "keyevent", "KEYCODE_WAKEUP"], 10)
        _ = try await command(["shell", "monkey", "-p", Self.package, "-c", "android.intent.category.LAUNCHER", "1"], 20)
        try await sleep(700_000_000)
        return try await navigationSnapshot(progress: progress)
    }
    private func navigationSnapshot(progress: (CleanupProgress) -> Void) async throws -> CleanupXML {
        for attempt in 0..<3 {
            do { return try await snapshot() }
            catch CleanupIssue.unstable {
                guard attempt < 2 else { throw CleanupIssue.unstable }
                progress(.waitingForPage)
                try await sleep(1_000_000_000)
            }
        }
        throw CleanupIssue.unstable
    }
    private func offer(from initial: CleanupXML, account expected: String?, allowRecovery: Bool,
                       progress: (CleanupProgress) -> Void) async throws -> (String, CleanupXML) {
        do {
            return try await navigateToOffer(from: initial, account: expected, progress: progress)
        } catch CleanupIssue.page {
            guard allowRecovery else { throw CleanupIssue.page }
            // Retry navigation only, never the cleanup action or an unresolved operation.
            // Read again before stopping Photos: another cleanup may have started meanwhile.
            let current = try await navigationSnapshot(progress: progress)
            guard !current.progress, !current.completed else { throw CleanupIssue.pending }
            if let actual = current.account, let expected, actual != expected { throw CleanupIssue.account }
            try await preflight()
            try Task.checkCancellation()
            progress(.restartingPhotos)
            try Task.checkCancellation()
            _ = try await command(["shell", "am", "force-stop", Self.package], 10)
            try Task.checkCancellation()
            let reopened = try await open(progress: progress)
            // Deliberately no recursive recovery: one restart per invocation.
            return try await navigateToOffer(from: reopened, account: expected, progress: progress)
        }
    }
    private func navigateToOffer(from initial: CleanupXML, account expected: String?,
                                 progress: (CleanupProgress) -> Void) async throws -> (String, CleanupXML) {
        var page = initial
        if page.progress { throw CleanupIssue.pending }
        if page.completed, let done = page.node("done_button") {
            try await tap(done); page = try await navigationSnapshot(progress: progress)
        }
        if page.account == nil, let close = page.node("og_bento_toolbar_close_button") ?? page.node("close_button") {
            try await tap(close); page = try await navigationSnapshot(progress: progress)
        }
        progress(.checkingAccount)
        guard let account = page.account, let disc = page.node("selected_account_disc") else { throw CleanupIssue.page }
        guard expected == nil || expected == account else { throw CleanupIssue.account }
        try await tap(disc)
        progress(.openingCleanup)
        page = try await navigationSnapshot(progress: progress)
        guard let entry = page.menuButton() else { throw CleanupIssue.page }
        // Google Photos, not global upload status, determines eligible copies.
        try await tap(entry)
        progress(.confirming)
        page = try await navigationSnapshot(progress: progress)
        guard page.empty || page.confirmation != nil || page.progress else { throw CleanupIssue.page }
        return (account, page)
    }
    // Probe the complete navigation path before binding the account. Never tap the
    // free-up button during setup; an empty page validates navigation only. Runtime
    // relies on Google Photos to select eligible copies on its safe-backup confirmation.
    func inspectAccount(progress: (CleanupProgress) -> Void = { _ in }) async throws -> String {
        progress(.checkingDevice)
        try await preflight()
        progress(.openingPhotos)
        let initial = try await open(progress: progress)
        let (account, page) = try await offer(from: initial, account: nil, allowRecovery: true, progress: progress)
        guard page.empty || page.confirmation != nil else { throw CleanupIssue.page }
        return account
    }
    func freeBytes() async throws -> Int64 {
        let text = try await command(["shell", "df", "-k", "/sdcard"], 20)
        guard let line = text.split(separator: "\n").last else { throw CleanupIssue.page }
        let values = line.split(whereSeparator: \.isWhitespace)
        guard values.count >= 6, let free = Int64(values[3]), free >= 0, free < Int64.max / 1024 else { throw CleanupIssue.page }
        return free * 1024
    }
    // pending is persisted before clicking, including ambiguous tap failures or app restarts.
    func run(account: String, pending: Bool, progress: (CleanupProgress) -> Void = { _ in }, started: () -> Void, finished: () -> Void) async throws -> CleanupResult {
        progress(.checkingDevice)
        try await preflight()
        let before = try await freeBytes()
        progress(.openingPhotos)
        let initial = try await open(progress: progress)
        if pending && (initial.progress || initial.completed) {
            return try await waitForCompletion(before: before, progress: progress, finished: finished)
        }
        let (_, offered) = try await offer(from: initial, account: account, allowRecovery: !pending, progress: progress)
        var page = offered
        if pending && page.progress { return try await waitForCompletion(before: before, progress: progress, finished: finished) }
        if page.empty {
            if pending { finished(); return .reconciled }
            throw CleanupIssue.nothing
        }
        if page.progress { throw CleanupIssue.pending }
        guard page.confirmation != nil else { throw CleanupIssue.page }
        if pending {
            // The known official UI is offering a fresh action, so the previous operation
            // has ended. Reconcile without pressing that action a second time.
            finished(); return .reconciled
        }
        // Re-read immediately before the only destructive UI action.
        page = try await navigationSnapshot(progress: progress)
        guard let confirm = page.confirmation else { throw CleanupIssue.page }
        started()
        try await tap(confirm)
        return try await waitForCompletion(before: before, progress: progress, finished: finished)
    }
    private func returnToPhotos(from page: CleanupXML, progress: (CleanupProgress) -> Void) async throws {
        progress(.returningHome)
        do {
            guard let done = page.node("done_button") else { throw CleanupIssue.page }
            try await tap(done)
            let page = try await navigationSnapshot(progress: progress)
            guard page.account != nil else { throw CleanupIssue.page }
        } catch is CancellationError { throw CancellationError() }
        catch {
            // Cleanup was already confirmed and measured. Navigation failure must
            // not turn a completed cleanup into an uncertain destructive operation.
            progress(.returnHomeFailed)
        }
    }
    private func waitForCompletion(before: Int64, progress: (CleanupProgress) -> Void, finished: () -> Void) async throws -> CleanupResult {
        progress(.releasing(nil))
        // UI Automator may time out while Google Photos animates. Retry fresh reads;
        // free-space growth alone is never a completion signal.
        for _ in 0..<40 {
            try Task.checkCancellation()
            do {
                let page = try await snapshot()
                if page.completed {
                    progress(.verifyingSpace)
                    let after = try await freeBytes()
                    finished()
                    try await returnToPhotos(from: page, progress: progress)
                    return .completed(reclaimed: max(0, after - before))
                }
                guard page.progress else { throw CleanupIssue.pending }
                progress(.releasing(page.progressPercent))
            } catch is CancellationError { throw CancellationError() }
            catch CleanupIssue.unstable { /* Animation: retry with a fresh path. */ }
            catch { throw error }
            try await sleep(3_000_000_000)
        }
        throw CleanupIssue.timeout
    }
}
