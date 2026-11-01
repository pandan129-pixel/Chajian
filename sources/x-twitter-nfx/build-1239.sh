#!/bin/sh
# BHTwitter / NFX 7.2 adapted for X 12.39.
#
# The 7.2 dylib was built for X 12.35/12.37. X 12.38+ removed
# -[T1TabView titleLabel] / _titleLabel, and 7.2's tab theming did
# [self valueForKey:@"titleLabel"] -> NSUnknownKeyException at launch.
# That single KVC call is skipped in src/BHTwitter.dylib (mov x0,#0), so the
# rest of the tweak keeps working; label tinting is disabled.
#
# Also ships 0NFBBundleFix.dylib + postinst: copy the 7.2 BHTwitter.bundle into
# X's data container so roothide's sandbox can read the 440-key zh_CN strings.
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
SRC="$ROOT/src"
DIST="$ROOT/dist"
PACKAGING="$ROOT/packaging"
DPKG_DEB="$ROOT/../../.buildtools/dpkg-deb"
MACHOCHECK="$ROOT/../../tools/machocheck/machocheck"
FIX_DYLIB="$ROOT/../x-twitter-nfb/fix/NFBBundleFix.dylib"
ROW_DYLIB="$ROOT/src/NFXSettingsRow.dylib"

PACKAGE=com.bandarhl.bhtwitter
VERSION=7.2-20
DYLIB_SRC="$SRC/BHTwitter.dylib"
BUNDLE_SRC="$SRC/BHTwitter.bundle"

ROOTHIDE_SUBSTRATE='@loader_path/.jbroot/usr/lib/libsubstrate.dylib'
ROOTLESS_SUBSTRATE='/var/jb/usr/lib/libsubstrate.dylib'
SIDELOADED_SUBSTRATE='@executable_path/Frameworks/libellekit.dylib'

[ -f "$DYLIB_SRC" ] || { echo "missing $DYLIB_SRC" >&2; exit 1; }
[ -d "$BUNDLE_SRC" ] || { echo "missing $BUNDLE_SRC" >&2; exit 1; }
[ -f "$FIX_DYLIB" ] || { echo "missing $FIX_DYLIB" >&2; exit 1; }
[ -f "$ROW_DYLIB" ] || { echo "missing $ROW_DYLIB" >&2; exit 1; }
[ -x "$DPKG_DEB" ] || { echo "missing dpkg-deb shim" >&2; exit 1; }
[ -x "$MACHOCHECK" ] || { echo "build tools/machocheck first" >&2; exit 1; }

mkdir -p "$DIST"
WORK=$(mktemp -d "${TMPDIR:-/private/tmp}/bhtwitter-1239.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

prepare() {
    flavor=$1
    substrate=$2
    out="$WORK/payload-$flavor"
    mkdir -p "$out"
    cp "$DYLIB_SRC" "$out/BHTwitter.dylib"

    install_name_tool -change "$SIDELOADED_SUBSTRATE" "$substrate" "$out/BHTwitter.dylib"
    if otool -L "$out/BHTwitter.dylib" | grep -q "$SIDELOADED_SUBSTRATE"; then
        echo "prepare: $flavor still links ellekit" >&2
        return 1
    fi
    otool -L "$out/BHTwitter.dylib" | grep -qF "$substrate" || {
        echo "prepare: $flavor missing $substrate" >&2
        return 1
    }

    codesign -f -s - "$out/BHTwitter.dylib" 2>/dev/null
    "$MACHOCHECK" --expect-arch arm64 "$out/BHTwitter.dylib" >/dev/null
    printf '%s\n' "$out"
}

stage() {
    flavor=$1
    prefix=$2
    arch=$3
    payload=$4

    stage="$WORK/stage-$flavor"
    dest="$stage/${prefix:+$prefix/}"
    rm -rf "$stage"
    mkdir -p "$stage/DEBIAN" \
             "$dest/Library/MobileSubstrate/DynamicLibraries" \
             "$dest/Library/Application Support/BHT"

    cp "$payload/BHTwitter.dylib" "$dest/Library/MobileSubstrate/DynamicLibraries/BHTwitter.dylib"
    cp "$PACKAGING/BHTwitter.plist" "$dest/Library/MobileSubstrate/DynamicLibraries/BHTwitter.plist"
    cp -R "$BUNDLE_SRC" "$dest/Library/Application Support/BHT/BHTwitter.bundle"

    cp "$FIX_DYLIB" "$dest/Library/MobileSubstrate/DynamicLibraries/0NFBBundleFix.dylib"
    cp "$PACKAGING/BHTwitter.plist" "$dest/Library/MobileSubstrate/DynamicLibraries/0NFBBundleFix.plist"
    codesign -f -s - "$dest/Library/MobileSubstrate/DynamicLibraries/0NFBBundleFix.dylib" 2>/dev/null

    cp "$ROW_DYLIB" "$dest/Library/MobileSubstrate/DynamicLibraries/ZZNFXSettingsRow.dylib"
    cp "$PACKAGING/BHTwitter.plist" "$dest/Library/MobileSubstrate/DynamicLibraries/ZZNFXSettingsRow.plist"
    codesign -f -s - "$dest/Library/MobileSubstrate/DynamicLibraries/ZZNFXSettingsRow.dylib" 2>/dev/null

    chmod 0755 "$dest/Library/MobileSubstrate/DynamicLibraries/"*.dylib
    chmod 0644 "$dest/Library/MobileSubstrate/DynamicLibraries/"*.plist

    installed_size=$(du -sk "$stage" | cut -f1)
    {
        echo "Package: $PACKAGE"
        echo "Name: BHTwitter / NFX 7.2 (X 12.39 适配)"
        echo "Version: $VERSION"
        echo "Architecture: $arch"
        echo "Section: Tweaks"
        echo "Priority: optional"
        echo "Maintainer: pandan (repack)"
        echo "Author: BandarHL / NFX"
        echo "Depends: firmware (>= 14.0), mobilesubstrate"
        echo "Conflicts: com.nfb.tweak"
        echo "Replaces: com.nfb.tweak"
        [ "$flavor" = roothide ] && echo "Pre-Depends: rootless-compat (>= 0.9)"
        echo "Installed-Size: $installed_size"
        echo "Description: BHTwitter / NFX 7.2，适配 X 12.39"
        echo " 跳过 12.38+ 已删除的 T1TabView.titleLabel KVC，修复启动闪退。"
        echo " 内置 0NFBBundleFix：把 7.2 的 440 条中文资源复制到 X data container。"
        echo " 在 X 设置页新增 NFX 分组/入口；双指长按可备用打开 7.2 设置。"
    } > "$stage/DEBIAN/control"
    chmod 0644 "$stage/DEBIAN/control"

    cat > "$stage/DEBIAN/postinst" <<'SH'
#!/bin/sh
SRC="/Library/Application Support/BHT/BHTwitter.bundle"
[ -d "$SRC" ] || SRC="/usr/lib/TweakInject/BHTwitter.bundle"
if [ -d "$SRC" ]; then
    for meta in /var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist; do
        [ -f "$meta" ] || continue
        d=$(dirname "$meta")
        if grep -qa "com.atebits.Tweetie2" "$meta" 2>/dev/null; then
            dest="$d/Library/Application Support/BHT"
            mkdir -p "$dest"
            rm -rf "$dest/BHTwitter.bundle"
            cp -R "$SRC" "$dest/BHTwitter.bundle"
            chown -R mobile:mobile "$dest/BHTwitter.bundle" 2>/dev/null || true
        fi
    done
fi
exit 0
SH
    chmod 0755 "$stage/DEBIAN/postinst"

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

    ctrl="$WORK/ctrl-$arch"
    rm -rf "$ctrl"; mkdir -p "$ctrl"
    tar -xOf "$deb" control.tar.gz 2>/dev/null | tar -xz -C "$ctrl" 2>/dev/null
    grep -qx "Package: $PACKAGE" "$ctrl/control"
    grep -qx "Version: $VERSION" "$ctrl/control"
    grep -qx "Architecture: $arch" "$ctrl/control"

    ex="$WORK/ex-$arch"
    rm -rf "$ex"; mkdir -p "$ex"
    tar -xOf "$deb" data.tar.gz 2>/dev/null | tar -xz -C "$ex" 2>/dev/null
    dylib="$ex/${prefix:+$prefix/}Library/MobileSubstrate/DynamicLibraries/BHTwitter.dylib"
    fix="$ex/${prefix:+$prefix/}Library/MobileSubstrate/DynamicLibraries/0NFBBundleFix.dylib"
    row="$ex/${prefix:+$prefix/}Library/MobileSubstrate/DynamicLibraries/ZZNFXSettingsRow.dylib"
    [ -f "$dylib" ] && [ -f "$fix" ] && [ -f "$row" ] || { echo "missing dylib in $deb" >&2; return 1; }
    lipo -info "$dylib" | grep -q arm64
    lipo -info "$fix" | grep -q arm64
    lipo -info "$row" | grep -q arm64
    codesign --verify "$row" >/dev/null 2>&1
    codesign --verify "$dylib" >/dev/null 2>&1
    codesign --verify "$fix" >/dev/null 2>&1
    otool -L "$dylib" | grep -qF "$substrate"
    bundle="$ex/${prefix:+$prefix/}Library/Application Support/BHT/BHTwitter.bundle"
    [ -f "$bundle/zh_CN.lproj/Localizable.strings" ] || { echo "no bundle" >&2; return 1; }
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
