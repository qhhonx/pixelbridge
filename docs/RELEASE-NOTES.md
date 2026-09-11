PixelBridge 0.1.0-beta.14 — detailed diagnostics for failed transfers.

- Correlate repeated attempts using a stable diagnostic task ID, with separate session, batch and attempt IDs.
- Record the processing stage, scan and resource metadata, lookup results, original error codes and underlying causes, retry deadlines and skip decisions.
- Preserve the original transfer error when recording its queue state also fails. Distinguish environmental interruptions, cancellation and completed Pixel delivery.
- Include structured diagnostics and cleanup stage changes in log exports while keeping the activity preview concise. Both log streams share the configured retention and size limits.
- Redact common sensitive text from exports and show the diagnostic ID in task details. Review exported logs before sharing; activity messages may still contain filenames.

To investigate a previously skipped task, update the app, restore one affected task and let it attempt again, then export logs from Settings. Earlier logs cannot recover context that was not recorded. The cause of the reported inaccessible assets remains under investigation; this release improves diagnosis and does not claim that issue is fixed.

Free macOS beta for Apple Silicon, macOS 14+.

Download the arm64 ZIP, extract it and move PixelBridge to Applications. This release is **ad hoc signed and not notarized by Apple**. If macOS blocks a download you trust, follow [Apple's per-app opening instructions](https://support.apple.com/en-us/102445). The SHA256SUMS file is provided for download integrity checks.

Includes native photo browsing, supported Live Photo conversion, incremental Pixel transfers, persistent progress, retry/pause controls, verified Mac cache cleanup, English/Chinese UI and Sparkle updates. Update archives and feeds carry a separate Ed25519 signature.

Transferred to Pixel does not confirm Google Photos cloud backup. Keep your originals, verify a small batch and manage Pixel space only after cloud backup is confirmed. See README for requirements and limitations.
