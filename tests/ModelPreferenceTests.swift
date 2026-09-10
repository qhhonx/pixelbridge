import Foundation

@main struct ModelPreferenceTests {
    @MainActor static func main() {
        // The standalone test executable has its own defaults domain; never launch a backup.
        let defaults = UserDefaults.standard
        let cleanupKeys = ["pixelCleanupEnabled", "pixelCleanupBinding", "pixelCleanupPendingDevice", "pixelCleanupHoldDevice", "pixelCleanupTransferBytes"]
        let savedCleanup = cleanupKeys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in savedCleanup {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let binding = ["device": "fixture-pixel", "account": "fixture-fingerprint"]
        defaults.set(true, forKey: "pixelCleanupEnabled")
        defaults.set(binding, forKey: "pixelCleanupBinding")
        defaults.set("fixture-pixel", forKey: "pixelCleanupPendingDevice")
        let upgraded = BridgeModel()
        precondition(upgraded.pixelCleanupEnabled)
        precondition(defaults.dictionary(forKey: "pixelCleanupBinding") as? [String: String] == binding)
        upgraded.disablePixelCleanup()
        precondition(!BridgeModel().pixelCleanupEnabled)
        precondition(defaults.string(forKey: "pixelCleanupPendingDevice") == "fixture-pixel")
        print("PASS: existing cleanup opt-in and binding survive upgrade; disabling preserves pending cleanup")
        let savedReclaim = defaults.object(forKey: "autoReclaimCache")
        let saved = Dictionary(uniqueKeysWithValues: NumericPreference.allCases.map { ($0.rawValue, defaults.object(forKey: $0.rawValue)) })
        defer {
            if let savedReclaim { defaults.set(savedReclaim, forKey: "autoReclaimCache") }
            else { defaults.removeObject(forKey: "autoReclaimCache") }
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let model = BridgeModel()
        model.autoReclaimCache = false
        precondition(!BridgeModel().autoReclaimCache)
        model.autoReclaimCache = true
        precondition(BridgeModel().autoReclaimCache)
        model.autoRunning = false
        let fields: [(NumericPreference, ReferenceWritableKeyPath<BridgeModel, Int>)] = [
            (.intervalMinutes, \.intervalMinutes), (.macReserveGB, \.macReserveGB),
            (.pixelReserveGB, \.pixelReserveGB), (.maxTemperatureC, \.maxTemperatureC),
            (.concurrentTasks, \.concurrentTasks)
        ]
        for (preference, field) in fields {
            for value in [preference.fallback, preference.fallback + 1, -1, 9999] {
                model[keyPath: field] = value
                let expected = preference.clamp(value)
                precondition(model[keyPath: field] == expected)
                precondition(BridgeModel()[keyPath: field] == expected)
            }
        }
        model.autoRunning = true
        model.intervalMinutes = 7
        precondition(abs(model.nextRun!.timeIntervalSinceNow - 420) < 2)
        let scheduled = model.nextRun
        model.busy = true
        model.intervalMinutes = 8
        precondition(model.nextRun == scheduled, "Editing during a batch must not reschedule it")
        model.busy = false
        model.autoRunning = false
        model.intervalMinutes = 9
        precondition(model.nextRun == scheduled, "Editing while paused must not start automation")
        print("PASS: published preference edits do not recurse, clamp, persist and reload; scheduler respects idle, busy and paused states")
    }
}
