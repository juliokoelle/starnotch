#!/bin/bash
# Builds the app with SwiftPM only (no Xcode needed) and signs it ad hoc.
#
#   ./scripts/build-app.sh          # -> build/<Name>.app
#   ./scripts/build-app.sh --zip    # also build/<Name>-<version>.zip for a release
#
# The name comes from Sources/NotchCore/Brand.swift. A private build (one that links its own
# connectors from another package) sets these instead:
#   NOTCH_PACKAGE      package to build (default: this repo)
#   NOTCH_PRODUCT      executable product (default: the app name)
#   APP_NAME           bundle name; EXECUTABLE, BUNDLE_ID, SUPPORT_FOLDER, URL_SCHEME
#   NOTCH_EXTRA_PACKS  colon-separated .notchpack folders to bundle besides the default pack
#   NOTCH_OUT          output folder (default: build/ in this repo)
#   VERSION            marketing version (default below)
# Release builds (see RELEASING.md) also set:
#   STARNOTCH_SPARKLE=1     link Sparkle 2 for updates (the package then fetches it)
#   SPARKLE_FEED_URL        appcast URL;  SPARKLE_PUBLIC_KEY  EdDSA public key (base64)
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

BRAND="$(sed -n 's/^ *public static let name = "\(.*\)"$/\1/p' Sources/NotchCore/Brand.swift)"
LOWER="$(echo "$BRAND" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
PACKAGE="${NOTCH_PACKAGE:-$REPO}"
PRODUCT="${NOTCH_PRODUCT:-$BRAND}"
APP_NAME="${APP_NAME:-$BRAND}"
EXECUTABLE="${EXECUTABLE:-$PRODUCT}"
BUNDLE_ID="${BUNDLE_ID:-app.$LOWER.mac}"
SUPPORT_FOLDER="${SUPPORT_FOLDER:-$BRAND}"
URL_SCHEME="${URL_SCHEME:-$LOWER}"
OUT="${NOTCH_OUT:-$REPO/build}"
COPYRIGHT="${COPYRIGHT:-Apache License 2.0}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo 1)"

swift build --package-path "$PACKAGE" -c release --product "$PRODUCT"
BIN_DIR="$(swift build --package-path "$PACKAGE" -c release --show-bin-path)"

APP="$OUT/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Characters"
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$EXECUTABLE"
# Sparkle (release builds only): the framework next to the app, found through the rpath.
if [[ -d "$BIN_DIR/Sparkle.framework" ]]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$EXECUTABLE" 2>/dev/null || true
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Character packs: the public ones (Astra, Cat, Pebbles), plus any the build adds.
cp -R Resources/Characters/*.notchpack "$APP/Contents/Resources/Characters/"
if [[ -n "${NOTCH_EXTRA_PACKS:-}" ]]; then
    IFS=':' read -r -a EXTRA <<< "$NOTCH_EXTRA_PACKS"
    for pack in "${EXTRA[@]}"; do
        cp -R "$pack" "$APP/Contents/Resources/Characters/"
    done
fi
# Interface strings (English and German).
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
cp docs/usage-setup.md "$APP/Contents/Resources/usage-setup.md"
# Approval hooks (Claude Code plugin, Codex hook and its installer), for Settings › Providers.
# The setup page installs from these copies when GitHub isn't reachable.
mkdir -p "$APP/Contents/Resources/integrations"
cp -R integrations/claude-code "$APP/Contents/Resources/integrations/"
cp scripts/statusline-bridge.sh "$APP/Contents/Resources/statusline-bridge.sh"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NotchSupportFolder</key><string>$SUPPORT_FOLDER</string>
    <key>NotchURLScheme</key><string>$URL_SCHEME</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>$APP_NAME status</string>
            <key>CFBundleURLSchemes</key><array><string>$URL_SCHEME</string></array>
        </dict>
    </array>
    <key>NSAppleEventsUsageDescription</key><string>Shows what Spotify or Music is playing in the notch and lets you pause or skip, and brings an agent's own Terminal or iTerm2 tab to the front when you click it.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>Shows your next meeting in the notch with a countdown and a Join button.</string>
    <key>NSCalendarsWriteOnlyAccessUsageDescription</key><string>Adds the event you type in quick capture to your calendar.</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>Shows your reminders due today in Today, when you switch this on.</string>
    <key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
$( [[ -n "${SPARKLE_FEED_URL:-}" ]] && printf '    <key>SUFeedURL</key><string>%s</string>\n' "$SPARKLE_FEED_URL" )
$( [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]] && printf '    <key>SUPublicEDKey</key><string>%s</string>\n' "$SPARKLE_PUBLIC_KEY" )
</dict>
</plist>
PLIST

# Ad-hoc signature: runs locally; Gatekeeper still warns on other Macs (not notarized).
# The designated requirement names the bundle id instead of this build's hash, so macOS privacy
# grants (calendar, automation) recorded against it survive rebuilds.
codesign --force --sign - --timestamp=none -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
codesign --verify --verbose=1 "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--zip" ]]; then
    ZIP="$OUT/$LOWER-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Packed $ZIP"
fi
