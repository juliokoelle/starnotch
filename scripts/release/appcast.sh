#!/bin/bash
# Writes the Sparkle appcast for the disk images in a folder, signed with your EdDSA key.
#
#   SPARKLE_BIN=~/Downloads/Sparkle-2.x/bin scripts/release/appcast.sh build/releases
#
# SPARKLE_BIN is the bin folder of Sparkle's release download (generate_appcast, generate_keys).
# generate_appcast reads the private key from your Keychain (put there once by generate_keys,
# see RELEASING.md) or from a file given with SPARKLE_KEY_FILE (the CI). The key never goes
# into this repository.
set -euo pipefail
DIR="${1:?usage: appcast.sh folder-with-dmgs}"
: "${SPARKLE_BIN:?set SPARKLE_BIN to the bin folder of the Sparkle download}"
BASE="${DOWNLOAD_URL_PREFIX:-https://github.com/juliokoelle/starnotch/releases/download/latest/}"
ARGS=(--download-url-prefix "$BASE")
[[ -n "${SPARKLE_KEY_FILE:-}" ]] && ARGS+=(--ed-key-file "$SPARKLE_KEY_FILE")
"$SPARKLE_BIN/generate_appcast" "${ARGS[@]}" "$DIR"
echo "Appcast: $DIR/appcast.xml"
