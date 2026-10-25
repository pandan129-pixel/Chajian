#!/bin/sh
# Copy every tweak filter plist to places Settings can read.
#
# Settings is sandboxed: it cannot read /var/jb or TweakInject, and the shell
# grep based scan only understood XML plists (so WeChat / Xianyu / Douyin were
# missing - theirs are binary). The Preferences bundle parses the copies at
# runtime with NSDictionary, which handles binary plists.
B=""
for c in /var/jb/Library/PreferenceBundles/JBBPrefs.bundle /Library/PreferenceBundles/JBBPrefs.bundle; do
    [ -d "$c" ] && B="$c" && break
done

DIRS="/var/jb/usr/lib/TweakInject /usr/lib/TweakInject /var/jb/Library/MobileSubstrate/DynamicLibraries /Library/MobileSubstrate/DynamicLibraries"

copy_all() {
    dest="$1"
    rm -rf "$dest"
    mkdir -p "$dest/TweakInject" "$dest/MobileSubstrate" || return 0

    for D in $DIRS; do
        [ -d "$D" ] || continue
        case "$D" in
            *TweakInject*) sub=TweakInject ;;
            *)             sub=MobileSubstrate ;;
        esac
        for f in "$D"/*.plist; do
            [ -f "$f" ] || continue
            n=$(basename "$f")
            case "$n" in jbb.plist) continue;; esac
            cp -f "$f" "$dest/$sub/$n" 2>/dev/null
        done
    done

    find "$dest" -type d -exec chmod 755 {} \; 2>/dev/null
    find "$dest" -type f -exec chmod 644 {} \; 2>/dev/null
    chown -R root:wheel "$dest" 2>/dev/null
}

# 1) inside the Preferences bundle (readable while the bundle is loaded)
[ -n "$B" ] && copy_all "$B/filters"

# 2) next to the prefs plist - a normal path Settings can always read
copy_all /var/mobile/Library/Preferences/jbb-filters
chown -R mobile:mobile /var/mobile/Library/Preferences/jbb-filters 2>/dev/null

exit 0
