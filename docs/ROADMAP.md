# Roadmap

Goal: the notch tool nobody beats on the basics, with the agentic layer on top. Ship in small waves, each one usable on its own, so feedback and traction start now.

Sources: Joel's test session (26.10.), the competitor matrix (23.10.), Notchy (the broadest notch app, now paid), Pushary (agent approvals on the lock screen, adapters for every agent framework).

Legend: ✅ exists today · 🔧 exists, needs fixing · ⬜ missing

## Wave 1: before the YC deadline (2 November)

### Joel's findings

| | Item | Notes |
|---|---|---|
| ⬜ | One-click Claude usage connection | No hand-edited status line; the app installs and removes the bridge itself after one confirmation |
| ⬜ | First-run onboarding | Pick an avatar, connect Claude, set up the Meeting Agent (key, folder) in one flow |
| 🔧 | Meeting Agent switch does nothing without setup | Opens the setup instead of failing silently |
| 🔧 | Watch mode toggle | Doesn't switch |
| 🔧 | Calendar | Move between days, a full-day view |
| 🔧 | Quick capture plus button | Lost in the compact view |
| ⬜ | Notch on external monitors | Floating pill on screens without a notch (see Shape) |
| ⬜ | Permission prompts | Open the exact System Settings pane |
| ⬜ | Past sessions | List with resume (`claude --resume <id>` in the right folder) |

### Basics nobody may beat us on

| | Item | Notes |
|---|---|---|
| ✅ | Battery, keep awake, reminders source, now playing, calendar, quick capture | |
| ⬜ | Clipboard history | Search, pin, skips concealed and transient types (passwords) |
| ⬜ | Pomodoro and timers | Focus chain, streak, end as a sneak |
| ⬜ | Device batteries | AirPods and Bluetooth devices |
| ⬜ | File shelf | Drag into the notch, drag back out, AirDrop |
| ⬜ | Image converter | Drop an image, get PNG, JPEG, HEIC or WebP back (ImageIO) |
| ⬜ | Sound | Output device switch, volume; per-app volume later |
| ⬜ | Reminders in the notch | Tick off, create from quick capture |

### Shape

| | Item | Notes |
|---|---|---|
| ⬜ | Pill mode | A floating island at the top center for displays without a notch (externals, Mac mini, iMac). The same pill is the design language of a later Windows build |

### Agentic layer

| | Item | Notes |
|---|---|---|
| ✅ | Claude Code sessions, approvals, subagents, usage | |
| ✅ | Meeting agent: contradictions, questions, commitments, prep, ask the memory | |
| ⬜ | Starnotch MCP server | Tools `notify`, `ask` (options or free text) and `approve`, answered in the notch. One install makes every MCP client a Starnotch client: Claude Code, Codex, Cursor, Gemini CLI, VS Code, Claude Desktop and Cowork |
| ⬜ | `ask` in the local API | Blocking question with options, returns the answer; the MCP server and the SDKs build on it |
| ⬜ | Codex provider | Sessions, limits, approvals through its `PermissionRequest` hook |

### Distribution

| | Item | Notes |
|---|---|---|
| ⬜ | Download build from CI | Every push builds the app as a downloadable artifact |
| ⬜ | Signed, notarized DMG with updates | Needs the Apple Developer account (99 USD a year) |
| ⬜ | Website | Waitlist, Founding Member pre-order (Stripe), no source links |

## Wave 2: November

- SDKs (Python, TypeScript) and adapters for agent frameworks: Claude Agent SDK, OpenAI Agents SDK, LangGraph, Mastra, Vercel AI SDK, CrewAI, n8n. Each one routes "the agent needs a human" to the notch.
- More coding agents: Cursor, Copilot CLI, Gemini CLI, opencode, Amp.
- Approvals on the phone (Pro): a relay with end-to-end encryption, opt-in, so a question reaches you away from the Mac.
- Daily briefing in the notch: calendar, open commitments, overdue captures, agent results overnight.
- Orchestrator: one agent that hands work to the others and reports in the notch.
- Command palette across all modules.
- Licensing: Free and Pro in the app, Stripe checkout, license key.

## Wave 3: after YC

- Windows build (pill at the top center; agents, approvals, meeting agent). The agent core, the protocol and the MCP server are already platform neutral.
- Android companion for approvals and the meeting agent.
- Team tier: shared meeting memory.
