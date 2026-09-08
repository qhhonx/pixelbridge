# Privacy and local data

PhotoKit reads the user's authorized System Photo Library and downloads originals through Apple's services when needed. Files are staged locally and sent to the selected Pixel over ADB. Google Photos on the Pixel communicates with Google using the account configured on that phone.

PixelBridge has no photo-upload backend and no product analytics. The app's queue, retry metadata, caches and logs live under `~/Library/Application Support/PixelBridge`. Logs may contain filenames, identifiers, paths and device diagnostics; redact them before sharing. Settings are stored in the macOS defaults domain for `org.pixelbridge.app`.

Sparkle checks an HTTPS update feed on the product website and downloads updates from GitHub Releases. These services receive normal network metadata such as IP address and user-agent/app version. System profiling is disabled. Automatic checks can be disabled in Settings. Installation remains a user choice.

The website uses a first-party language-preference cookie when a language is explicitly chosen, and follows browser language otherwise. There is no advertising or analytics integration. Hosting providers may keep service/security logs.

The app never deletes Apple Photos originals or Pixel photos automatically. Mac staging cleanup verifies the Pixel copy; that check is not evidence of Google cloud backup.
