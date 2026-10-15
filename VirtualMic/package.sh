#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
bash "$ROOT/build.sh"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/voicebridge-package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Library/Audio/Plug-Ins/HAL"
ditto "$ROOT/VoiceBridgeMic.driver" "$STAGE/Library/Audio/Plug-Ins/HAL/VoiceBridgeMic.driver"
pkgbuild --root "$STAGE" --identifier local.voicebridge.virtual-mic.pkg \
  --version 0.1.1 --ownership recommended --install-location / \
  --scripts "$ROOT/InstallerScripts" \
  "$ROOT/Install VoiceBridge Microphone.pkg"
# Postinstall restarts audio after the installer obtains admin authorization.
# Default devices and other installed drivers are left unchanged.
pkgutil --payload-files "$ROOT/Install VoiceBridge Microphone.pkg"
