"""claude.ClaudeCode against a fake claude binary on PATH, and the STARNOTCH_BRAIN choice."""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

import claude
from agent import Agent
from claude import ClaudeCode, ClaudeCodeError, ClaudeCodeUnavailable, find_claude, make_brain
from memory import Memory

ROOT = Path(__file__).resolve().parent.parent

# Plays `claude auth status --json` and `claude -p`. FAKE_CLAUDE picks the act, FAKE_CLAUDE_LOG gets what it saw.
FAKE = f"""#!{sys.executable}
import json, os, sys, time
mode = os.environ.get("FAKE_CLAUDE", "ok")
args = sys.argv[1:]
if args[:2] == ["auth", "status"]:
    status = {{"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty"}}
    if mode == "logged-out":
        status = {{"loggedIn": False, "authMethod": "none", "apiProvider": "firstParty"}}
    if mode == "api-key":
        status = {{"loggedIn": True, "authMethod": "api_key", "apiKeySource": "ANTHROPIC_API_KEY"}}
    print(json.dumps(status))
    sys.exit(0 if status["loggedIn"] else 1)
system = open(args[args.index("--system-prompt-file") + 1], encoding="utf-8").read()
seen = {{"args": args, "env": dict(os.environ), "cwd": os.getcwd(), "stdin": sys.stdin.read(), "system": system}}
with open(os.environ["FAKE_CLAUDE_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps(seen) + "\\n")
result = {{"type": "result", "subtype": "success", "is_error": False, "stop_reason": "tool_use",
          "result": '{{"a": 1}}', "structured_output": {{"a": 1}}, "usage": {{"input_tokens": 900}}}}
if mode == "slow":
    time.sleep(5)
elif mode == "text-only":
    del result["structured_output"]
elif mode == "refusal":
    result.update(stop_reason="refusal", result="", structured_output=None)
elif mode == "not-logged-in":
    result.update(is_error=True, result="Not logged in · Please run /login", structured_output=None)
elif mode == "overloaded":
    result.update(is_error=True, result="API Error: 529 overloaded", api_error_status=529, structured_output=None)
elif mode == "crash":
    print("boom", file=sys.stderr)
    sys.exit(2)
elif mode == "recorded":  # a real result Claude Code printed, from tests/fixtures
    print(open(os.environ["FAKE_CLAUDE_OUTPUT"], encoding="utf-8").read())
    sys.exit(0)
print(json.dumps(result))
sys.exit(1 if result["is_error"] else 0)
"""


@pytest.fixture
def fake(tmp_path, monkeypatch):
    """A fake claude first on PATH; returns a reader for the calls it saw."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    binary = bin_dir / "claude"
    binary.write_text(FAKE, encoding="utf-8")
    binary.chmod(0o755)
    log = tmp_path / "calls.jsonl"
    monkeypatch.setenv("PATH", f"{bin_dir}:/usr/bin:/bin")
    monkeypatch.setenv("FAKE_CLAUDE_LOG", str(log))
    monkeypatch.setattr(claude, "BRAIN_FOLDER", tmp_path / "brain")
    monkeypatch.setattr(claude, "CLAUDE_BINARIES", ())
    for name in ("STARNOTCH_BRAIN", "ANTHROPIC_API_KEY"):
        monkeypatch.delenv(name, raising=False)

    def calls():
        return [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()] if log.exists() else []

    calls.binary = str(binary)
    return calls


def code(tmp_path, **kw):
    return ClaudeCode(folder=tmp_path / "brain", **kw)


def test_args_keep_the_context_small(fake, tmp_path):
    schema = {"type": "object", "properties": {"a": {"type": "integer"}}}
    assert code(tmp_path).json("Gedächtnis: 30 Euro", "Welcher Preis?", schema) == {"a": 1}
    seen = fake()[0]
    args = seen["args"]
    assert args[0] == "-p" and seen["stdin"] == "Welcher Preis?"
    assert seen["system"] == "Gedächtnis: 30 Euro"  # through a file, not argv: the memory can be long
    pairs = dict(zip(args, args[1:]))
    assert pairs["--output-format"] == "json" and json.loads(pairs["--json-schema"]) == schema
    assert pairs["--model"] == "sonnet" and pairs["--effort"] == "low"
    assert pairs["--tools"] == "" and pairs["--setting-sources"] == ""
    assert json.loads(pairs["--mcp-config"]) == {"mcpServers": {}}
    assert {"--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands"} <= set(args)
    assert "--bare" not in args  # --bare reads only ANTHROPIC_API_KEY, never the plan login
    assert Path(seen["cwd"]).resolve() == (tmp_path / "brain").resolve()
    assert list((tmp_path / "brain").iterdir()) == []  # stays empty: no CLAUDE.md, no leftovers


def test_billing_env_is_stripped(fake, tmp_path, monkeypatch):
    for name in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK"):
        monkeypatch.setenv(name, "x")
    monkeypatch.setenv("HOME_HINT", "kept")
    code(tmp_path).json("s", "u", {})
    env = fake()[0]["env"]
    assert not {"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK"} & set(env)
    assert env["HOME_HINT"] == "kept"


def test_answer_parsing(fake, tmp_path, monkeypatch):
    brain = code(tmp_path)
    monkeypatch.setenv("FAKE_CLAUDE", "text-only")
    assert brain.json("s", "u", {}) == {"a": 1}  # older CLIs: the JSON is in result
    monkeypatch.setenv("FAKE_CLAUDE", "refusal")
    assert brain.json("s", "u", {}) is None
    monkeypatch.setenv("FAKE_CLAUDE", "overloaded")
    with pytest.raises(ClaudeCodeError) as error:
        brain.json("s", "u", {})
    assert not isinstance(error.value, ClaudeCodeUnavailable)  # the next call may work
    monkeypatch.setenv("FAKE_CLAUDE", "crash")
    with pytest.raises(ClaudeCodeError, match="boom"):
        brain.json("s", "u", {})
    monkeypatch.setenv("FAKE_CLAUDE", "not-logged-in")
    with pytest.raises(ClaudeCodeUnavailable):
        brain.json("s", "u", {})


def test_timeout(fake, tmp_path, monkeypatch):
    monkeypatch.setenv("FAKE_CLAUDE", "slow")
    with pytest.raises(ClaudeCodeError) as error:
        code(tmp_path, timeout=0.5).json("s", "u", {})
    assert str(error.value) == "Claude Code took longer than 0.5 s"  # not the command line with the whole schema
    assert not isinstance(error.value, ClaudeCodeUnavailable)
    assert list((tmp_path / "brain").glob("starnotch-system-*")) == []


def test_retries_are_capped(fake, tmp_path, monkeypatch):
    monkeypatch.setenv("CLAUDE_CODE_MAX_RETRIES", "10")
    code(tmp_path).json("s", "u", {})
    assert fake()[0]["env"]["CLAUDE_CODE_MAX_RETRIES"] == "1"  # an overloaded API fails in seconds, not minutes


def test_leftover_system_prompts_are_swept(fake, tmp_path):
    folder = tmp_path / "brain"
    folder.mkdir()
    old, fresh = folder / "starnotch-system-old.md", folder / "starnotch-system-fresh.md"
    old.write_text("private transcript")
    fresh.write_text("a call running in another agent")
    os.utime(old, (1_000_000, 1_000_000))
    code(tmp_path)
    assert not old.exists() and fresh.exists()


def test_login_is_checked_up_front(fake, tmp_path, monkeypatch):
    monkeypatch.setenv("FAKE_CLAUDE", "logged-out")
    with pytest.raises(ClaudeCodeUnavailable, match="signed in"):
        code(tmp_path)
    monkeypatch.setenv("FAKE_CLAUDE", "api-key")
    with pytest.raises(ClaudeCodeUnavailable, match="api_key"):
        code(tmp_path)
    assert fake() == []  # no thinking call either way


def test_find_claude(fake, tmp_path, monkeypatch):
    assert find_claude() == fake.binary
    monkeypatch.setenv("PATH", "/usr/bin:/bin")
    assert find_claude() is None
    monkeypatch.setattr(claude, "CLAUDE_BINARIES", ("/nowhere/claude", fake.binary))
    assert find_claude() == fake.binary  # the app's PATH may lack ~/.local/bin


def test_brain_choice(fake, tmp_path, monkeypatch):
    brain, llm, why = make_brain()
    assert brain == "claude-code" and isinstance(llm, ClaudeCode) and llm.model == "sonnet" and why is None
    assert make_brain("rules") == ("rules", None, None)
    assert make_brain("Telepathie")[0] == "rules"

    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    assert make_brain()[0] == "claude-code"  # the plan wins over a key
    assert make_brain("api")[0] == "api"
    monkeypatch.setenv("FAKE_CLAUDE", "logged-out")
    brain, llm, why = make_brain()
    assert (brain, llm) == ("rules", None) and "claude auth login" in why  # never the API by surprise

    monkeypatch.setenv("PATH", "/usr/bin:/bin")
    assert make_brain()[0] == "api"
    monkeypatch.delenv("ANTHROPIC_API_KEY")
    assert make_brain() == ("rules", None, None)
    assert make_brain("claude-code")[0] == "rules"


def test_agent_falls_back_to_rules(fake, tmp_path, memory_dir, monkeypatch):
    out = []
    agent = Agent(Memory(memory_dir), code(tmp_path, timeout=0.5), out.append)
    monkeypatch.setenv("FAKE_CLAUDE", "slow")
    agent.handle({"type": "utterance", "speaker": "Max", "text": "Wir waren doch bei 25 Euro im Monat, oder?"})
    assert out[0]["state"] == "offline" and out[1]["type"] == "contradiction"
    assert out[0]["message"] == "Claude unavailable, using rules: Claude Code took longer than 0.5 s"
    assert agent.llm is not None  # a slow answer isn't a lost login
    agent.handle({"type": "utterance", "speaker": "Max", "text": "Weiter"})
    assert len(fake()) == 1  # resting on the rules: the next batch doesn't wait for Claude again
    agent.resting_until = 0
    monkeypatch.setenv("FAKE_CLAUDE", "not-logged-in")
    agent.handle({"type": "utterance", "speaker": "Max", "text": "Weiter"})
    assert agent.llm is None


def test_cli_ready_names_the_brain(fake, tmp_path):
    proc = subprocess.run(
        [sys.executable, "agent.py", "--memory", "demo/meetings", "--today", "2026-10-26"],
        input=json.dumps({"cmd": "ask", "question": "Preis?", "id": 1}) + "\n",
        capture_output=True, text=True, cwd=ROOT, timeout=30,
        env={**os.environ, "HOME": str(tmp_path)},  # its brain folder lands in tmp_path, not the real Library
    )
    assert proc.returncode == 0, proc.stderr
    lines = [json.loads(line) for line in proc.stdout.splitlines()]
    assert lines[0]["type"] == "ready" and lines[0]["brain"] == "claude-code" and lines[0]["model"] == "sonnet"
    assert lines[1]["type"] == "answer" and lines[1]["reply_to"] == 1
    assert "Kickoff Lumen-Abo" in fake()[0]["system"]
    ledger = tmp_path / "Library" / "Application Support" / "Starnotch" / "usage.jsonl"
    entry = json.loads(ledger.read_text(encoding="utf-8"))  # one line: the question's call
    assert entry["feature"] == "ask" and entry["brain"] == "claude-code" and entry["input_tokens"] == 900


def test_usage_of_a_real_result(fake, tmp_path, monkeypatch):
    monkeypatch.setenv("FAKE_CLAUDE", "recorded")
    monkeypatch.setenv("FAKE_CLAUDE_OUTPUT", str(ROOT / "tests" / "fixtures" / "claude-code-ask-cached.json"))
    brain = code(tmp_path)
    answer = brain.json("s", "u", {"type": "object"})
    assert answer["answer"].startswith("Max schuldet dem Team noch die Margenzahlen")
    assert brain.last_usage == {"model": "claude-sonnet-5-5", "input_tokens": 2, "cache_creation_input_tokens": 1115,
                                "cache_read_input_tokens": 32025, "output_tokens": 308, "duration_ms": 4456,
                                "cost_usd": 0.0107465}
    monkeypatch.setenv("FAKE_CLAUDE", "crash")
    with pytest.raises(ClaudeCodeError):
        brain.json("s", "u", {})
    assert brain.last_usage is None  # nothing known about a call that printed no result


def test_a_screenshot_is_read_from_the_brain_folder(fake, tmp_path):
    shot = tmp_path / "window.png"
    shot.write_bytes(b"\x89PNG fake")
    assert code(tmp_path).json("system", "What is this?", {"type": "object"}, images=[shot]) == {"a": 1}
    seen = fake()[0]
    args = seen["args"]
    first = seen["stdin"].splitlines()[0]
    name = first.split("./")[1].split(" ")[0]
    assert args[args.index("--tools") + 1] == "Read" and args[args.index("--allowedTools") + 1] == f"Read(./{name})"
    assert first.startswith("Screenshot of the window the user asks about: ./starnotch-image-") and first.endswith(".png (read it first)")
    assert seen["stdin"].endswith("\n\nWhat is this?")
    assert not list((tmp_path / "brain").glob("starnotch-image-*"))  # deleted after the call


def test_api_sends_a_screenshot_as_an_image_block(tmp_path):
    from types import SimpleNamespace

    shot = tmp_path / "window.jpg"
    shot.write_bytes(b"jpeg")
    requests = []
    response = SimpleNamespace(stop_reason="end_turn", content=[SimpleNamespace(type="text", text='{"a": 1}')])
    client = SimpleNamespace(beta=SimpleNamespace(messages=SimpleNamespace(
        create=lambda **request: requests.append(request) or response)))
    assert claude.Claude(client=client).json("s", "What is this?", {}, images=[shot]) == {"a": 1}
    content = requests[0]["messages"][0]["content"]
    assert content[0] == {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "anBlZw=="}}
    assert content[1] == {"type": "text", "text": "What is this?"}
