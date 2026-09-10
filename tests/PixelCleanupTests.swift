import Foundation

@main struct PixelCleanupTests {
    @MainActor static func main() async throws {
        func check(_ value: Bool) { precondition(value) }
        let prefix = PixelCleanup.package + ":id/"
        func node(_ id: String, _ text: String = "", desc: String = "", click: Bool = false, body: String = "") -> String {
            "<node package=\"\(PixelCleanup.package)\" resource-id=\"\(prefix + id)\" text=\"\(text)\" content-desc=\"\(desc)\" enabled=\"true\" clickable=\"\(click)\" bounds=\"[10,20][110,120]\">\(body)</node>"
        }
        func xml(_ body: String) -> String { "<hierarchy>\(body)</hierarchy>" }
        let home = xml(node("selected_account_disc", desc: "Account example@example.test", click: true) + node("", "已完成备份"))
        let menu = xml(node("", "", click: true, body: node("og_bento_card_title", "释放此设备的空间")) + node("og_bento_card_subtitle", "备份已完成"))
        let confirm = xml(node("safetyTip", "这些内容已按照您选择的画质安全备份。了解详情") + node("free_up_button", "释放 16.22 GB 空间", click: true))
        let empty = xml(node("title", "没有可释放的空间") + node("close_button", desc: "忽略", click: true))
        let progress = xml(node("free_up_space_progress_text", "已完成 50%，共 16.22 GB"))
        let complete = xml(node("free_up_space_completed_title", "您已释放 16.22 GB 空间") + node("done_button", "完成", click: true))
        let account = try CleanupXML.read(home).account!
        check(try CleanupXML.read(menu).menuButton()?.point?.0 == 60)
        check(try CleanupXML.read(confirm).confirmation != nil)
        let duplicate = xml(node("free_up_button", "释放 16.22 GB 空间", click: true) + node("free_up_button", "释放 16.22 GB 空间", click: true) + node("safetyTip", "安全备份"))
        check(try CleanupXML.read(duplicate).confirmation == nil)
        check(try CleanupXML.read(confirm.replacingOccurrences(of: "安全备份", with: "尚未备份")).confirmation == nil)
        for invalid in ["<broken>", home.replacingOccurrences(of: PixelCleanup.package, with: "other.app"), "<!DOCTYPE x>" + home] {
            do { _ = try CleanupXML.read(invalid); preconditionFailure("Unsafe XML accepted") } catch {}
        }
        let english = xml(node("safetyTip", "These items have been safely backed up.") + node("free_up_button", "Free up 16.22 GB", click: true))
        check(try CleanupXML.read(english).confirmation != nil)
        print("PASS: account fingerprint, parent-button discovery, bilingual confirmation, duplicate IDs, unsafe XML and foreign packages")

        var pages: [String] = [], calls: [[String]] = [], lastDump = "", idleFailures = 0
        var free: Int64 = 1_000_000, version = "7.91.0.973540846", locked = false, swipeScreen = false
        let adapter = PixelCleanup(command: { args, _ in
            calls.append(args)
            if args.contains("ro.product.device") { return "marlin\n" }
            if args.contains("ro.build.version.release") { return "10\n" }
            if args.starts(with: ["shell", "dumpsys", "package"]) { return "versionName=\(version)\nversionName=4.17.0.factory" }
            if args.starts(with: ["shell", "dumpsys", "activity"]) { return "mResumedActivity: ActivityRecord{ test com.google.android.apps.photos/.Home }" }
            if args == ["shell", "wm", "dismiss-keyguard"] { precondition(!locked); swipeScreen = false; return "" }
            if args.starts(with: ["shell", "dumpsys", "window"]) {
                if swipeScreen { return "showing=true\ninputRestricted=false\nsecure=false" }
                return locked ? "showing=true\ninputRestricted=true" : "showing=false\ninputRestricted=false" }
            if args.starts(with: ["shell", "df"]) { return "Filesystem 1K-blocks Used Available Use% Mounted\n/data/media 25000000 1000000 \(free) 10% /storage/emulated" }
            if args.starts(with: ["shell", "uiautomator"]) {
                lastDump = args.last!
                if idleFailures > 0 { idleFailures -= 1; return "ERROR: could not get idle state." }
                return "UI hierchary dumped to: " + lastDump
            }
            if args.starts(with: ["exec-out", "cat"]) {
                precondition(args.last == lastDump)
                guard !pages.isEmpty else { throw CleanupIssue.page }
                let page = pages.removeFirst()
                if page == complete { free = 17_000_000 }
                return page
            }
            return ""
        }, sleep: { _ in try Task.checkCancellation() })
        func taps() -> Int { calls.filter { $0.starts(with: ["shell", "input", "tap"]) }.count }
        var started = 0, finished = 0
        // Version changes alone must not reject the same recognized flow. Setup
        // may navigate, but never presses the cleanup confirmation button.
        for candidate in ["7.91.0.973540846", "8.0.0.fixture", "6.0.0.fixture"] {
            version = candidate
            for destination in [confirm, empty] {
                pages = [home, menu, destination]; calls = []; swipeScreen = true
                check(try await adapter.inspectAccount() == account && taps() == 2 && pages.isEmpty)
            }
        }
        for candidate in ["7.91.0.973540846", "8.0.0.fixture"] {
            version = candidate
            for destination in [duplicate, confirm.replacingOccurrences(of: "安全备份", with: "尚未备份"), progress] {
                pages = [home, menu, destination]; calls = []
                do { _ = try await adapter.inspectAccount(); preconditionFailure("Unsafe setup accepted") } catch {}
                precondition(taps() == 2)
            }
            pages = [home, menu.replacingOccurrences(of: "释放此设备的空间", with: "清理存储空间")]; calls = []
            do { _ = try await adapter.inspectAccount(); preconditionFailure("Cloud storage menu accepted") } catch {}
            precondition(taps() == 1)
        }
        print("PASS: setup probes confirmation or empty state across versions without cleaning; unknown and cloud-storage pages are rejected")
        version = "8.0.0.fixture"
        pages = [home, menu, confirm, confirm, progress, complete]; calls = []
        let result = try await adapter.run(account: account, pending: false, started: { started += 1 }, finished: { finished += 1 })
        guard case .completed(let reclaimed) = result else { preconditionFailure("Missing completion") }
        precondition(started == 1 && finished == 1 && taps() == 3 && reclaimed == 16_000_000 * 1024)
        let paths = calls.filter { $0.starts(with: ["shell", "uiautomator"]) }.compactMap(\.last)
        precondition(paths.count == Set(paths).count)
        print("PASS: read-only enable; one cleanup click; fresh confirmation; completion plus real space measurement")

        // Real home pages use a different completion label, or omit it entirely.
        // Ongoing uploads do not make already-backed-up copies ineligible for cleanup.
        for status in ["备份完成", "", "正在备份", "Backing up 3 items"] {
            let currentHome = home.replacingOccurrences(of: "已完成备份", with: status)
            let currentMenu = menu.replacingOccurrences(of: "备份已完成", with: status)
            pages = [currentHome, currentMenu, confirm, confirm, complete]; calls = []; started = 0; finished = 0
            _ = try await adapter.run(account: account, pending: false, started: { started += 1 }, finished: { finished += 1 })
            precondition(taps() == 3 && started == 1 && finished == 1 && pages.isEmpty)
            // The global status is irrelevant, but the official safe-backup claim is mandatory.
            pages = [currentHome, currentMenu, confirm.replacingOccurrences(of: "安全备份", with: "尚未备份")]; calls = []
            do {
                _ = try await adapter.run(account: account, pending: false, started: { preconditionFailure("Unsafe confirmation") }, finished: {})
                preconditionFailure("Unsafe cleanup accepted")
            } catch CleanupIssue.page {}
            precondition(taps() == 2)
        }
        print("PASS: real-world completion labels, missing status and ongoing uploads use official eligibility; unsafe confirmation never cleans")

        for bad in ["version", "lock", "account", "changed-confirmation"] {
            calls = []; started = 0; finished = 0; version = "7.91.0.973540846"; locked = false
            pages = [home]
            if bad == "version" { version = "" }
            if bad == "lock" { locked = true }
            if bad == "account" { pages = [home.replacingOccurrences(of: "example@example.test", with: "other@example.test")] }
            if bad == "changed-confirmation" { pages = [home, menu, confirm, duplicate] }
            do { _ = try await adapter.run(account: account, pending: false, started: { started += 1 }, finished: { finished += 1 }); preconditionFailure("Should stop") } catch {}
            precondition(started == 0 && finished == 0 && taps() <= (bad == "changed-confirmation" ? 2 : 0))
        }
        print("PASS: missing active version, secure lock, changed account and changed confirmation never trigger cleanup")
        version = "7.91.0.973540846"; locked = false; calls = []; pages = [progress, progress, complete]
        _ = try await adapter.run(account: account, pending: true, started: { preconditionFailure("Duplicate cleanup") }, finished: { finished += 1 })
        precondition(taps() == 0)
        calls = []; pages = [home, menu, confirm]
        _ = try await adapter.run(account: account, pending: true, started: { preconditionFailure("Repeated cleanup") }, finished: { finished += 1 })
        precondition(taps() == 2)
        calls = []; pages = [xml(node("unknown", "Unknown page"))]
        do { _ = try await adapter.run(account: account, pending: true, started: {}, finished: {}); preconditionFailure("Unknown pending state") } catch {}
        precondition(taps() == 0)
        calls = []; pages = [home, menu, empty]
        _ = try await adapter.run(account: account, pending: true, started: { preconditionFailure("Cleanup on empty page") }, finished: { finished += 1 })
        precondition(taps() == 2)
        calls = []; pages = [home, menu, empty]
        do { _ = try await adapter.run(account: account, pending: false, started: { preconditionFailure("Cleanup on empty page") }, finished: {}); preconditionFailure("Empty page") } catch CleanupIssue.nothing {}
        calls = []; idleFailures = 1; pages = [complete]
        do { _ = try await adapter.snapshot(); preconditionFailure("Stale dump accepted") } catch {}
        precondition(!calls.contains { $0.starts(with: ["exec-out", "cat"]) })
        print("PASS: pending cleanup is only observed, unknown completion blocks transfers, idle failure never reads stale XML")

        var pending = false
        pages = [home, menu, confirm, confirm]; calls = []
        let cancelled = Task { @MainActor in
            try await adapter.run(account: account, pending: false, started: {
                pending = true
                withUnsafeCurrentTask { $0?.cancel() }
            }, finished: { pending = false })
        }
        do { _ = try await cancelled.value; preconditionFailure("Cancelled cleanup continued") } catch is CancellationError {}
        precondition(pending && taps() == 2)
        print("PASS: cancellation at commit boundary retains uncertain state and sends no destructive tap")
    }
}
