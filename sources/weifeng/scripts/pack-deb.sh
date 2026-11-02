#!/bin/sh
# Build WeifengAdClean debs (rootless + roothide) from the extracted, patched dylib.
set -e
cd "$(dirname "$0")/.."

python3 scripts/patch-dylib.py
BUILD=build/WeifengAdClean.dylib
VER=$(awk '/^Version:/{print $2}' packaging/control)

build_one() {
    ARCH=$1
    SUBSTRATE=$2
    ROOT=build/root-$ARCH
    OUT=dist/com.pandan.weifengadclean_${VER}_${ARCH}.deb
    LIB=build/WeifengAdClean-$ARCH.dylib
    cp "$BUILD" "$LIB"
    install_name_tool -change \
        @loader_path/.jbroot/usr/lib/libsubstrate.dylib \
        "$SUBSTRATE" "$LIB" 2>/dev/null || true
    codesign -f -s - "$LIB" >/dev/null 2>&1

    rm -rf "$ROOT"
    mkdir -p "$ROOT/usr/lib/TweakInject" "$ROOT/DEBIAN"
    cp "$LIB" "$ROOT/usr/lib/TweakInject/WeifengAdClean.dylib"
    cp packaging/WeifengAdClean.plist "$ROOT/usr/lib/TweakInject/WeifengAdClean.plist"
    sed "s/^Architecture:.*/Architecture: $ARCH/" packaging/control > "$ROOT/DEBIAN/control"
    chmod 755 "$ROOT/usr/lib/TweakInject/WeifengAdClean.dylib"
    chmod 644 "$ROOT/usr/lib/TweakInject/WeifengAdClean.plist" "$ROOT/DEBIAN/control"
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -b -Zgzip "$ROOT" "$OUT" >/dev/null
    else
        ../.buildtools/dpkg-deb -b -Zgzip "$ROOT" "$OUT" >/dev/null
    fi
    echo "built: $OUT"
}

mkdir -p dist
# roothide: .jbroot symlink inside TweakInject maps to the real jbroot
build_one iphoneos-arm64e @loader_path/.jbroot/usr/lib/libsubstrate.dylib
# rootless: /var/jb is the real path
build_one iphoneos-arm64 /var/jb/usr/lib/libsubstrate.dylib
shasum -a 256 dist/*.deb > dist/SHA256SUMS
rm -rf build/root-iphoneos-arm64 build/root-iphoneos-arm64e
ls -lh dist/*.deb
