# Plan limits and context in the notch

The notch shows your Claude plan's 5-hour and weekly limits and how full each session's context is, exactly as Claude Code reports them. Claude Code hands this to its **status line**; a small bridge script saves it for the notch. Nothing leaves your Mac, no Keychain, no network.

## Set up

The setup page does this for you (menu bar › Set up…, "Claude plan limits and context"), with a backup and a Remove button. By hand, it is one line:


Open `~/.claude/settings.json` and set `statusLine` to run the bridge. If you already have a status line, put your old command at the end, so it keeps working:

```json
"statusLine": {
  "type": "command",
  "command": "bash /path/to/starnotch/scripts/statusline-bridge.sh bash ~/.claude/statusline-command.sh",
  "refreshInterval": 60
}
```

Without an old status line, leave out everything after `statusline-bridge.sh`.

`refreshInterval` (seconds) keeps the numbers fresh while a session sits idle.

## What you see

- Header: `5 h 62 % · 2 h 14 m left`, the week in the tooltip (`48 % · resets Tue`).
- Each session: a ring with `ctx 43 %`, amber from 70 %, red from 90 %.

Plan limits appear for Pro and Max plans after the first answer in a session. The files live in `status/` inside the app's folder in `~/Library/Application Support/`, one per session, readable only by you.
