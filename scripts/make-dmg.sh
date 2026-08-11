#!/bin/zsh
# Stage and build the PaperDrop DMG — single home for the DMG layout,
# shared by release.sh (local) and release.yml (CI).
#   scripts/make-dmg.sh <app-path> <dmg-path>
set -e
APP=$1
DMG=$2
[[ -d "$APP" && -n "$DMG" ]] || { echo "usage: make-dmg.sh <app> <dmg>" >&2; exit 1; }

rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname PaperDrop -srcfolder "$STAGE" -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
echo "built $DMG"
