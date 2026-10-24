#!/bin/bash
# Posts a status line to Starnotch (its local API on 127.0.0.1).
#
#   scripts/notch-status.sh "Digest fertig" ["5 Quellen"] [ok|waiting|critical|accent|neutral] [key]
#
# The token is read from the app's support folder ($NOTCH_SUPPORT_DIR, else
# ~/Library/Application Support/<App>) and handed to
# curl on stdin, so it never shows up in the process list. Nothing is printed on success.
set -euo pipefail

SUPPORT="${NOTCH_SUPPORT_DIR:-}"
if [[ -z "$SUPPORT" ]]; then
    BASE="$HOME/Library/Application Support"
    BRAND=$(sed -n 's/^ *public static let name = "\(.*\)"$/\1/p' "$(dirname "$0")/../Sources/NotchCore/Brand.swift" 2>/dev/null)
    SUPPORT="$BASE/${BRAND:-Starnotch}"
    # Builds from before the rename keep their folder.
    [[ -d "$BASE/NotchSwitcher" ]] && SUPPORT="$BASE/NotchSwitcher"
fi
TOKEN_FILE="$SUPPORT/api-token"
PORT="${NOTCH_PORT:-47789}"

if [[ $# -lt 1 || -z "$1" ]]; then
    echo "usage: $(basename "$0") TITLE [DETAIL] [TINT] [KEY]" >&2
    exit 2
fi
if [[ ! -r "$TOKEN_FILE" ]]; then
    echo "No token yet: start the app once (and switch 'Local status API' on)." >&2
    exit 1
fi

# JSON string escaping for backslash, quote and control characters.
json() {
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/ }
    s=${s//$'\r'/ }
    s=${s//$'\t'/ }
    printf '"%s"' "$s"
}

body="{\"title\":$(json "$1")"
[[ -n "${2:-}" ]] && body+=",\"detail\":$(json "$2")"
[[ -n "${3:-}" ]] && body+=",\"tint\":$(json "$3")"
[[ -n "${4:-}" ]] && body+=",\"key\":$(json "$4")"
body+="}"

token=$(<"$TOKEN_FILE")
curl --silent --show-error --fail --max-time 3 --output /dev/null --config - <<CONFIG
url = "http://127.0.0.1:$PORT/status"
request = "POST"
header = "Content-Type: application/json"
header = "Authorization: Bearer $token"
data-binary = "$(printf '%s' "$body" | sed 's/\\/\\\\/g; s/"/\\"/g')"
CONFIG
