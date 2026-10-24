#!/bin/bash
# Signs the app with your Developer ID (hardened runtime), notarizes it and staples the ticket.
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=starnotch-notary \
#   scripts/release/sign-and-notarize.sh build/Starnotch.app
#
# NOTARY_PROFILE names credentials stored once with `xcrun notarytool store-credentials`
# (see RELEASING.md); nothing secret lives in this repository.
set -euo pipefail
APP="${1:?usage: sign-and-notarize.sh path/to/App.app}"
: "${DEVELOPER_ID:?set DEVELOPER_ID to your 'Developer ID Application: …' identity}"
PROFILE="${NOTARY_PROFILE:-starnotch-notary}"
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
ENTITLEMENTS="${ENTITLEMENTS:-$HERE/Resources/Starnotch.entitlements}"
sign() { codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID" "$@"; }

# Inside out: Sparkle's helpers and framework first, then the app.
if [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
    for helper in "$SPARKLE/Versions/B/XPCServices/Installer.xpc" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
                  "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app"; do
        [[ -e "$helper" ]] && sign "$helper"
    done
    sign "$SPARKLE"
fi
# The hook scripts are resources; the executable gets the entitlements.
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

ZIP="$(mktemp -d)/$(basename "$APP" .app).zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
echo "Signed, notarized and stapled: $APP"
