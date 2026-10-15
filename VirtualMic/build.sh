#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
BUNDLE="$ROOT/VoiceBridgeMic.driver"
if [ ! -f "$ROOT/../Assets/VoiceBridge.icns" ]; then bash "$ROOT/../Assets/build-icon.sh"; fi
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
xcrun clang -std=c11 -O2 -fblocks -mmacosx-version-min=14.4 -bundle \
  "$ROOT/Driver.c" -framework CoreAudio -framework CoreFoundation \
  -o "$BUNDLE/Contents/MacOS/VoiceBridgeMic"
cp "$ROOT/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$ROOT/APPLE-LICENSE.txt" "$ROOT/PROVENANCE.txt" "$BUNDLE/Contents/Resources/"
cp "$ROOT/../Assets/VoiceBridge.icns" "$BUNDLE/Contents/Resources/DeviceIcon.icns"
codesign --force --sign - --identifier local.voicebridge.virtual-mic "$BUNDLE"
codesign --verify --strict "$BUNDLE"
du -sh "$BUNDLE"
