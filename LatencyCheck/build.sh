#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
APP="${VB_CHECK_APP_PATH:-$ROOT/VoiceBridge Delay Check.app}"
mkdir -p "$APP/Contents/MacOS" "$ROOT/build"
swift build --package-path "$ROOT/.." -c release
COREBUILD="$(swift build --package-path "$ROOT/.." -c release --show-bin-path)"
clang -O2 -I "$ROOT/../Sources/AudioCore/include" -c "$ROOT/Capture.c" -o "$ROOT/build/Capture.o"
swiftc -O -parse-as-library -Xcc -I"$ROOT/../Sources/AudioCore/include" -import-objc-header "$ROOT/Capture.h" "$ROOT/Analysis.swift" "$ROOT/Main.swift" "$ROOT/../Sources/VoiceBridge/Devices.swift" "$ROOT/build/Capture.o" "$COREBUILD/AudioCore.build/"*.o "$COREBUILD/RNNoise.build/src/"*.o "$COREBUILD/SpeexDSP.build/src/"*.o -framework AppKit -framework AVFoundation -framework AudioToolbox -o "$APP/Contents/MacOS/DelayCheck"
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
 plistlib.dump({'CFBundleExecutable':'DelayCheck','CFBundleIdentifier':'local.voicebridge.latencycheck','CFBundleName':'VoiceBridge Delay Check','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1.0','NSMicrophoneUsageDescription':'Compare the physical microphone and selected virtual microphone timing locally for ten seconds. No audio is saved or uploaded.','NSAudioCaptureUsageDescription':'The automatic local test uses speaker audio in memory as an echo-cancellation reference. Speaker audio is not saved or uploaded.','LSMinimumSystemVersion':'14.4'},f)
PY
mkdir -p "$APP/Contents/Resources"
# A voice fixture is private local input, never part of this repository.
# Remove any previous bundled fixture when rebuilding without one.
rm -f "$APP/Contents/Resources/test-fixture.caf"
if [ -n "${VB_TEST_FIXTURE:-}" ]; then
  test -f "$VB_TEST_FIXTURE"
  cp "$VB_TEST_FIXTURE" "$APP/Contents/Resources/test-fixture.caf"
fi
cp "$ROOT/../Sources/RNNoise/COPYING" "$APP/Contents/Resources/RNNoise-LICENSE.txt"
cp "$ROOT/../Sources/SpeexDSP/COPYING" "$APP/Contents/Resources/SpeexDSP-LICENSE.txt"
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/DelayCheck" --self-test
