#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
APP="${VB_APP_PATH:-$ROOT/VoiceBridge.app}"
bash "$ROOT/Assets/build-icon.sh"
bash "$ROOT/VirtualMic/package.sh"
swift build --package-path "$ROOT" -c release
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/.build/release/VoiceBridge" "$APP/Contents/MacOS/VoiceBridge"
/usr/bin/plutil -create xml1 "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/bin/python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({
      'CFBundleExecutable':'VoiceBridge','CFBundleIdentifier':'local.voicebridge.prototype',
      'CFBundleName':'VoiceBridge','CFBundleDisplayName':'VoiceBridge',
      'CFBundleIconFile':'VoiceBridge.icns',
      'CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.5.2-preview','CFBundleVersion':'1',
      'LSMinimumSystemVersion':'14.4','NSHighResolutionCapable':True,'LSUIElement':True,
      'NSMicrophoneUsageDescription':'VoiceBridge processes your microphone locally to reduce background noise and test echo cancellation. Audio is recorded only when you press the sample button.',
      'NSAudioCaptureUsageDescription':'VoiceBridge uses the selected speaker output as a local reference for experimental echo cancellation. Speaker audio is not saved or uploaded.',
    },f)
PY
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/Assets/VoiceBridge.icns" "$APP/Contents/Resources/VoiceBridge.icns"
cp "$ROOT/VirtualMic/Install VoiceBridge Microphone.pkg" "$APP/Contents/Resources/Install VoiceBridge Microphone.pkg"
cp "$ROOT/Sources/RNNoise/COPYING" "$APP/Contents/Resources/RNNoise-LICENSE.txt"
cp "$ROOT/Sources/RNNoise/PROVENANCE.txt" "$APP/Contents/Resources/RNNoise-PROVENANCE.txt"
cp "$ROOT/Sources/SpeexDSP/COPYING" "$APP/Contents/Resources/SpeexDSP-LICENSE.txt"
cp "$ROOT/Sources/SpeexDSP/PROVENANCE.txt" "$APP/Contents/Resources/SpeexDSP-PROVENANCE.txt"
if [ -d "$ROOT/VirtualMic/VoiceBridgeMic.driver" ]; then
  ditto "$ROOT/VirtualMic/VoiceBridgeMic.driver" "$APP/Contents/Resources/VoiceBridgeMic.driver"
fi
codesign --force --sign - --identifier local.voicebridge.prototype "$APP"
codesign --verify --strict "$APP"
printf '%s\n' "$APP"
