#!/bin/sh
# Build CrashAnalyzerPro.dylib (arm64 + arm64e). Sign LAST.
set -e
cd "$(dirname "$0")/.."

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OUT=${1:-build/CrashAnalyzerPro.dylib}
mkdir -p "$(dirname "$OUT")"

clang -x objective-c \
    -arch arm64 -arch arm64e \
    -miphoneos-version-min=15.0 \
    -isysroot "$SDK" \
    -fobjc-arc -fblocks -O2 \
    -fvisibility=hidden \
    -ffile-prefix-map="$PWD"=. \
    -Wall -Wextra \
    -Wno-unused-parameter -Wno-unused-function -Wno-unused-variable \
    -Wno-deprecated-declarations -Wno-objc-method-access \
    -Wno-nullability-completeness -Wno-unguarded-availability-new \
    -dynamiclib \
    -install_name /usr/lib/TweakInject/CrashAnalyzerPro.dylib \
    -framework Foundation -framework UIKit -framework CoreGraphics \
    src/CrashAnalyzerPro.m -o "$OUT"

codesign -f -s - "$OUT"
lipo -info "$OUT"
ls -lh "$OUT"
