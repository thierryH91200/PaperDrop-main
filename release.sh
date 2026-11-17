#!/bin/zsh
# Build, sign, and package PaperDrop as a compressed DMG.
# Notarization (required for clean Gatekeeper on other Macs) needs stored
# credentials:  xcrun notarytool store-credentials <profile> \
#                 --apple-id <id> --team-id Y3XMZAK2SQ --password <app-pass>
# Profile name: $NOTARY_PROFILE (default: pecule-notary, same team as Pecule).
set -e
NOTARY_PROFILE="${NOTARY_PROFILE:-pecule-notary}"
cd "$(dirname "$0")"
./bundle.sh

DMG=PaperDrop.dmg
scripts/make-dmg.sh PaperDrop.app $DMG
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: thierry hentic (Y3XMZAK2SQ)}"
[[ "$IDENTITY" != "-" ]] && codesign --sign "$IDENTITY" --timestamp $DMG

if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "notarizing…"
    xcrun notarytool submit $DMG --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple $DMG
else
    echo "NOTE: not notarized (no '$NOTARY_PROFILE' keychain profile stored)."
fi
ls -la $DMG
