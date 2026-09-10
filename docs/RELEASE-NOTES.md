PixelBridge 0.1.0-beta.8 — coordinate cleanup and transfers with one space budget.

- Use one Minimum free space on Pixel setting for cleanup and transfer admission. Add the pending file and concurrent reservations before permitting a transfer; remove the separate derived 3 GB cleanup threshold.
- Correct Android storage-unit conversion so the Rust transfer checks and Swift cleanup checks agree at the same free-space boundary.
- Persist low-space cleanup waits across batches, pauses and restarts. Stop and drain active transfers before cleanup; waiting for Google Photos, temperature, an empty cleanup page or cooldown no longer resumes new transfers.
- Resume after cleanup only when available space meets the reserve and pending-file budget. Preserve prepared files and delivery records. External/manual space recovery can release the hold, while uncertain cleanup must be reconciled first.
- Start the ten-minute action interval immediately before clicking cleanup. Failed preflight checks no longer consume it.
- Show concrete, consistent overview and log messages for temperature, cloud uploads, foreground app, cooldown, cleanup start/completion and required free space.

Existing experiment opt-in and account bindings are retained. This update uses your existing Pixel space reserve directly; there is no separate cleanup threshold to configure.

Free macOS beta for Apple Silicon, macOS 14+.

Download the arm64 ZIP, extract it and move PixelBridge to Applications. This release is **ad hoc signed and not notarized by Apple**. If macOS blocks a download you trust, follow [Apple's per-app opening instructions](https://support.apple.com/en-us/102445). The SHA256SUMS file is provided for download integrity checks.

Includes native photo browsing, supported Live Photo conversion, incremental Pixel transfers, persistent progress, retry/pause controls, verified Mac cache cleanup, English/Chinese UI and Sparkle updates. Update archives and feeds carry a separate Ed25519 signature.

Transferred to Pixel does not confirm Google Photos cloud backup. Keep your originals, verify a small batch and manage Pixel space only after cloud backup is confirmed. See README for requirements and limitations.
