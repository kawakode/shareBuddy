#!/bin/sh
# Packs ShareMan.app into a drag-to-install disk image: the window shows the
# app next to a shortcut to /Applications.
# Usage: scripts/make-dmg.sh [path/to/ShareMan.app] [output.dmg]
# Defaults: build/ShareMan.app -> build/ShareMan.dmg
# SIGN_IDENTITY (optional) also signs the disk image.
set -eu

cd "$(dirname "$0")/.."
APP="${1:-build/ShareMan.app}"
DMG="${2:-build/ShareMan.dmg}"
VOLNAME="ShareMan"

[ -d "$APP" ] || { echo "Application introuvable : $APP (lancez scripts/build-app.sh)" >&2; exit 1; }

WORK="$(mktemp -d)"
MNT=""
cleanup() {
    [ -n "$MNT" ] && hdiutil detach "$MNT" -quiet -force 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/stage"
ditto "$APP" "$WORK/stage/ShareMan.app"
ln -s /Applications "$WORK/stage/Applications"

# Read-write image first, so the Finder window can be laid out.
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$WORK/stage" \
    -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"

# Mounted under /Volumes so Finder sees it as a disk. The name may get a
# suffix ("ShareMan 1") if a volume with that name is already mounted.
MNT="$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" \
    | awk -F '\t' '/\/Volumes\// { print $NF }' | tail -n 1)"
[ -d "$MNT" ] || { echo "Montage de l'image impossible" >&2; exit 1; }
DISK_NAME="$(basename "$MNT")"

# Best effort: icon view, big icons, app on the left, Applications on the
# right. Finder scripting can be unavailable (headless CI without automation
# rights); the image still works, the window is just not arranged.
cat > "$WORK/layout.applescript" <<EOF
tell application "Finder"
    tell disk "$DISK_NAME"
        open
        set theWindow to container window
        set current view of theWindow to icon view
        set toolbar visible of theWindow to false
        set statusbar visible of theWindow to false
        set bounds of theWindow to {200, 120, 740, 460}
        set viewOptions to icon view options of theWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set position of item "ShareMan.app" of theWindow to {140, 160}
        set position of item "Applications" of theWindow to {400, 160}
        update without registering applications
        delay 2
        close theWindow
    end tell
end tell
EOF
# osascript can wait forever on an automation prompt: give it 60 s.
osascript "$WORK/layout.applescript" &
OSA_PID=$!
( sleep 60; kill "$OSA_PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCH_PID=$!
stop_watchdog() {
    pkill -P "$WATCH_PID" 2>/dev/null || true
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
}
if wait "$OSA_PID"; then
    stop_watchdog
else
    stop_watchdog
    echo "Avertissement : mise en page Finder impossible, image créée sans disposition." >&2
fi

rm -rf "$MNT/.fseventsd"
sync
hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -quiet -force
MNT=""

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

echo "Image disque créée : $DMG"
