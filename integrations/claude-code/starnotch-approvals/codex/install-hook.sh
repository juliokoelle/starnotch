#!/bin/bash
# Codex approvals in the notch: adds Starnotch's PermissionRequest hook to ~/.codex/hooks.json
# (the entry in hooks.json next to this script), or takes it out again with --remove.
#
#   ./install-hook.sh            # install (keeps a backup of hooks.json)
#   ./install-hook.sh --remove   # remove (keeps a backup too)
#
# Copies scripts/ask-notch.sh to ~/.codex/hooks/starnotch-ask-notch.sh, so the hook doesn't depend
# on where this folder lives. Other hooks in the file stay as they are. Codex runs new hooks only
# after you trust them: open /hooks in Codex once. Without the notch running, the hook prints
# nothing and Codex asks as usual.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
codex="${CODEX_HOME:-$HOME/.codex}"
hooks="$codex/hooks.json"
target="$codex/hooks/starnotch-ask-notch.sh"
mode="${1:-install}"

[ -d "$codex" ] || { echo "No Codex folder at $codex" >&2; exit 1; }
if [ -f "$hooks" ]; then
    backup="$hooks.bak-starnotch-$(date +%Y%m%d-%H%M%S)-$$"
    cp -p "$hooks" "$backup"
    echo "Backup: $backup"
fi
if [ "$mode" != "--remove" ]; then
    mkdir -p "$codex/hooks"
    install -m 0755 "$here/../scripts/ask-notch.sh" "$target"
fi

/usr/bin/python3 -I - "$hooks" "$target" "$mode" <<'PY'
import json, os, sys
path, target, mode = sys.argv[1], sys.argv[2], sys.argv[3]
data = {"hooks": {}}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f:
        data = json.load(f)
hooks = data.setdefault("hooks", {})
groups = [g for g in hooks.get("PermissionRequest", [])
          if not any("starnotch-ask-notch.sh" in h.get("command", "") for h in g.get("hooks", []))]
if mode != "--remove":
    groups.append({"hooks": [{"type": "command", "command": '"%s" codex' % target,
                              "timeout": 75, "statusMessage": "Asking in the notch"}]})
if groups:
    hooks["PermissionRequest"] = groups
else:
    hooks.pop("PermissionRequest", None)
with open(path + ".tmp", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
PY

if [ "$mode" = "--remove" ]; then
    rm -f "$target"
    echo "Removed the Starnotch hook from $hooks"
else
    echo "Added the Starnotch hook to $hooks. Open /hooks in Codex once to trust it."
fi
