#!/bin/sh
# Dev deploy ritual: sign the freshest Debug build and swap it into
# /Applications (stable TCC path), then relaunch.
# Run this from Terminal (NOT a headless session): codesign needs the
# keychain authorization dialog on first use - click "Always Allow".
set -eu

APP=$(xcodebuild -project "$(dirname "$0")/../Saaa.xcodeproj" -scheme Saaa \
    -configuration Debug -showBuildSettings 2>/dev/null \
    | awk '/BUILT_PRODUCTS_DIR/ {print $3; exit}')/Saaa.app
CERT=664B46DC3FD1EE8415F1C15468E5C9E719E7E6A6  # Apple Development
ENTITLEMENTS="$(dirname "$0")/../SaaaApp/Saaa.entitlements"

echo "== signing $APP"
find "$APP" -name '*.cstemp' -delete
codesign --force --deep --sign "$CERT" --entitlements "$ENTITLEMENTS" "$APP"

echo "== deploying to /Applications"
pkill -x Saaa 2>/dev/null || true
sleep 1
ditto "$APP" /Applications/Saaa.app
open /Applications/Saaa.app
echo "done - Saaa relaunched"
