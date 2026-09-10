PixelBridge 0.1.0-beta.12 — automatic cleanup recovery and retained activity logs.

- Recover once from an unrecognized Google Photos navigation page by force-stopping and reopening the app, then checking the account and official cleanup confirmation again.
- Never restart Photos to recover an unresolved cleanup action. Retry transient UI animation reads without using stale page data.
- Retain activity logs in daily, size-limited files instead of overwriting everything beyond 200 entries. Import existing activity logs on upgrade.
- Configure log retention from 1–90 days and total storage from 10–500 MB in Settings; defaults are 7 days and 50 MB. Older files are removed first.
- Open retained history or export it to one text file. File operations run on a background queue; the preview remains limited to 15 entries.
- Show log-storage failures and cleanup recovery stages in the app.

Free macOS beta for Apple Silicon, macOS 14+.

Download the arm64 ZIP, extract it and move PixelBridge to Applications. This release is **ad hoc signed and not notarized by Apple**. If macOS blocks a download you trust, follow [Apple's per-app opening instructions](https://support.apple.com/en-us/102445). The SHA256SUMS file is provided for download integrity checks.

Includes native photo browsing, supported Live Photo conversion, incremental Pixel transfers, persistent progress, retry/pause controls, verified Mac cache cleanup, English/Chinese UI and Sparkle updates. Update archives and feeds carry a separate Ed25519 signature.

Transferred to Pixel does not confirm Google Photos cloud backup. Keep your originals, verify a small batch and manage Pixel space only after cloud backup is confirmed. See README for requirements and limitations.
