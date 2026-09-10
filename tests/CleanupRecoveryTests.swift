import Foundation

@main struct CleanupRecoveryTests {
    @MainActor static func main() async throws {
        let defaults = UserDefaults.standard
        let keys = ["automatic", "appLanguage", "autoReclaimCache", "concurrentTasks", "pixelReserveGB", "macReserveGB", "maxTemperatureC", "pixelSerial", "pixelCleanupEnabled", "pixelCleanupBinding", "pixelCleanupPendingDevice", "pixelCleanupHoldDevice", "pixelCleanupTransferBytes", "pixelCleanupLastAction", "pixelCleanupLastAttempt"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set("en", forKey: "appLanguage")
        defaults.set(true, forKey: "pixelCleanupEnabled")
        defaults.set("fixture", forKey: "pixelSerial")
        defaults.set(1, forKey: "pixelReserveGB")
        defaults.set(40, forKey: "maxTemperatureC")
        defaults.set(Date(), forKey: "pixelCleanupLastAttempt") // Legacy failed attempts must not impose a cooldown.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ensureDirectory(root.appendingPathComponent("State"))
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = PixelCleanup.package
        func node(_ id: String, _ text: String = "", desc: String = "", click: Bool = false, body: String = "") -> String {
            "<node package=\"\(pkg)\" resource-id=\"\(pkg):id/\(id)\" text=\"\(text)\" content-desc=\"\(desc)\" enabled=\"true\" clickable=\"\(click)\" bounds=\"[10,20][110,120]\">\(body)</node>"
        }
        func xml(_ body: String) -> String { "<hierarchy>\(body)</hierarchy>" }
        let home = xml(node("selected_account_disc", desc: "Account example@example.test", click: true) + node("", "Backup complete"))
        let uploading = home.replacingOccurrences(of: "Backup complete", with: "Backing up")
        let menu = xml(node("", click: true, body: node("og_bento_card_title", "Free up space on this device")) + node("og_bento_card_subtitle", "Backup complete"))
        let confirm = xml(node("safetyTip", "These items have been safely backed up.") + node("free_up_button", "Free up 2 GB", click: true))
        let complete = xml(node("free_up_space_completed_title", "You freed up 2 GB") + node("done_button", "Done", click: true))
        let empty = xml(node("title", "Nothing to free up") + node("close_button", click: true))
        let progress = xml(node("free_up_space_progress_text", "50%"))
        let account = try CleanupXML.read(home).account!
        defaults.set(["device": "fixture", "account": account], forKey: "pixelCleanupBinding")
        var available: Int64 = 1_400_000_000, recovered: Int64 = 5_000_000_000
        var temperature = 39.0, foreground = pkg, pages: [String] = [], taps = 0
        let adapter = PixelCleanup(command: { args, _ in
            if args.contains("ro.product.device") { return "marlin" }
            if args.contains("ro.build.version.release") { return "10" }
            if args.starts(with: ["shell", "dumpsys", "package"]) { return "versionName=8.fixture" }
            if args.starts(with: ["shell", "dumpsys", "activity"]) { return "mResumedActivity: \(foreground)/.Home" }
            if args.starts(with: ["shell", "dumpsys", "window"]) { return "showing=false\ninputRestricted=false" }
            if args.starts(with: ["shell", "df"]) { return "Filesystem 1K-blocks Used Available Use% Mounted\n/data/media 25000000 1000000 \(available / 1024) 10% /storage/emulated" }
            if args.starts(with: ["shell", "uiautomator"]) { return "UI hierchary dumped to: " + args.last! }
            if args.starts(with: ["exec-out", "cat"]) {
                guard !pages.isEmpty else { throw CleanupIssue.page }
                let page = pages.removeFirst()
                if page == complete { available = recovered }
                return page
            }
            if args.starts(with: ["shell", "input", "tap"]) { taps += 1 }
            return ""
        }, sleep: { _ in try Task.checkCancellation() })
        let item = LibraryItem(id: "large-file", name: "large.mov", date: .distantPast, kind: "video")
        var deliveries = 0, requirements: [Double] = []
        func model() -> BridgeModel {
            let model = BridgeModel(root: root)
            model.autoRunning = true; model.autoReclaimCache = false; model.concurrentTasks = 1
            model.library = [item]; model.adbPath = "/fixture/adb"
            model.testPrepareBatch = {}
            model.testCleanupAdapter = adapter
            model.testCleanupDeviceStatus = { "{\"connected\":true,\"temperature_c\":\(temperature)}" }
            model.testSpaceGuard = { needed in
                requirements.append(needed)
                if Double(available) / 1_000_000_000 < needed { throw fail("Pixel free space is below the batch reserve") }
            }
            model.testPrepareItem = { item, _ in
                model.rows = [QueueRow(asset_id: item.id, filename: item.name, phase: "prepared", timestamp_ms: 0, sha256: "verified", remote: nil, message: nil)]
                return PreparedDelivery(item: item, file: root.appendingPathComponent("large.mov"), hash: "verified", bytes: 600_000_000)
            }
            model.testDeliverItem = { delivery in
                deliveries += 1; available -= delivery.bytes
                model.rows = [QueueRow(asset_id: item.id, filename: item.name, phase: "transferred", timestamp_ms: 0, sha256: "verified", remote: "/device/large.mov", message: nil)]
            }
            return model
        }
        let first = model()
        pages = [uploading, menu, empty]
        await first.batch()
        precondition(deliveries == 0 && first.detail.key == .cleanup_nothing)
        precondition(requirements.contains(1.6) && first.rows.first?.phase == "prepared")
        precondition(defaults.string(forKey: "pixelCleanupHoldDevice") == "fixture")
        precondition((defaults.object(forKey: "pixelCleanupTransferBytes") as? NSNumber)?.int64Value == 600_000_000)
        precondition(defaults.object(forKey: "pixelCleanupLastAction") == nil)
        print("PASS: one 1 GB reserve plus a 600 MB file blocks at 1.4 GB; no eligible copies keeps transfers stopped")

        let restarted = model()
        let guards = requirements.count
        temperature = 41.2; pages = []
        await restarted.batch()
        precondition(deliveries == 0 && requirements.count == guards)
        precondition(restarted.detail.key == .cleanup_temperature && restarted.detail.text.contains("41.2") && restarted.detail.text.contains("40"))
        precondition(defaults.object(forKey: "pixelCleanupLastAction") == nil)
        temperature = 39; foreground = "other.app"
        await restarted.batch()
        precondition(restarted.detail.key == .cleanup_foreground && deliveries == 0)
        foreground = pkg; pages = [uploading, menu, empty]
        await restarted.batch()
        precondition(restarted.detail.key == .cleanup_nothing && deliveries == 0)
        pages = [home, menu, empty]
        await restarted.batch()
        precondition(restarted.detail.key == .cleanup_nothing && deliveries == 0)
        precondition(defaults.object(forKey: "pixelCleanupLastAction") == nil)
        print("PASS: restart preserves the required file space; temperature, foreground and empty states block transfers without consuming the action cooldown")

        pages = [uploading, menu.replacingOccurrences(of: "Backup complete", with: "Backing up"), confirm, confirm, progress, complete]; taps = 0
        await restarted.batch()
        precondition(taps == 3 && deliveries == 1 && restarted.delivered == 1)
        precondition(defaults.object(forKey: "pixelCleanupHoldDevice") == nil && defaults.object(forKey: "pixelCleanupPendingDevice") == nil)
        precondition(defaults.object(forKey: "pixelCleanupLastAction") != nil)
        await restarted.batch(); precondition(deliveries == 1)
        print("PASS: ongoing cloud uploads allow eligible cleanup; confirmed completion plus sufficient space releases the queue; completed photos are not transferred again")

        available = 700_000_000
        let cooled = model(); pages = []; taps = 0
        await cooled.batch()
        precondition(cooled.detail.key == .cleanup_retry_after && deliveries == 1 && taps == 0)
        precondition(defaults.string(forKey: "pixelCleanupHoldDevice") == "fixture")
        print("PASS: cooldown after a real action keeps new transfers stopped")

        // An uncertain operation must be observed even when free space already looks sufficient.
        defaults.set("fixture", forKey: "pixelCleanupPendingDevice")
        available = 5_000_000_000
        let uncertain = model(); pages = [progress, xml(node("unknown"))]; taps = 0
        await uncertain.batch()
        precondition(uncertain.detail.key == .cleanup_pending && deliveries == 1 && taps == 0)
        pages = [progress, complete]
        await uncertain.batch()
        precondition(deliveries == 2 && taps == 0)
        print("PASS: high free space cannot bypass pending cleanup; restart reconciliation never sends another cleanup click")

        defaults.removeObject(forKey: "pixelCleanupLastAction")
        available = 700_000_000; recovered = 800_000_000
        let insufficient = model(); pages = [home, menu, confirm, confirm, complete]
        await insufficient.batch()
        precondition(insufficient.detail.key == .cleanup_space_low && deliveries == 2)
        precondition(defaults.string(forKey: "pixelCleanupHoldDevice") == "fixture" && defaults.object(forKey: "pixelCleanupPendingDevice") == nil)
        available = 4_000_000_000; pages = []
        await insufficient.batch()
        precondition(deliveries == 3 && defaults.object(forKey: "pixelCleanupHoldDevice") == nil)
        print("PASS: insufficient cleanup retains the hold; external space recovery safely releases it without another cleanup action")
        defaults.removeObject(forKey: "pixelCleanupLastAction")
        available = 2_500_000_000; pages = [uploading, menu, empty]
        let parallel = model(); parallel.concurrentTasks = 3
        let group = (0..<3).map { LibraryItem(id: "parallel-\($0)", name: "sample.mov", date: .distantPast, kind: "video") }
        parallel.library = group
        parallel.testPrepareItem = { item, _ in
            parallel.rows.append(QueueRow(asset_id: item.id, filename: item.name, phase: "prepared", timestamp_ms: 0, sha256: "verified", remote: nil, message: nil))
            return PreparedDelivery(item: item, file: root.appendingPathComponent(item.id), hash: "verified", bytes: 600_000_000)
        }
        var active = 0
        parallel.testDeliverItem = { _ in
            active += 1; defer { active -= 1 }
            try await Task.sleep(nanoseconds: 60_000_000_000)
            preconditionFailure("Space interruption should cancel existing workers")
        }
        await parallel.batch()
        precondition(active == 0 && parallel.activeIDs.isEmpty && parallel.rows.count == 3)
        precondition(parallel.detail.key == .cleanup_nothing && requirements.contains(2.8))
        precondition((defaults.object(forKey: "pixelCleanupTransferBytes") as? NSNumber)?.int64Value == 1_800_000_000)
        precondition(parallel.rows.allSatisfy { $0.phase == "prepared" })
        parallel.disablePixelCleanup()
        precondition(defaults.object(forKey: "pixelCleanupHoldDevice") == nil)
        print("PASS: concurrent reservations share the same floor; low space drains workers, preserves prepared files and records the full recovery budget")
        parallel.pause()
        for model in [first, restarted, cooled, uncertain, insufficient] { model.pause() }
    }
}
