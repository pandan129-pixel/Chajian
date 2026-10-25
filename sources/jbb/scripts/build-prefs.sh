#!/bin/sh
# Build the PreferenceLoader bundle. Requires Theos + ldid in PATH.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

# Theos calls `ldid`; use the local shim if the host does not have it.
if ! command -v ldid >/dev/null 2>&1 && [ -x "$ROOT/.buildtools/ldid" ]; then
    export PATH="$ROOT/.buildtools:$PATH"
fi

cd "$HERE/../prefs"
export THEOS=${THEOS:-$HOME/theos-roothide}
make clean >/dev/null 2>&1 || true
make
echo "bundle: $(pwd)/.theos/obj/debug/JBBPrefs.bundle"
