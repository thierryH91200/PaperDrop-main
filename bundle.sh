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
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: BENJAMIN RICHARD SOUIRE (SZHK3JVH6J)}"

command -v xcodegen >/dev/null || { echo "brew install xcodegen first" >&2; exit 1; }
xcodegen generate

DERIVED=.build/xcode
xcodebuild \
    -project PaperDrop.xcodeproj \
    -scheme PaperDrop \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    MARKETING_VERSION="$VERSION" \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    OTHER_SWIFT_FLAGS='-Osize' \
    build

rm -rf PaperDrop.app
cp -R "$DERIVED/Build/Products/Release/PaperDrop.app" PaperDrop.app
echo "built and signed $PWD/PaperDrop.app (v$VERSION)"
