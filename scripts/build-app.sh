#!/bin/sh
# Builds ShareBuddy.app (release) into ./build.
# Usage: scripts/build-app.sh [--install]   (--install copies it to /Applications)
set -eu

cd "$(dirname "$0")/.."
APP="build/ShareBuddy.app"

swift build -c release --product ShareBuddyApp
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ShareBuddyApp" "$APP/Contents/MacOS/ShareBuddyApp"
cp Sources/ShareBuddyApp/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: enough to run locally and to get the "Local Network" prompt.
codesign --force --sign - --timestamp=none "$APP"

echo "Application créée : $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/ShareBuddy.app"
    cp -R "$APP" /Applications/
    echo "Installée dans /Applications/ShareBuddy.app"
fi
