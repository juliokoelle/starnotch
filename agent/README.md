# Starnotch meeting agent (sidecar)

A Python sidecar that gives Starnotch a memory of past meetings. While a meeting runs it notices when something
said contradicts an earlier decision, suggests a question worth asking, and records new commitments. Before a
meeting it builds a prep card: earlier decisions and open commitments, each with the quote it came from.

The Swift app starts these programs and reads their JSON lines; [PROTOCOL.md](PROTOCOL.md) has every message.

| File | What it does |
|---|---|
| `memory.py` | The meeting memory: one JSON file per meeting, in `~/Library/Application Support/Starnotch/memory/` |
| `agent.py` | The agent: utterances and commands on stdin, contradictions, questions, commitments, prep cards and answers on stdout |
| `claude.py` | The Claude call: through the user's Claude Code on their Claude plan, or the Anthropic API (Claude Sonnet 5.5, effort `low`, structured outputs, server-side fallback on refusals) |
| `jamie_sync.py` | Pulls meetings from [Jamie](https://meetjamie.ai) over its MCP server (OAuth login in the browser) into the memory |
| `transcribe.py` | Live transcription with Reson8 Realtime, from the microphone or an audio file streamed in real time |
| `captures.py` | Reads Starnotch's quick-capture queue, so the agent knows the user's own tasks, questions and notes |
| `connectors.py` | Reads the snapshots other tools leave in `connectors/*.json` (a vault's tasks and today's note), for Ask Tara |
| `feed.py` | The full text behind each notch card: a page on 127.0.0.1 (a click on the card opens it) and `Meeting-Agent.md` |
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
| `auto` (default) | Claude Code if a `claude` binary is found, else the API if `ANTHROPIC_API_KEY` is set, else rules | |
| `claude-code` | The user's Claude Code CLI, headless (`claude -p`), model alias `sonnet`, effort `low` | counts against their Claude plan |
| `api` | The Anthropic API with `ANTHROPIC_API_KEY` | API credits |
| `rules` | Simple built-in rules, no model (same as `--offline`) | nothing |

The claude binary is looked up on `PATH`, then in `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`.
Claude Code never bills an API by surprise: before the first call the agent runs `claude auth status` and only goes
on with a Claude plan login (`claude.ai`, or a `claude setup-token` token); otherwise, also when it isn't signed
in, it uses rules, never the API. Every call runs without `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
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

For Ask Tara the meeting memory in the system prompt is at most 60,000 characters: the summary, decisions and
commitments of every meeting always, then notes and transcripts in equal parts per meeting (what a short one doesn't
need goes to the others); a longer transcript keeps its lines with numbers first, then its earliest, with `…` for the
gaps. The up to six transcript lines that share the most words with the question come along in the prompt, so the
parts the excerpt left out still count.

The live analysis is the cost driver (one call per batch while people talk), so it sends less, and less often. Its
system prompt carries only the facts of every meeting (summary, decisions, commitments with their quotes) and the
quick captures: about 1,100 characters of facts for the demo meetings; for a memory at the full 60,000-character
budget the whole system prompt is about 9,600 characters instead of 59,000. The transcripts come per batch: for each
new utterance up to eight earlier lines that share its words, stop words left out, numbers counted double, and a
figure in the same unit the more the closer it is ("25 Euro" finds the "30 Euro" decision before "4 Euro" support
costs); at most 16 lines and 4,000 characters per batch. Notes stay out: the agent only reports a contradiction whose
earlier words it finds in a transcript, decision or commitment, so one quoted from notes alone was dropped before too.
And Claude is asked at most once every 25 seconds (`STARNOTCH_MEETING_GAP` or `--meeting-gap`; `0` asks for every
batch): what is said in between waits and goes with the next call, a quiet stretch sends what waits once the gap is
over, and saving or ending the meeting analyses the rest first. The rules, Ask Tara and captured questions aren't
held back. Both system prompts only change when the memory does, so they stay cacheable.

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

Claude, Jamie and Reson8 are replaced by fakes: a fake Anthropic client, a fake `claude` binary on `PATH`, an in-process MCP server with Jamie's
tool names, and a local WebSocket server.

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
