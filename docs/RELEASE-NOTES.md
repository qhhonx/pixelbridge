PixelBridge 0.1.0-beta.5 — experimental automatic Pixel space cleanup.

- Add an opt-in “Check and enable” setup in Preferences. It verifies the connected Pixel and binds a fingerprint of the Google Photos account without deleting files.
- During backup, attempt Google's “Free up space on this device” below 3 GB or the configured Pixel reserve plus 1 GB, whichever is higher. Stop concurrent transfers before cleanup and resume through the existing scheduler after completion.
- Use fresh UI trees, exact control identifiers, backup-complete and safety text checks. Unknown screens, changed accounts, secure locks, and unsupported versions stop the flow. No direct photo-folder deletion or private Google API is used.
- Persist uncertain cleanup across cancellation/restart. Observe or reconcile it without starting a duplicate operation. Require Google Photos completion and remeasure available space; keep delivery records unchanged.
- The first compatibility adapter targets Android 10 on original Pixel/Pixel XL and Google Photos 7.91.0.973540846. Chinese was checked on-device; English selectors have fixture coverage. Other builds require compatibility validation.

Enable under Preferences → Auto-free Pixel space after pausing backup. This is intended for a dedicated backup phone: Google's cleanup can remove eligible backed-up device copies outside PixelBridge too. A secure lock requires manual unlocking. Pause stops PixelBridge work, but cleanup already started in Google Photos may continue. There is a 10-minute interval between new cleanup attempts.

Includes beta.4 task sizes, stage progress, concurrency and gallery scroll restoration.

Free macOS beta for Apple Silicon, macOS 14+.

Download the arm64 ZIP, extract it and move PixelBridge to Applications. This release is **ad hoc signed and not notarized by Apple**. If macOS blocks a download you trust, follow [Apple's per-app opening instructions](https://support.apple.com/en-us/102445). The SHA256SUMS file is provided for download integrity checks.

Includes native photo browsing, supported Live Photo conversion, incremental Pixel transfers, persistent progress, retry/pause controls, verified Mac cache cleanup, English/Chinese UI and Sparkle updates. Update archives and feeds carry a separate Ed25519 signature.

Transferred to Pixel does not confirm Google Photos cloud backup. Keep your originals, verify a small batch and manage Pixel space only after cloud backup is confirmed. See README for requirements and limitations.
