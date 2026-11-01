#!/bin/sh
# Build NeoFreeBird 7.3.0 debs (X 12.38.1) for the Pandan repo.
#
# Upstream release: https://github.com/NeoFreeBird/app/releases/tag/v7.3.0
#   com.nfb.tweak_7.3.0-1+debug_iphoneos-arm64.deb   rootless (/var/jb)
#   (the arm64 payload already carries rpaths for both /var/jb and
#    @loader_path/.jbroot, so no load-command rewrite is needed)
#
# Output:
#   dist/com.nfb.tweak_7.3.0-1_iphoneos-arm64.deb    rootless
#   dist/com.nfb.tweak_7.3.0-1_iphoneos-arm64e.deb   roothide (no prefix)
#
# The package id changes to upstream's com.nfb.tweak. Conflicts/Replaces on
# com.bandarhl.bhtwitter make apt remove the old NFX 7.2 first, otherwise two
# copies of BHTwitter.dylib would be injected into X.
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
DIST="$ROOT/dist"
VENDOR="$ROOT/vendor"
DPKG_DEB="$ROOT/../../.buildtools/dpkg-deb"
UPSTREAM_URL='https://github.com/NeoFreeBird/app/releases/download/v7.3.0/com.nfb.tweak_7.3.0-1%2Bdebug_iphoneos-arm64.deb'
UPSTREAM_SHA='19bde39f5c70f2abe4dd507f1030505e418de82cc2cd2420a14ebd7a1dd632f3'
PACKAGE=com.nfb.tweak
VERSION=7.3.0-1

[ -x "$DPKG_DEB" ] || { echo "missing dpkg-deb shim: $DPKG_DEB" >&2; exit 1; }
mkdir -p "$DIST" "$VENDOR"

SRC="$VENDOR/upstream-arm64.deb"
if [ ! -f "$SRC" ]; then
    echo "downloading $UPSTREAM_URL"
    curl -fL --retry 3 --max-time 300 -o "$SRC" "$UPSTREAM_URL"
fi
actual=$(shasum -a 256 "$SRC" | cut -d' ' -f1)
[ "$actual" = "$UPSTREAM_SHA" ] || { echo "upstream sha mismatch: $actual" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/private/tmp}/nfb730.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---- extract upstream rootless payload
mkdir -p "$WORK/up"
( cd "$WORK/up" && ar -x "$SRC" && tar -xf data.tar.* )
PAYLOAD="$WORK/up/var/jb"
[ -f "$PAYLOAD/Library/MobileSubstrate/DynamicLibraries/BHTwitter.dylib" ] || {
    echo "unexpected upstream layout" >&2; exit 1; }
[ -d "$PAYLOAD/Library/Application Support/BHT/BHTwitter.bundle" ] || {
    echo "missing resource bundle" >&2; exit 1; }

# ---- re-sign every injected Mach-O (payload bytes otherwise untouched)
for f in "$PAYLOAD/Library/MobileSubstrate/DynamicLibraries/"*.dylib; do
    codesign -f -s - "$f" 2>/dev/null
    codesign --verify "$f" >/dev/null 2>&1 || { echo "sign failed: $f" >&2; exit 1; }
done

stage() {
    flavor=$1 prefix=$2 arch=$3
    stage="$WORK/stage-$flavor"
    dest="$stage/${prefix:+$prefix/}"
    rm -rf "$stage"
    mkdir -p "$stage/DEBIAN" "$dest"
    cp -R "$PAYLOAD/." "$dest/"

    installed_size=$(du -sk "$stage" | cut -f1)
    {
        echo "Package: $PACKAGE"
        echo "Name: NeoFreeBird (X 12.38.1)"
        echo "Version: $VERSION"
        echo "Architecture: $arch"
        echo "Section: Tweaks"
        echo "Priority: optional"
        echo "Maintainer: pandan (repack)"
        echo "Author: NeoFreeBird"
        echo "Depends: firmware (>= 15.0), mobilesubstrate"
        echo "Conflicts: com.bandarhl.bhtwitter, com.den.twigalaxy, xyz.cypwn.twigalaxy, xyz.cypwn.bhtwitter, com.netskao.twitternoads, xyz.cypwn.bringbacktwitter"
        echo "Replaces: com.bandarhl.bhtwitter"
        [ "$flavor" = roothide ] && echo "Pre-Depends: rootless-compat (>= 0.9)"
        echo "Installed-Size: $installed_size"
        echo "Description: NeoFreeBird 7.3.0，已适配 X 12.38.1"
        echo " 修复 X 12.38 删除 T1TabView.titleLabel 导致的启动闪退；"
        echo " 含 Liquid Glass / 分栏 / 分享参数等 12.38.1 适配。"
        echo " 与旧 com.bandarhl.bhtwitter 冲突，安装时会先移除旧版，避免双注入。"
    } > "$stage/DEBIAN/control"
    chmod 0644 "$stage/DEBIAN/control"

    out="$DIST/${PACKAGE}_${VERSION}_${arch}.deb"
    rm -f "$out"
    "$DPKG_DEB" --root-owner-group -Zgzip -b "$stage" "$out" >/dev/null
    printf '%s\n' "$out"
}

verify() {
    deb=$1 arch=$2 prefix=$3
    ctrl="$WORK/ctrl-$arch"; rm -rf "$ctrl"; mkdir -p "$ctrl"
    tar -xOf "$deb" control.tar.gz 2>/dev/null | tar -xz -C "$ctrl" 2>/dev/null
    grep -qx "Package: $PACKAGE" "$ctrl/control"
    grep -qx "Version: $VERSION" "$ctrl/control"
    grep -qx "Architecture: $arch" "$ctrl/control"
    grep -q "com.bandarhl.bhtwitter" "$ctrl/control"

    ex="$WORK/ex-$arch"; rm -rf "$ex"; mkdir -p "$ex"
    tar -xOf "$deb" data.tar.gz 2>/dev/null | tar -xz -C "$ex" 2>/dev/null
    dylib="$ex/${prefix:+$prefix/}Library/MobileSubstrate/DynamicLibraries/BHTwitter.dylib"
    [ -f "$dylib" ] || { echo "no dylib in $deb" >&2; return 1; }
    lipo -info "$dylib" | grep -q arm64
    codesign --verify "$dylib" >/dev/null 2>&1
    bundle="$ex/${prefix:+$prefix/}Library/Application Support/BHT/BHTwitter.bundle"
    [ -f "$bundle/Info.plist" ] || { echo "no bundle in $deb" >&2; return 1; }
    strings -a "$dylib" | grep -q 'NeoFreeBird v7.3.0'
}

rootless=$(stage rootless /var/jb iphoneos-arm64)
roothide=$(stage roothide '' iphoneos-arm64e)
verify "$rootless" iphoneos-arm64 /var/jb
verify "$roothide" iphoneos-arm64e ''

echo
echo "built:"
for deb in "$rootless" "$roothide"; do
    printf '  %s  (%s)\n' "$deb" "$(du -h "$deb" | cut -f1)"
    shasum -a 256 "$deb" | sed 's/^/    /'
done
