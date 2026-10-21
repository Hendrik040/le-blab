#!/bin/bash
# Runs the unit tests. With only the Command Line Tools installed, SwiftPM doesn't find
# Swift Testing on its own, and the CLT's `_Testing_Foundation` overlay ships without module
# files — so point at the framework and disable cross-import overlays. With full Xcode, plain
# `swift test` works too.
set -euo pipefail
cd "$(dirname "$0")/.."
FW="$(xcode-select -p)/Library/Developer/Frameworks"
[ -d "$FW" ] || FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
exec swift test -Xswiftc -F"$FW" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F"$FW" -Xlinker -rpath -Xlinker "$FW" "$@"
