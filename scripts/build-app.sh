#!/bin/bash
# Builds build/Localflow.app (release) and signs it with the stable dev identity from
# scripts/dev-signing.sh. The speech models aren't in the app: it downloads the one the user picks.
#
# usage: scripts/build-app.sh [--install]   # --install copies to /Applications and relaunches
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Localflow.app

swift build -c release --product Localflow

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Localflow "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# Icon Composer document → Assets.car (layered Liquid Glass icon) + AppIcon.icns fallback.
ICONS=$(mktemp -d)
xcrun actool Resources/AppIcon.icon --compile "$ICONS" --app-icon AppIcon --platform macosx \
  --target-device mac --minimum-deployment-target 26.0 --output-partial-info-plist "$ICONS/partial.plist" >/dev/null
cp "$ICONS/Assets.car" "$ICONS/AppIcon.icns" "$APP/Contents/Resources/"
rm -rf "$ICONS"
# The mark and wordmark (Resources/Images), drawn as templates.
cp Resources/Images/*.svg "$APP/Contents/Resources/"
# Loaded by /usr/bin/perl to ask what is playing (SystemAudio.swift); not part of the Swift package.
clang -dynamiclib -fobjc-arc -arch arm64 -mmacosx-version-min=26.0 -O2 -framework Foundation \
  Sources/NowPlaying/now-playing.m -o "$APP/Contents/Resources/NowPlaying.dylib"

scripts/dev-signing.sh
# codesign only seals files in Resources/ by hash; sign the dylib itself first, with the same identity.
KEYCHAIN="$HOME/Library/Keychains/localflow-dev.keychain-db"
codesign --force --sign "Localflow Development" --keychain "$KEYCHAIN" "$APP/Contents/Resources/NowPlaying.dylib"
codesign --force --options runtime --entitlements Resources/Localflow.entitlements \
  --sign "Localflow Development" --keychain "$KEYCHAIN" "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x Localflow 2>/dev/null && sleep 0.5 || true
  rm -rf /Applications/Localflow.app
  ditto "$APP" /Applications/Localflow.app
  open /Applications/Localflow.app
  echo "Installed and launched /Applications/Localflow.app"
fi
