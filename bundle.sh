#!/bin/zsh
# Build PaperDrop.app via the Xcode project (generated from project.yml).
#
# The app target's "Embed & sign vendored SANE" build phase
# (scripts/xcode-embed-sane.sh) assembles Contents/Helpers, Frameworks and
# Resources and signs them inside-out; Xcode then signs the .app wrapper.
# This script just drives xcodebuild and drops the result at ./PaperDrop.app
# so release.sh / make-dmg.sh keep their contract.
#
# Env overrides (used by CI):
#   VERSION           marketing version (default 0.1.0)
#   CODESIGN_IDENTITY signing identity ("-" for ad-hoc; default: local
#                     Developer ID)
set -e
cd "$(dirname "$0")"

VERSION="${VERSION:-0.1.0}"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: thierry hentic (Y3XMZAK2SQ)}"

if command -v xcodegen >/dev/null; then
    xcodegen generate
elif [[ ! -d PaperDrop.xcodeproj ]]; then
    echo "brew install xcodegen first" >&2; exit 1
else
    echo "xcodegen not found: using the existing PaperDrop.xcodeproj"
fi

# Developer ID builds must be notarizable: secure timestamp and no
# get-task-allow (Xcode injects it unless told not to).
SIGN_FLAGS=()
if [[ "$IDENTITY" != "-" ]]; then
    SIGN_FLAGS=(CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp)
fi

DERIVED=.build/xcode
# Start from a fresh .app so Xcode always re-signs it (an incremental build
# can skip CodeSign while the embed phase still adds files).
rm -rf "$DERIVED/Build/Products/Release/PaperDrop.app"
xcodebuild \
    -project PaperDrop.xcodeproj \
    -scheme PaperDrop \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    MARKETING_VERSION="$VERSION" \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    OTHER_SWIFT_FLAGS='-Osize' \
    "${SIGN_FLAGS[@]}" \
    build

rm -rf PaperDrop.app
cp -R "$DERIVED/Build/Products/Release/PaperDrop.app" PaperDrop.app
echo "built and signed $PWD/PaperDrop.app (v$VERSION)"
