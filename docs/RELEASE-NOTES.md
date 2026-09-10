PixelBridge 0.1.0-beta.10 — show cleanup progress and return to Photos.

- Display each live cleanup stage in Backup Overview, the bottom status bar and Experiments: device readiness, opening Google Photos, verifying the account, checking eligible copies, releasing space, returning to Photos and verifying available space.
- Show the percentage reported by Google Photos when available. Otherwise show an activity indicator, without fabricated percentage or stale photo-transfer progress.
- Record stage transitions in the activity log without logging every percentage refresh. Clear transient progress after cancellation, failure or completion.
- After confirmed cleanup, press the recognized Done button and verify the Photos home screen. A return-navigation failure is reported separately and does not repeat a completed cleanup.

Existing settings, queue progress and cleanup safeguards are retained.

Free macOS beta for Apple Silicon, macOS 14+.

Download the arm64 ZIP, extract it and move PixelBridge to Applications. This release is **ad hoc signed and not notarized by Apple**. If macOS blocks a download you trust, follow [Apple's per-app opening instructions](https://support.apple.com/en-us/102445). The SHA256SUMS file is provided for download integrity checks.

Includes native photo browsing, supported Live Photo conversion, incremental Pixel transfers, persistent progress, retry/pause controls, verified Mac cache cleanup, English/Chinese UI and Sparkle updates. Update archives and feeds carry a separate Ed25519 signature.

Transferred to Pixel does not confirm Google Photos cloud backup. Keep your originals, verify a small batch and manage Pixel space only after cloud backup is confirmed. See README for requirements and limitations.
