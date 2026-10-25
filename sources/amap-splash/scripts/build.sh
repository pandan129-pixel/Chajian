#!/bin/sh
# Build AmapSplash.dylib as a fat arm64 + arm64e dylib, then ad-hoc sign.
set -e
cd "$(dirname "$0")/.."
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OUT=${1:-build/AmapSplash.dylib}
mkdir -p "$(dirname "$OUT")"

clang -x objective-c \
    -arch arm64 -arch arm64e \
    -miphoneos-version-min=15.0 \
    -isysroot "$SDK" \
    -O2 -fvisibility=hidden \
    -ffile-prefix-map="$PWD"=. \
    -Wall -Wextra \
    -Wno-unused-parameter -Wno-unused-function -Wno-objc-root-class \
    -dynamiclib -framework Foundation \
    -install_name /usr/lib/TweakInject/AmapSplash.dylib \
    src/AmapSplash.m -o "$OUT"

# 签名最后一步：签完不要再改文件
codesign -f -s - "$OUT"
lipo -info "$OUT"
ls -lh "$OUT"
