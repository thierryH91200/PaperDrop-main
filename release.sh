#!/bin/zsh
# Build, sign, and package PaperDrop as a compressed DMG.
# Notarization (required for clean Gatekeeper on other Macs) needs stored
# credentials:  xcrun notarytool store-credentials paperdrop \
#                 --apple-id <id> --team-id SZHK3JVH6J --password <app-pass>
set -e
cd "$(dirname "$0")"
./bundle.sh

DMG=PaperDrop.dmg
scripts/make-dmg.sh PaperDrop.app $DMG

if xcrun notarytool history --keychain-profile paperdrop >/dev/null 2>&1; then
    echo "notarizing…"
    xcrun notarytool submit $DMG --keychain-profile paperdrop --wait
    xcrun stapler staple $DMG
else
    echo "NOTE: not notarized (no 'paperdrop' keychain profile stored)."
fi
ls -la $DMG
