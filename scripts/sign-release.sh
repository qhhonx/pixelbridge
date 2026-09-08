#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
: "${SPARKLE_KEY_FILE:?Set SPARKLE_KEY_FILE to the private signing seed file}"
repository="${GITHUB_REPOSITORY:-qhhonx/pixelbridge}"
version=$(cat VERSION)
./.build-cache/sparkle/bin/generate_appcast \
  --ed-key-file "$SPARKLE_KEY_FILE" \
  --download-url-prefix "https://github.com/$repository/releases/download/v$version/" \
  --link https://pixelbridge-app.vercel.app \
  --maximum-deltas 0 dist/release
./.build-cache/sparkle/bin/sign_update --verify --ed-key-file "$SPARKLE_KEY_FILE" dist/release/appcast.xml
python3 scripts/check-appcast.py
