#!/bin/sh
# Build debs from the NFB 7.3.0 dylib bundled in a 秋名山 X IPA.
#
#   ./build-ipa.sh [/path/to/X_Twitter_12.39_NFB730_秋名山.ipa]
#
# The sideload dylib links the sideload injector
#   @executable_path/Frameworks/libellekit.dylib
# so each flavor rewrites that one load command to the bootstrap's substrate
# path and re-signs. Payload bytes are otherwise untouched.
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
IPA=${1:-$HOME/Downloads/X_Twitter_12.39_NFB730_秋名山.ipa}
DIST="$ROOT/dist"
DPKG_DEB="$ROOT/../../.buildtools/dpkg-deb"
PACKAGE=com.nfb.tweak
VERSION=7.3.0-5
XVER=12.39

ROOTHIDE_SUBSTRATE='@loader_path/.jbroot/usr/lib/libsubstrate.dylib'
ROOTLESS_SUBSTRATE='/var/jb/usr/lib/libsubstrate.dylib'
SIDELOADED_SUBSTRATE='@executable_path/Frameworks/libellekit.dylib'

[ -f "$IPA" ] || { echo "missing IPA: $IPA" >&2; exit 1; }
[ -x "$DPKG_DEB" ] || { echo "missing dpkg-deb shim" >&2; exit 1; }
mkdir -p "$DIST"

WORK=$(mktemp -d "${TMPDIR:-/private/tmp}/nfb-ipa.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

unzip -q -o "$IPA" \
    'Payload/Twitter.app/Frameworks/BHTwitter.dylib' \
    'Payload/Twitter.app/Frameworks/libbhFLEX.dylib' \
    'Payload/Twitter.app/BHTwitter.bundle/*' \
    -d "$WORK" || { echo "unzip failed" >&2; exit 1; }
APP="$WORK/Payload/Twitter.app"
[ -f "$APP/Frameworks/BHTwitter.dylib" ] || { echo "no BHTwitter.dylib" >&2; exit 1; }
[ -f "$APP/BHTwitter.bundle/Info.plist" ] || { echo "no BHTwitter.bundle" >&2; exit 1; }
strings -a "$APP/Frameworks/BHTwitter.dylib" | grep -q 'NeoFreeBird' || {
    echo "dylib does not look like NeoFreeBird" >&2; exit 1; }

# Simplified-Chinese localization (zh-Hans for modern iOS, zh_CN for legacy).
for l in zh-Hans zh_CN; do
    [ -d "$ROOT/l10n/$l.lproj" ] || { echo "missing l10n/$l.lproj" >&2; exit 1; }
    rm -rf "$APP/BHTwitter.bundle/$l.lproj"
    cp -R "$ROOT/l10n/$l.lproj" "$APP/BHTwitter.bundle/$l.lproj"
done

prepare() {
    flavor=$1 substrate=$2
    out="$WORK/payload-$flavor"
    mkdir -p "$out"
    cp "$APP/Frameworks/BHTwitter.dylib" "$out/BHTwitter.dylib"
    cp "$APP/Frameworks/libbhFLEX.dylib" "$out/libbhFLEX.dylib"

    install_name_tool -change "$SIDELOADED_SUBSTRATE" "$substrate" "$out/BHTwitter.dylib"
    if otool -L "$out/BHTwitter.dylib" | grep -q "$SIDELOADED_SUBSTRATE"; then
        echo "prepare: $flavor still links ellekit" >&2; return 1
    fi
    otool -L "$out/BHTwitter.dylib" | grep -qF "$substrate" || {
        echo "prepare: $flavor missing $substrate" >&2; return 1; }

    for d in "$out"/*.dylib; do
        codesign -f -s - "$d" 2>/dev/null
        codesign --verify "$d" >/dev/null 2>&1 || { echo "sign: $d" >&2; return 1; }
    done
    printf '%s\n' "$out"
}

stage() {
    flavor=$1 prefix=$2 arch=$3 payload=$4
    stage="$WORK/stage-$flavor"
    dest="$stage/${prefix:+$prefix/}"
    rm -rf "$stage"
    mkdir -p "$stage/DEBIAN" \
             "$dest/Library/MobileSubstrate/DynamicLibraries" \
             "$dest/Library/Application Support/BHT"

    cp "$payload/BHTwitter.dylib" "$dest/Library/MobileSubstrate/DynamicLibraries/BHTwitter.dylib"
    cp "$payload/libbhFLEX.dylib" "$dest/Library/MobileSubstrate/DynamicLibraries/libbhFLEX.dylib"
    # filters: only X
    cat > "$dest/Library/MobileSubstrate/DynamicLibraries/BHTwitter.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Filter</key><dict><key>Bundles</key>
<array><string>com.atebits.Tweetie2</string></array></dict></dict></plist>
PLIST
    cp "$dest/Library/MobileSubstrate/DynamicLibraries/BHTwitter.plist" \
       "$dest/Library/MobileSubstrate/DynamicLibraries/libbhFLEX.plist"
    cp -R "$APP/BHTwitter.bundle" "$dest/Library/Application Support/BHT/BHTwitter.bundle"
    # NeoFreeBird 7.3.0 (12.39 build) looks for BHTwitter.bundle next to the
    # loaded dylib first (tweakDylibPath uses dladdr + realpath, so this is the
    # physical .../Library/MobileSubstrate/DynamicLibraries directory).
    cp -R "$APP/BHTwitter.bundle" "$dest/Library/MobileSubstrate/DynamicLibraries/BHTwitter.bundle"
    chmod 0755 "$dest/Library/MobileSubstrate/DynamicLibraries/"*.dylib
    chmod 0644 "$dest/Library/MobileSubstrate/DynamicLibraries/"*.plist

    installed_size=$(du -sk "$stage" | cut -f1)
    {
        echo "Package: $PACKAGE"
        echo "Name: NeoFreeBird (X $XVER)"
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
        echo "Description: NeoFreeBird 7.3.0（X $XVER 构建，已修 12.38+ T1TabView 崩溃，含简体中文汉化）"
        echo " 从 X $XVER NFB730 IPA 提取；T1TabView 改用 applyTintColor:，"
        echo " 不再调用已删除的 _t1_updateTitleLabel / titleLabel KVC。"
        echo " 简体中文已补 zh-Hans.lproj（iOS 现代语言码），并修正术语/文案。"
echo " 与旧 com.bandarhl.bhtwitter 冲突，安装时先移除旧版，避免双注入。"
    } > "$stage/DEBIAN/control"
    chmod 0644 "$stage/DEBIAN/control"

    out="$DIST/${PACKAGE}_${VERSION}_${arch}.deb"
    rm -f "$out"
    "$DPKG_DEB" --root-owner-group -Zgzip -b "$stage" "$out" >/dev/null
    printf '%s\n' "$out"
}

verify() {
    deb=$1 arch=$2 prefix=$3 substrate=$4
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
    otool -L "$dylib" | grep -qF "$substrate"
    strings -a "$dylib" | grep -q 'NeoFreeBird'
    bundle="$ex/${prefix:+$prefix/}Library/Application Support/BHT/BHTwitter.bundle"
    [ -f "$bundle/Info.plist" ] || { echo "no bundle in $deb" >&2; return 1; }
    for l in zh-Hans zh_CN; do
        [ -f "$bundle/$l.lproj/Localizable.strings" ] || {
            echo "no $l.lproj in $deb" >&2; return 1; }
        [ -f "$bundle/$l.lproj/RenameWords.strings" ] || {
            echo "no $l RenameWords in $deb" >&2; return 1; }
    done
}

payload_roothide=$(prepare roothide "$ROOTHIDE_SUBSTRATE")
payload_rootless=$(prepare rootless "$ROOTLESS_SUBSTRATE")

rootless=$(stage rootless /var/jb iphoneos-arm64 "$payload_rootless")
roothide=$(stage roothide '' iphoneos-arm64e "$payload_roothide")
verify "$rootless" iphoneos-arm64 /var/jb "$ROOTLESS_SUBSTRATE"
verify "$roothide" iphoneos-arm64e '' "$ROOTHIDE_SUBSTRATE"

echo
echo "built:"
for deb in "$rootless" "$roothide"; do
    printf '  %s  (%s)\n' "$deb" "$(du -h "$deb" | cut -f1)"
    shasum -a 256 "$deb" | sed 's/^/    /'
done
