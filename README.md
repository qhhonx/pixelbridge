# PixelBridge

[中文](README.zh-Hans.md) · [Download](https://github.com/qhhonx/pixelbridge/releases) · [Website](https://pixelbridge-app.vercel.app)

A native macOS app that sends Apple Photos originals to a Google Pixel for a second backup in Google Photos.

**Public beta. Apple Silicon, macOS 14 or later.**

Source code is available under the MIT license. Download the latest published beta from Releases, or build it locally using the instructions below.
The app uses an ad hoc integrity signature and is **not notarized by Apple**.

## What it does

- Reads your System Photo Library with PhotoKit, including originals stored in iCloud when Optimize Mac Storage is enabled.
- Shows a paginated native photo grid, with photo-type and transfer-status icons.
- Packages supported Live Photos as motion photos, retaining the still image and paired video together.
- Transfers files through USB/ADB with hashes, resumable progress, retry backoff and temperature/storage guards.
- Stores progress in a local SQLite queue and can reclaim verified Mac staging files.
- Offers English and Simplified Chinese, following your system language by default.
- Checks for app updates with Sparkle; downloaded update archives are verified with a separate Ed25519 signing key.

The path is **Apple Photos / iCloud → Mac → Pixel → Google Photos**. No PixelBridge server receives your photos. The website serves product information and release metadata only.

## Install and start

1. Download `PixelBridge-…-arm64.zip` from [Releases](https://github.com/qhhonx/pixelbridge/releases), extract it and move **PixelBridge.app to Applications**.
2. Try opening the app. If macOS blocks it and you trust the source, use **System Settings → Privacy & Security → Open Anyway**, then confirm. Follow [Apple's instructions](https://support.apple.com/en-us/102445). This beta is not notarized; do not disable system-wide security. Managed Macs may restrict exceptions. Updates may require renewed approval or Photos permission.
3. Allow access to your photo library. Connect a Pixel by USB, enable USB debugging and approve the computer on the phone. The app can guide you through installing Android Platform Tools after you accept Google's terms.
4. Sign into Google Photos on the Pixel, enable backup and check the account's storage benefit and selected backup quality.
5. Start with a small batch. Check the photos and motion playback on both Google Photos web and the phone. Enable automatic backup once you are satisfied.

Keep the Mac awake, the Pixel connected, and both devices online during transfers. Closing the window keeps the menu-bar app running; quitting stops scheduling. Keep an old phone ventilated and inspect its battery condition.

## Understand backup status

**Transferred means a file reached the Pixel and passed file verification. It does not mean Google Photos has backed it up.** Google Photos uploads independently. Motion playback can become available after upload processing finishes.

Mac staging cleanup only removes eligible files after durable progress is saved and the corresponding Pixel file passes another hash check. It does not delete Apple Photos originals, Pixel files or backup progress. Free Pixel storage through Google Photos only after confirming cloud backup.

The app transfers **unmodified originals**. Album organization, edits, deleted-item mirroring, and every Apple media format are not reproduced. Library identifiers can differ between Macs; moving to a different photo library can cause re-transfers. Google storage benefits are device/account dependent and subject to [Google's policy](https://support.google.com/pixelphone/answer/6220791). Large-library unattended operation remains a beta limitation.

## Updates

Use **PixelBridge → Check for Updates…**, the menu-bar menu or **Settings → Software updates**. Automatic checks are enabled by default; you decide when to install. A relaunch waits for the active backup to stop safely. No system profile is sent by the updater.

This beta receives the newest complete public release, including subsequent betas. Sparkle's signature verifies update authenticity; it is separate from Apple notarization. GitHub/Vercel availability is required to check and download updates. Manual downloads remain available if an update cannot be installed.

## Build from source

Requirements: Apple Silicon Mac, macOS 14+, Xcode Command Line Tools, Rust/Cargo, Python 3 (build/test scripts only), Perl and an internet connection to fetch dependencies. End users do not need Rust or Python.

```sh
./scripts/build-macos-app.sh
./scripts/package-release.sh
```

Builds download checksum-pinned ExifTool and Sparkle archives. Rust dependencies are locked. The output is `dist/PixelBridge.app` and a ZIP in `dist/release/`. No Apple developer certificate is required. Self-built forks must supply their own update feed and signing key before distributing; the upstream private signing key is not part of the repository.

```sh
cargo test --locked
./scripts/test-macos.sh
python3 tests/transport_scenarios.py
python3 tests/sparkle_integration.py
cd site
npm ci
npm test
npm run build
```

Tests use temporary synthetic files and simulated devices; they do not transfer your actual photos. The AppKit grid test requires a macOS graphical session.

See [architecture](docs/ARCHITECTURE.md), [localization](docs/LOCALIZATION.md), [release automation](docs/RELEASING.md), [privacy](docs/PRIVACY.md) and [contributing](CONTRIBUTING.md).

## License

Project code is MIT licensed. Third-party software retains its own licenses; see [notices](THIRD_PARTY_NOTICES.md). PixelBridge is an independent project, not affiliated with Apple or Google. Product names and logos belong to their respective owners.

### Automatic Pixel space cleanup (experimental)

In **Experiments**, pause backup and choose **Check and enable** under **Auto-free Pixel space**. This checks the connected device, reads the current Google Photos account, and navigates to the official device-cleanup confirmation or empty page. It stores only an account fingerprint and does not clean during setup. An empty page verifies navigation; every actual cleanup still requires the affirmative backup and confirmation screens. It is off by default and must be enabled separately on each Mac.

During backup, PixelBridge checks for low space (below 3 GB or the Pixel reserve plus 1 GB, whichever is higher), waits for its transfers to stop, and operates Google Photos’ **Free up space on this device**. It requires the recognized backup-complete and safety messages. After Google Photos confirms completion, PixelBridge remeasures space and resumes through its normal scheduler. Completed transfer records remain intact. No direct deletion of photo folders is performed.

The adapter currently targets Android 10 on original Pixel/Pixel XL. Google Photos is **not pinned to a version**: compatibility depends on recognizing the account, device-cleanup entry, safety text and action controls. Unknown or ambiguous pages stop instead of guessing, even on a previously checked version. Chinese navigation was tested on-device with Google Photos 7.91.0.973540846; English selectors and alternate version numbers have fixture coverage, not device validation. This does not guarantee every Google Photos release or language. Existing opt-in and account bindings survive updates; use **Check again** to repeat the non-destructive probe. A secure lock must be unlocked manually. An active app other than Photos or the launcher delays cleanup. UI inspection failures never reuse an older XML dump.

Use a dedicated backup phone: Google Photos may also clean eligible backed-up files outside PixelBridge’s folder. Google decides eligibility and may retain recent photos. The feature does not independently prove every cloud item or motion track is available. Pause cancels PixelBridge, but an operation already accepted by Google Photos can continue; uncertain completion is saved and checked before further transfers. New cleanup attempts are separated by 10 minutes.
