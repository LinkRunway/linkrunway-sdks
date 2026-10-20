#!/bin/sh
# Builds and tests the package on this Mac, then compiles it for iOS and tvOS, device and Simulator.
# Any compiler warning fails the run.
#
#   Scripts/verify.sh [output-directory]
#
# All build output goes to the directory given (default: .build/verify in the package, which git ignores).
# Expect several hundred megabytes; name a directory on another volume when this one is short of space.
set -eu
cd "$(dirname "$0")/.."
OUT="${1:-$PWD/.build/verify}"

echo "== macOS: swift build"
swift build --scratch-path "$OUT/swiftpm" -Xswiftc -warnings-as-errors
echo "== macOS: swift test"
swift test --scratch-path "$OUT/swiftpm" -Xswiftc -warnings-as-errors

for destination in 'generic/platform=iOS Simulator' 'generic/platform=iOS'; do
  echo "== $destination"
  xcodebuild -scheme LinkRunway -destination "$destination" -derivedDataPath "$OUT/xcode" -quiet \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build
done

# Xcode offers no tvOS destination until the tvOS platform is installed (Settings > Components), but the tvOS
# SDKs ship with Xcode, so SwiftPM compiles against them either way.
for sdk in appletvsimulator appletvos; do
  triple=arm64-apple-tvos15.0
  [ "$sdk" = appletvsimulator ] && triple="$triple-simulator"
  echo "== tvOS: $triple"
  swift build --triple "$triple" --sdk "$(xcrun --sdk "$sdk" --show-sdk-path)" \
    --scratch-path "$OUT/$sdk" -Xswiftc -warnings-as-errors
done
echo "== done"
