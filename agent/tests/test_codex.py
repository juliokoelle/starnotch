"""claude.Codex against a fake codex binary: structured answers on the user's ChatGPT plan, nothing of their setup."""

import json
import stat

import pytest

import claude

FAKE = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
prompt = sys.stdin.read()
schema = json.load(open(args[args.index("--output-schema") + 1]))
out = args[args.index("-o") + 1]
json.dump({"args": args, "prompt": prompt, "schema": schema, "env": dict(os.environ)}, open(os.environ["FAKE_SEEN"], "w"))
mode = os.environ.get("FAKE_MODE", "ok")
print(json.dumps({"type": "thread.started", "thread_id": "t"}))
if mode == "ok":
    open(out, "w").write(json.dumps({"blocks": []}))
    print(json.dumps({"type": "turn.completed", "usage": {"input_tokens": 19000, "cached_input_tokens": 3000,
                                                          "output_tokens": 120, "reasoning_output_tokens": 30}}))
elif mode == "login":
    print(json.dumps({"type": "turn.failed", "error": {"message": "401 Unauthorized: please run codex login"}}))
    sys.exit(1)
else:
    print(json.dumps({"type": "turn.failed", "error": {"message": "rate limited"}}))
    sys.exit(1)
'''

SCHEMA = {"type": "object", "properties": {"blocks": {"type": "array", "items": {
    "type": "object", "properties": {"title": {"type": "string"}, "open": {"type": "array", "items": {"type": "string"}}},
    "required": ["title"]}}}, "required": ["blocks"]}


@pytest.fixture
def codex(tmp_path, monkeypatch):
    binary = tmp_path / "codex"
    binary.write_text(FAKE, encoding="utf-8")
    binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setenv("FAKE_SEEN", str(tmp_path / "seen.json"))
    monkeypatch.setenv("OPENAI_API_KEY", "sk-should-not-pass")
    model = claude.Codex(binary=str(binary), folder=tmp_path / "brain")
    return model, lambda: json.loads((tmp_path / "seen.json").read_text())


def test_a_bare_read_only_session_on_the_plan(codex):
    model, seen = codex
    assert model.json("SYSTEM", "USER", SCHEMA) == {"blocks": []}
    call = seen()
    args = call["args"]
    for flag in ("--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--json"):
        assert flag in args
    assert args[args.index("-s") + 1] == "read-only" and "project_doc_max_bytes=0" in args
    assert call["prompt"].startswith("SYSTEM") and "USER" in call["prompt"]
    # OpenAI's strict format: every object closed and every property required.
    item = call["schema"]["properties"]["blocks"]["items"]
    assert call["schema"]["additionalProperties"] is False and item["additionalProperties"] is False
    assert item["required"] == ["title", "open"]
    # Never the API key: the plan pays, not a bill.
    assert "OPENAI_API_KEY" not in call["env"]
    usage = model.last_usage
    assert usage["model"] == "codex" and usage["input_tokens"] == 16000 and usage["cache_read_input_tokens"] == 3000
    assert usage["output_tokens"] == 150 and usage["cost_usd"] is None
    assert not list((model.folder).glob("starnotch-codex-*"))  # its files are gone again


def test_errors(codex, monkeypatch):
    model, _ = codex
    monkeypatch.setenv("FAKE_MODE", "login")
    with pytest.raises(claude.CodexUnavailable):
        model.json("S", "U", SCHEMA)
    monkeypatch.setenv("FAKE_MODE", "busy")
    with pytest.raises(claude.ClaudeCodeError):
        model.json("S", "U", SCHEMA)


def test_the_brain_can_be_codex(monkeypatch, tmp_path):
    monkeypatch.setattr(claude, "find_codex", lambda: None)
    brain, model, why = claude.make_brain("codex")
    assert brain == "rules" and model is None and "Codex" in why
    binary = tmp_path / "codex"
    binary.write_text("#!/bin/sh\n", encoding="utf-8")
    binary.chmod(0o755)
    monkeypatch.setattr(claude, "find_codex", lambda: str(binary))
    brain, model, why = claude.make_brain("codex")
    assert brain == "codex" and isinstance(model, claude.Codex) and why is None
