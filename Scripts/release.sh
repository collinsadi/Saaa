#!/bin/sh
# Saaa release pipeline: build, Developer ID sign, notarize, staple, zip.
# Prereqs (one time):
#   1. A "Developer ID Application" certificate in the login keychain.
#   2. Stored notary credentials:
#      xcrun notarytool store-credentials saaa-notary \
#        --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
# Usage: Scripts/release.sh "Developer ID Application: Name (TEAMID)" [profile]
set -eu

IDENTITY="${1:?usage: release.sh \"Developer ID Application: Name (TEAMID)\" [notary-profile]}"
PROFILE="${2:-saaa-notary}"

echo "== build (Release)"
xcodebuild -project Saaa.xcodeproj -scheme Saaa -configuration Release build | grep -E "^\*\*" || true
APP=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Saaa-*/Build/Products/Release/Saaa.app | head -1)

echo "== stage"
rm -rf dist && mkdir dist
cp -R "$APP" dist/Saaa.app

echo "== sign (inside out)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  dist/Saaa.app/Contents/Frameworks/whisper.framework
codesign --force --options runtime --timestamp \
  --entitlements SaaaApp/Saaa.entitlements --sign "$IDENTITY" dist/Saaa.app
codesign --verify --deep --strict dist/Saaa.app
echo "signature ok"

echo "== notarize"
ditto -c -k --keepParent dist/Saaa.app dist/Saaa-notarize.zip
xcrun notarytool submit dist/Saaa-notarize.zip --keychain-profile "$PROFILE" --wait

echo "== staple + package"
xcrun stapler staple dist/Saaa.app
ditto -c -k --keepParent dist/Saaa.app dist/Saaa.zip
rm dist/Saaa-notarize.zip

echo "== dmg (styled drag-install image; background via Scripts/make-dmg-background.swift)"
rm -rf dist/dmg-staging dist/Saaa.dmg && mkdir dist/dmg-staging
cp -R dist/Saaa.app dist/dmg-staging/Saaa.app
if command -v create-dmg >/dev/null; then
  create-dmg --volname "Saaa" \
    --volicon dist/dmg-staging/Saaa.app/Contents/Resources/AppIcon.icns \
    --background Scripts/dmg-background.png \
    --window-pos 200 160 --window-size 660 420 --icon-size 128 \
    --icon "Saaa.app" 170 190 --app-drop-link 490 190 \
    --text-size 12 --hide-extension "Saaa.app" --no-internet-enable \
    dist/Saaa.dmg dist/dmg-staging
else
  echo "create-dmg not found (brew install create-dmg); building plain dmg"
  ln -s /Applications dist/dmg-staging/Applications
  hdiutil create -volname "Saaa" -srcfolder dist/dmg-staging -ov -format UDZO dist/Saaa.dmg
fi
codesign --force --timestamp --sign "$IDENTITY" dist/Saaa.dmg

echo "== notarize + staple dmg"
xcrun notarytool submit dist/Saaa.dmg --keychain-profile "$PROFILE" --wait
xcrun stapler staple dist/Saaa.dmg
rm -rf dist/dmg-staging

echo "== gatekeeper check"
spctl -a -vv --type execute dist/Saaa.app
spctl -a -vv -t open --context context:primary-signature dist/Saaa.dmg
echo "done: dist/Saaa.zip + dist/Saaa.dmg"
