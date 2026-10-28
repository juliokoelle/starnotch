"""Apple's on-device model as Tara's free brain: the helper call (claude.AppleModel against a fake helper), the
retrieval that fits its 4,096-token window, the locale instruction, pictures, and the speaker-prefix source check."""

import datetime as dt
import json
import os
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

import claude
from agent import (APPLE_ANSWER, APPLE_CHARS_PER_TOKEN, APPLE_WINDOW, ASK_SCHEMA, NO_PICTURE, Agent)
from claude import AppleModel, AppleModelError, AppleModelUnavailable, make_brain
from memory import Line, Meeting, Memory

ROOT = Path(__file__).resolve().parent.parent
TODAY = dt.date(2026, 10, 26)
WINDOW_CHARS = (APPLE_WINDOW - APPLE_ANSWER) * APPLE_CHARS_PER_TOKEN
SCHEMA = {"type": "object", "properties": {"answer": {"type": "string"}}, "required": ["answer"]}


class FakeLLM:
    def __init__(self, *answers):
        self.answers = list(answers)
        self.calls = []

    def json(self, system, user, schema, max_tokens=4000, **extra):
        self.calls.append(SimpleNamespace(system=system, user=user, schema=schema, extra=extra))
        answer = self.answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer


def on_device(memory_dir, llm, tmp_path=None, captures=None):
    out = []
    agent = Agent(Memory(memory_dir), llm, out.append, TODAY, captures, None, brain="apple")
    return agent, out


def sent(call):
    """Everything that goes into the window: instructions, prompt and schema."""
    return len(call.system) + len(call.user) + len(json.dumps(call.schema))


# The helper call


def test_request_format_and_usage(apple):
    model = AppleModel()
    assert model.model == "apple-on-device"
    assert model.json("Be brief.", "Preis?", SCHEMA, 2000, locale="de_DE") == {"answer": "30 Euro.", "sources": []}
    request = apple()[0]
    assert request == {"instructions": "Be brief.", "prompt": "Preis?", "schema": SCHEMA, "locale": "de_DE"}
    usage = model.last_usage
    assert usage["model"] == "apple-on-device" and usage["cost_usd"] == 0.0
    assert usage["input_tokens"] == claude.estimate_tokens("Be brief." + "Preis?" + json.dumps(SCHEMA)) > 0
    assert usage["output_tokens"] > 0 and usage["cache_read_input_tokens"] == 0 and usage["duration_ms"] >= 0


def test_errors(apple, monkeypatch):
    model = AppleModel()
    for kind in ("rateLimited", "contextWindowExceeded", "unsupportedLanguage", "other"):
        monkeypatch.setenv("FAKE_APPLE", kind)
        with pytest.raises(AppleModelError) as caught:
            model.json("s", "u", SCHEMA)
        assert caught.value.kind == kind and not isinstance(caught.value, AppleModelUnavailable)
        assert model.last_usage["cost_usd"] == 0.0  # the call ran, so the ledger counts it
    monkeypatch.setenv("FAKE_APPLE", "guardrail")
    assert model.json("s", "u", SCHEMA) is None  # declined, like a refusal
    monkeypatch.setenv("FAKE_APPLE", "unavailable")
    with pytest.raises(AppleModelUnavailable) as caught:
        model.json("s", "u", SCHEMA)
    assert caught.value.kind == "modelNotReady"
    monkeypatch.setenv("FAKE_APPLE", "crash")
    with pytest.raises(AppleModelError, match="exited 2: boom"):
        model.json("s", "u", SCHEMA)
    assert model.last_usage is None
    monkeypatch.setenv("FAKE_APPLE", "slow")
    with pytest.raises(AppleModelError, match="longer than 0.5 s"):
        AppleModel(timeout=0.5).json("s", "u", SCHEMA)


def test_status_decides_whether_apple_can_think(apple, monkeypatch):
    assert claude.apple_status() == {"available": True}
    for mode, reason in (("notEnabled", "appleIntelligenceNotEnabled"), ("downloading", "modelNotReady"),
                         ("unsupported", "deviceNotEligible")):
        monkeypatch.setenv("FAKE_APPLE", mode)
        with pytest.raises(AppleModelUnavailable) as caught:
            AppleModel()
        assert caught.value.kind == reason
        brain, llm, why = make_brain("apple")
        assert (brain, llm) == ("rules", None) and "using rules" in why
    monkeypatch.delenv("STARNOTCH_APPLE_HELPER")
    assert claude.apple_status()["reason"] == "noHelper"


def test_cli_answers_with_apple_and_records_it_free(apple, tmp_path):
    proc = subprocess.run(
        [sys.executable, "agent.py", "--memory", "demo/meetings", "--today", "2026-10-26", "--connectors", ""],
        input=json.dumps({"cmd": "ask", "question": "Welchen Preis haben wir beschlossen?", "id": 1}) + "\n",
        capture_output=True, text=True, cwd=ROOT, timeout=30,
        env={**os.environ, "HOME": str(tmp_path), "STARNOTCH_BRAIN": "apple", "PATH": "/usr/bin:/bin"},
    )
    assert proc.returncode == 0, proc.stderr
    lines = [json.loads(line) for line in proc.stdout.splitlines()]
    assert lines[0]["type"] == "ready" and lines[0]["brain"] == "apple" and lines[0]["model"] == "apple-on-device"
    assert lines[1]["type"] == "answer" and lines[1]["brain"] == "apple" and lines[1]["text"] == "30 Euro."
    request = apple()[0]
    assert "Kickoff Lumen-Abo" in request["prompt"] and request["locale"] == "de_DE"
    ledger = tmp_path / "Library" / "Application Support" / "Starnotch" / "usage.jsonl"
    entry = json.loads(ledger.read_text(encoding="utf-8"))
    assert entry["feature"] == "ask" and entry["brain"] == "apple" and entry["cost_usd"] == 0.0


# Fitting the window


def big_memory(folder, meetings=60):
    """Far more than 4,096 tokens: long meetings about other things, and the demo's two."""
    memory = Memory(folder)
    for n in range(meetings):
        memory.save(Meeting(
            id=f"2026-09-{n % 28 + 1:02d}-runde-{n}", title=f"Team-Runde {n}", date=f"2026-09-{n % 28 + 1:02d}",
            participants=["Anna", "Ben"], summary=f"Laufende Themen der Runde {n}, Budget und Reisen.",
            transcript=[Line("Anna" if i % 2 else "Ben", f"Punkt {i} der Runde {n}: Reisekosten, Schulungen und die "
                             f"Kundenliste für Hamburg, Wien und Zürich, nichts zum Abo.", i * 10.0)
                        for i in range(30)]))
    return Memory(folder)


def test_retrieval_fits_the_window_and_finds_the_line(memory_dir):
    memory = big_memory(memory_dir)
    assert len(memory.as_context()) > 3 * WINDOW_CHARS  # the whole memory would never fit
    llm = FakeLLM({"answer": "Donnerstag nächste Woche im Raum Ahorn.", "sources": [
        {"kind": "meeting", "id": "2026-10-19-weekly", "quote": "Lisa: Der Raum ist gebucht, Donnerstag nächste Woche, Raum Ahorn."}]})
    agent = Agent(memory, llm, [].append, TODAY, None, None, brain="apple")
    answer = agent.ask("Wann und wo findet der Launch-Workshop statt?", history=[
        {"question": "Wer hat den Raum gebucht?", "answer": "Lisa hat den Raum gebucht."}])
    call = llm.calls[0]
    assert sent(call) <= WINDOW_CHARS
    assert "Lisa: Der Raum ist gebucht, Donnerstag nächste Woche, Raum Ahorn." in call.user  # via the follow-up's words
    assert "Lisa: Ich buche den Raum für den Launch-Workshop." in call.user
    assert call.user.index("# Material") < call.user.index("# Question now\nWann und wo")
    assert answer["sources"][0]["quote"] == "Der Raum ist gebucht, Donnerstag nächste Woche, Raum Ahorn."


def test_the_schema_cites_only_what_was_sent(memory_dir):
    llm = FakeLLM({"answer": "30 Euro.", "sources": []}, {"answer": "Weiß ich nicht.", "sources": []})
    agent, _ = on_device(memory_dir, llm)
    agent.ask("Welchen Preis haben wir für das Lumen-Abo beschlossen?")
    schema = llm.calls[0].schema
    item = schema["properties"]["sources"]["items"]["properties"]
    assert item["id"]["enum"] and all(f"id={ref}" in llm.calls[0].user for ref in item["id"]["enum"])
    assert item["kind"]["enum"] == ["meeting"] and schema["properties"]["sources"]["maxItems"] == 3
    assert ASK_SCHEMA["properties"]["sources"]["items"]["properties"]["id"] == {"type": "string"}  # left untouched
    agent.ask("Wie heißt der Hund vom Nachbarn?")
    empty = llm.calls[1]
    assert "(Nothing in the meetings, captures or notes matches this question.)" in empty.user
    assert empty.schema["properties"]["sources"]["maxItems"] == 0


def test_captures_and_notes_that_match_come_along(memory_dir, tmp_path):
    import connectors

    queue = tmp_path / "capture-queue.jsonl"
    queue.write_text(json.dumps({"id": "c7", "created": "2026-10-24T09:00:00Z", "route": "task",
                                 "text": "Workshop-Agenda an Lisa schicken"}) + "\n", encoding="utf-8")
    folder = tmp_path / "connectors"
    folder.mkdir()
    (folder / "vault.json").write_text(json.dumps({"name": "vault", "tasks": [
        {"text": "Workshop-Material drucken", "content": "Flipchart und Stifte"}, {"text": "Steuer"}]}), encoding="utf-8")
    llm = FakeLLM({"answer": "Agenda und Material.", "sources": [{"kind": "capture", "id": "c7", "quote": "Agenda"}]})
    agent = Agent(Memory(memory_dir), llm, [].append, TODAY, queue, folder, brain="apple")
    answer = agent.ask("Was steht für den Workshop noch an?")
    call = llm.calls[0]
    assert "- [c7] 2026-10-24 task: Workshop-Agenda an Lisa schicken" in call.user
    assert "- [vault:0] tasks: Workshop-Material drucken: Flipchart und Stifte" in call.user and "Steuer" not in call.user
    ids = call.schema["properties"]["sources"]["items"]["properties"]["id"]["enum"]
    assert "c7" in ids and "vault:0" in ids and "vault:1" not in ids
    assert answer["sources"][0]["kind"] == "capture"
    assert connectors.read(folder)[1].title == "Steuer"


def test_locale_instruction_follows_the_question(memory_dir):
    llm = FakeLLM({"answer": "30 Euro.", "sources": []}, {"answer": "30 euros.", "sources": []})
    agent, _ = on_device(memory_dir, llm)
    agent.ask("Welchen Preis haben wir beschlossen?")
    agent.ask("Which price did we decide on?")
    german, english = llm.calls
    assert german.system.startswith("The person's locale is de_DE.\n") and german.system.endswith("You MUST respond in German.")
    assert german.extra == {"locale": "de_DE"}
    assert "locale is" not in english.system and english.system.endswith("You MUST respond in English.")
    assert english.extra == {"locale": "en_US"}


def test_follow_up_history_is_short(memory_dir):
    llm = FakeLLM({"answer": "ok", "sources": []})
    agent, _ = on_device(memory_dir, llm)
    history = [{"question": f"Frage {n} " + "x" * 500, "answer": f"Antwort {n}"} for n in range(6)]
    agent.ask("Und wer?", history=history)
    prompt = llm.calls[0].user
    assert "Frage 3" not in prompt and "User: Frage 4" in prompt and "User: Frage 5" in prompt
    assert "x" * 301 not in prompt


def test_an_overflow_is_tried_again_with_half_the_material(memory_dir):
    memory = big_memory(memory_dir)
    llm = FakeLLM(AppleModelError("contextWindowExceeded", "too long"), {"answer": "30 Euro.", "sources": []})
    out = []
    agent = Agent(memory, llm, out.append, TODAY, brain="apple")
    assert agent.ask("Was ist mit Budget und Reisen?")["text"] == "30 Euro."
    first, second = llm.calls
    assert 0.9 * WINDOW_CHARS < sent(first) <= WINDOW_CHARS  # every summary matches: the budget is full
    assert len(second.user) < len(first.user) * 0.7 and not out  # no offline status: it answered


def test_a_picture_is_not_sent_and_the_answer_says_so(memory_dir, tmp_path):
    shot = tmp_path / "shot.png"
    shot.write_bytes(b"png")
    llm = FakeLLM({"answer": "Der Preis ist 30 Euro.", "sources": []})
    agent, _ = on_device(memory_dir, llm)
    answer = agent.ask("Welcher Preis steht hier?", image=str(shot))
    call = llm.calls[0]
    assert "images" not in call.extra and "you cannot see pictures" in call.system
    assert answer["text"] == NO_PICTURE["de"] + "Der Preis ist 30 Euro."


def test_the_live_meeting_runs_on_rules(memory_dir):
    llm = FakeLLM()
    agent, out = on_device(memory_dir, llm)
    agent.gap = 0
    agent.handle({"type": "utterance", "speaker": "Max", "text": "Wir waren doch bei 25 Euro im Monat, oder?"})
    assert llm.calls == [] and out[0]["type"] == "contradiction"


def test_lost_availability_switches_to_rules(memory_dir):
    llm = FakeLLM(AppleModelUnavailable("appleIntelligenceNotEnabled", "Apple Intelligence isn't available: off"))
    agent, out = on_device(memory_dir, llm)
    agent.handle({"cmd": "ask", "question": "Welchen Preis haben wir beschlossen?"})
    assert agent.llm is None
    assert out[0] == {"type": "status", "state": "offline",
                      "message": "Apple Intelligence unavailable, using rules: Apple Intelligence isn't available: off"}
    assert out[1]["type"] == "answer" and out[1]["brain"] == "rules"


# The source check, for every brain


@pytest.mark.parametrize("brain", ["apple", "claude-code"])
def test_a_quote_with_its_speaker_still_counts(memory_dir, brain):
    llm = FakeLLM({"answer": "Super.", "sources": [
        {"kind": "meeting", "id": "2026-10-12-kickoff", "quote": "Jonas: Super."},
        {"kind": "meeting", "id": "2026-10-19-weekly", "quote": '"Max: Noch nicht, mir fehlen noch die Supportkosten."'},
        {"kind": "meeting", "id": "2026-10-12-kickoff", "quote": "Lisa:"},
    ]})
    agent = Agent(Memory(memory_dir), llm, [].append, TODAY, brain=brain)
    sources = agent.ask("Was hat Jonas gesagt?")["sources"]
    assert [(s["speaker"], s["quote"]) for s in sources] == [
        ("Jonas", "Super. Nächste Woche gleiche Zeit, dann schauen wir auf den Stand."),
        ("Max", "Noch nicht, mir fehlen noch die Supportkosten. Die kommen diese Woche."),
    ]


def test_a_decision_quote_with_its_speaker_still_counts(memory_dir):
    memory = Memory(memory_dir)
    memory.get("2026-10-12-kickoff").transcript = []  # only the decision holds the words now
    agent = Agent(memory, None, [].append, TODAY)
    found = agent._locate("Jonas: Das Lumen-Abo kostet 30 Euro im Monat", "2026-10-12-kickoff")
    assert found and found[2] == "Jonas" and found[1].startswith("Okay, dann entscheiden wir")
