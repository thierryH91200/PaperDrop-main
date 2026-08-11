#!/bin/zsh
# Xcode build-phase equivalent of the SANE-bundling half of bundle.sh.
#
# Runs as a "Run Script" phase on the PaperDrop app target, AFTER link and
# BEFORE Xcode's built-in CodeSign of the .app — so the vendored Mach-Os are
# signed first (inside-out), then Xcode signs the outer app wrapper.
#
# Relies on Xcode-provided env: SRCROOT, BUILT_PRODUCTS_DIR,
# CONTENTS_FOLDER_PATH, EXPANDED_CODE_SIGN_IDENTITY.
#
# NOTE: the Helpers/Frameworks/Resources layout here must stay in sync with
# SANECLIBackend.swift (bundled scanimage + SANE env paths) and bundle.sh.
set -e
cd "$SRCROOT"

# Vendored SANE stack (scanimage + libsane + backends). Rebuilt from Homebrew
# when absent — see scripts/vendor-sane.sh.
[[ -d Vendor/sane ]] || scripts/vendor-sane.sh

CONTENTS="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH"
mkdir -p "$CONTENTS/Helpers" "$CONTENTS/Frameworks/sane" "$CONTENTS/Resources"

cp Vendor/sane/bin/scanimage "$CONTENTS/Helpers/"
cp Vendor/sane/lib/*.dylib "$CONTENTS/Frameworks/"
cp Vendor/sane/lib/sane/*.so "$CONTENTS/Frameworks/sane/"
cp -R Vendor/sane/etc/sane.d "$CONTENTS/Resources/"
cp -R Vendor/sane/licenses "$CONTENTS/Resources/"
cp Vendor/sane/VERSION "$CONTENTS/Resources/licenses/SANE-VERSION"

# EXPANDED_CODE_SIGN_IDENTITY is the resolved identity hash, or "-" for ad-hoc.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"

# --timestamp does a network round-trip; only worth it for a real Developer ID.
TS=()
[[ "$IDENTITY" != "-" ]] && TS=(--timestamp)

# One batched invocation over every vendored Mach-O, then done. Xcode signs
# the app wrapper itself as its final step.
codesign --force --options runtime "${TS[@]}" --sign "$IDENTITY" \
    "$CONTENTS/Helpers/scanimage" \
    "$CONTENTS/Frameworks/"*.dylib \
    "$CONTENTS/Frameworks/sane/"*.so

echo "embedded & signed vendored SANE into $CONTENTS (identity: $IDENTITY)"
