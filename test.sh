#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
mkdir -p "$ROOT/.build/tests"
clang -mmacosx-version-min=14.4 -fobjc-arc -std=c11 -g -O1 -fsanitize=address,undefined \
  -I "$ROOT/Sources/AudioCore/include" -I "$ROOT/Sources/RNNoise/include" -I "$ROOT/Sources/RNNoise/src" -I "$ROOT/Sources/SpeexDSP/include" -I "$ROOT/Sources/SpeexDSP/src" -DFLOATING_POINT -DUSE_SMALLFT -DEXPORT= \
  "$ROOT/Sources/AudioCore/AudioCore.c" "$ROOT/Sources/AudioCore/Noise.c" "$ROOT/Sources/AudioCore/Echo.c" "$ROOT/Sources/AudioCore/SpeakerTap.m" "$ROOT/Sources/SpeexDSP/src/"*.c "$ROOT/Sources/RNNoise/src/"*.c "$ROOT/Tests/selftest.c" \
  -framework Foundation -framework AudioToolbox -framework CoreAudio -o "$ROOT/.build/tests/selftest"
"$ROOT/.build/tests/selftest"
swiftc "$ROOT/Sources/VoiceBridge/Diagnostics.swift" "$ROOT/Tests/DiagnosticsTests.swift" -o "$ROOT/.build/tests/diagnostics-test"
"$ROOT/.build/tests/diagnostics-test"
