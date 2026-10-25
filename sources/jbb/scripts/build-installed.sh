#!/bin/sh
# Build the installed-app scanner. It MUST be signed with these entitlements,
# otherwise iOS puts the (root) process in a sandbox where every path outside
# the jbroot returns EPERM.
set -e
cd "$(dirname "$0")/.."
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
mkdir -p build
cat > build/jbb-ent.plist <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>platform-application</key><true/>
<key>com.apple.private.security.no-sandbox</key><true/>
<key>com.apple.system-task-ports</key><true/>
<key>task_for_pid-allow</key><true/>
</dict></plist>
PL
clang -arch arm64 -arch arm64e -miphoneos-version-min=15.0 \
      -isysroot "$SDK" -fobjc-arc -O2 \
      -o build/jbb-installed tools/scan-installed.m
codesign -f -s - --entitlements build/jbb-ent.plist build/jbb-installed
echo "built build/jbb-installed"
