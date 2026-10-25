#!/bin/sh
# Build jbb.dylib (arm64 + arm64e). Output: build/jbb.dylib
set -e
cd "$(dirname "$0")/.."

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OUT=${1:-build/jbb.dylib}
mkdir -p "$(dirname "$OUT")"

clang -x objective-c -arch arm64 -arch arm64e -miphoneos-version-min=15.0 \
    -isysroot "$SDK" \
    -fobjc-arc -O2 -fvisibility=hidden \
    -ffile-prefix-map="$PWD"=. \
    -dynamiclib -framework Foundation \
    -o "$OUT" src/jbb_v617.c

# sign LAST: nothing may modify the file afterwards
codesign -f -s - "$OUT"
lipo -info "$OUT"
