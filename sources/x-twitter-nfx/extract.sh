#!/bin/sh
# Re-extract the tweak from the modded IPA into src/.
#
#   ./extract.sh [path/to/ipa]
#
# Default: ~/Downloads/X_Twitter_12.37_NFX7.2_秋名山.ipa
# Extracts only what the packages need, plus one reference binary:
#   src/BHTwitter.dylib          the tweak (arm64)
#   src/BHTwitter.bundle/        its resources, loaded from
#                                /Library/Application Support/BHT/
#   src/zxPluginsInject.dylib    reference only: a sideloading helper, never packaged
#
# libellekit.dylib in the IPA is the sideloaded injection framework, not a
# tweak; the device's own ElleKit/substrate provides it after jailbreak.
set -eu
ROOT=$(cd "$(dirname "$0")" && pwd)
IPA=${1:-"$HOME/Downloads/X_Twitter_12.37_NFX7.2_秋名山.ipa"}
APP=Payload/Twitter.app

[ -f "$IPA" ] || { echo "no such IPA: $IPA" >&2; exit 1; }
mkdir -p "$ROOT/src"

unzip -o -q "$IPA" \
    "$APP/Frameworks/BHTwitter.dylib" \
    "$APP/Frameworks/zxPluginsInject.dylib" \
    "$APP/BHTwitter.bundle/*" \
    -d "$ROOT/.unpack"

mv "$ROOT/.unpack/$APP/Frameworks/BHTwitter.dylib" "$ROOT/src/"
mv "$ROOT/.unpack/$APP/Frameworks/zxPluginsInject.dylib" "$ROOT/src/"
rm -rf "$ROOT/src/BHTwitter.bundle"
mv "$ROOT/.unpack/$APP/BHTwitter.bundle" "$ROOT/src/"
rm -rf "$ROOT/.unpack"

echo "extracted into $ROOT/src:"
ls -1 "$ROOT/src"
