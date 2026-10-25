#!/bin/sh
# Pack everything (tweak + settings) into one deb.
# Usage: pack-deb.sh [iphoneos-arm64e|iphoneos-arm64]
set -e
cd "$(dirname "$0")/.."
ARCH=${1:-iphoneos-arm64e}
VER=6.22.7
ROOT=build/root
OUT=dist/com.pandan.jbb_${VER}_${ARCH}.deb

sh scripts/build-jbb.sh build/jbb.dylib
sh scripts/build-prefs.sh
sh scripts/build-installed.sh
sh scripts/build-jbbd.sh

rm -rf "$ROOT"; mkdir -p "$ROOT/usr/lib/TweakInject" \
    "$ROOT/Library/PreferenceBundles" \
    "$ROOT/Library/PreferenceLoader/Preferences" "$ROOT/DEBIAN" "$ROOT/usr/lib/jbb" \
    "$ROOT/Library/LaunchDaemons"

cp build/jbb.dylib "$ROOT/usr/lib/TweakInject/jbb.dylib"
cp packaging/jbb.plist "$ROOT/usr/lib/TweakInject/jbb.plist"
cp -a prefs/.theos/obj/debug/JBBPrefs.bundle "$ROOT/Library/PreferenceBundles/"
cp -a prefs/layout/Library/PreferenceLoader/Preferences/JBBPrefs.plist \
      "$ROOT/Library/PreferenceLoader/Preferences/"
cp prefs/scan-tweaks.sh "$ROOT/usr/lib/jbb/scan-tweaks.sh"
cp build/jbb-installed "$ROOT/usr/lib/jbb/jbb-installed"
cp build/jbbd "$ROOT/usr/lib/jbb/jbbd"
chmod 755 "$ROOT/usr/lib/jbb/scan-tweaks.sh" "$ROOT/usr/lib/jbb/jbb-installed" "$ROOT/usr/lib/jbb/jbbd"

cat > "$ROOT/Library/LaunchDaemons/com.pandan.jbbd.plist" <<'LD'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>com.pandan.jbbd</string>
	<key>ProgramArguments</key>
	<array><string>/var/jb/usr/lib/jbb/jbbd</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ThrottleInterval</key><integer>5</integer>
</dict>
</plist>
LD
cat > "$ROOT/DEBIAN/postinst" <<'PI'
#!/bin/sh
# Paths differ depending on whether dpkg runs us inside or outside the jbroot.
JB=/var/jb
B=""
for c in "$JB/Library/PreferenceBundles/JBBPrefs.bundle" /Library/PreferenceBundles/JBBPrefs.bundle; do
    [ -d "$c" ] && B="$c" && break
done

TOOL=""
for t in "$JB/usr/lib/jbb/jbb-installed" /usr/lib/jbb/jbb-installed; do
    [ -x "$t" ] && TOOL="$t" && break
done
SCAN=""
for t in "$JB/usr/lib/jbb/scan-tweaks.sh" /usr/lib/jbb/scan-tweaks.sh; do
    [ -x "$t" ] && SCAN="$t" && break
done

# The scanner needs to run unsandboxed: add it to the jailbreak trust cache.
[ -n "$TOOL" ] && "$JB/basebin/jbctl" trustcache add "$TOOL" >/dev/null 2>&1 || true

if [ -n "$TOOL" ] && [ -n "$B" ]; then
    # stdout goes to the host filesystem; direct writes from the tool would land
    # in the jbroot namespace instead.
    "$TOOL" - > "$B/jbb-installed.txt" 2>/dev/null || true
    if [ -s "$B/jbb-installed.txt" ]; then
        chown root:wheel "$B/jbb-installed.txt" 2>/dev/null
        chmod 644 "$B/jbb-installed.txt" 2>/dev/null
        cp -f "$B/jbb-installed.txt" /var/mobile/Library/Preferences/jbb-installed.txt 2>/dev/null || true
        chown mobile:mobile /var/mobile/Library/Preferences/jbb-installed.txt 2>/dev/null
        chmod 644 /var/mobile/Library/Preferences/jbb-installed.txt 2>/dev/null
    fi
fi

[ -n "$SCAN" ] && "$SCAN" || true

# Publish per-app config into app containers (sandboxed apps can only read them).
if [ -x /var/jb/usr/lib/jbb/jbbd ]; then
    /var/jb/basebin/jbctl trustcache add /var/jb/usr/lib/jbb/jbbd >/dev/null 2>&1 || true
    launchctl unload /var/jb/Library/LaunchDaemons/com.pandan.jbbd.plist >/dev/null 2>&1 || true
    launchctl load -w /var/jb/Library/LaunchDaemons/com.pandan.jbbd.plist >/dev/null 2>&1 || \
        launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.pandan.jbbd.plist >/dev/null 2>&1 || true
    sleep 1
    /var/jb/usr/lib/jbb/jbbd >/dev/null 2>&1 &
fi

# First install: give Settings a sane starting config (global on, no per-app
# overrides). Settings mirrors this into cfprefsd on load, which is how a
# sandboxed App gets to see it.
CFG=/var/mobile/Library/Preferences/com.pandan.jbb.cfg.plist
OLD=/var/mobile/Library/Preferences/com.pandan.jbb.plist
if [ ! -f "$CFG" ] && [ -f "$OLD" ]; then
    cp -f "$OLD" "$CFG" 2>/dev/null || true
    chown mobile:mobile "$CFG" 2>/dev/null || true
    chmod 644 "$CFG" 2>/dev/null || true
fi
if [ ! -f "$CFG" ]; then
    cat > "$CFG" <<'PLCFG'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>globalEnabled</key><true/>
	<key>globalExtraTokens</key><false/>
	<key>profiles</key>
	<dict/>
</dict>
</plist>
PLCFG
    chown mobile:mobile "$CFG" 2>/dev/null
    chmod 644 "$CFG" 2>/dev/null
fi
exit 0
PI
chmod 755 "$ROOT/DEBIAN/postinst"
cp prefs/prerm "$ROOT/DEBIAN/prerm"
chmod 755 "$ROOT/DEBIAN/prerm"
find "$ROOT" -name "._*" -delete 2>/dev/null || true

cat > "$ROOT/DEBIAN/control" <<CTL
Package: com.pandan.jbb
Name: JBB
Version: ${VER}
Architecture: ${ARCH}
Description: Jailbreak detection bypass (tweak + per-app settings)
Maintainer: pandan
Author: pandan
Section: Tweaks
Depends: preferenceloader
CTL

mkdir -p dist; rm -f "$OUT"
if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb --root-owner-group -Zgzip -b "$ROOT" "$OUT"
else
    "${THEOS:-$HOME/theos-roothide}/bin/dm.pl" -b "$ROOT" "$OUT"
fi
ls -lh "$OUT"
