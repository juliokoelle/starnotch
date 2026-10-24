#!/bin/bash
# Claude Code status line bridge for Starnotch.
#
# Claude Code pipes a JSON with the session's context window and, on Pro/Max plans, the
# official 5-hour and weekly limits into the status line command. This script saves that JSON
# per session for the notch (atomically, readable only by you) and then hands the same input
# to your previous status line command, so that line looks exactly as before.
#
#   statusLine.command = "bash /path/to/statusline-bridge.sh [your previous command ...]"
#
# The files go to the app's support folder: $NOTCH_SUPPORT_DIR if set, else the folder named
# after the app (Sources/NotchCore/Brand.swift). Nothing leaves the Mac; no network, no Keychain.
input=$(cat)

support="${NOTCH_SUPPORT_DIR:-}"
if [ -z "$support" ]; then
    base="$HOME/Library/Application Support"
    brand=$(sed -n 's/^ *public static let name = "\(.*\)"$/\1/p' "$(dirname "$0")/../Sources/NotchCore/Brand.swift" 2>/dev/null)
    support="$base/${brand:-Starnotch}"
    # Builds from before the rename keep their folder.
    [ -d "$base/NotchSwitcher" ] && support="$base/NotchSwitcher"
fi
dir="$support/status"
id=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]\{1,80\}\)".*/\1/p' | head -n 1)
if [ -n "$id" ]; then
    mkdir -p "$dir" && chmod 700 "$dir"
    tmp=$(mktemp "$dir/.$id.XXXXXX") && {
        printf '%s' "$input" > "$tmp"
        chmod 600 "$tmp"
        mv -f "$tmp" "$dir/$id.json"
    }
fi

if [ "$#" -gt 0 ]; then
    printf '%s' "$input" | "$@"
else
    # No previous command: a short line of our own.
    model=$(printf '%s' "$input" | sed -n 's/.*"display_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    printf '%s' "${model:-Claude}"
fi
