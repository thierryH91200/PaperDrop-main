#!/bin/zsh
# Vendor SANE (scanimage + libsane + all backends + deps) from the local
# Homebrew install into Vendor/sane/, relocating every Mach-O from
# absolute /opt/homebrew install names to @rpath so the tree works from
# inside PaperDrop.app.
#
#   scripts/vendor-sane.sh            # vendor (requires brew sane-backends)
#   scripts/vendor-sane.sh --verify   # assert no /opt/homebrew references
set -e
cd "$(dirname "$0")/.."

VENDOR=Vendor/sane
BREW_SANE=/opt/homebrew/opt/sane-backends

# Single home for "every vendored Mach-O" — used by verify and signing.
machos() {
    echo $VENDOR/bin/scanimage $VENDOR/lib/*.dylib $VENDOR/lib/sane/*.so
}

if [[ "$1" == "--verify" ]]; then
    bad=0
    for f in $(machos); do
        if otool -L "$f" | tail -n +2 | grep -q "/opt/homebrew"; then
            echo "UNRELOCATED: $f"
            bad=1
        fi
    done
    [[ $bad == 0 ]] && echo "vendor tree clean: no /opt/homebrew references"
    exit $bad
fi

[[ -d "$BREW_SANE" ]] || { echo "brew install sane-backends first" >&2; exit 1; }

rm -rf $VENDOR
mkdir -p $VENDOR/bin $VENDOR/lib/sane $VENDOR/etc $VENDOR/licenses

# --- Copy (dereference symlinks; skip backend symlink aliases) ---
cp "$BREW_SANE/bin/scanimage" $VENDOR/bin/
cp "$BREW_SANE/lib/libsane.1.dylib" $VENDOR/lib/
for so in "$BREW_SANE"/lib/sane/*.so; do
    [[ -L "$so" ]] && continue
    cp "$so" $VENDOR/lib/sane/
done
DEPS=(
    /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib
    /opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib
    /opt/homebrew/opt/libpng/lib/libpng16.16.dylib
    /opt/homebrew/opt/libtiff/lib/libtiff.6.dylib
    /opt/homebrew/opt/zstd/lib/libzstd.1.dylib
    /opt/homebrew/opt/xz/lib/liblzma.5.dylib
)
for dep in $DEPS; do
    cp "$dep" $VENDOR/lib/
done
cp -RL /opt/homebrew/etc/sane.d $VENDOR/etc/
cp "$BREW_SANE"/{COPYING,LICENSE} $VENDOR/licenses/
brew list --versions sane-backends > $VENDOR/VERSION

chmod -R u+w $VENDOR

# --- Relocate: absolute /opt/homebrew install names -> @rpath ---
# One install_name_tool invocation per file: -change pairs for every
# non-system dep, plus the file's -id/-add_rpath, batched together
# (each invocation rewrites the whole binary).
relocate() {
    local f=$1
    shift
    local -a extra_args=("$@")
    local -a changes=()
    for dep in $(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep "^/opt/homebrew"); do
        changes+=(-change "$dep" "@rpath/$(basename "$dep")")
    done
    [[ ${#changes} -eq 0 && ${#extra_args} -eq 0 ]] && return 0
    install_name_tool "${changes[@]}" "${extra_args[@]}" "$f" 2>/dev/null
}

for dylib in $VENDOR/lib/*.dylib; do
    # siblings live in the same dir (Contents/Frameworks)
    relocate "$dylib" -id "@rpath/$(basename "$dylib")" -add_rpath "@loader_path"
done
for so in $VENDOR/lib/sane/*.so; do
    # backends live one level below the dylibs (Frameworks/sane)
    relocate "$so" -add_rpath "@loader_path/.."
done
# scanimage is installed at Contents/Helpers; dylibs at Contents/Frameworks
relocate $VENDOR/bin/scanimage -add_rpath "@executable_path/../Frameworks"

# install_name_tool invalidates signatures; ad-hoc re-sign so the tree is
# runnable locally. bundle.sh force-re-signs with the real identity.
codesign --force --sign - $(machos) 2>/dev/null

echo "vendored SANE $(cat $VENDOR/VERSION) into $VENDOR ($(du -sh $VENDOR | cut -f1))"
