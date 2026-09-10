PixelBridge 0.1.0-beta.6 — a home for experiments and more flexible cleanup compatibility.

- Add a dedicated Experiments page in the sidebar. Automatic Pixel space cleanup moves here with independent enable/disable controls, status and a non-destructive Check again action.
- Remove the exact Google Photos version requirement. Recognized UI controls and safety messages determine compatibility; unknown or ambiguous screens still stop without guessing.
- Strengthen Check and enable: navigate to the official device-cleanup confirmation or empty page without pressing the cleanup action. Actual cleanup always rechecks the account, backup-complete state and affirmative confirmation.
- Preserve existing enabled preferences, account bindings and unfinished cleanup records across the update.

Currently targets original Pixel / Pixel XL on Android 10, with recognized Chinese/English screens. The on-device baseline remains Google Photos 7.91.0.973540846 in Chinese; other version numbers and English screens have simulated coverage, not a universal compatibility guarantee. Pause backup before changing experiment settings.

Free macOS beta for Apple Silicon, macOS 14+.

Download the arm64 ZIP, extract it and move PixelBridge to Applications. This release is **ad hoc signed and not notarized by Apple**. If macOS blocks a download you trust, follow [Apple's per-app opening instructions](https://support.apple.com/en-us/102445). The SHA256SUMS file is provided for download integrity checks.

Includes native photo browsing, supported Live Photo conversion, incremental Pixel transfers, persistent progress, retry/pause controls, verified Mac cache cleanup, English/Chinese UI and Sparkle updates. Update archives and feeds carry a separate Ed25519 signature.

Transferred to Pixel does not confirm Google Photos cloud backup. Keep your originals, verify a small batch and manage Pixel space only after cloud backup is confirmed. See README for requirements and limitations.
