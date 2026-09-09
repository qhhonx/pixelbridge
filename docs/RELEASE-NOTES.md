PixelBridge 0.1.0-beta.2 — task filters and automatic recovery.

- Filter transfers by status and media type together, with matching counts and clear-filter controls.
- Starting or resuming automatic backup requeues existing failures immediately, including after an app restart.
- Temperature, storage and recognized network/connection interruptions preserve progress and recheck after 60 seconds while automatic backup is enabled.
- Other failed items retry automatically with a 30-second to 5-minute backoff. The scheduler wakes when a retry is due instead of waiting a full scan interval.
- Explicit pause remains paused. Already delivered files stay excluded from retries.

Known limitation: underlying PhotoKit errors do not always identify a network failure. Unclassified errors use the bounded per-item retry policy. Space limits still require enough available space; this release does not delete Pixel photos.

Free macOS beta for Apple Silicon, macOS 14+.

Download the arm64 ZIP, extract it and move PixelBridge to Applications. This release is **ad hoc signed and not notarized by Apple**. If macOS blocks a download you trust, follow [Apple's per-app opening instructions](https://support.apple.com/en-us/102445). The SHA256SUMS file is provided for download integrity checks.

Includes native photo browsing, supported Live Photo conversion, incremental Pixel transfers, persistent progress, retry/pause controls, verified Mac cache cleanup, English/Chinese UI and Sparkle updates. Update archives and feeds carry a separate Ed25519 signature.

Transferred to Pixel does not confirm Google Photos cloud backup. Keep your originals, verify a small batch and manage Pixel space only after cloud backup is confirmed. See README for requirements and limitations.
