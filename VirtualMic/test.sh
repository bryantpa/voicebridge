#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
mkdir -p "$ROOT/.build"
xcrun clang -std=c11 -g -O1 -fblocks -fsanitize=address,undefined \
  "$ROOT/test.c" -framework CoreAudio -framework CoreFoundation -o "$ROOT/.build/test"
"$ROOT/.build/test"
