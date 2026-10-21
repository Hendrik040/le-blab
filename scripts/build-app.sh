#!/bin/bash
# Builds Le Blab.app from the Swift package (no Xcode project needed; Command Line Tools suffice).
#
#   scripts/build-app.sh                       # release build, ad-hoc signed
#   CODESIGN_IDENTITY="My Cert" scripts/build-app.sh
#
# Signing with a stable identity (any local code-signing certificate) keeps macOS privacy grants
# (Accessibility, Microphone, Keychain "Always Allow") valid across rebuilds. Ad-hoc signatures
# change on every build, so macOS treats each build as a new app.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
IDENTITY="${CODESIGN_IDENTITY:--}"
APP="build/Le Blab.app"

swift build -c "$CONFIG" --product LeBlab
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LeBlab" "$APP/Contents/MacOS/LeBlab"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi

codesign --force --sign "$IDENTITY" --identifier local.leblab.LeBlab "$APP"
codesign --verify --verbose=1 "$APP"
echo "Built $APP (signed with: $IDENTITY)"
