# Starnotch meeting agent (sidecar)

A Python sidecar that gives Starnotch a memory of past meetings. While a meeting runs it notices when something
said contradicts an earlier decision, suggests a question worth asking, and records new commitments. Before a
meeting it builds a prep card: earlier decisions and open commitments, each with the quote it came from.

The Swift app starts these programs and reads their JSON lines; [PROTOCOL.md](PROTOCOL.md) has every message.

| File | What it does |
|---|---|
| `memory.py` | The meeting memory: one JSON file per meeting, in `~/Library/Application Support/Starnotch/memory/` |
| `agent.py` | The agent: utterances and commands on stdin, contradictions, questions, commitments, prep cards and answers on stdout |
| `claude.py` | The Claude call (Claude Sonnet 5.5, effort `low`, structured outputs, server-side fallback on refusals) |
| `jamie_sync.py` | Pulls meetings from [Jamie](https://meetjamie.ai) over its MCP server (OAuth login in the browser) into the memory |
| `transcribe.py` | Live transcription with Reson8 Realtime, from the microphone or an audio file streamed in real time |
| `captures.py` | Reads Starnotch's quick-capture queue, so the agent knows the user's own tasks, questions and notes |
| `feed.py` | The full text behind each notch card: a page on 127.0.0.1 (a click on the card opens it) and `Meeting-Agent.md` |
| `notch_bridge.py` | Shows the agent's events in the running Starnotch app, through its local status API (no Swift change) |
| `demo/` | Two made-up meetings, a script that replays a third one, and a macOS script that turns it into audio |

## Setup

Python 3.12 and [uv](https://docs.astral.sh/uv/):

```sh
cd agent
uv sync                 # add --extra mic for the microphone
export ANTHROPIC_API_KEY=...   # for agent.py
export RESON8_API_KEY=...      # for transcribe.py
```

Keys are read from the environment only. Without `ANTHROPIC_API_KEY` the agent runs on simple built-in rules.

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
```

## Tests

```sh
uv run pytest
```

Claude, Jamie and Reson8 are replaced by fakes: a fake Anthropic client, an in-process MCP server with Jamie's
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
