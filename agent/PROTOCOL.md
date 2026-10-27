# Sidecar protocol

How the Swift app talks to the Python sidecar in `agent/`. Three programs, all JSON Lines over pipes:

| Program | Lifetime | stdin | stdout |
|---|---|---|---|
| `agent.py` | runs for the whole session | utterances and commands | events and replies |
| `transcribe.py` | runs while a meeting is transcribed | nothing | utterances and status |
| `jamie_sync.py` | one run, then exits | nothing | progress and a summary |
| `notch_bridge.py` | as long as its input | any of the above | its input, unchanged; posts events to the notch |

Shared rules:

- UTF-8, one JSON object per line, `\n` after each line. stdout is flushed after every line.
- stdout carries only protocol lines. stderr is free-text logging; show it in a debug log, don't parse it.
- Ignore fields and `type`s you don't know. New fields may appear; existing ones keep their meaning.
- Dates are `YYYY-MM-DD`. `t` is seconds from the start of the meeting (a number).
- Keys come from the environment the app starts the process with: `ANTHROPIC_API_KEY` for `agent.py` (only with
  `STARNOTCH_BRAIN=api`, or `auto` without Claude Code), `RESON8_API_KEY` for `transcribe.py`. Jamie needs no key
  (browser login, see below).
- `STARNOTCH_BRAIN` picks what `agent.py` thinks with: `auto` (default), `claude-code`, `api` or `rules`
  (see [README.md](README.md#taras-brain)). `auto` is Claude Code when a `claude` binary is found (`PATH`,
  `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`), else the API when `ANTHROPIC_API_KEY` is set, else rules.
  Claude Code that isn't signed in to a Claude plan falls back to rules, never to the API.

## Starting

Run everything from the `agent/` folder with uv (it creates the environment on first run):

```sh
cd agent
uv run python agent.py [--memory DIR] [--today YYYY-MM-DD] [--offline] [--captures FILE] [--watch-captures]
uv run python transcribe.py (--file AUDIO [--speed N] | --mic) [--names Max,Lisa]
uv run python jamie_sync.py [--memory DIR] [--limit N] [--since YYYY-MM-DD] [--query TEXT] [--force]
uv run python jamie_sync.py --logout
```

`DIR` defaults to `~/Library/Application Support/Starnotch/memory/`, one JSON file per meeting
(schema in `memory.py`). `--offline` runs the agent without Claude, on simple built-in rules.

The agent also reads what the user noted with quick capture (⌃⌥N): the app's `capture-queue.jsonl` in the same
folder (`--captures` points elsewhere, `--captures ''` ignores it). Those tasks, questions and notes, with their
dates and due dates, count as memory for `ask`, the live analysis and the prep card. With `--watch-captures`,
each new **question** typed into quick capture is answered like an `ask`, with `"reply_to": "capture:<id>"`.

During a meeting the app reads `transcribe.py`'s stdout and writes each `utterance` line, unchanged, into
`agent.py`'s stdin (it may show the line as a live caption on the way). For a test without the app:
`uv run python transcribe.py --file x.wav | uv run python agent.py`.

`agent.py` ends when its stdin closes. Close stdin (or send SIGTERM) to stop it.

## agent.py

### First line

```json
{"type": "ready", "meetings": 2, "memory": "/Users/…/memory", "brain": "claude-code", "model": "sonnet", "errors": []}
```

`brain` is what the agent thinks with: `claude-code` (the user's Claude plan, `model` is Claude Code's alias
`sonnet`), `api` (`model` is the API model id, e.g. `claude-sonnet-5-5`) or `rules` (`model` is `null`: `--offline`,
`STARNOTCH_BRAIN=rules`, no Claude Code and no key, or Claude Code not signed in; the reason comes as a `status`
`offline` line just before `ready`). `errors` lists meeting files that couldn't be read. Wait for `ready` before
sending commands.

### stdin

Utterance (exactly what `transcribe.py` prints):

```json
{"type": "utterance", "speaker": "Max", "text": "Wir waren doch bei 25 Euro, oder?", "t": 24.0}
```

Commands. `id` is optional (string or number); the reply carries it back as `reply_to`.

| Command | Line | Reply |
|---|---|---|
| Prep card | `{"cmd": "prep", "participants": ["Max", "Lisa"], "id": 1}` | `prep` |
| Question to the memory | `{"cmd": "ask", "question": "Welchen Preis haben wir beschlossen?", "id": 2}` | `answer` |
| Store the live meeting | `{"cmd": "save", "title": "Launch-Check", "date": "2026-10-26", "meeting_id": "…", "id": 3}` | `status` `saved` |
| Start a new meeting | `{"cmd": "reset"}` | `status` `reset` |
| Re-read the memory folder | `{"cmd": "reload"}` (after `jamie_sync.py`) | `status` `reloaded` |

`save` writes the utterances since the last `reset` (and the commitments found in them) as a meeting file;
`title`, `date` (default today) and `meeting_id` (default `<date>-<title>`) are optional.
Lines with `"type": "status"` or `"type": "partial"` are ignored, so the transcriber's output can be piped in whole.

Order: replies come in the order of the input lines. Utterances that arrive while Claude is busy are analysed
together in the next call, so proactive events arrive one to a few seconds after the words, sometimes
several at once.

### stdout: proactive events

Sent on their own while the meeting runs. Each item is sent once per meeting (until `reset`).

**contradiction**: something said now conflicts with the memory.

```json
{
  "type": "contradiction",
  "now": "Wir waren doch bei 25 Euro im Monat, oder?",
  "speaker": "Max",
  "t": 24.0,
  "before": {
    "quote": "Okay, dann entscheiden wir: Das Lumen-Abo kostet 30 Euro im Monat.",
    "speaker": "Jonas",
    "meeting": "Kickoff Lumen-Abo",
    "meeting_id": "2026-10-12-kickoff",
    "date": "2026-10-12"
  },
  "note": "Im Kickoff wurden 30 Euro entschieden, 25 Euro wurden verworfen."
}
```

`now` is the quoted part of what was said (may be shorter than the utterance); `speaker`/`t` belong to that
utterance (`t` may be `null`). `before.quote` is always a line that exists in the memory: the agent drops
contradictions whose earlier quote it can't find.

**question**: a question worth asking now, grounded in the memory. At most one per analysis.

```json
{"type": "question", "text": "Max, die Margenzahlen waren bis 16.10. zugesagt. Wie ist der Stand?", "reason": "Offene Zusage aus dem Kickoff (2026-10-12)"}
```

**commitment**: someone in the live meeting promised something.

```json
{"type": "commitment", "who": "Lisa", "what": "Folien für den Workshop schicken", "due": "2026-10-28", "quote": "Ich schicke euch bis Mittwoch die Folien für den Workshop."}
```

`due` is `null` when no date was said. `what` may be the whole sentence when the agent runs on rules.

### stdout: replies

**prep**

```json
{
  "type": "prep",
  "participants": ["Max", "Lisa"],
  "meetings": [{"meeting": "Weekly Lumen-Abo", "meeting_id": "2026-10-19-weekly", "date": "2026-10-19"}],
  "last_meeting": {"meeting": "Weekly Lumen-Abo", "meeting_id": "2026-10-19-weekly", "date": "2026-10-19", "summary": "…"},
  "decisions": [
    {"text": "Preis bleibt bei 30 Euro, …", "quote": "Okay. Und wir bleiben beim Preis von 30 Euro, …", "speaker": "Jonas",
     "meeting": "Weekly Lumen-Abo", "meeting_id": "2026-10-19-weekly", "date": "2026-10-19"}
  ],
  "open_commitments": [
    {"who": "Max", "what": "Zahlen zur Marge an das Team schicken", "due": "2026-10-16", "overdue": true,
     "quote": "Ich schicke euch die Zahlen zur Marge bis Freitag.",
     "meeting": "Kickoff Lumen-Abo", "meeting_id": "2026-10-12-kickoff", "date": "2026-10-12"}
  ],
  "captures": [
    {"route": "task", "text": "Max wegen Margenzahlen anstupsen", "due": "2026-10-23", "overdue": true,
     "created": "2026-10-20T09:00:00Z"}
  ],
  "reply_to": 1
}
```

Meetings are those with at least one of the participants (first name match, case-insensitive), newest first;
an empty list means all meetings. `decisions` (newest first, at most 6) come from those meetings.
`open_commitments` are open ones from those meetings or made by a participant; `overdue` compares `due` with
today. `captures` are quick-capture tasks and questions that tag or name a participant, newest first (at most 6);
`due` may carry a time (`2026-10-23 15:00`). `last_meeting` is `null` when there is none. The card is built from the memory without Claude, so it's instant.

**answer**

```json
{
  "type": "answer",
  "question": "Welchen Preis haben wir beschlossen?",
  "text": "30 Euro im Monat; 25 Euro wurde im Kickoff verworfen.",
  "sources": [{"quote": "Okay, dann entscheiden wir: Das Lumen-Abo kostet 30 Euro im Monat.", "speaker": "Jonas",
               "meeting": "Kickoff Lumen-Abo", "meeting_id": "2026-10-12-kickoff", "date": "2026-10-12"}],
  "reply_to": 2
}
```

`sources` may be empty (then the memory had no answer). Every source quote exists in the memory.

**status**

| `state` | Extra fields | When |
|---|---|---|
| `offline` | `message` | Claude isn't reachable (no key, Claude Code not signed in or not on a Claude plan, a timeout, an error); the agent continues on rules (sent once) |
| `saved` | `meeting_id`, `path` | after `save` |
| `reset` | | after `reset` |
| `reloaded` | `meetings` | after `reload` |

**error**: `{"type": "error", "message": "…", "reply_to": 4}`, for a line that isn't JSON, an unknown command
or a failed command. The agent keeps running.

## transcribe.py

stdout:

```json
{"type": "status", "state": "connected", "sample_rate": 16000}
{"type": "utterance", "speaker": "Max", "text": "Wir waren doch bei 25 Euro, oder?", "t": 24.0}
{"type": "error", "message": "reson8: …"}
{"type": "status", "state": "done", "utterances": 7}
```

Only finished utterances are printed (no partials). `speaker` is the name from `--names` in order of first
appearance, else `Sprecher 1`, `Sprecher 2`, … or `""` without diarization. Exit code 0 when done,
1 on an error, 2 without `RESON8_API_KEY`. With `--file`, audio is sent at real-time speed (`--speed 2` is twice
as fast); with `--mic` it runs until the process is stopped (SIGINT/SIGTERM).

## notch_bridge.py

Until the app shows the agent's events itself, this filter puts them in the notch: each `contradiction`,
`question`, `commitment`, `prep`, `answer` and `ready` (and with `--captions` each `utterance`) becomes one
status of the app's local status API (`docs/SDK.md`): POST to `127.0.0.1:47789` with the token from
`~/Library/Application Support/Starnotch/api-token`, or, when that isn't reachable, `open -g starnotch://status?…`.
Lines pass through unchanged, so it can sit between any two programs.

The notch shows one short line, so each card links to its full text: a click opens a page on
`http://127.0.0.1:47790/` (the next free port if taken) with every event of the session in full, newest first, and the
same text is appended to `~/Library/Application Support/Starnotch/Meeting-Agent.md`. `--no-feed` switches both off.

## jamie_sync.py

stdout:

```json
{"type": "status", "state": "login", "url": "https://…"}
{"type": "synced", "meeting_id": "jamie-abc", "title": "Weekly", "date": "2026-10-19", "lines": 120, "path": "/Users/…/jamie-abc.json"}
{"type": "synced", "meeting_id": "jamie-def", "title": "Kickoff", "date": "2026-10-12", "lines": 88, "path": "/Users/…/jamie-def.json", "unchanged": true}
{"type": "status", "state": "warning", "message": "get_meeting abc: …"}
{"type": "status", "state": "synced", "meetings": 12, "updated": 1, "unchanged": 11}
{"type": "error", "message": "jamie sync: …"}
```

One `synced` line per meeting, in the order they finish (several are fetched at once). `unchanged: true`: Jamie
reports nothing new for it since the last sync, so the file wasn't touched. `partial: true`: only the start of
the transcript could be read (get_meeting cuts long ones; the full read failed); the next sync tries again.
`warning` lines don't stop the sync; a meeting whose details can't be fetched keeps its stored copy.

The last line counts the meetings that are now in the memory (`meetings`), how many were written (`updated`) and
skipped (`unchanged`). When an unfiltered sync (no `--since`, no `--query`) finds no meetings at all, it says so,
so the app can offer to sign in with another Jamie account:

```json
{"type": "status", "state": "synced", "meetings": 0, "hint": "empty_account"}
```

What is fetched: `list_meetings` page by page (`cursor`/`nextCursor`) until `--limit` meetings (default 50, newest
first); for each, `get_meeting`, and when its `transcriptInfo.truncated` is true, every page of
`get_meeting_transcript` until `isFinal`. `list_tasks` once (the newest 100). Re-syncs are fast: Jamie has no
`updatedAt`, so each meeting's `get_meeting` answer (summary, participants, tasks, transcript size) is
fingerprinted into `<memory>/jamie-sync.state`; an unchanged meeting costs one `get_meeting` and no transcript
pages. `--force` writes every meeting again.

How Jamie's meeting becomes a memory file: Jamie's transcript blocks (`Speaker 0`, `###### 00:00 - 00:08`, text)
become one line each with `speaker` and `t`; a speaker label becomes the participant's name when Jamie knows it,
`Speaker -1` (no speaker detected) becomes `""`. `participants` are the named participants and calendar
attendees, without unnamed voices (`Speaker 2`) and without the Jamie user. `summary` is the summary's
"Executive Summary" (or "Summary", "Overview", "Zusammenfassung") section, else Jamie's short summary, else the
whole summary; it is what the prep card shows. `notes` keeps Jamie's whole summary as Markdown (Full Summary and its
topic sections) whenever `summary` is only part of it: the memory is the only copy, and Claude reads the notes.
`decisions` come from a "Decisions"/"Key Decisions"/"Entscheidungen" section, `commitments` from Jamie's tasks
(assignee, due date, done), or, when the meeting has none, from an "Action Items"/"Next
Steps"/"Aufgaben" section (`**Lisa**: …`, `[x] …`, an ISO date as `due`). Jamie's default summary template has
neither section, so most meetings carry none.

`login` appears only when no valid token is stored and it can't be refreshed: the script has opened the browser at
`url` and waits (up to 5 minutes) for the redirect to `http://127.0.0.1:47791/callback`. Tokens are kept in
`~/Library/Application Support/Starnotch/jamie-oauth.json` (mode 0600) with the time they run out, so an expired
access token is refreshed without the browser. Exit code 0 on success, 1 on error.
Send `{"cmd": "reload"}` to a running `agent.py` afterwards.

`--logout` deletes that file and prints `{"type": "status", "state": "logged_out", "removed": true}` (`false` when
there was none); it doesn't connect. The next sync opens the login again. Which account it signs in to is decided
by the Jamie session in the browser: to switch accounts, sign out at app.meetjamie.ai first. Meetings already
synced stay in the memory.
