#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 scripts/check-version.py
codesign --verify --deep --strict dist/PixelBridge.app
version=$(cat VERSION)
mkdir -p dist/release
archive="PixelBridge-$version-arm64.zip"
ditto -c -k --keepParent --norsrc dist/PixelBridge.app "dist/release/$archive"
(cd dist/release && shasum -a 256 "$archive" > SHA256SUMS)
echo "dist/release/$archive"
