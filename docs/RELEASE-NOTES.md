PixelBridge 0.1.0-beta.3 — stable empty-state layouts.

- Keep the photo library heading and transfer task filters anchored at the top when a list is empty.
- Place permission, loading, empty-library and no-match messages within the content area below the heading.
- Keep the transfer cloud-backup notice at the bottom, so changing filters does not move the entire page.

Includes the task filters and automatic recovery improvements from beta.2.

Free macOS beta for Apple Silicon, macOS 14+.

Download the arm64 ZIP, extract it and move PixelBridge to Applications. This release is **ad hoc signed and not notarized by Apple**. If macOS blocks a download you trust, follow [Apple's per-app opening instructions](https://support.apple.com/en-us/102445). The SHA256SUMS file is provided for download integrity checks.

Includes native photo browsing, supported Live Photo conversion, incremental Pixel transfers, persistent progress, retry/pause controls, verified Mac cache cleanup, English/Chinese UI and Sparkle updates. Update archives and feeds carry a separate Ed25519 signature.

Transferred to Pixel does not confirm Google Photos cloud backup. Keep your originals, verify a small batch and manage Pixel space only after cloud backup is confirmed. See README for requirements and limitations.
