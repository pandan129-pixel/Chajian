#!/bin/sh
# Build BHTwitter 7.2 debs from the tweak extracted out of the modded X IPA.
#
#   ./build.sh
#
# Two packages from the same payload:
#   dist/com.bandarhl.bhtwitter_7.2_iphoneos-arm64e.deb   roothide (no prefix)
#   dist/com.bandarhl.bhtwitter_7.2_iphoneos-arm64.deb    rootless (/var/jb)
#
# The IPA's dylib is linked against the *sideloaded* injector
#   @executable_path/Frameworks/libellekit.dylib
# which does not exist in an app installed from the App Store, so each variant
# is rewritten to the substrate path its bootstrap actually has, then re-signed
# (install_name_tool invalidates the old signature). Everything else about the
# payload is byte-identical to the IPA.
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
SRC="$ROOT/src"
DIST="$ROOT/dist"
PACKAGING="$ROOT/packaging"
DPKG_DEB="$ROOT/../../.buildtools/dpkg-deb"
MACHOCHECK="$ROOT/../../tools/machocheck/machocheck"

PACKAGE=com.bandarhl.bhtwitter
VERSION=7.2
DYLIB_SRC="$SRC/BHTwitter.dylib"
BUNDLE_SRC="$SRC/BHTwitter.bundle"

# The library whose MSHookMessageEx the dylib binds, per bootstrap.
ROOTHIDE_SUBSTRATE='@loader_path/.jbroot/usr/lib/libsubstrate.dylib'
ROOTLESS_SUBSTRATE='/var/jb/usr/lib/libsubstrate.dylib'
SIDELOADED_SUBSTRATE='@executable_path/Frameworks/libellekit.dylib'

[ -f "$DYLIB_SRC" ] || { echo "missing $DYLIB_SRC (run extract.sh)" >&2; exit 1; }
[ -d "$BUNDLE_SRC" ] || { echo "missing $BUNDLE_SRC (run extract.sh)" >&2; exit 1; }
[ -x "$DPKG_DEB" ] || { echo "missing dpkg-deb shim at $DPKG_DEB" >&2; exit 1; }
[ -x "$MACHOCHECK" ] || { echo "build tools/machocheck first" >&2; exit 1; }

mkdir -p "$DIST"
WORK=$(mktemp -d "${TMPDIR:-/private/tmp}/bhtwitter-deb.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

plutil -lint "$PACKAGING/BHTwitter.plist" >/dev/null

# Copy the dylib, point it at the bootstrap's substrate, sign it, gate it.
prepare() {
    flavor=$1
    substrate=$2
    out="$WORK/payload-$flavor"
    mkdir -p "$out"
    cp "$DYLIB_SRC" "$out/BHTwitter.dylib"

    install_name_tool -change "$SIDELOADED_SUBSTRATE" "$substrate" "$out/BHTwitter.dylib" 2>/dev/null
    if otool -L "$out/BHTwitter.dylib" | grep -q "$SIDELOADED_SUBSTRATE"; then
        echo "prepare: $flavor still links the sideloaded ellekit" >&2
        return 1
    fi
    if ! otool -L "$out/BHTwitter.dylib" | grep -qF "$substrate"; then
        echo "prepare: $flavor does not link $substrate" >&2
        return 1
    fi

    codesign -f -s - "$out/BHTwitter.dylib" 2>/dev/null
    "$MACHOCHECK" --expect-arch arm64 "$out/BHTwitter.dylib" >/dev/null
    printf '%s\n' "$out/BHTwitter.dylib"
}

stage() {
    flavor=$1
    prefix=$2
    arch=$3
    payload=$4

    stage="$WORK/stage-$flavor"
    dest="$stage/${prefix:+$prefix/}"
    rm -rf "$stage"
    mkdir -p "$stage/DEBIAN"
    mkdir -p "$dest/Library/MobileSubstrate/DynamicLibraries"
    mkdir -p "$dest/Library/Application Support/BHT"

    cp "$payload" "$dest/Library/MobileSubstrate/DynamicLibraries/BHTwitter.dylib"
    cp "$PACKAGING/BHTwitter.plist" "$dest/Library/MobileSubstrate/DynamicLibraries/BHTwitter.plist"
    cp -R "$BUNDLE_SRC" "$dest/Library/Application Support/BHT/BHTwitter.bundle"
    chmod 0755 "$dest/Library/MobileSubstrate/DynamicLibraries/BHTwitter.dylib"
    chmod 0644 "$dest/Library/MobileSubstrate/DynamicLibraries/BHTwitter.plist"

    installed_size=$(du -sk "$stage" | cut -f1)
    sed -e "s/@ARCH@/$arch/" -e "s/@VERSION@/$VERSION/" -e "s/@INSTALLED_SIZE@/$installed_size/" \
        "$PACKAGING/control.in" > "$stage/DEBIAN/control"
    chmod 0644 "$stage/DEBIAN/control"

    out="$DIST/${PACKAGE}_${VERSION}_${arch}.deb"
    rm -f "$out"
    "$DPKG_DEB" --root-owner-group -Zgzip -b "$stage" "$out" >/dev/null
    printf '%s\n' "$out"
}

verify() {
    deb=$1
    arch=$2
    prefix=$3
    substrate=$4

    members=$(ar t "$deb" | tr '\n' ' ')
    case "$members" in
        *debian-binary*control.tar*data.tar*) ;;
        *) echo "verify: unexpected members in $deb: $members" >&2; return 1 ;;
    esac

    control_dir="$WORK/control-$arch"
    rm -rf "$control_dir"
    mkdir -p "$control_dir"
    tar -xOf "$deb" control.tar.gz 2>/dev/null | tar -xz -C "$control_dir" 2>/dev/null
    control=$(cat "$control_dir/control")
    printf '%s\n' "$control" | grep -qx "Package: $PACKAGE"
    printf '%s\n' "$control" | grep -qx "Version: $VERSION"
    printf '%s\n' "$control" | grep -qx "Architecture: $arch"

    extract="$WORK/verify-$arch"
    rm -rf "$extract"
    mkdir -p "$extract"
    tar -xOf "$deb" data.tar.gz 2>/dev/null | tar -xz -C "$extract" 2>/dev/null
    dylib="$extract/${prefix:+$prefix/}Library/MobileSubstrate/DynamicLibraries/BHTwitter.dylib"
    [ -f "$dylib" ] || { echo "verify: $deb has no dylib at the expected path" >&2; return 1; }
    "$MACHOCHECK" --expect-arch arm64 --check-filter "$dylib" >/dev/null
    otool -L "$dylib" | grep -qF "$substrate" || {
        echo "verify: $deb does not link $substrate" >&2
        return 1
    }
    bundle="$extract/${prefix:+$prefix/}Library/Application Support/BHT/BHTwitter.bundle"
    [ -f "$bundle/Info.plist" ] || { echo "verify: $deb has no resource bundle" >&2; return 1; }
}

payload_roothide=$(prepare roothide "$ROOTHIDE_SUBSTRATE")
payload_rootless=$(prepare rootless "$ROOTLESS_SUBSTRATE")

roothide=$(stage roothide "" iphoneos-arm64e "$payload_roothide")
rootless=$(stage rootless "/var/jb" iphoneos-arm64 "$payload_rootless")

verify "$roothide" iphoneos-arm64e "" "$ROOTHIDE_SUBSTRATE"
verify "$rootless" iphoneos-arm64 "/var/jb" "$ROOTLESS_SUBSTRATE"

echo
echo "built:"
for deb in "$roothide" "$rootless"; do
    printf '  %s  (%s)\n' "$deb" "$(du -h "$deb" | cut -f1)"
    shasum -a 256 "$deb" | sed 's/^/    /'
done
