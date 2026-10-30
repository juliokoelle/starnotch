# Changelog

What changed in Starnotch, newest first: one section per day an update landed, grouped by theme. Each feature keeps the name the app uses. Smaller fixes are in the commit history.

## 30 October 2026

### Tara
- **New:** Tara's eyes follow the pointer. While it moves she is awake with her eyes open, glances around now and then when it rests, and dozes off again a while after it stops. A click in the notch or on her and her eyes laugh (^ ^). She blinks twice now and then, and her eyes move softly, a little behind the pointer. Settings › Notch › Tara's eyes: her own lines, or round eyes with pupils. The eyes move only when the pointer does; with Reduce Motion they stay still.

### Notch
- **New:** Settings › Notch: Tara beside the notch (Always, When something's up, Never), Open on hover (Click only, 0.5 s, 1 s; a click always opens it) and Open on the last tab, so the notch comes back where you left it, on music for example. The last tab is on by default.

### Ask Tara
- **New:** Tara beside the shelf: drag a file onto the notch and drop it on Tara instead of the shelf. Ask opens her bubble with it (a PDF, Word or text file goes as its text, a picture as a copy); Remember keeps its text as a Markdown note in Documents › Starnotch › Documents, which Tara searches with every question, like the rest of that folder. The file itself is only read, never moved or copied elsewhere.
- **Improved:** A file dropped on Tara herself or on her bubble goes along as the file (it used to land in the field as its path); a file a browser only promises, such as a Gmail attachment dragged out of Chrome, is taken too. She hops and looks pleased when she takes one, and stays on screen when her bubble opens.
- **New:** Earlier chats: the clock in Ask Tara's field lists your last chats with when and how many questions; a click carries on with one, with what was said, and the cross forgets it. Kept on this Mac only (`ask-chats.json`), at most 50.
- **Improved:** A follow-up keeps the questions before it above the answer, a scroll up away. The card is see-through glass now instead of near black.

### Quick capture
- **Improved:** The confirmation says where a capture went and takes you there: Notepad opens Tools › Notepad › Tara's notes, the file button opens the Markdown inbox. The note flies into the Notepad button. The confirmation stays while the pointer is on it.
- **Changed:** Without a vault inbox, captures go to `Inbox.md` in a visible folder, Documents › Starnotch, as plain Markdown any notes app or AI can read; a README there says what the folder holds. The lines of the old inbox in the app's folder come along (copied).
- **Improved:** Tab and ⇧Tab switch between Task, Question and Note, the arrow keys too while the field is empty. The cursor stays in the field after switching, and a click anywhere on the field puts it there.
- **Fixed:** Every capture after the first stayed out of the Markdown inbox ("kept on this Mac"): the file was opened for writing only, so checking its last line failed.
- **Fixed:** A click in quick capture that slid down a little pulled Tara out of the notch and closed it.

## 29 October 2026


### Notch
- **Improved:** Hovering the resting notch shows Tara alone, to grab and pull out, with one line only while something waits for you. The System tab's numbers no longer take the hover because it was the tab open last or memory is merely tight; only what matters now (camera or microphone in use, full memory, a battery about to run out, the lid state, a running timer, a meeting about to start) takes Tara's place.
- **Changed:** No more amber in the notch: what waits for you (your turn, a loop to check, the inbox count) is in Tara's colour, a high value is said with brighter text, and only a critical state is red.
- **Improved:** Plan limits in the Agents header: one quiet chip per tool ("66 %" over "Claude"), the same with one tool, two, or one that has been closed for a while (dimmed, last seen in the popover). A click shows each tool's 5-hour window and week with the share used, a bar, when it resets and, when it runs out first, at what time, dark and readable.
- **Improved:** Tara is one figure on the notch: whole beside it at rest, never cut off by the notch's edge, and on hover she grows where she stands or moves down beside the line of what waits, without a second Tara crossing over her. With nothing waiting the hover adds no empty black band below the notch; with something waiting the band is only as tall as Tara and her line.
- **New:** Today and Calendar are one switch at the left of the calendar's header, Today first: the calendar tab opens on it, unless a meeting starts within the quarter hour. Today has the day's to-dos (tasks from your notes and Apple Reminders due today or overdue, ticked off in place), the weather by the hour, the work day and last night. Reminders are offered there and macOS asks for access only on that click; without a place or a wearable, one line and one button say what to do.
- **Improved:** The clipboard lists text, web addresses led by their domain and copied images with a preview, with the app and the time; it opens the large panel, searches once the list is long, keeps images to 150 MB together (pinned ones included), and still lives in memory only and skips password apps.
- **Improved:** The System tab's switches keep their words ("Keep awake", "Pause Tara" with Tara asleep, "Dark mode", "Hide icons"); a long command and the battery's detail give way first. Top apps opens Activity Monitor from its title.
- **Improved:** A paused or running timer stays readable beside the notch ("12m" instead of a cut-off "12:35") and in the hover line, where the time comes first.
- **Improved:** A tab's tooltip says that tabs can be moved: hold, then drag.
- **Improved:** Today's cards shrink with a narrower island instead of running past its edges, and last night shows its main score alone where both don't fit. The timer's kinds and presets no longer shorten to "…".
- **Improved:** The notepad opens as large as the clipboard, so switching between them doesn't resize the island. The Tools tab's own tabs (Clipboard, Timer, Shelf, Notepad) can be moved like the main tabs: hold, then drag; the order is kept.
- **New:** The Today tab shows the morning briefing from today's note in full, as a note reads (headings, lists, tasks, links), scrolling in its card: the section whose heading names a brief, or the note it links to. Its title opens it in Obsidian; links in it open their notes. Without a briefing yet, one calm line. With the notes vault off in Tara's memory, Today reads nothing from your notes (no tasks, no daily note, no briefing) and says so.
- **Improved:** Weather where you are: Today's weather card and Settings › Daily have Use my location. macOS asks on that click, with Starnotch in front; after a no it opens System Settings at Location Services, and the weather comes by itself once you turn Starnotch on there. Set a city stays beside it.
- **Fixed:** Accessibility no longer brings up macOS's prompt again and again. It asks once, on your click; when macOS stopped recognising an updated Starnotch although its switch shows on, Settings says to switch it off and on again and opens the right pane.

### Characters
- **Changed:** Tara and the Cat are no longer under the Apache License: they are all rights reserved and come only with Starnotch. The code and Pebbles stay Apache 2.0, and earlier versions keep the license they came with. Starnotch, Tara and the characters are trademarks; see TRADEMARKS.md.

## 28 October 2026

### Tara's memory and privacy
- **New:** Settings › Tara's memory. Pause her memory for an hour, until midnight or until you resume. The System tab has a switch for it, and while she is paused a mark beside the tabs says so and resumes her on a click.
- **New:** A switch per source: meetings and calendar, quick captures, notes vault, clipboard, agent sessions. A source that is off records nothing new and is left out of Ask Tara and your AI apps.
- **New:** Delete what Tara remembers from one source, after a confirmation. Only Starnotch's copy goes; your vault, Jamie and your calendar keep theirs.
- **New:** Apps Tara never records: password apps always, and any app you add.
- **New:** Tara's memory in your AI apps. Claude Desktop, Claude Code, Cursor and ChatGPT's Mac app can search your meetings, captures and notes, read only, from this Mac. What an app looks up goes to its AI provider with your chat. Each app is off until you choose it, in the setup or in Settings › Tara's memory.

### Ask Tara
- **New:** Ask Tara: press ⌃⌥T or click on Tara, then type or speak a question. She answers from your meetings, quick captures and notes, with sources you can open, and follow-ups keep the thread.
- **New:** Tara can think with Apple Intelligence on this Mac, for free, when no Claude is available. Answers are simpler than with Claude.
- **New:** The mic dictates with Wispr Flow when it is installed and falls back to Apple's speech recognition.
- **New:** The answer card: the answer in large type, compact sources that unfold on a click, Copy, and Save to notes (into your notes inbox, or the Notepad without a vault).
- **New:** Cut, copy, paste and undo work in every text field.

### Meetings and Tara's brain
- **New:** Jamie syncs by itself while you are connected: after launch, every 30 minutes, after waking and after a meeting ends. New meetings reach Tara at once.
- **New:** Tara's usage in Settings › Meeting agent: calls, tokens and the cost at API prices for today and the last 7 days.
- **Improved:** The meeting agent keeps everything that was said, and Save writes the meeting before the last analysis.

### Setup
- **Improved:** Onboarding is one calm card per step: Tara, your agents, calendar, music, meetings, how Tara thinks, notes, Tara's memory in your AI apps, tools. Each says why it asks and where the data stays, shows a check once it is done, and optional steps offer "Skip for now". Nothing changes without your click.
- **New:** Tara's welcome: after the first setup she drops out of the notch, greets you, shows what she already found on this Mac and opens the notch on your agents.
- **Improved:** The approvals plugin for Claude Code repairs its own registration at launch.

### Agents
- **New:** Command palette on ⌃⌥K: searches tabs, sessions, loops, today's events, tools and settings; what you pick often comes first.
- **New:** Agents inbox on ⌃⌥A: permission prompts, questions, finished turns and failed loops, one card at a time, with a count beside the notch.
- **New:** Cursor, Copilot CLI, Gemini CLI and opencode sessions show next to Claude Code and Codex. Answering Cursor, Copilot CLI and opencode in the notch is a choice of its own in the setup.
- **New:** A click on a session jumps to its exact terminal tab or editor window.
- **Improved:** Plan limits say when they run out at this pace ("full 16:40", or the day for a weekly limit).

### In the notch
- **New:** Notes: connect an Obsidian vault or any Markdown folder. Today shows your tasks and ticks them off in the file itself, quick capture lands in the vault's inbox, and with nothing due Today shows the week ahead.
- **New:** Weather, day progress, the Notepad and sleep scores from Oura or WHOOP, each off until you switch it on.
- **Improved:** Now playing works with any app, browsers included, with synced lyrics and a volume per app.
- **Improved:** Now playing, dictation and tools open in a smaller panel; the other tabs keep the large one.
- **Improved:** The ears stay clear of menu bar icons, the figures answer a hover and a press, and a small music note sits beside Tara while music plays.
- **Improved:** A click on the notch opens it with the keyboard ready: ← and → switch tabs, ↵ acts, esc closes.
- **Improved:** Keep awake with the lid closed works on battery too: 1 h, 3 h or until you switch it off, with a battery floor. It stops when the Mac gets too hot, and the Mac can sleep again if Starnotch quits unexpectedly.
- **Improved:** Dictation and an empty clipboard fill the panel; dark mode says when macOS blocks it.

## 27 October 2026

### Tara
- **New:** Pull Tara out of the notch: she floats under the pointer across the screen, and goes back when you let her go at the notch.
- **New:** While the microphone or camera is in use, your main character listens in the left ear.

### First run and Tara's brain
- **New:** The first launch is one window in four steps: meet Tara and pick her look, set up your agents in one click, connect Jamie and choose how Tara thinks, switch on the tools you want.
- **New:** Tara can think with your own Claude plan through Claude Code, with an API key, or with simple rules.
- **Improved:** On a fresh install every tool except Agents, Calendar and Now playing starts off, also tools a later version adds.
- **Improved:** Jamie brings whole meetings with speakers and times, and Tara reads every meeting, not only the newest.

### In the notch
- **Improved:** Every tab opens in one panel size, so switching tabs never resizes the island; long lists scroll inside it.
- **Improved:** The System tab shows CPU, GPU, memory and network speed beside your top apps, with switches for keep awake, dark mode and hiding the desktop icons.
- **New:** Keep awake with the lid closed, on the power adapter, for 1 h, 3 h or until you unplug. A ring beside the notch shows the time left, and Settings › What's set up removes it.
- **Improved:** Now playing shows a large cover, a scrubber to seek, and the volume with the output device by name.
- **Improved:** The open island never cuts a menu bar icon in half. With Accessibility allowed, it ends between two icons.

## 26 October 2026

### Calendar and tools
- **Improved:** The calendar shows your Day, Week or Month, moves a day back or ahead with the arrows or ⌘← ⌘→, and opens Calendar.app.
- **New:** Tools beside the notch: a countdown, a stopwatch and a focus timer, clipboard history on ⌃⌥V, and a file shelf with an image converter. Drag files onto the closed notch and it opens on the shelf.
- **New:** AirPods battery shows in the notch when they connect.
- **Improved:** Watch mode hides the island completely, also the pill over a fullscreen video, and switching it off holds until the video ends.

### Agents
- **New:** Agents can ask with options to pick or a field to type. Through the MCP server, any agent can show a line in the notch or ask you yes or no.
- **New:** The agents panel lists recent sessions, resumed with one click.
- **New:** Loops from a run log: any recurring agent that writes one line per run shows in the notch.

### Meeting agent
- **Improved:** The meeting agent comes inside the app and sets itself up; its key and uv are on the setup page and in Settings › Meeting agent.

## 24 October 2026

### First release
- **New:** Starnotch turns the MacBook notch into a small island; on a display without a notch it is a small pill. Hover to peek, click to open, ⌃⌥Space from the keyboard, swipe on the notch to switch, hold for the wheel.
- **New:** Agents: Claude Code and Codex sessions as small characters (working, waiting for you, idle) with their last steps, subagents and context window, plan limits for both side by side in the header, and recurring loops.
- **New:** Answer permission prompts from the notch: Allow once with ↵, Allow for session with ⌘↵, Deny with esc. Nothing is allowed without your click.
- **New:** Calendar: your day on a time band, the next meeting with a countdown and Join, a reminder five minutes before.
- **New:** Now playing for Spotify and Music, with the output device.
- **New:** Dictate starts Wispr Flow hands-free from the notch.
- **New:** Today: tasks, follow-ups and a short brief from a connector.
- **New:** Quick capture on ⌃⌥N for one line out of the notch, and its inbox on ⌃⌥I from anywhere.
- **New:** System: CPU, GPU and memory with the apps behind them, and the battery.
- **New:** Watch mode: while a fullscreen app or a video runs, the island stays quiet and only urgent lines come through.
- **New:** Meeting agent: listens along during a call and shows contradictions, open questions and new commitments as cards, each with its source; a demo meeting shows it without a microphone. Jamie sync brings your recorded meetings in.
- **New:** A setup page sets up the approvals, plan limits and more in one click, each with a backup; Settings › What's set up removes each change exactly.
- **New:** Tara, the Cat and Pebbles as characters, more through character packs, tabs you reorder by dragging, and English and German.
