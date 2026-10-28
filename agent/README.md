# Starnotch meeting agent (sidecar)

A Python sidecar that gives Starnotch a memory of past meetings. While a meeting runs it notices when something
said contradicts an earlier decision, suggests a question worth asking, and records new commitments. Before a
meeting it builds a prep card: earlier decisions and open commitments, each with the quote it came from.

The Swift app starts these programs and reads their JSON lines; [PROTOCOL.md](PROTOCOL.md) has every message.

| File | What it does |
|---|---|
| `memory.py` | The meeting memory: one JSON file per meeting, in `~/Library/Application Support/Starnotch/memory/` |
| `agent.py` | The agent: utterances and commands on stdin, contradictions, questions, commitments, prep cards and answers on stdout |
| `claude.py` | The model call: through the user's Claude Code on their Claude plan, the Anthropic API (Claude Sonnet 5.5, effort `low`, structured outputs, server-side fallback on refusals), or Apple's on-device model through the app's helper |
| `jamie_sync.py` | Pulls meetings from [Jamie](https://meetjamie.ai) over its MCP server (OAuth login in the browser) into the memory |
| `transcribe.py` | Live transcription with Reson8 Realtime, from the microphone or an audio file streamed in real time |
| `captures.py` | Reads Starnotch's quick-capture queue, so the agent knows the user's own tasks, questions and notes |
| `connectors.py` | Reads the snapshots other tools leave in `connectors/*.json` (a vault's tasks and today's note), for Ask Tara |
| `feed.py` | The full text behind each notch card: a page on 127.0.0.1 (a click on the card opens it) and `Meeting-Agent.md` |
| `privacy.py` | Reads the app's privacy switches (`privacy.json`): a pause, sources switched off, the ignore list |
| `memory_mcp.py` | Tara's memory as a read-only MCP server for AI apps (Claude Desktop, Claude Code, Cursor, ChatGPT) |
| `notch_bridge.py` | Shows the agent's events in the running Starnotch app, through its local status API (no Swift change) |
| `demo/` | Two made-up meetings, a script that replays a third one, and a macOS script that turns it into audio |

## Setup

Python 3.12 and [uv](https://docs.astral.sh/uv/):

```sh
cd agent
uv sync                 # add --extra mic for the microphone
export RESON8_API_KEY=...      # for transcribe.py
```

Keys are read from the environment only.

## Tara's brain

`agent.py` thinks with whatever `STARNOTCH_BRAIN` names (the app sets it from Settings and onboarding):

| `STARNOTCH_BRAIN` | Thinks with | Costs |
|---|---|---|
| `auto` (default) | Claude Code if a `claude` binary is found, else the API if `ANTHROPIC_API_KEY` is set, else Apple's on-device model if it is ready, else rules | |
| `claude-code` | The user's Claude Code CLI, headless (`claude -p`), model alias `sonnet`, effort `low` | counts against their Claude plan |
| `api` | The Anthropic API with `ANTHROPIC_API_KEY` | API credits |
| `apple` | Apple's on-device model (Apple Intelligence, macOS 26 on Apple silicon) through the app's helper | nothing |
| `rules` | Simple built-in rules, no model (same as `--offline`) | nothing |

The claude binary is looked up on `PATH`, then in `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`.
Claude Code never bills an API by surprise: before the first call the agent runs `claude auth status` and only goes
on with a Claude plan login (`claude.ai`, or a `claude setup-token` token); otherwise, also when it isn't signed
in, it uses (under `auto`) Apple's free on-device model when that is ready, else rules, never the API.
That includes a `claude auth status` that times out (15 s) or prints nothing readable: then `auto` thinks with Apple
for the rest of the session even if Claude Code would have worked, and the live meeting analysis runs on rules.
A brain chosen by name falls back to rules only. Every call runs without `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
`ANTHROPIC_BASE_URL` and the Bedrock/Vertex/Foundry switches in its environment (with a key there, Claude Code
silently bills the key).

Each call is a bare session so it reads little: an empty folder of its own
(`~/Library/Application Support/Starnotch/brain`, so no CLAUDE.md or project loads), no tools (`--tools ""`; a question about a screenshot gets `Read`, allowed for that one file), no
MCP servers (`--strict-mcp-config` with an empty config), no user or project settings (`--setting-sources ""`: no
hooks, plugins, memory or `apiKeyHelper`), no slash commands, no saved transcript (`--no-session-persistence`); the
system prompt comes from a file (`--system-prompt-file`), the prompt on stdin, the answer as `--output-format json`
validated against `--json-schema`. That is about 1,100 tokens of Claude Code's own on top of our prompt (a plain
`claude -p` loads about 220,000 here); a live analysis of the demo meetings reads about 3,000. `--bare` would trim
further but reads only `ANTHROPIC_API_KEY`, never the plan login, so it isn't used. A call that takes longer than
30 seconds, fails or is refused falls back to rules for those lines, and the next minute stays on rules before
Claude is asked again; a lost login switches the rest of the session to rules. Claude Code's own retries are capped
at one (`CLAUDE_CODE_MAX_RETRIES=1`), so an overloaded or throttled API fails in seconds rather than after the
timeout. The system prompt file sits in the brain folder and is deleted after the call (also when the app ends the
agent with SIGTERM; one left by a hard kill is swept on the next start). stderr logs each call's tokens and duration.

The meeting memory in the system prompt is at most 60,000 characters: the summary, decisions and commitments of every
meeting always, then notes and transcripts in equal parts per meeting (what a short one doesn't need goes to the
others); a longer transcript keeps its lines with numbers first, then its earliest, with `…` for the gaps. The up to
six transcript lines that share the most words with a question, or with each utterance of a live batch (at most 16
lines and 4,000 characters per batch), come along in the prompt, so the parts the excerpt left out still count. The
system prompt only changes when the memory does, so it stays cacheable.

The live analysis is the cost driver, so Claude is asked at most once every 25 seconds (`STARNOTCH_MEETING_GAP` or
`--meeting-gap`; `0` asks for every batch): what is said in between waits and goes with the next call, and a quiet
stretch sends what waits once the gap is over. The rules, Ask Tara and captured questions aren't held back. `save`
writes the meeting before it analyses what still waits, so a slow call can't cost the transcript; `reset` drops what
waits, and stdin closing runs it through the rules only. The system prompt keeps the whole memory: read from the
prompt cache, a token of it costs a fortieth of a token in the batch prompt (Claude Code writes each batch prompt to
the one-hour cache), so moving the transcripts into the batch prompt would make a call dearer, not cheaper. With a
memory at the full budget (about 33,000 tokens) and Sonnet's API list prices, a call costs about $0.010 for a
one-line batch and up to about $0.026 for a busy one (10 new utterances, 12 of context, 20 items already reported and
the recall at its 4,000-character cap: about 8,000 characters). A meeting hour of steady talk, 144 calls, comes to
about $1.50 to $3.70 plus about $0.13 for the first call, against $2.60 to $10 when every call followed the last one.

### Apple Intelligence (`apple`)

The free brain for people without Claude. The app ships a small helper, `Contents/MacOS/AppleModel`
(`Sources/AppleModel`, built by `scripts/build-app.sh`), and passes its path as `STARNOTCH_APPLE_HELPER`; without
that variable the agent looks in this repo's `.build/release` and `.build/debug`. Each call runs the helper once:
one JSON request on stdin, one JSON line back (see [PROTOCOL.md](PROTOCOL.md#applemodel-the-apps-helper)). The helper
builds Apple's guided-generation schema from the same JSON schema the Claude brains get, so the source ids it may
cite are limited to the material sent. `auto` uses it only when `AppleModel --status` says the model is available
(before macOS 26 the helper isn't even started); a call that reports it unavailable (switched off, still
downloading) moves the rest of the session to rules. A rate-limited call is tried once more after 2 seconds.

The model reads at most 4,096 tokens for instructions, prompt, schema and answer together. Ask Tara and captured
questions get the whole memory (as Claude gets it, with every meeting, capture and connector id to cite) when it
fits, which a new user's small memory mostly does, and something in it shares a content word with the question.
Otherwise they get a retrieval: the facts (summary, decisions, commitments) of the meetings that share content words
with the question, the 10 best transcript lines from `memory.search` with the line before and after each, and the
quick captures and connector items that share words with it (pronouns don't count). When nothing shares a word,
the prompt says that nothing matches, so the model says it isn't in the material, or answers a general question
without sources. A follow-up adds the words of the last turn to the search and carries the last 2 turns (300
characters each); the question itself counts up to 1,500 characters. It all has to fit into what is left after 600
tokens for the answer (also the answer's cap, `maximumResponseTokens`), counted at 2.5 characters per token (German
runs about 2 to 3; the Command Line Tools SDK can't count tokens); a window overflow anyway is retried once with a
retrieval in half the room. The answer is asked for in under 300 characters with ids only in the sources; an id the
model still writes in brackets is taken out of the text. The
instructions name the question's locale the way Apple documents it ("The person's locale is de_DE." and "You MUST
respond in German."), so the answer comes in the question's language. A picture (Tara dropped on a window) is not
sent: the model is told it can't see it, and the answer opens with a sentence saying so. The live meeting analysis
needs the whole memory, so with `apple` it runs on the rules. The usage ledger records each call with the model
`apple-on-device`, tokens estimated at 3 characters per token, and cost 0.

Measured on this repo's demo meetings with the 10 questions of the on-device benchmark (macOS 27, greedy sampling,
two runs with the same answers; the demo memory fits whole): 8 of 10 answers right by the benchmark's word checks,
10 of 10 with a source from the right meeting, all 10 in the question's language, 0.7 to 3.9 seconds per question
(median about 3 s). Read by hand, 9 of 10 are right: "Has Max sent the margin numbers yet?" is right but leaves out
why (the word check wants it), and the follow-up "who proposed this price?" names the wrong person. Answers are
simpler than Claude's, sometimes repeat the quote or name a meeting id in the text, and a French question gets an
English answer (only German and English are told apart); the source check keeps only quotes that are in the memory.

## Ask Tara

⌃⌥T (or a click on Tara floating beside the notch) opens a small question bubble; type or hold the keys to speak.
The app sends `ask` to its own `agent.py` and shows the answer in Tara's speech bubble, with its sources: the
meeting and date, a quick capture, or a note from a connector snapshot (a click opens it). Follow-ups carry the last
six turns. Without a brain Tara says what she can do: find words in the meetings, captures and notes. Try it from
the terminal:

```sh
echo '{"cmd": "ask", "question": "Welchen Preis haben wir beschlossen?"}' \
  | uv run python agent.py --memory demo/meetings --connectors ''
```

## Demo

```sh
./demo/run_demo.sh             # prep card, the live meeting, a question at the end (SPEED=4 for faster)
./demo/run_demo.sh --offline   # the same without Claude
NOTCH=1 ./demo/run_demo.sh     # every event also appears in the notch (Starnotch must be running)
```

In the notch: a contradiction shows for 10 seconds in red with the earlier quote, a question in amber, a commitment
in green. With Settings › Local status API on, the bridge posts over HTTP; otherwise it uses the `starnotch://` link.

The memory holds a kickoff (price decided at 30 Euro, Max sends margin numbers by Friday, Lisa books the room)
and a weekly a week later (room booked, numbers still missing, 30 Euro confirmed). In the third meeting Max says
"Wir waren doch bei 25 Euro": the agent flags the contradiction with the kickoff quote, asks about Max's
overdue numbers, and records Lisa's new promise.

With real audio on a Mac:

```sh
uv run python demo/make_audio.py
uv run python transcribe.py --file demo/live.wav --language de \
  | uv run python notch_bridge.py --captions \
  | uv run python agent.py --memory demo/meetings --today 2026-10-26 \
  | uv run python notch_bridge.py
```

Jamie:

```sh
uv run python jamie_sync.py --list-tools   # first run opens the Jamie login
uv run python jamie_sync.py --limit 200    # pages through Jamie; full transcripts; unchanged meetings are skipped
uv run python jamie_sync.py --logout       # forget the login (sign out at app.meetjamie.ai to switch accounts)
uv run python jamie_sync.py --no-login     # never opens the browser (the app's automatic syncs)
```

## Tests

```sh
uv run pytest
```

Claude, Apple's model, Jamie and Reson8 are replaced by fakes: a fake Anthropic client, a fake `claude` binary on `PATH`,
a fake Apple Intelligence helper, an in-process MCP server with Jamie's tool names, and a local WebSocket server. The
tests never use a helper a local `swift build` left in `.build`.

## MCP server: any agent reaches you in the notch

`mcp_server.py` makes Starnotch an MCP server with two tools: `notify` (one line in the notch,
optionally with a link) and `confirm` (a yes/no question as a card; returns `yes`, `no` or
`no answer`). Settings › Setup › "Agents can reach you" adds it to Claude Code and Codex; by hand:

```sh
claude mcp add --scope user starnotch -- uv run --directory "$HOME/Library/Application Support/Starnotch/agent" python mcp_server.py
```

Other clients (Cursor, VS Code, Gemini CLI, Claude Desktop) take the same command in their MCP
config. Questions travel over the app's approvals socket and queue with permission requests; only
a click answers yes.

## Tara's memory in every AI app

`memory_mcp.py` is a second, read-only MCP server, `starnotch-memory`: any AI app on the Mac can look things up in
Tara's memory. Five tools, every result with its `source` (`meeting`, `capture`, `note`, `calendar`, `session`), `id`
and a `link` when there is one:

| Tool | Returns |
|---|---|
| `search_memory(query, sources?, limit?)` | Meeting summaries, decisions, commitments and transcript lines, captures, notes and recent Claude Code sessions that share words with the query, best first |
| `get_meeting(meeting_id)` | One meeting in full: participants, summary, notes, decisions and commitments with quotes, transcript (cut at about 40,000 characters) |
| `open_commitments(person?)` | Open promises from meetings and captured tasks, with due and overdue |
| `recent_decisions(days?, person?)` | Decisions from the meetings of the last days, newest first |
| `today()` | Today's calendar (`connectors/calendar.json`, written by the app), tasks due or overdue, commitments due |

Settings › Setup › "Tara's memory in your AI apps" registers it, one switch per app, each with a backup and an exact
Remove: Claude Desktop (`claude_desktop_config.json`), Claude Code (`claude mcp add --scope user`), Cursor
(`~/.cursor/mcp.json`) and ChatGPT's Mac app. ChatGPT runs its local tools through Codex, so that one is a marked
block in `~/.codex/config.toml` (Codex sees it too); ChatGPT on the web can't reach a server on the Mac. By hand:

```sh
claude mcp add --scope user starnotch-memory -- uv run --directory "$HOME/Library/Application Support/Starnotch/agent" python memory_mcp.py
```

### Privacy switches

Settings › Tara's memory mirrors its switches to `privacy.json` in the app's folder; `privacy.py` reads it on every
use, so a change counts at once (`STARNOTCH_PRIVACY` names another file; the tests use their own).

- **Pause** (1 hour, until tomorrow, until resumed): nothing new is recorded. The agent drops what it hears and
  answers `save` with `{"type": "status", "state": "not_saved"}`, `jamie_sync.py` prints `{"state": "paused"}` and
  syncs nothing, the app writes no capture, vault or calendar snapshot and keeps no clipboard copy. What Tara has stays
  searchable.
- **A source switched off** (`meetings`, `captures`, `notes`, `clipboard`, `sessions`) is neither recorded nor used:
  Ask Tara, the prep card and the memory server leave it out, and the server lists it in `left_out`.
  `connectors/calendar.json` answers to `meetings`, every other snapshot to `notes`.
- **Ignore list**: the password apps always, plus the user's apps. Nothing copied in them is kept, and Tara takes no
  picture of their windows.
- **Delete** per source removes Starnotch's own files only (the meetings and their feed, the capture queue, the
  snapshots, the resume scripts); the Jamie sync state stays, so deleted meetings don't come back by themselves.

A capture made while paused goes to the Markdown inbox only; if that fails, the queue keeps it with `"memory": false`
so it isn't lost, and Tara never reads it.
