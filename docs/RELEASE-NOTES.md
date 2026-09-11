PixelBridge 0.1.0-beta.13 — stop repeated failures and manage skipped tasks.

- Remove an inactive task from the retry queue, or skip failed tasks matching the current filters. Skipped tasks stay in history and can be explicitly restored.
- Preserve skipped state across restarts, automatic resume and bulk retries. Keep originals, transferred files and existing queue history.
- Stop automatic retries for inaccessible assets, missing resources and unsupported formats. Other item-specific errors stop after five consecutive failures; environmental interruptions remain recoverable.
- Use consistent PhotoKit fetch options for library scans, original lookup and thumbnails, including all burst members.
- Stop a batch if recording a failure in the durable queue fails, instead of silently rediscovering the same error.

Known limitation: the cause of the reported inaccessible assets is still under investigation. Matching burst fetch options addresses a confirmed code inconsistency; it does not prove every affected asset was a burst member. A skipped task is neither a confirmed deletion nor a completed backup. Restore it after the underlying issue is resolved.

Free macOS beta for Apple Silicon, macOS 14+.

Download the arm64 ZIP, extract it and move PixelBridge to Applications. This release is **ad hoc signed and not notarized by Apple**. If macOS blocks a download you trust, follow [Apple's per-app opening instructions](https://support.apple.com/en-us/102445). The SHA256SUMS file is provided for download integrity checks.

Includes native photo browsing, supported Live Photo conversion, incremental Pixel transfers, persistent progress, retry/pause controls, verified Mac cache cleanup, English/Chinese UI and Sparkle updates. Update archives and feeds carry a separate Ed25519 signature.

Transferred to Pixel does not confirm Google Photos cloud backup. Keep your originals, verify a small batch and manage Pixel space only after cloud backup is confirmed. See README for requirements and limitations.
