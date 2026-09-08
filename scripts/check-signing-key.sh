#!/bin/sh
# Exercise the release key without publishing or modifying any release asset.
set -eu
cd "$(dirname "$0")/.."
: "${SPARKLE_KEY_FILE:?Set SPARKLE_KEY_FILE to the private signing seed file}"
umask 077
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT
printf '%s\n' 'PixelBridge release signing preflight' > "$fixture_dir/probe.bin"
signature=$(./.build-cache/sparkle/bin/sign_update --ed-key-file "$SPARKLE_KEY_FILE" -p "$fixture_dir/probe.bin")
public_key=$(python3 -c 'import plistlib; print(plistlib.load(open("macos/Info.plist", "rb"))["SUPublicEDKey"])')
mkdir -p .build-cache/test-modules
xcrun swift -module-cache-path .build-cache/test-modules tests/VerifyUpdate.swift "$fixture_dir/probe.bin" "$public_key" "$signature"
echo 'Release signing key matches the public key embedded in the app.'
