#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || { echo 'Build on an Apple Silicon Mac.' >&2; exit 1; }
./scripts/fetch-dependencies.sh
python3 scripts/check-version.py
export MACOSX_DEPLOYMENT_TARGET=14.0
export CARGO_ENCODED_RUSTFLAGS=$(printf '%s\037%s\037%s' "--remap-path-prefix=$project_dir=/pixelbridge" "--remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo" "--remap-path-prefix=${RUSTUP_HOME:-$HOME/.rustup}=/rustup")
cargo build --release --locked
app_dir="$project_dir/dist/PixelBridge.app"
contents="$app_dir/Contents"
rm -rf "$app_dir"
mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/Frameworks" .build-cache/swift-modules
cp target/release/pixelbridge "$contents/MacOS/pixelbridge-core"
ditto .build-cache/exiftool "$contents/Resources/exiftool"
ditto .build-cache/sparkle/Sparkle.framework "$contents/Frameworks/Sparkle.framework"
xcrun swiftc -O -whole-module-optimization -parse-as-library \
  -module-cache-path .build-cache/swift-modules -target arm64-apple-macos14.0 \
  -debug-prefix-map "$project_dir=/pixelbridge" \
  -framework SwiftUI -framework Photos -framework AppKit -framework ServiceManagement \
  -F .build-cache/sparkle -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  macos/Localization.swift macos/BridgeSupport.swift macos/ActivityLog.swift macos/Diagnostics.swift macos/PixelCleanup.swift macos/BridgeModel.swift \
  macos/PhotoGrid.swift macos/AppUpdater.swift macos/PixelBridgeApp.swift \
  -o "$contents/MacOS/PixelBridge"
cp macos/Resources/*.json "$contents/Resources/"
for locale in en zh-Hans; do
  mkdir -p "$contents/Resources/$locale.lproj"
  cp "macos/Resources/$locale.lproj/InfoPlist.strings" "$contents/Resources/$locale.lproj/"
done
cp macos/Info.plist "$contents/Info.plist"
cp assets/PixelBridge.icns "$contents/Resources/PixelBridge.icns"
cp THIRD_PARTY_NOTICES.md LICENSE "$contents/Resources/"
python3 scripts/collect-licenses.py "$contents/Resources/Licenses"
# A local integrity signature, deliberately independent of personal Apple certificates.
# Sparkle's own nested helpers already carry ad hoc signatures from its verified release.
codesign --force --sign - "$contents/MacOS/pixelbridge-core"
codesign --force --sign - "$contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
python3 scripts/audit-public.py --app "$app_dir"
echo "$app_dir"
