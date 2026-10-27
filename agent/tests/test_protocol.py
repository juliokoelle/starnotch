"""The stdin/stdout contract from PROTOCOL.md, end to end through agent.main()."""

import io
import json
import subprocess
import sys
from pathlib import Path

import agent as agent_module
from agent import Agent, make_emit, run
from memory import Memory

ROOT = Path(__file__).resolve().parent.parent


def drive(memory_dir, lines, llm=None):
    out = io.StringIO()
    agent = Agent(Memory(memory_dir), llm, make_emit(out), agent_module.dt.date(2026, 10, 26))
    run(agent, io.StringIO("".join(json.dumps(x) + "\n" if not isinstance(x, str) else x for x in lines)))
    return [json.loads(line) for line in out.getvalue().splitlines()]


def test_every_line_is_one_json_object(memory_dir):
    out = drive(memory_dir, [
        {"cmd": "prep", "participants": ["Max"]},
        {"type": "utterance", "speaker": "Max", "text": "Wir waren doch bei 25 Euro", "t": 1},
        "kein json\n",
        "\n",
        "[1, 2]\n",
        {"cmd": "fliegen"},
        {"type": "status", "state": "connected"},
        {"cmd": "ask", "question": "Preis?", "id": 3},
    ])
    types = [o["type"] for o in out]
    assert types == ["prep", "contradiction", "question", "error", "error", "error", "answer"]
    assert out[-1]["reply_to"] == 3


def test_contradiction_fields_for_swift(memory_dir):
    out = drive(memory_dir, [{"type": "utterance", "speaker": "Max", "text": "Wir waren doch bei 25 Euro", "t": 1}])
    c = out[0]
    assert set(c) == {"type", "now", "speaker", "t", "before", "note"}
    assert set(c["before"]) == {"quote", "speaker", "meeting", "meeting_id", "date"}


def test_commitment_and_question_fields(memory_dir):
    out = drive(memory_dir, [
        {"type": "utterance", "speaker": "Lisa", "text": "Ich buche bis Freitag den Bus."},
        {"type": "utterance", "speaker": "Max", "text": "Hallo"},
    ])
    assert set(out[0]) == {"type", "who", "what", "due", "quote"}
    assert out[0]["due"] == "2026-10-30"
    assert set(out[1]) == {"type", "text", "reason"}


def test_commands_wait_for_earlier_utterances(memory_dir):
    out = drive(memory_dir, [
        {"type": "utterance", "speaker": "Lisa", "text": "Ich buche bis Freitag den Bus."},
        {"cmd": "save", "title": "X"},
        {"cmd": "reset"},
        {"cmd": "reload", "id": "r"},
    ])
    assert [o["type"] for o in out] == ["commitment", "status", "status", "status"]
    assert out[1]["state"] == "saved"
    assert out[3] == {"type": "status", "state": "reloaded", "meetings": 3, "reply_to": "r"}


def test_cli_offline_demo_meetings():
    """The real process: ready first, then answers; exit 0 when stdin closes."""
    proc = subprocess.run(
        [sys.executable, "agent.py", "--offline", "--memory", "demo/meetings", "--today", "2026-10-26"],
        input=json.dumps({"cmd": "prep", "participants": ["Max", "Lisa"]}) + "\n",
        capture_output=True, text=True, cwd=ROOT, timeout=30,
    )
    assert proc.returncode == 0, proc.stderr
    lines = [json.loads(line) for line in proc.stdout.splitlines()]
    assert lines[0]["type"] == "ready" and lines[0]["meetings"] == 2 and lines[0]["model"] is None
    assert lines[0]["brain"] == "rules"
    assert lines[1]["type"] == "prep"
