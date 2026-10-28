#!/bin/bash
# Starnotch's hook for agent tools other than Claude Code and Codex (Cursor, Copilot CLI, Gemini CLI).
#
#   starnotch-hook.sh <tool> <event>          # status: forwards the event, prints nothing (Cursor's
#                                             # beforeSubmitPrompt gets {"continue":true})
#   starnotch-hook.sh <tool> <event> --ask    # a permission prompt: waits for the island's answer
#
# Forwards the hook's JSON (stdin) to the Starnotch island, adding the tool, the event, the agent's
# process and its terminal, so the island can show the session and jump to its tab. Status events
# go out in the background and never slow the tool down.
#
# With --ask it waits for a click in the island and prints the answer in the tool's own format.
# It never allows on its own: with no app, a stale socket, a timeout or any error it prints what
# makes the tool ask as usual (Cursor: {"permission":"ask"}; Copilot: nothing, which falls through
# to its own rules and prompt). A Copilot session started with --allow-all (or --yolo,
# --allow-all-tools) is left alone at once. Nothing is written to disk.
#
# The socket: $STARNOTCH_SOCKET if set, else ~/Library/Application Support/Starnotch/approvals.sock.
# Its folder must be yours with mode 0700 and the socket yours, so no other user can stand in.
umask 077
tool="${1:-}"
event="${2:-}"
ask="${3:-}"
case "$tool" in cursor|copilot|gemini) ;; *) exit 0 ;; esac
case "$event" in ''|*[!A-Za-z.]*) exit 0 ;; esac

# What the tool does without an answer from the island.
fallback() {
    if [ "$ask" = "--ask" ] && [ "$tool" = cursor ]; then printf '{"permission":"ask"}'; fi
    if [ "$ask" != "--ask" ] && [ "$tool" = cursor ] && [ "$event" = beforeSubmitPrompt ]; then printf '{"continue":true}'; fi
    exit 0
}

sock="${STARNOTCH_SOCKET:-}"
if [ -z "$sock" ]; then
    for name in Starnotch NotchSwitcher; do
        candidate="$HOME/Library/Application Support/$name/approvals.sock"
        if [ -S "$candidate" ]; then sock="$candidate"; break; fi
    done
fi
[ -n "$sock" ] && [ -S "$sock" ] || fallback
dir=$(dirname "$sock")
me=$(id -u)
[ "$(stat -f %u "$dir" 2>/dev/null)" = "$me" ] || fallback
[ "$(stat -f %Lp "$dir" 2>/dev/null)" = "700" ] || fallback
[ "$(stat -f %u "$sock" 2>/dev/null)" = "$me" ] || fallback

# One line of JSON (raw newlines are only whitespace between tokens; inside strings they are \n).
input=$(tr -d '\r\n')
input="${input#"${input%%[![:space:]]*}"}"
[ -n "$input" ] || input='{}'

# The agent: the hook's parent, or the parent of a plain `sh -c` in between.
pid=$PPID
case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
    sh|*/sh|bash|*/bash|zsh|*/zsh|dash|*/dash)
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        case "$parent" in ''|*[!0-9]*) ;; *) [ "$parent" -gt 1 ] && pid=$parent ;; esac ;;
esac
# Copilot asks this hook before its own rules: a session that allows everything needs no click.
if [ "$ask" = "--ask" ] && [ "$tool" = copilot ]; then
    case " $(ps -o args= -p "$pid" 2>/dev/null) " in
        *' --allow-all '*|*' --yolo '*|*' --allow-all-tools '*) fallback ;;
    esac
fi
tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
case "$tty" in ttys[0-9]*) tty="\"starnotch_tty\":\"/dev/$tty\"," ;; *) tty="" ;; esac
prefix="\"starnotch_provider\":\"$tool\",\"starnotch_event\":\"$event\",\"starnotch_pid\":$pid,$tty"
case "$input" in
    '{}') input="{${prefix%,}}" ;;
    '{'*) input="{$prefix${input#\{}" ;;
    *) fallback ;;
esac

if [ "$ask" != "--ask" ]; then
    # Status: in the background, so the tool goes on at once.
    ( printf '%s\n' "$input" | /usr/bin/nc -U -w 2 "$sock" >/dev/null 2>&1 ) >/dev/null 2>&1 &
    fallback
fi

# Keep our side of the socket open while waiting, with a newline every 0.2 s, so the island
# notices when the tool takes the answer itself and stops this hook.
reply=$( { printf '%s\n' "$input"; while sleep 0.2; do printf '\n' || exit 0; done; } 2>/dev/null \
    | /usr/bin/nc -U -w "${STARNOTCH_WAIT:-70}" "$sock" 2>/dev/null | head -c 65536 )

# Only a decision in this tool's format goes through; anything else means "ask as usual".
case "$tool:$reply" in
    cursor:'{'*'"permission":"allow"'*'}' | cursor:'{'*'"permission":"deny"'*'}' | \
    copilot:'{'*'"behavior":"allow"'*'}' | copilot:'{'*'"behavior":"deny"'*'}')
        case "$reply" in *$'\n'*) fallback ;; esac
        printf '%s' "$reply"
        exit 0 ;;
esac
fallback
