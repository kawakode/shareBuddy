#!/bin/sh
# Builds ShareMan.app (release) into ./build.
# Usage: scripts/build-app.sh [--install]   (--install copies it to /Applications)
#
# Optional environment variables (used by the release workflow):
#   VERSION=1.2.3          sets CFBundleShortVersionString / CFBundleVersion
#   UNIVERSAL=1            builds for both arm64 and x86_64
#   SIGN_IDENTITY="Developer ID Application: …"
#                          signs with that identity and the hardened runtime
#                          (required for notarization); ad-hoc signature otherwise
set -eu

cd "$(dirname "$0")/.."
APP="build/ShareMan.app"

if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCH_FLAGS="--arch arm64 --arch x86_64"
else
    ARCH_FLAGS=""
fi

# shellcheck disable=SC2086 # ARCH_FLAGS is intentionally split
swift build -c release --product ShareManApp $ARCH_FLAGS
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c release $ARCH_FLAGS --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ShareManApp" "$APP/Contents/MacOS/ShareManApp"
cp Sources/ShareManApp/Info.plist "$APP/Contents/Info.plist"

if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

if [ -n "${SIGN_IDENTITY:-}" ]; then
    # Developer ID signature with hardened runtime, as notarization requires.
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    # Ad-hoc signature: enough to run locally and to get the "Local Network" prompt.
    codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --strict "$APP"

echo "Application créée : $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/ShareMan.app"
    cp -R "$APP" /Applications/
    echo "Installée dans /Applications/ShareMan.app"
fi
