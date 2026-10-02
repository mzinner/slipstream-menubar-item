#!/bin/sh
# Builds build/Slipstream Menubar.app from the Swift package and signs it ad hoc.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CONFIGURATION=${CONFIGURATION:-release}
APP="$ROOT/build/Slipstream Menubar.app"

swift build --package-path "$ROOT" -c "$CONFIGURATION" --arch arm64
BINARY=$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --arch arm64 --show-bin-path)/SlipstreamMenubar

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/SlipstreamMenubar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
VERSION=$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo dev)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
codesign --force --sign - --options runtime "$APP"
echo "$APP"
