# Releasing

## Free distribution model

The public app is ad hoc signed, not Developer ID signed or notarized. Builds need no Apple developer credentials. Sparkle separately verifies Ed25519 signatures on both the update archive and appcast (`SUVerifyUpdateBeforeExtraction` and `SURequireSignedFeed`). Keep the private key safe: losing it can break the automatic update path for existing users of this ad hoc signed app.

The repository's public key belongs to upstream releases. A fork needs a new keypair, bundle identifier, HTTPS `SUFeedURL`, website URLs and repository URL. Generate an Ed25519 seed with Sparkle's `generate_keys` and export it following upstream documentation. Store the private seed only as the `SPARKLE_PRIVATE_KEY` GitHub Actions secret and in a secure offline backup. Never put it in the repository, build artifacts or Vercel environment.

## Publishing a version

1. Update `VERSION` and Cargo's package version (including Cargo.lock). Beta versions use `0.1.0-beta.1`.
2. Set `CFBundleShortVersionString` to its numeric part and **increase `CFBundleVersion` for every release**, including betas. Sparkle compares this build number.
3. Update `docs/RELEASE-NOTES.md` with the actual changes. Keep the signing/notarization notice.
4. Push to `main`. Checks build the website and optimized native app, then upload a CI artifact. If that version has not been published, the release job signs its ZIP and appcast, verifies the archive with CryptoKit and publishes a GitHub Release. A `-beta.N` version is a prerelease.
5. Verify CI, GitHub download, `/download`, `/appcast.xml` and an actual installed-app update. Release publication occurs only after both app and website checks pass. The upload uses a draft until every required asset is present; an interrupted draft can be retried.

Pushing a tag matching `v<VERSION>` also triggers checks and release. Published versions are immutable in normal CI: another push without a version bump produces a build artifact but does not overwrite a user's existing release. CI-generated tags do not recursively trigger another workflow run. PR jobs cannot access the release secret.

Before publication, ensure the build number is greater than every existing release's build number. No delta updates are generated in this beta pipeline.

## Website

Vercel project Root Directory: `site`; framework: Next.js; Node: 22.x; production branch: `main`. Connect the GitHub repository using Vercel's Git integration. A personal/non-commercial website can use Hobby within its limits; open-source status does not waive its usage terms. Public repositories can use standard GitHub-hosted runners without Actions minute charges.

`/download` and `/appcast.xml` select the newest published release with all three assets (ZIP, SHA256SUMS, appcast.xml), including betas. Release metadata is cached for up to five minutes. Draft/incomplete releases are excluded. The signed feed is served byte-for-byte; changing its XML invalidates its signature. GitHub failures return a temporary feed error and direct manual-download users to Releases. No photo data passes through this service.

The product's current update URL is embedded in Info.plist. Preserve that URL for existing users; if the domain must change, ship an update carrying the new feed URL while the old URL still works.

## Local packaging

```sh
./scripts/build-macos-app.sh
./scripts/package-release.sh
SPARKLE_KEY_FILE=/secure/path/to/private-seed ./scripts/sign-release.sh
```

Only copy the ZIP, SHA256SUMS and signed appcast to a release. No local private key or intermediate file belongs in a public asset. If the public key changes, do not publish over an existing tag.
