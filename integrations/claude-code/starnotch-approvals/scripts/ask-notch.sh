#!/bin/bash
# PermissionRequest hook: asks the Starnotch island, prints its decision.
#
#   ask-notch.sh          # Claude Code (the plugin's hooks.json)
#   ask-notch.sh codex    # Codex (~/.codex/hooks.json, see ../codex/install-hook.sh)
#
# Fails open to Claude Code's own prompt: with no app, a stale socket, a timeout or any error it
# prints nothing and exits 0, and Claude Code asks in the terminal as usual. It never allows on
# its own; only a click in the island produces "allow". Nothing is written to disk.
#
# The socket lives in the app's support folder: $STARNOTCH_SOCKET if set, else the first of
# ~/Library/Application Support/{Starnotch,NotchSwitcher}/approvals.sock. The folder must be a
# directory owned by you with mode 0700 and the socket owned by you, so no other user can stand in.
umask 077
sock="${STARNOTCH_SOCKET:-}"
if [ -z "$sock" ]; then
    for name in Starnotch NotchSwitcher; do
        candidate="$HOME/Library/Application Support/$name/approvals.sock"
        if [ -S "$candidate" ]; then sock="$candidate"; break; fi
    done
fi
# Fast path: no socket, no app.
[ -n "$sock" ] && [ -S "$sock" ] || exit 0
dir=$(dirname "$sock")
me=$(id -u)
[ "$(stat -f %u "$dir" 2>/dev/null)" = "$me" ] || exit 0
[ "$(stat -f %Lp "$dir" 2>/dev/null)" = "700" ] || exit 0
[ "$(stat -f %u "$sock" 2>/dev/null)" = "$me" ] || exit 0

# One line of JSON (raw newlines are only whitespace between tokens; inside strings they are \n).
input=$(tr -d '\r\n')
[ -n "$input" ] || exit 0
# Another tool than Claude Code: tell the island, so it answers in that tool's format.
provider="${1:-}"
if [ -n "$provider" ]; then
    case "$provider" in *[!a-z-]*) exit 0 ;; esac
    input="${input#"${input%%[![:space:]]*}"}"
    case "$input" in
        '{}') input="{\"starnotch_provider\":\"$provider\"}" ;;
        '{'*) input="{\"starnotch_provider\":\"$provider\",${input#\{}" ;;
        *) exit 0 ;;
    esac
fi

# Keep our side of the socket open while waiting, with a newline every 0.2 s, so the island
# notices when Claude Code takes the answer in the terminal and stops this hook. The writer
# stops on its own once nc has exited (its next write fails).
reply=$( { printf '%s\n' "$input"; while sleep 0.2; do printf '\n' || exit 0; done; } 2>/dev/null \
    | /usr/bin/nc -U -w "${STARNOTCH_WAIT:-70}" "$sock" 2>/dev/null | head -c 65536 )

# Only a decision for this event goes through; anything else means "ask in the terminal".
case "$reply" in
    '{"hookSpecificOutput":{"decision":{"behavior":"allow"'*'"hookEventName":"PermissionRequest"}}' | \
    '{"hookSpecificOutput":{"decision":{"behavior":"deny"'*'"hookEventName":"PermissionRequest"}}')
        printf '%s' "$reply" ;;
esac
exit 0
