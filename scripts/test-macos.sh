#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build-cache/test-modules .build-cache/tests
for test in ActivityLogTests BridgeSupportTests ModelPreferenceTests LocalizationTests RecoveryTests PixelCleanupTests CleanupSchedulingTests CleanupRecoveryTests ConcurrencyTests PhotoGridTests GalleryNavigationTests; do
  xcrun swiftc -O -D PIXELBRIDGE_TESTING -parse-as-library \
    -module-cache-path .build-cache/test-modules -target arm64-apple-macos14.0 \
    -framework SwiftUI -framework Photos -framework AppKit -framework ServiceManagement \
    macos/Localization.swift macos/BridgeSupport.swift macos/ActivityLog.swift macos/PixelCleanup.swift macos/BridgeModel.swift macos/PhotoGrid.swift \
    "tests/$test.swift" -o ".build-cache/tests/$test"
  cp macos/Resources/*.json .build-cache/tests/
  ".build-cache/tests/$test"
done
