# Sidecar protocol

How the Swift app talks to the Python sidecar in `agent/`. Three programs, all JSON Lines over pipes:

| Program | Lifetime | stdin | stdout |
|---|---|---|---|
| `agent.py` | runs for the whole session | utterances and commands | events and replies |
| `transcribe.py` | runs while a meeting is transcribed | nothing | utterances and status |
| `jamie_sync.py` | one run, then exits | nothing | progress and a summary |
| `meeting_sources.py` | one run, then exits | the API key, one line (`--key-stdin`) | progress and a summary |
| `notch_bridge.py` | as long as its input | any of the above | its input, unchanged; posts events to the notch |

Shared rules:

- UTF-8, one JSON object per line, `\n` after each line. stdout is flushed after every line.
- stdout carries only protocol lines. stderr is free-text logging; show it in a debug log, don't parse it.
- Ignore fields and `type`s you don't know. New fields may appear; existing ones keep their meaning.
- Dates are `YYYY-MM-DD`. `t` is seconds from the start of the meeting (a number).
- Keys come from the environment the app starts the process with: `ANTHROPIC_API_KEY` for `agent.py` (only with
  `STARNOTCH_BRAIN=api`, or `auto` without Claude Code), `RESON8_API_KEY` for `transcribe.py`. Jamie needs no key
  (browser login, see below).
- `STARNOTCH_BRAIN` picks what `agent.py` thinks with: `auto` (default), `claude-code`, `api`, `apple` or `rules`
  (see [README.md](README.md#taras-brain)). `auto` is Claude Code when a `claude` binary is found (`PATH`,
  `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`), else the API when `ANTHROPIC_API_KEY` is set, else Apple's
  on-device model when its helper says it is available, else rules. Claude Code that isn't signed in to a Claude plan
  falls back to Apple's model (under `auto`) or rules, never to the API; a brain chosen by name falls back to rules.
- `STARNOTCH_APPLE_HELPER` is the path of the app's Apple Intelligence helper (`Contents/MacOS/AppleModel`), which
  the app sets; without it the agent looks for a build in this repo's `.build`.
- `STARNOTCH_MEETING_GAP` (or `agent.py --meeting-gap`, which wins) is the least number of seconds between two
  live analysis calls to Claude, default `25` (also for a value that isn't a number), at most `600`; `0` asks for
  every batch (see "Order" under `agent.py`).

## Starting

Run everything from the `agent/` folder with uv (it creates the environment on first run):

```sh
cd agent
uv run python agent.py [--memory DIR] [--today YYYY-MM-DD] [--offline] [--captures FILE] [--watch-captures] [--connectors DIR] [--usage FILE] [--meeting-gap SECONDS]
uv run python transcribe.py (--file AUDIO [--speed N] | --mic) [--names Max,Lisa]
uv run python jamie_sync.py [--memory DIR] [--limit N] [--since YYYY-MM-DD] [--query TEXT] [--force] [--no-login]
uv run python jamie_sync.py --logout
uv run python meeting_sources.py --source granola|wispr|fireflies|fathom [--memory DIR] [--limit N] [--since YYYY-MM-DD] [--force] [--no-login] [--key-stdin]
uv run python meeting_sources.py --source granola|wispr --logout | --list-tools
```

`DIR` defaults to `~/Library/Application Support/Starnotch/memory/`, one JSON file per meeting
(schema in `memory.py`). `--offline` runs the agent without Claude, on simple built-in rules.

The agent follows the privacy switches in `privacy.json` (README › Privacy switches): while Tara's memory is paused or
meetings are off, utterances are dropped. `save` during a pause stores what was heard before it; with meetings off (or
nothing heard) it answers `{"type": "status", "state": "not_saved", "message": …}` and keeps what it heard for a later
`save`. A source switched off is left out of `ask` and `prep`.

The agent also reads what the user noted with quick capture (⌃⌥N): the app's `capture-queue.jsonl` in the same
folder (`--captures` points elsewhere, `--captures ''` ignores it). Lines with `"memory": false` (kept only as a
safety net while Tara's memory was paused) are skipped. Those tasks, questions and notes, with their
dates and due dates, count as memory for `ask`, the live analysis and the prep card. With `--watch-captures`,
each new **question** typed into quick capture is answered like an `ask`, with `"reply_to": "capture:<id>"`.

Other tools can leave snapshots for Tara in `~/Library/Application Support/Starnotch/connectors/*.json`
(`--connectors` points elsewhere, `--connectors ''` ignores them); they count for `ask` only. No schema is required:
every object with a `title`, `name` or `text` becomes an item, with its body (`text`, `content`, `body`, `summary`,
`notes`, `description`), a date (`date`, `due`, `updated`), where it lives (`url`, `link`, `uri`, or an absolute
`path`) and the key it sits under as its group. A top-level `name` names the source, else the file name does. A
missing folder, or a file that isn't JSON, is skipped. Example, as a vault connector might write it:

```json
{"name": "vault",
 "today": {"title": "2026-10-28", "path": "/Users/…/Daily/2026-10-28.md", "content": "…"},
 "tasks": [{"text": "Send the deck", "due": "2026-10-29", "path": "/Users/…/Tasks.md"}]}
```

Every call to the brain (an `ask`, a captured question, a live analysis batch) appends one line to the usage
ledger, `usage.jsonl` in the same folder (`--usage` points elsewhere, `--usage ''` keeps none): `time` (UTC),
`feature` (`ask`, `capture` or `meeting`), `brain`, `model`, `input_tokens`, `cache_creation_input_tokens`,
`cache_read_input_tokens`, `output_tokens`, `duration_ms` and `cost_usd`, the call's price at API list prices
(Claude Code's own `total_cost_usd`; for `api` computed from the price table in `usage.py`, `null` for a model not
in it). On a Claude plan nothing is billed per call; the tokens count against the plan's limits. Apple's on-device
model (`brain` `apple`, `model` `apple-on-device`) costs nothing: `cost_usd` is `0` and the tokens are estimated
(3 characters per token), since the framework can't count them here. Lines older than
90 days are dropped when an agent first writes after it starts; appends and that prune hold a lock on
`usage.jsonl.lock`, since Ask Tara's agent and the meeting's write the same file. The tokens are summed over
every turn and model of a call. A call that times out or is ended by SIGTERM printed no result and is missing
from the ledger, though it may have spent tokens. The app passes `--usage` with its own support folder and
Settings shows today and the last 7 days.

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
`sonnet`), `api` (`model` is the API model id, e.g. `claude-sonnet-5-5`), `apple` (Apple's on-device model, `model`
is `apple-on-device`) or `rules` (`model` is `null`: `--offline`,
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
| Ask Tara | `{"cmd": "ask", "question": "Welchen Preis haben wir beschlossen?", "id": 2}` | `answer` |
| Store the live meeting | `{"cmd": "save", "title": "Launch-Check", "date": "2026-10-26", "meeting_id": "…", "id": 3}` | `status` `saved` |
| Start a new meeting | `{"cmd": "reset"}` | `status` `reset` |
| Re-read the memory folder | `{"cmd": "reload"}` (after `jamie_sync.py`) | `status` `reloaded` |

`ask` answers from the meetings, the quick captures and the connector snapshots, through the brain (rules without
one). Optional fields: `history`, the conversation so far for a follow-up, oldest first
(`[{"question": "…", "answer": "…"}]`, the last 6 count); `image`, the path of a screenshot (PNG or JPEG) of the window
the question is about. `screen`, recent screen context the app picked for the question while that source is on
(`[{"id", "app", "time", "title", "text", "label"}]`, text already masked); it goes into the question, not the cached
system prompt, is dropped when `privacy.json` lists `screen` as off, and comes back as sources of kind `screen` titled
like `Screen · Mail · 14:05`. Claude Code gets the screenshot as a copy in its brain folder, readable with `Read` for that
file only, and deleted after the call; the API gets it as an image block. Apple's on-device model gets no picture:
it is told it can't see one, and the answer's `text` opens with a sentence saying so ("I can't see pictures with
Apple Intelligence." or the German one). `day` (`"2026-10-24"`) limits the material to that day: its meetings,
captures and connector items with that date (the Timeline's day page); `context` is plain text the app counted that
day besides (agent sessions, time per app), sent along with the question.

With `apple`, the window holds 4,096 tokens for instructions, prompt, schema and answer: the prompt carries the
whole memory when it fits and something in it shares a word with the question, else the facts, transcript lines
(with the line before and after), captures and connector items that share words with the question (and with the
last turn of a follow-up); then the last 2 turns, and the instructions name the question's locale (see
[README.md](README.md#apple-intelligence-apple)).

The brain is told today's date (`--today`, else the real date, so an agent kept running overnight moves on) and, when
`<memory>/jamie-sync.state` exists, when Jamie last synced: that file is written only at the end of a successful
sync, so its modification time is the sync time, read fresh for every question. Both open the question, not the
system prompt, so a sync that brought nothing new doesn't cost the prompt cache. A question about a meeting from
today that isn't in the memory (Jamie hadn't finished it by then) gets an honest "Jamie last synced at …" instead of a
guess. The memory itself is read at start and on `reload`: the app sends `reload` to every running agent after a sync
with `updated` > 0.

`save` writes the utterances since the last `reset` (and the commitments found in them) as a meeting file, the ones
still waiting for the meeting gap included; then it analyses those and, if that finds commitments, writes the file
again before it replies. `reset` drops the utterances still waiting, unanalysed;
`title`, `date` (default today) and `meeting_id` (default `<date>-<title>`) are optional.
Lines with `"type": "status"` or `"type": "partial"` are ignored, so the transcriber's output can be piped in whole.

Order: replies come in the order of the input lines. Utterances are collected and analysed together, so
proactive events arrive after the words, sometimes several at once. With Claude, the live analysis asks at most once
every meeting gap (default 25 s): the first utterance after a quiet stretch goes at once, the ones after it wait until
the gap since the last call is over and then go together in one call, also when nobody speaks in the meantime; none
is dropped or sent twice. So a contradiction shows up to the gap plus a few seconds after the words. `save` analyses
what is still waiting (see above), stdin closing runs it through the rules, `reset` drops it. With `apple` the live
analysis always runs on the rules (the memory doesn't fit the on-device window). Not held back by the
gap: the rules (no brain, or Claude resting for a minute after a failed call), `ask` and captured questions; a
proactive event from a waiting utterance may therefore come after the reply to a later command.

What the live analysis sends: the system prompt holds the instructions, the meeting memory (as for `ask`: the facts
of every meeting, notes and transcript excerpts, up to 60,000 characters) and the quick captures. It only changes
when the memory or the captures do, so the prompt cache keeps it from batch to batch. Each batch's prompt carries
today's date, the last 12 utterances of the live meeting, the new ones, and for each new utterance up to 6 earlier
transcript lines that share words with it (two or more; a number counts twice), the best line of each utterance first, at most 16 lines and
4,000 characters, plus up to 20 items already reported.

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
  "sources": [
    {"kind": "meeting", "title": "Kickoff Lumen-Abo", "quote": "Okay, dann entscheiden wir: Das Lumen-Abo kostet 30 Euro im Monat.",
     "speaker": "Jonas", "meeting": "Kickoff Lumen-Abo", "meeting_id": "2026-10-12-kickoff", "date": "2026-10-12"},
    {"kind": "capture", "id": "c1", "title": "Preis mit Max klären", "quote": "Preis mit Max klären", "date": "2026-10-24"},
    {"kind": "note", "id": "vault:0", "title": "2026-10-28", "quote": "…", "source": "vault", "date": "2026-10-28",
     "url": "file:///Users/…/Daily/2026-10-28.md"}
  ],
  "brain": "claude-code",
  "reply_to": 2
}
```

`sources` may be empty (then nothing in the material answered it, or it was a general question). Every source
exists: a meeting quote is a line of that meeting, a capture is in the queue, a note is an item of a snapshot (its
`quote` is empty unless the words are in the item; `url` is empty when the item names no place). `brain` is what
answered: `claude-code`, `api`, `apple`, or `rules` (no brain, or the brain failed just now and the rules found a line). On rules
the answer is the line that shares the most words with the question, stop words left out (at least two; one for a
question about a decision); a captured question is never an answer, least of all to itself. When nothing matches,
the answer is a sentence in the question's language: without a brain, what Tara can do without one; with a brain
that gave no answer this time (a refusal, a failed call), that she has no answer, and `brain` names the brain. A
missing screenshot is left out, and a failed question doesn't rest Claude for the questions after it.

**status**

| `state` | Extra fields | When |
|---|---|---|
| `offline` | `message` | Claude isn't reachable (no key, Claude Code not signed in or not on a Claude plan, a timeout, an error) or Apple Intelligence isn't (switched off, still downloading, an error); the agent continues on rules, or under `auto` on Apple's model when the message ends in "using Apple Intelligence" (sent once) |
| `saved` | `meeting_id`, `path` | after `save` |
| `reset` | | after `reset` |
| `reloaded` | `meetings` | after `reload` |

**error**: `{"type": "error", "message": "…", "reply_to": 4}`, for a line that isn't JSON, an unknown command
or a failed command. The agent keeps running.

## AppleModel (the app's helper)

`Contents/MacOS/AppleModel` (source `Sources/AppleModel`) asks Apple's on-device model once per run; the agent runs
it for the `apple` brain. It needs macOS 26 and Apple silicon, and starts on older systems to say so.

`AppleModel --status` prints `{"available": true}` or `{"available": false, "reason": "…", "message": "…"}`, `reason`
being Apple's: `deviceNotEligible` (not this Mac, or older than macOS 26), `appleIntelligenceNotEnabled`,
`modelNotReady` (still downloading).

A call is one JSON object on stdin and one line on stdout:

```json
{"instructions": "…", "prompt": "…", "schema": {"type": "object", "properties": {…}, "required": […]}, "locale": "de_DE", "maximumResponseTokens": 600}
{"result": {"answer": "…", "sources": […]}}
{"error": {"kind": "rateLimited", "message": "…"}}
```

`schema` is the JSON Schema subset the agent uses: `object` (`properties`, `required`; properties come in the order
of `required`, then the others by name), `array` (`items`, `minItems`, `maxItems`), `string` (with `enum` for a
fixed choice), `integer`, `number`, `boolean`, and `description`. The root must be an object and each `type` one
string (a node without `type` is a string); anything else, such as `["string", "null"]`, is refused with kind `other`.
`locale` is checked against the model's languages first; `maximumResponseTokens` (optional) caps the answer.
`kind` is `unavailable` (with `reason` as above), `rateLimited` (the agent tries once more after 2 seconds),
`guardrail` (the agent treats it as a refusal), `contextWindowExceeded` (the agent retries once with a retrieval in
half the room), `unsupportedLanguage` or `other`.
Exit code 0 with a `result`, 1 with an `error`.

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
`stale: true`: Jamie couldn't give the whole meeting this time (`get_meeting` or `list_tasks` failed), so the stored
copy stays as it was. `warning` lines don't stop the sync.

The last line counts the meetings that are now in the memory (`meetings`), how many were written (`updated`),
skipped (`unchanged`) and kept from last time (`stale`, only when there are some): `meetings` is their sum. When an unfiltered sync (no `--since`, no `--query`) finds no meetings at all, it says so,
so the app can offer to sign in with another Jamie account:

```json
{"type": "status", "state": "synced", "meetings": 0, "hint": "empty_account"}
```

What is fetched: `list_meetings` page by page (`cursor`/`nextCursor`) until `--limit` meetings (default 50, newest
first); for each, `get_meeting`, and when its `transcriptInfo.truncated` is true, every page of
`get_meeting_transcript` until `isFinal`. `list_tasks` page by page, all of them (a task belongs to its meeting's
fingerprint, so a cut list would rewrite older meetings without their tasks). Re-syncs are fast: Jamie has no
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
access token is refreshed without the browser. Each sync first reads the authorization server's metadata (two small
GETs), so a token that runs out during a long sync is refreshed at Jamie's `/oauth/token` too. Exit code 0 on success, 1 on error.
Send `{"cmd": "reload"}` to a running `agent.py` afterwards when `updated` is above 0.

`--no-login` is for syncs nobody asked for (the app's automatic ones): it never opens the browser. Without a stored
login (the file holds tokens only after a finished browser login; registering the client writes it earlier), or when
Jamie wants a new one, it prints `{"type": "status", "state": "login_required"}` and exits with 2; the app then stops
syncing on its own until the user connects again. The app's automatic syncs also pass `--limit 10`: an unchanged
meeting still costs one `get_meeting`, so they look only at the newest ten; Connect and Sync now look at 50.
Without Jamie reachable at all, the error reads `jamie sync: Jamie isn't reachable; check your internet connection`.

`--logout` deletes that file and prints `{"type": "status", "state": "logged_out", "removed": true}` (`false` when
there was none); it doesn't connect. The next sync opens the login again. Which account it signs in to is decided
by the Jamie session in the browser: to switch accounts, sign out at app.meetjamie.ai first. Meetings already
synced stay in the memory.

## meeting_sources.py

The meeting tools besides Jamie, one `--source` per run, with jamie_sync.py's output: one `synced` line per meeting,
`warning`, `login`, `login_required` and `error` lines, then the summary line. A meeting that another source already
holds is not written: its line has `duplicate_of` (the id that stays) instead of `path`, and the summary counts these
as `duplicates` (only when there are some).

| Source | Reached through | Login | What's read |
|---|---|---|---|
| `granola` | MCP, `https://mcp.granola.ai/mcp` | browser (OAuth, client registered on the fly, PKCE) | `list_meetings`, `get_meetings`, `get_meeting_transcript` (paid plans; the Free plan reaches the last 30 days, without transcripts) |
| `wispr` | MCP, `https://api.wisprflow.ai/connect/mcp` | browser (as Granola) | `search_meetings` paged by `next_cursor`, `get_meeting` with the transcript in ranges of 40,000 characters |
| `fireflies` | GraphQL, `https://api.fireflies.ai/graphql` | personal API key (`Authorization: Bearer`) | `transcripts` with summary, action items and sentences, 50 per request |
| `fathom` | REST, `https://api.fathom.ai/external/v1/meetings` | personal API key (`X-Api-Key`) | the meetings list with transcript, summary and action items, paged by `next_cursor` |

Browser logins are kept as Jamie's, in `<source>-oauth.json` next to the memory (0600), on the same callback port;
`--logout` deletes the file. An API key comes on the first line of stdin with `--key-stdin` (the app reads it from the
Keychain and never writes it to a file, the command line or the environment), else from `FIREFLIES_API_KEY` /
`FATHOM_API_KEY`; without one, or when the provider refuses it, the run prints `login_required` and exits with 2.
Fingerprints of what was written are kept in `<memory>/<source>-sync.state`.

Ids are `<source>-<the provider's id>`. Every source hands one dict in common keys (`id`, `title`, `start`,
`participants`, `summary`, `notes`, `action_items`, `transcript`) to `normalize`, which reads it as jamie_sync.py reads
Jamie's meetings (summary sections, action items, `Name: text` lines) and adds `start`, the meeting's start as ISO
8601 with its offset, and `date`, the user's local day of it.

**Which sources feed the memory.** The app writes `meeting-sources.json` next to the memory
(`STARNOTCH_MEETING_SOURCES` names another file): `{"enabled": ["starnotch", "jamie", "granola"]}`. Without the file,
`starnotch` (the recordings) and `jamie` are on. A source not listed prints
`{"type": "status", "state": "off", "message": …}` and syncs nothing (jamie_sync.py too); `agent.py` answers a `save`
with `not_saved` while `starnotch` isn't listed. A pause or meetings switched off come first (`paused`).

**One copy per meeting.** Before a meeting is written (by any source, the recordings' `save` too), the memory is
searched for the same meeting from another source: both started within 20 minutes and share title words or a
person; without start times, the same day and a similar title, and no people that tell them apart. A recording on
this Mac always stays and replaces another source's copy; between two tools the copy with a transcript (then the
longer one, then more notes and facts) stays, the one already there on a tie. A copy that is replaced is deleted.

