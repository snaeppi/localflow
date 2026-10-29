#!/bin/bash
# Builds the end-to-end test's helpers: TextTarget.app, the paste target, and LFDriver.app, which posts
# key events and needs Localflow's permission for that: it gets Localflow's bundle ID and is signed with
# the same identity (scripts/dev-signing.sh), so it shares the grant.
#
# usage: bench/end_to_end/build.sh [OUTPUT_DIR]   (default /tmp/localflow-e2e)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-/tmp/localflow-e2e}
bundle() {  # NAME BUNDLE_ID SOURCE
  local app=$OUT/$1.app
  rm -rf "$app" && mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>$1</string>
<key>CFBundleName</key><string>$1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
$([ "$1" = LFDriver ] && echo '<key>LSUIElement</key><true/>')
</dict></plist>
EOF
  swiftc -O -target arm64-apple-macosx26.0 "$ROOT/bench/end_to_end/$3" -o "$app/Contents/MacOS/$1"
}
bundle TextTarget io.github.snaeppi.localflow.texttarget TextTarget.swift
codesign --force --sign - "$OUT/TextTarget.app"
bundle LFDriver io.github.snaeppi.localflow Driver.swift
"$ROOT/scripts/dev-signing.sh"
codesign --force --options runtime --sign "Localflow Development" \
  --keychain "$HOME/Library/Keychains/localflow-dev.keychain-db" "$OUT/LFDriver.app"
echo "Built $OUT/TextTarget.app and $OUT/LFDriver.app"
