PixelBridge 0.1.0-beta.4 — file sizes, task progress and bounded concurrency.

- Restore photo-library scroll positions when returning from another page, with separate positions per media filter and photo-identity anchors across new arrivals.
- Show measured delivery sizes in the task list. Sizes include the motion track and remain in SQLite after Mac cache cleanup. Older tasks without size records display a dash.
- Show per-task download, preparation, transfer and verification stages with an activity indicator. Stage indicators are not byte-completion percentages or Google Photos cloud-upload progress.
- Configure 1–3 concurrent tasks in Preferences (default 1). Preparation stays sequential to bound memory and Mac cache use; Pixel transfers can overlap. Pause backup before changing the setting.
- Reserve space for all in-flight Pixel files together. Pause cancels all workers; shared temporary failures retain prepared progress for automatic recovery.
- Isolate temporary paths for identical-content photos with different destination filenames.

Includes beta.2 recovery and filtering and beta.3 empty-state layout fixes. This setting controls Mac-to-Pixel work, not Google Photos uploads. Actual throughput depends on USB, Pixel storage and iCloud downloads.

Free macOS beta for Apple Silicon, macOS 14+.

Download the arm64 ZIP, extract it and move PixelBridge to Applications. This release is **ad hoc signed and not notarized by Apple**. If macOS blocks a download you trust, follow [Apple's per-app opening instructions](https://support.apple.com/en-us/102445). The SHA256SUMS file is provided for download integrity checks.

Includes native photo browsing, supported Live Photo conversion, incremental Pixel transfers, persistent progress, retry/pause controls, verified Mac cache cleanup, English/Chinese UI and Sparkle updates. Update archives and feeds carry a separate Ed25519 signature.

Transferred to Pixel does not confirm Google Photos cloud backup. Keep your originals, verify a small batch and manage Pixel space only after cloud backup is confirmed. See README for requirements and limitations.
