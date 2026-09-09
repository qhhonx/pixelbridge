import Foundation

enum TextKey: String, CaseIterable {
    case updates_title
    case updates_description
    case updates_check
    case updates_automatic
    case updates_automatic_description

    case gallery_refreshing
    case gallery_refresh_help
    case gallery_loaded
    case gallery_labels_title
    case gallery_labels_description
    case gallery_loaded_all
    case gallery_refreshed
    case gallery_processing
    case gallery_not_transferred
    case queue_retry_queued
    case action_cancel
    case adb_accept_install
    case adb_choose
    case adb_choose_prompt
    case adb_consent
    case adb_description
    case adb_download
    case adb_install_action
    case adb_installing
    case adb_license
    case adb_official_download
    case adb_ready
    case adb_sheet_description
    case adb_sheet_title
    case adb_title
    case app_tagline
    case automatic_paused
    case backup_activity_reason
    case backup_another_instance
    case backup_automatic
    case backup_batch_progress
    case backup_cloud_notice
    case backup_description
    case backup_details
    case backup_footer_summary
    case backup_next_check
    case backup_once
    case backup_pause
    case backup_paused
    case backup_progress
    case backup_ready
    case batch_empty
    case batch_summary
    case cache_budget
    case cache_budget_value
    case cache_cleanup_disabled
    case cache_cleanup_enabled
    case cache_used
    case cache_verifying
    case device_authorize
    case device_connected
    case device_connection_failed
    case device_description
    case device_disconnected
    case device_heading
    case device_metrics
    case device_offline
    case device_picker
    case device_previous_offline
    case device_refresh
    case device_select
    case device_setup_action
    case device_setup_prompt
    case device_tools_required
    case device_unselected
    case device_view
    case device_waiting
    case error_adb_executable
    case error_asset_missing
    case error_cache_budget
    case error_cache_corrupt
    case error_download_budget
    case error_exit_code
    case error_external
    case error_format_unsupported
    case error_hash_failed
    case error_hash_missing
    case error_hash_unavailable
    case error_icloud_timeout
    case error_lock_acquire
    case error_lock_create
    case error_mac_storage
    case error_motion_missing
    case error_original_missing
    case error_photos_permission
    case error_pixel_disconnected
    case error_pixel_generation
    case error_pixel_storage
    case error_pixel_temperature
    case error_pixel_waiting
    case error_setup_required
    case error_timeout
    case error_tools_download
    case error_tools_existing
    case error_tools_validation
    case error_transfer_verification
    case gallery_empty
    case gallery_empty_description
    case gallery_filter
    case gallery_heading
    case gallery_intro
    case gallery_loading
    case gallery_loading_description
    case gallery_media_type
    case gallery_refresh
    case gallery_size
    case language_chinese
    case language_description
    case language_system
    case language_title
    case library_counts
    case log_cache_batch_reclaimed
    case log_cache_file_retained
    case log_cache_reclaimed
    case log_cache_retained
    case log_delivered
    case log_library_updated
    case log_tools_installed
    case logs_empty
    case logs_original_language
    case logs_title
    case media_all
    case media_motion
    case media_photo
    case media_video
    case menu_delivered
    case menu_open
    case menu_pause
    case menu_quit
    case menu_start
    case metric_cache
    case metric_delivered
    case nav_device
    case nav_library
    case nav_overview
    case nav_settings
    case nav_tasks
    case overview_description
    case overview_heading
    case photos_access_closed
    case photos_connect_action
    case photos_connect_description
    case photos_connect_title
    case photos_permission_help
    case photos_permission_usage
    case preference_value
    case queue_automatic_pending
    case queue_backed_up
    case queue_discovered
    case queue_exporting
    case queue_failed
    case queue_motion_verified
    case queue_prepared
    case queue_prepared_missing
    case queue_verified
    case recent_all
    case recent_empty_description
    case recent_empty_title
    case recent_title
    case settings_automatic_title
    case settings_batch
    case settings_batch_description
    case settings_cache_limit
    case settings_cache_title
    case settings_capabilities
    case settings_data_folder
    case settings_description
    case settings_heading
    case settings_interval
    case settings_interval_control
    case settings_interval_description
    case settings_locked
    case settings_login
    case settings_login_description
    case settings_mac_reserve
    case settings_mac_reserve_control
    case settings_pixel_reserve
    case settings_pixel_reserve_control
    case settings_privacy_action
    case settings_privacy_title
    case settings_protection_notice
    case settings_protection_title
    case settings_reclaim
    case settings_reclaim_description
    case settings_reclaim_notice
    case settings_resume_notice
    case settings_temperature
    case settings_temperature_control
    case setup_authorize_description
    case setup_authorize_title
    case setup_cable_description
    case setup_cable_title
    case setup_cloud_description
    case setup_cloud_title
    case setup_debug_description
    case setup_debug_title
    case setup_photos_description
    case setup_photos_title
    case setup_pixel_description
    case setup_pixel_title
    case setup_steps_title
    case sidebar_management
    case sidebar_photos
    case status_attention
    case status_automatic
    case status_batch_finished
    case status_exporting
    case status_library_connected
    case status_motion_preparing
    case status_paused
    case status_pausing
    case status_permission_pending
    case status_permission_required
    case status_ready
    case status_reclaiming
    case status_tools_downloading
    case status_tools_installed
    case status_transferring
    case status_waiting
    case storage_title
    case tasks_cloud_notice
    case tasks_column_details
    case tasks_column_file
    case tasks_column_status
    case tasks_column_updated
    case tasks_empty
    case tasks_empty_description
    case tasks_file_details
    case tasks_heading
    case tasks_retry
    case tasks_status_all
    case tasks_type_unknown
    case tasks_filtered_count
    case tasks_clear_filters
    case tasks_no_matches
    case tasks_no_matches_description
    case tasks_summary
    case unit_items
    case unit_minutes
}

enum L10n {
    static func resolve(preference: String, preferredLanguages: [String]) -> String {
        if preference == "en" || preference == "zh-Hans" { return preference }
        // Use the first preferred language; unsupported languages fall back to English.
        return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
    }
    static var language: String {
        resolve(preference: UserDefaults.standard.string(forKey: "appLanguage") ?? "system", preferredLanguages: Locale.preferredLanguages)
    }
    private static let placeholderPattern = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
    static let catalogs: [String: [String: String]] = {
        var result: [String: [String: String]] = [:]
        for language in ["en", "zh-Hans"] {
            if let url = Bundle.main.url(forResource: language, withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let catalog = try? JSONDecoder().decode([String: String].self, from: data) { result[language] = catalog }
        }
        return result
    }()
    static func text(_ key: TextKey, arguments: [String] = [], language: String = L10n.language) -> String {
        let template = catalogs[language]?[key.rawValue] ?? catalogs["en"]?[key.rawValue] ?? key.rawValue
        // One pass: user-provided filenames containing braces are never interpreted as placeholders.
        guard !arguments.isEmpty else { return template }
        let pattern = placeholderPattern
        let matches = pattern.matches(in: template, range: NSRange(template.startIndex..., in: template))
        var output = template
        for match in matches.reversed() {
            let index = Int((template as NSString).substring(with: match.range(at: 1)))!
            if index < arguments.count, let range = Range(match.range, in: output) { output.replaceSubrange(range, with: arguments[index]) }
        }
        return output
    }
}
func tr(_ key: TextKey, _ arguments: String...) -> String { L10n.text(key, arguments: arguments) }
func mediaLabel(_ kind: String) -> String { tr(TextKey(rawValue: "media_" + kind) ?? .media_all) }

struct Message: Equatable {
    let key: TextKey?
    let arguments: [String]
    private let literal: String?
    init(_ key: TextKey, _ arguments: String...) { self.key = key; self.arguments = arguments; self.literal = nil }
    private init(literal: String) { key = nil; arguments = []; self.literal = literal }
    static func raw(_ text: String) -> Message { Message(literal: text) }
    static let empty = Message.raw("")
    init(error: Error) {
        if let failure = error as? BridgeFailure, failure.message.key != nil { self = failure.message }
        else { self = Message(.error_external) }
    }
    var text: String { key.map { L10n.text($0, arguments: arguments) } ?? literal ?? "" }
}
