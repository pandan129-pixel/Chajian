#!/bin/sh
set -e
cd "$(dirname "$0")/.."
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
mkdir -p build
clang -arch arm64 -arch arm64e -miphoneos-version-min=15.0 -isysroot "$SDK" \
      -fobjc-arc -O2 -o build/jbbd tools/jbbd.m
codesign -f -s - --entitlements build/jbb-ent.plist build/jbbd 2>/dev/null || codesign -f -s - build/jbbd
echo built build/jbbd
