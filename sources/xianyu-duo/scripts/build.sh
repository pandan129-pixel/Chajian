#!/bin/sh
# 构建 XianyuDuo.dylib（arm64 + arm64e），签名必须最后一步
set -e
cd "$(dirname "$0")/.."
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OUT=${1:-build/XianyuDuo.dylib}
mkdir -p "$(dirname "$OUT")"

clang -x objective-c \
    -arch arm64 -arch arm64e \
    -miphoneos-version-min=15.0 \
    -isysroot "$SDK" \
    -fobjc-arc -fblocks -O2 \
    -fvisibility=hidden \
    -ffile-prefix-map="$PWD"=. \
    ${EXTRA_CFLAGS:-} \
    -Wall -Wextra -Wno-unused-function -Wno-unused-parameter -Wno-unused-variable \
    -Wno-deprecated-declarations -Wno-objc-method-access -Wl,-no_warn_inits \
    -dynamiclib \
    -install_name /usr/lib/TweakInject/XianyuDuo.dylib \
    -framework Foundation -framework UIKit -framework Photos \
    -framework ImageIO -framework CoreGraphics -framework AVFoundation -framework CoreMedia \
    src/*.m -o "$OUT"

# sign LAST
codesign -f -s - "$OUT"
lipo -info "$OUT"
ls -lh "$OUT"
