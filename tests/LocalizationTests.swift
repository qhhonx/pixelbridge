import Foundation

@main struct LocalizationTests {
    @MainActor static func main() {
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: "appLanguage")
        defer { if let old { defaults.set(old, forKey: "appLanguage") } else { defaults.removeObject(forKey: "appLanguage") } }
        precondition(L10n.resolve(preference: "system", preferredLanguages: ["zh-Hant-TW", "en"]) == "zh-Hans")
        precondition(L10n.resolve(preference: "system", preferredLanguages: ["fr-FR", "zh-CN"]) == "en")
        precondition(L10n.resolve(preference: "en", preferredLanguages: ["zh-CN"]) == "en")
        precondition(L10n.resolve(preference: "zh-Hans", preferredLanguages: ["en-US"]) == "zh-Hans")
        precondition(L10n.resolve(preference: "unknown", preferredLanguages: []) == "en")
        let keys = Set(TextKey.allCases.map(\.rawValue))
        for language in ["en", "zh-Hans"] {
            let catalog = L10n.catalogs[language]!
            precondition(Set(catalog.keys) == keys)
            precondition(catalog.values.allSatisfy { !$0.isEmpty && !$0.contains("%@") })
            precondition(L10n.text(.cleanup_description, arguments: ["6"], language: language).contains("6 GB"))
            precondition(L10n.text(.cleanup_finished, arguments: ["2 GB"], language: language).contains("2 GB"))
            for key in TextKey.allCases {
                let rendered = L10n.text(key, arguments: ["{1}-filename", "second", "third"], language: language)
                precondition(rendered != key.rawValue)
            }
        }
        let filename = "photo-{1}.jpg"
        precondition(L10n.text(.cache_verifying, arguments: ["1", "3", filename], language: "en").hasSuffix(filename))
        let message = Message(.status_motion_preparing)
        let model = BridgeModel()
        model.status = Message(.status_waiting)
        model.libraryCounts = Message(.library_counts, "4", "2", "1", "3")
        model.gallery = ["motion": [LibraryItem(id: "test", name: "sample", date: .distantPast, kind: "motion")]]
        defaults.set("zh-Hans", forKey: "appLanguage")
        precondition(message.text == "处理动图")
        precondition(mediaLabel("motion") == "动图")
        precondition(mediaLabel("burst") == "连拍")
        precondition(model.libraryCounts.text.contains("3 张连拍照片"))
        precondition(model.needsAttention)
        let chineseCounts = model.libraryCounts.text
        defaults.set("en", forKey: "appLanguage")
        precondition(message.text == "Preparing motion photo")
        precondition(mediaLabel("motion") == "Motion photos")
        precondition(mediaLabel("burst") == "Bursts")
        precondition(model.libraryCounts.text.contains("3 burst photos"))
        precondition(model.needsAttention && model.status.key == .status_waiting)
        precondition(model.libraryCounts.text != chineseCounts)
        precondition(model.gallery["motion"]?.count == 1)
        let error = fail(Message(.error_mac_storage, "8"))
        precondition(error.localizedDescription.contains("8 GB"))
        defaults.set("zh-Hans", forKey: "appLanguage")
        precondition(error.localizedDescription.contains("剩余空间"))
        print("PASS: semantic key coverage, locale fallback, override, live status translation, placeholders, media identity and protection messages")
    }
}
