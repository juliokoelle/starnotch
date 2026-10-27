# Roadmap

Goal: the notch tool nobody beats on the basics, with the agentic layer on top. Ship in small waves, each one usable on its own, so feedback and traction start now.

Principles: never overloaded. Calm, smooth and playful (the characters, the motion) beats a long feature list. A tool is off until the user switches it on; the notch shows only what matters now; Settings stay short (General, Tools, Agents, Privacy) with the rest one level down.

Sources: Joel's test session (26.10.), the competitor matrix (23.10.), Notchy (the broadest notch app, now paid), Pushary (agent approvals on the lock screen, adapters for every agent framework).

Legend: ✅ exists today · 🔧 exists, needs fixing · ⬜ missing

## Wave 1: before the YC deadline (2 November)

### Joel's findings

| | Item | Notes |
|---|---|---|
| ✅ | One-click Claude usage connection | Setup page: "Claude plan limits and context" installs the status line bridge, with backup and Remove. Onboarding should lead there |
| ✅ | First-run onboarding | Four skippable steps: Tara (character and colour), your agents (one-click setup), meetings and Tara's brain (Jamie, Claude subscription, API key or rules), tools |
| ✅ | Meeting Agent switch does nothing without setup | The agent ships in the app; keys and uv in Settings › Meeting agent |
| ✅ | Watch mode toggle | Switching off now holds while a video or fullscreen app keeps it on |
| ✅ | Calendar | Day before and after (arrows, ⌘← ⌘→, week strip), Today, open Calendar |
| ✅ | Quick capture plus button | Stays in narrow strips and right of the notch |
| ✅ | Notch on external monitors | Settings › Display: Notch, Main display or With pointer; a pill without a notch |
| ✅ | Permission prompts | Calendar, Reminders, Accessibility, Automation open their pane |
| ⬜ | Past sessions | List with resume (`claude --resume <id>` in the right folder) |

### Basics nobody may beat us on

| | Item | Notes |
|---|---|---|
| ✅ | Battery, keep awake, reminders source, now playing, calendar, quick capture | |
| ✅ | Clipboard history | Tools module: pin, Clear, skips concealed types and password apps; search next |
| ✅ | Pomodoro and timers | Tools module: 25/5, long break every fourth, time beside the notch |
| ⬜ | Device batteries | AirPods and Bluetooth devices |
| ✅ | File shelf | Tools module: drop in the panel, drag out, AirDrop; drop on the closed notch next |
| ✅ | Image converter | Shelf: PNG, JPEG, HEIC, TIFF next to the original |
| ✅ | Sound | Output device switch and volume (with music); per-app volume later |
| 🔧 | Reminders in the notch | Shown in Today; tick off and create from quick capture next |

### Shape

| | Item | Notes |
|---|---|---|
| ✅ | Pill mode | A floating island at the top center for displays without a notch (externals, Mac mini, iMac). The same pill is the design language of a later Windows build |

### Agentic layer

| | Item | Notes |
|---|---|---|
| ✅ | Claude Code sessions, approvals, subagents, usage | |
| ✅ | Meeting agent: contradictions, questions, commitments, prep, ask the memory | |
| ✅ | Starnotch MCP server | Tools `notify` and `confirm` (yes/no card); `ask` with options or free text next. One install makes every MCP client a Starnotch client: Claude Code, Codex, Cursor, Gemini CLI, VS Code, Claude Desktop and Cowork |
| ⬜ | `ask` in the local API | Blocking question with options, returns the answer; the MCP server and the SDKs build on it |
| ⬜ | Cloud sessions | Not on disk: the Claude app keeps no local list of cloud sessions (checked 26.10.: only `local_*.json`, ids and presets). Comes with the relay in Wave 2: a hook in the cloud environment reports to the relay, the notch shows the session with the star on a cloud |
| ✅ | Codex provider | Sessions, limits, approvals through its `PermissionRequest` hook |

### Distribution

| | Item | Notes |
|---|---|---|
| ✅ | Download build from CI | Every push builds the app as a downloadable artifact |
| ⬜ | Signed, notarized DMG with updates | Needs the Apple Developer account (99 USD a year) |
| ⬜ | Website | Waitlist, Founding Member pre-order (Stripe), no source links |

## Wave 2: November

- SDKs (Python, TypeScript) and adapters for agent frameworks: Claude Agent SDK, OpenAI Agents SDK, LangGraph, Mastra, Vercel AI SDK, CrewAI, n8n. Each one routes "the agent needs a human" to the notch.
- More coding agents: Cursor, Copilot CLI, Gemini CLI, opencode, Amp.
- Relay (Pro): end-to-end encrypted, opt-in. Carries approvals to the phone, and cloud sessions (claude.ai/code) into the notch.
- Daily briefing in the notch: calendar, open commitments, overdue captures, agent results overnight.
- Orchestrator: one agent that hands work to the others and reports in the notch.
- Command palette across all modules.
- Licensing: Free and Pro in the app, Stripe checkout, license key.

## Utilities: parity with Vorssaint and Notchy (Wave 2)

Feature level only: Vorssaint is GPL-3.0, so none of its code comes into Starnotch (rule since 22.10: no GPL code). Built ourselves:

- Per-app volume mixer (boost past 100 %, favourites), without an audio driver
- App switcher with window previews; Dock hover previews; quit an app when its last window closes
- Mouse and keyboard: natural scrolling per device, mouse button shortcuts, trackpad middle click
- Quick toggles: dark mode, hide desktop icons, keep awake, do not disturb, hidden files
- Permissions page: the status of every permission the app uses, with buttons to revoke or uninstall cleanly
- System: network up and down next to CPU, GPU and memory
- Music: synced lyrics and the play queue
- Agents: OpenCode and GitHub Copilot next to Claude Code and Codex, with plan limits, tokens and the API value of a session
- ✅ A Tools gallery in Settings and onboarding: each tool with one line and a switch, off by default except Agents, Calendar and Music; the notch shows only the ones switched on

## Console (later)

A page where the user sees everything in depth: each agent's work and conversation, agent-to-agent messages, what happened in the background (mails drafted, meetings prepared, tasks handed on), and where to step in. It grows out of the meeting agent's full-text page (agent/feed.py); local first, served by the app, later also through the relay. Settings stay the place for setup.

## Wave 3: after YC

- Windows build (pill at the top center; agents, approvals, meeting agent). The agent core, the protocol and the MCP server are already platform neutral.
- Android companion for approvals and the meeting agent.
- Team tier: shared meeting memory.
