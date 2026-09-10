PixelBridge 0.1.0-beta.7 — show the effective Pixel cleanup threshold.

The Experiments page now displays the calculated cleanup threshold in GB instead of asking users to interpret a formula. The description updates when the Pixel reserve changes and uses the same value as the cleanup scheduler. Available in English and Chinese.

Also correct the cleanup-completed message so it displays the amount of space freed.

For example, a 1 GB reserve displays “below 3 GB”; a 5 GB reserve displays “below 6 GB”.

Free macOS beta for Apple Silicon, macOS 14+.

Download the arm64 ZIP, extract it and move PixelBridge to Applications. This release is **ad hoc signed and not notarized by Apple**. If macOS blocks a download you trust, follow [Apple's per-app opening instructions](https://support.apple.com/en-us/102445). The SHA256SUMS file is provided for download integrity checks.

Includes native photo browsing, supported Live Photo conversion, incremental Pixel transfers, persistent progress, retry/pause controls, verified Mac cache cleanup, English/Chinese UI and Sparkle updates. Update archives and feeds carry a separate Ed25519 signature.

Transferred to Pixel does not confirm Google Photos cloud backup. Keep your originals, verify a small batch and manage Pixel space only after cloud backup is confirmed. See README for requirements and limitations.
