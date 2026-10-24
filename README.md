# Starnotch

**Your notch, the control strip for your agents.**

Meet Tara, a little star that lives in your MacBook's notch. Starnotch turns the notch into a small island. It shows what your coding agents are doing, your next meeting, what's playing, and anything a connector adds. Hover to peek, click to open, ⌃⌥Space from the keyboard, swipe on the notch to switch.

<p align="center">
  <img src="docs/screenshots/agents.png" width="680" alt="Tara in the Starnotch agents panel: the session at max effort glows in Sol, the others in their effort colours, plan usage in the header">
</p>

## What it shows

| Module | What you see | Needs |
|---|---|---|
| **Agents** | Your Claude Code sessions as small characters: working, waiting for you, idle. Last steps, subagents, context window per session, plan limits in the header, recurring loops. | Claude Code |
| **Calendar** | Your day on a time band, the next meeting with a countdown and Join (Meet, Zoom, Teams), a reminder five minutes before. | Calendar access (asked when you first open it) |
| **Now playing** | Cover, controls, volume and output device for Spotify or Music. | Spotify or Music |
| **Dictate** | Starts Wispr Flow hands-free from the notch. | Wispr Flow |
| **Today** | Tasks, follow-ups and a short brief from a connector. | A connector |
| **Quick capture** | ⌃⌥N: one line out of the notch, dates and people recognised as you type (English and German). | Nothing |

Modules whose source isn't on your Mac hide themselves. You can switch any module off in Settings.

<p align="center">
  <img src="docs/screenshots/calendar.png" width="420" alt="Starnotch calendar: the day band and the next meeting with Join">
  <img src="docs/screenshots/today.png" width="420" alt="Starnotch Today: up next, the list, follow-ups and a brief">
</p>
<p align="center">
  <img src="docs/screenshots/music.png" width="560" alt="Starnotch now playing with output devices">
</p>

On a display without a notch, the island is a small pill at the top center. Settings choose the display: the one with the notch, the main display, or the one with the pointer.

## Install

There are no signed releases yet. Build it yourself (a minute, no Xcode needed):

```sh
git clone https://github.com/juliokoelle/starnotch.git
cd starnotch
./scripts/build-app.sh          # -> build/Starnotch.app (signed ad hoc)
open build/Starnotch.app
```

Requires macOS 14 Sonoma or later and the Swift 6 toolchain (Xcode or just the Command Line Tools).

The first launch shows what Starnotch can show on this Mac and asks for nothing until you click.

<p align="center"><img src="docs/screenshots/onboarding.png" width="360" alt="Starnotch first launch: modules and permissions"></p>

## Set up in one click

On first launch a setup page lists what it found (Claude Code, Codex, calendars, Spotify or Music, Wispr Flow) and exactly what it would set up: the Claude Code approvals plugin, the Codex approvals hook, the plan-limits status line (your current status line keeps running behind it), a small zsh snippet for long terminal commands, open at login, and the calendar and player permissions. One button sets up everything, or switch items off first. Nothing happens before that click; each change keeps a backup, and Settings › What's set up removes it again exactly. The one step left to you: trust the new hook once in Codex with `/hooks`. The menu bar's "Set up…" opens the page again.

## Permissions

| What | Needed for | Without it |
|---|---|---|
| none | The island, hover, click, swipes, ⌃⌥Space, quick capture | — |
| Calendars | The calendar module | The module hides |
| Automation (Spotify, Music) | Now playing, asked the first time music plays | The module stays quiet |
| Accessibility (optional) | Escape cancels the wheel while you hold the notch over other apps | Release in the center to cancel |

## Privacy

Everything stays on your Mac. There is no telemetry and no account. The app reads Claude Code's and Codex's local session files read-only and never touches the Keychain. Connectors you add decide what they talk to.

## Plan limits and context

Claude Code hands your plan's 5-hour and weekly limits and each session's context window to its status line. A one-line bridge saves them for Starnotch: see [docs/usage-setup.md](docs/usage-setup.md).

## Approve from the notch

Claude Code's permission prompts ("Allow Bash: npm run build?") can show up in the island, so you answer without switching to the terminal: **Allow once** (↵), **Allow for session** (⌘↵, kept in memory until the session ends) or **Deny** (esc). The session's character waits next to the request.

It is a small Claude Code plugin in this repository. Install it once, from your shell:

```sh
claude plugin marketplace add /path/to/starnotch/integrations/claude-code
claude plugin install starnotch-approvals@starnotch
```

Restart running Claude Code sessions afterwards. To remove it:

```sh
claude plugin uninstall starnotch-approvals@starnotch
claude plugin marketplace remove starnotch
```

How it behaves:

- It never allows anything on its own. Only a click (or ↵ / ⌘↵) in the island allows.
- If Starnotch isn't running, or nobody answers within 60 seconds, the hook prints nothing and Claude Code asks in the terminal as usual. Answering in the terminal instead closes the card.
- The hook talks to the app over a Unix socket in `~/Library/Application Support/Starnotch/` (folder 0700, socket 0600); the app only serves processes of your own user. Nothing is logged or sent anywhere.
- "Allow for session" uses Claude Code's own suggestion for the rule where it has one (with `destination: session`); otherwise it allows exactly that Bash command, or that tool, for the session.

### Codex

Codex sessions (CLI, desktop app, IDE extension) show up next to Claude Code's without setup: the app reads `~/.codex` read-only (the thread list and each session's log). Sessions of one project share its character; a small badge (C, Cx) tells the tools apart, and the panel header shows both tools' plan limits, the one closest to its limit first. Settings › Providers switches each tool off.

Codex's permission prompts can come to the island too. The same hook script serves Codex; this adds it to `~/.codex/hooks.json` (with a backup) and removes it again:

```sh
integrations/claude-code/starnotch-approvals/codex/install-hook.sh
integrations/claude-code/starnotch-approvals/codex/install-hook.sh --remove
```

Then open `/hooks` in Codex once to trust the new hook. Codex can't take a rule for the whole session, so its card offers **Allow once** and **Deny** only.

## Configuration

`~/Library/Application Support/Starnotch/config.toml` is written on first launch with every option commented out: Claude Code's folder, which launchd jobs to show, the home project's character, the local API port, a Markdown file for quick capture, the interface language, and the connectors to run.

## Extend it

- **Connectors** bring your own data: a Today list, loops, people for meeting prep, a quick capture inbox. A connector is a small Swift package; see [docs/SDK.md](docs/SDK.md).
- **Character packs** add characters: a folder with a `manifest.json` and one PNG per state, optionally a look per effort level. Starnotch ships Tara, the Cat (its eyes show the effort) and Pebbles. See [docs/CHARACTER_PACKS.md](docs/CHARACTER_PACKS.md).
- **Local status API**: scripts post a line to the notch over `127.0.0.1` with a token, or with a `starnotch://status?title=…` link. See [docs/SDK.md](docs/SDK.md#local-status-api).

## Release

`RELEASING.md` has the steps for a signed, notarized release with a DMG, Sparkle updates and a Homebrew cask.

## Develop

```sh
./scripts/test.sh                          # unit tests (Swift Testing)
open build/Starnotch.app --args --sample-data  # test mode: made-up agents, day, music; asks for nothing
open build/Starnotch.app --args --preview usage --capturable   # fixed states for screenshots
```

```
Sources/NotchCore    pure logic, unit tested: geometry, parsers, config, the connector API
Sources/NotchKit     the app: island, modules, wheel, settings, onboarding
Sources/Starnotch    the app's executable (no connectors)
Resources/           app icon, the Pebbles character pack, interface strings (en, de)
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[Apache License 2.0](LICENSE), including the three character packs: Tara (the default), the Cat and Pebbles (drawn by `scripts/make-pebbles.swift`).
