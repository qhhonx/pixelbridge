# Localization

User-facing app copy lives in `macos/Resources/en.json` and `zh-Hans.json`. `TextKey` provides typed semantic snake_case identifiers, such as `gallery_heading`, `settings_cache_limit` and `error_pixel_temperature`. Text content is never the lookup key. Ordered placeholders use `{0}`, `{1}`; substitutions run once and preserve literal braces in filenames.

`appLanguage` stores `system`, `en` or `zh-Hans`. The default follows the first system-preferred language; Chinese variants use Simplified Chinese and unsupported languages fall back to English. The settings picker applies immediately. Dates in SwiftUI follow the selected locale. macOS-provided menus and system dialogs follow macOS language behavior.

`Message` retains a semantic key and arguments until rendering, so status, counts, protection notices and device information switch languages without restarting or mutating work. Photo types use stable `all`, `photo`, `motion`, `video` identifiers; queue phases and stored backup IDs remain unchanged. Chinese UI uses 动图 for Live Photo; the English UI uses motion photos, with the website explaining the Apple format.

Historical logs and third-party diagnostics retain their original text. App-owned current errors use semantic messages. The activity log makes the distinction explicit.

The system photo-access prompt is localized with `en.lproj/InfoPlist.strings` and `zh-Hans.lproj/InfoPlist.strings`. The build packages both catalogs and permission resources.

`tests/LocalizationTests.swift` verifies key parity, fallback, overrides, existing-message updates, stable media identity, error messages and placeholder handling. The test bundle uses its own defaults domain and never starts a backup.
