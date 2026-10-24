#!/bin/bash
# A drag-to-Applications disk image of a signed app, itself signed, notarized and stapled.
#
#   DEVELOPER_ID=… NOTARY_PROFILE=… scripts/release/make-dmg.sh build/Starnotch.app 0.2.0
set -euo pipefail
APP="${1:?usage: make-dmg.sh path/to/App.app version}"
VERSION="${2:?usage: make-dmg.sh path/to/App.app version}"
: "${DEVELOPER_ID:?set DEVELOPER_ID}"
PROFILE="${NOTARY_PROFILE:-starnotch-notary}"
NAME="$(basename "$APP" .app)"
OUT="$(dirname "$APP")/$(echo "$NAME" | tr '[:upper:]' '[:lower:]')-$VERSION.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT"
codesign --force --timestamp --sign "$DEVELOPER_ID" "$OUT"
xcrun notarytool submit "$OUT" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT"
shasum -a 256 "$OUT"
echo "$OUT"
