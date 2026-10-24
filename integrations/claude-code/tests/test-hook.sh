#!/bin/bash
# Tests the hook script's fail-open paths and the pass-through of a decision, with fake sockets.
#   integrations/claude-code/tests/test-hook.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
hook="$here/../starnotch-approvals/scripts/ask-notch.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/sn-hook.XXXXXX")
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT
input='{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}'
allow='{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}'
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fails=$((fails+1)); fi; }

# A fake island: answers every connection with $1 (or never, with "hang"), in the background.
serve() {
    rm -f "$work/approvals.sock"
    python3 -I - "$work/approvals.sock" "$1" <<'PY' &
import os, socket, sys, time
path, answer = sys.argv[1], sys.argv[2]
try: os.unlink(path)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX); s.bind(path); os.chmod(path, 0o600); s.listen(1)
c, _ = s.accept(); got = c.recv(65536)
open(path + ".got", "wb").write(got)
if answer == "hang": time.sleep(5)
else: c.sendall(answer.encode())
c.close(); s.close(); os.unlink(path)
PY
    server=$!
    for _ in $(seq 50); do [ -S "$work/approvals.sock" ] && break; sleep 0.05; done
}

# 1. No socket at all: nothing, fast.
out=$(printf '%s' "$input" | STARNOTCH_SOCKET="$work/none.sock" "$hook"; echo "exit=$?")
ms=$( { /usr/bin/time -p bash -c "printf '%s' '$input' | STARNOTCH_SOCKET='$work/none.sock' '$hook'" ; } 2>&1 | awk '/^real/ {print int($2*1000)}')
check "no app: empty output, exit 0" "$out" "exit=0"
[ "$ms" -lt 50 ] && echo "ok   no app: ${ms} ms" || { echo "FAIL no app took ${ms} ms"; fails=$((fails+1)); }

# 2. A stale socket file (app gone): connection refused, nothing.
python3 -I -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$work/approvals.sock"
out=$(printf '%s' "$input" | STARNOTCH_SOCKET="$work/approvals.sock" "$hook")
check "stale socket: empty" "$out" ""
rm -f "$work/approvals.sock"

# 3. A decision passes through unchanged.
serve "$allow"
out=$(printf '%s' "$input" | STARNOTCH_SOCKET="$work/approvals.sock" "$hook")
check "allow passes through" "$out" "$allow"
wait $server 2>/dev/null

# 4. A malformed or foreign reply is dropped.
serve '{"hookSpecificOutput":{"decision":{"behavior":"allow"}}} trailing'
out=$(printf '%s' "$input" | STARNOTCH_SOCKET="$work/approvals.sock" "$hook")
check "malformed reply: empty" "$out" ""
wait $server 2>/dev/null

# 5. No answer in time: nothing (the island timed out or hangs).
serve hang
out=$(printf '%s' "$input" | STARNOTCH_SOCKET="$work/approvals.sock" STARNOTCH_WAIT=1 "$hook")
check "timeout: empty" "$out" ""
kill $server 2>/dev/null; wait $server 2>/dev/null

# 6. A folder others can read: refused before connecting.
serve "$allow"
chmod 755 "$work"
out=$(printf '%s' "$input" | STARNOTCH_SOCKET="$work/approvals.sock" "$hook")
check "open folder: empty" "$out" ""
chmod 700 "$work"
kill $server 2>/dev/null; wait $server 2>/dev/null

# 7. Codex: the request names its tool, and Codex's allow passes through.
serve "$allow"
out=$(printf '%s' "$input" | STARNOTCH_SOCKET="$work/approvals.sock" "$hook" codex)
check "codex allow passes through" "$out" "$allow"
wait $server 2>/dev/null
case "$(cat "$work/approvals.sock.got" 2>/dev/null)" in
    '{"starnotch_provider":"codex","session_id":"s"'*) echo "ok   codex request tagged" ;;
    *) echo "FAIL codex request not tagged: $(cat "$work/approvals.sock.got" 2>/dev/null)"; fails=$((fails+1)) ;;
esac

# 8. A provider name with odd characters: nothing sent.
out=$(printf '%s' "$input" | STARNOTCH_SOCKET="$work/approvals.sock" "$hook" 'co dex')
check "odd provider: empty" "$out" ""

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
