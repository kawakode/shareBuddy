#!/bin/sh
# Builds ShareMan.app (release) into ./build.
# Usage: scripts/build-app.sh [--install]   (--install copies it to /Applications)
set -eu

cd "$(dirname "$0")/.."
APP="build/ShareMan.app"

swift build -c release --product ShareManApp
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ShareManApp" "$APP/Contents/MacOS/ShareManApp"
cp Sources/ShareManApp/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: enough to run locally and to get the "Local Network" prompt.
codesign --force --sign - --timestamp=none "$APP"

echo "Application créée : $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/ShareMan.app"
    cp -R "$APP" /Applications/
    echo "Installée dans /Applications/ShareMan.app"
fi
