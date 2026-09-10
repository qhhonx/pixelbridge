PixelBridge 0.1.0-beta.9 — let Google Photos determine cleanup eligibility.

- Fix cleanup stopping immediately after opening Google Photos when its home screen uses a different backup status label or omits the status banner.
- Remove the requirement for all Google Photos uploads to finish. Its official device-cleanup flow selects safely backed-up copies even while other uploads continue.
- Keep account binding, the explicit safe-backup confirmation, fresh checks before clicking, and pending-operation reconciliation. Never infer deletion eligibility from file age or PixelBridge transfer records.
- Keep PixelBridge transfers paused during cleanup, then measure free space before resuming. Existing settings, account bindings and queue progress are retained.

Free macOS beta for Apple Silicon, macOS 14+.

Download the arm64 ZIP, extract it and move PixelBridge to Applications. This release is **ad hoc signed and not notarized by Apple**. If macOS blocks a download you trust, follow [Apple's per-app opening instructions](https://support.apple.com/en-us/102445). The SHA256SUMS file is provided for download integrity checks.

Includes native photo browsing, supported Live Photo conversion, incremental Pixel transfers, persistent progress, retry/pause controls, verified Mac cache cleanup, English/Chinese UI and Sparkle updates. Update archives and feeds carry a separate Ed25519 signature.

Transferred to Pixel does not confirm Google Photos cloud backup. Keep your originals, verify a small batch and manage Pixel space only after cloud backup is confirmed. See README for requirements and limitations.
