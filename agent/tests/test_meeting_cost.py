"""What a meeting costs: Claude at most once per meeting gap, and a system prompt that the cache keeps."""

import datetime as dt
import io
import json
import threading

import pytest
from types import SimpleNamespace

from agent import MEETING_GAP, SYSTEM, Agent, run
from memory import Line, Meeting, Memory

TODAY = dt.date(2026, 10, 26)
QUIET = {"contradictions": [], "commitments": [], "questions": []}


class FakeLLM:
    def __init__(self, *answers):
        self.answers = list(answers)
        self.calls = []

    def json(self, system, user, schema, max_tokens=4000):
        self.calls.append(SimpleNamespace(system=system, user=user, schema=schema))
        answer = self.answers.pop(0) if self.answers else (
            QUIET if "contradictions" in schema["properties"] else {"answer": "30 Euro.", "sources": []})
        if isinstance(answer, Exception):
            raise answer
        return answer


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


def make(memory, llm, gap=MEETING_GAP):
    out, clock = [], Clock()
    folder = memory if isinstance(memory, Memory) else Memory(memory)
    return Agent(folder, llm, out.append, TODAY, gap=gap, clock=clock), out, clock


def utter(speaker, text, t=0.0):
    return {"type": "utterance", "speaker": speaker, "text": text, "t": t}


def sent(llm):
    """The new utterances of each meeting call, as the model saw them."""
    batches = []
    for call in llm.calls:
        if "# New utterances" in call.user:
            part = call.user.split("# New utterances\n", 1)[1].split("\n\n", 1)[0]
            batches.append(part.splitlines())
    return batches


# Throttle

def test_utterances_wait_for_the_gap_and_go_together(memory_dir):
    llm = FakeLLM()
    agent, _, clock = make(memory_dir, llm)
    agent.handle(utter("Jonas", "Hallo zusammen."))  # the first one after a quiet stretch goes at once
    clock.now += 5
    agent.handle(utter("Lisa", "Die Landingpage ist live."))
    clock.now += 5
    agent.handle(utter("Max", "Ich rechne die Marge."))
    assert sent(llm) == [["Jonas: Hallo zusammen."]]
    assert agent.due() == 15  # 25 s after the last call
    clock.now += 15
    assert agent.due() == 0
    agent.flush()  # what run() does when the gap is over and nothing new came
    assert sent(llm) == [["Jonas: Hallo zusammen."], ["Lisa: Die Landingpage ist live.", "Max: Ich rechne die Marge."]]
    assert "Jonas: Hallo zusammen." in llm.calls[1].user.split("# New utterances")[0]  # context, not new
    clock.now += 1
    agent.handle(utter("Jonas", "Gut."))
    assert len(llm.calls) == 2 and agent.due() == 24


def test_an_utterance_after_the_gap_goes_at_once_with_the_waiting_ones(memory_dir):
    llm = FakeLLM()
    agent, _, clock = make(memory_dir, llm)
    agent.handle(utter("Jonas", "Eins."))
    clock.now += 10
    agent.handle(utter("Jonas", "Zwei."))
    clock.now += 20
    agent.handle(utter("Jonas", "Drei."))
    assert sent(llm) == [["Jonas: Eins."], ["Jonas: Zwei.", "Jonas: Drei."]]
    assert agent.due() is None


def test_nothing_lost_or_sent_twice(memory_dir):
    llm = FakeLLM()
    agent, _, clock = make(memory_dir, llm)
    texts = [f"Satz {i}." for i in range(40)]
    for i, text in enumerate(texts):
        agent.handle(utter("Max", text, i * 3))
        clock.now += 3
        if agent.due() == 0:
            agent.flush()
    agent.handle({"cmd": "save", "title": "Gap"})
    seen = [line for batch in sent(llm) for line in batch]
    assert seen == [f"Max: {t}" for t in texts]
    assert len(llm.calls) <= 120 // 25 + 2  # 120 s of talk: one call per 25 s, plus the first and the last
    assert [line.text for line in Memory(memory_dir).get("2026-10-26-gap").transcript] == texts


def test_save_analyses_what_waits_and_saves_its_commitments(memory_dir):
    commitment = {**QUIET, "commitments": [{"who": "Lisa", "what": "Folien schicken", "due": "2026-10-28",
                                            "quote": "Ich schicke euch bis Mittwoch die Folien."}]}
    llm = FakeLLM(QUIET, commitment)
    agent, out, _ = make(memory_dir, llm)
    agent.handle(utter("Jonas", "Hallo."))
    agent.handle(utter("Lisa", "Ich schicke euch bis Mittwoch die Folien."))
    assert len(llm.calls) == 1
    agent.handle({"cmd": "save", "title": "Ende"})
    assert sent(llm)[1] == ["Lisa: Ich schicke euch bis Mittwoch die Folien."]
    assert [o["type"] for o in out] == ["commitment", "status"]  # the commitment is found before the save is confirmed
    saved = Memory(memory_dir).get("2026-10-26-ende")
    assert [c.what for c in saved.commitments] == ["Folien schicken"] and len(saved.transcript) == 2


def test_save_writes_the_meeting_before_it_asks_claude(memory_dir):
    """The app ends the agent with SIGTERM (SystemExit in main) when the save takes too long: the meeting is written."""
    class Ended(FakeLLM):
        def json(self, *args, **kwargs):
            if self.calls:
                raise SystemExit(143)
            return super().json(*args, **kwargs)

    agent, _, _ = make(memory_dir, Ended())
    agent.handle(utter("Jonas", "Hallo."))
    agent.handle(utter("Lisa", "Ich schicke euch bis Mittwoch die Folien."))  # waits for the gap
    with pytest.raises(SystemExit):
        agent.handle({"cmd": "save", "title": "Ende"})
    saved = Memory(memory_dir).get("2026-10-26-ende")
    assert [line.text for line in saved.transcript] == ["Hallo.", "Ich schicke euch bis Mittwoch die Folien."]
    assert saved.participants == ["Jonas", "Lisa"]


def test_reset_drops_what_waits(memory_dir):
    llm = FakeLLM()
    agent, out, clock = make(memory_dir, llm)
    agent.handle(utter("Jonas", "Hallo."))
    agent.handle(utter("Jonas", "Noch was."))
    agent.handle({"cmd": "reset"})
    assert len(llm.calls) == 1 and agent.live == [] and agent.waiting == [] and agent.due() is None
    clock.now += 30
    agent.handle(utter("Max", "Neues Meeting."))
    assert sent(llm) == [["Jonas: Hallo."], ["Max: Neues Meeting."]]
    assert "Noch was." not in llm.calls[1].user


def test_stdin_closing_runs_what_waits_through_the_rules(memory_dir):
    """The app closes stdin after a save or to throw the meeting away: what still waits gets the rules, not Claude."""
    llm = FakeLLM()
    out = []
    agent = Agent(Memory(memory_dir), llm, out.append, TODAY, clock=lambda: 0.0)  # the clock never moves
    first = threading.Event()
    real = llm.json

    def json_and_signal(*args, **kwargs):
        answer = real(*args, **kwargs)
        first.set()
        return answer

    llm.json = json_and_signal

    def stream():
        yield json.dumps(utter("Jonas", "Hallo.")) + "\n"
        first.wait(5)  # the next line comes after the first call, so it waits for the gap when stdin closes
        yield json.dumps(utter("Lisa", "Ich schicke euch bis Mittwoch die Folien.")) + "\n"

    run(agent, stream())
    assert first.is_set() and sent(llm) == [["Jonas: Hallo."]]
    assert [o["type"] for o in out] == ["commitment"] and out[0]["who"] == "Lisa"  # the rules found it
    assert agent.waiting == [] and [u.text for u in agent.live][-1] == "Ich schicke euch bis Mittwoch die Folien."


def test_run_sends_what_waits_when_the_gap_is_over_without_new_words(memory_dir):
    """The one test with the real clock: a gap of 50 ms, and stdin stays open until the second call came."""
    llm = FakeLLM()
    agent = Agent(Memory(memory_dir), llm, lambda _: None, TODAY, gap=0.05)
    first, second = threading.Event(), threading.Event()
    real = llm.json

    def json_and_signal(*args, **kwargs):
        answer = real(*args, **kwargs)
        (first if len(llm.calls) == 1 else second).set()
        return answer

    llm.json = json_and_signal

    open_when_sent = []

    def stream():
        yield json.dumps(utter("Max", "Eins.")) + "\n"
        first.wait(5)  # "Zwei." comes after the first call, so it waits for the gap
        yield json.dumps(utter("Max", "Zwei.")) + "\n"
        open_when_sent.append(second.wait(5))  # stdin open, nobody speaks: the call comes before it closes

    run(agent, stream())
    assert open_when_sent == [True] and sent(llm) == [["Max: Eins."], ["Max: Zwei."]]


def test_ask_and_captured_questions_are_not_throttled(memory_dir):
    llm = FakeLLM()
    agent, out, _ = make(memory_dir, llm)
    agent.handle(utter("Jonas", "Hallo."))
    agent.handle(utter("Jonas", "Weiter."))  # waits for the gap
    agent.handle({"cmd": "ask", "question": "Welcher Preis?", "id": 1})
    agent.handle({"cmd": "ask", "question": "Welcher Preis gilt?", "id": "capture:c1"})
    assert len(llm.calls) == 3 and [o["type"] for o in out] == ["answer", "answer"]
    assert [u.text for u in agent.waiting] == ["Weiter."]  # still waiting, and asked once the gap is over


def test_rules_are_not_throttled(memory_dir):
    agent, out, _ = make(memory_dir, None)
    agent.handle(utter("Lisa", "Ich schicke euch bis Mittwoch die Folien."))
    agent.handle(utter("Max", "Wir waren doch bei 25 Euro im Monat."))
    types = [o["type"] for o in out]
    assert types[0] == "commitment" and "contradiction" in types and agent.due() is None


def test_while_claude_rests_the_rules_answer_at_once(memory_dir, monkeypatch):
    llm = FakeLLM(RuntimeError("overloaded"))
    agent, out, clock = make(memory_dir, llm)
    agent.handle(utter("Jonas", "Hallo."))  # fails: the rules, and Claude rests
    clock.now += 1
    agent.handle(utter("Max", "Wir waren doch bei 25 Euro im Monat."))
    assert len(llm.calls) == 1 and "contradiction" in [o["type"] for o in out] and agent.due() is None
    monkeypatch.setattr("agent.time.monotonic", lambda: agent.resting_until + 1)
    clock.now += 60
    agent.handle(utter("Jonas", "Und jetzt?"))
    assert len(llm.calls) == 2


def test_the_gap_comes_from_the_environment_or_a_flag(monkeypatch, memory_dir):
    import agent as agent_module

    seen = {}
    monkeypatch.setattr(agent_module, "run", lambda agent, *_: seen.setdefault("gap", agent.gap))
    monkeypatch.setattr(agent_module.sys, "stdout", io.StringIO())
    args = ["--offline", "--memory", str(memory_dir), "--usage", "", "--captures", "", "--connectors", ""]
    monkeypatch.delenv("STARNOTCH_MEETING_GAP", raising=False)
    agent_module.main(args)
    assert seen.pop("gap") == 25
    monkeypatch.setenv("STARNOTCH_MEETING_GAP", "40")
    agent_module.main(args)
    assert seen.pop("gap") == 40
    agent_module.main(args + ["--meeting-gap", "0"])
    assert seen.pop("gap") == 0
    for value, gap in (("abc", 25), ("", 25), ("nan", 25), ("inf", 600), ("-3", 0)):  # never an exit or a crash later
        monkeypatch.setenv("STARNOTCH_MEETING_GAP", value)
        assert agent_module.main(args) == 0 and seen.pop("gap") == gap
    assert agent_module.main(args + ["--meeting-gap", "inf"]) == 0 and seen.pop("gap") == 600


# Memory

def test_the_meeting_prompt_carries_the_whole_memory(memory_dir):
    """Transcript lines are what contradictions turn on, and in the cached system prompt they cost a tenth of a cent
    per thousand tokens: the live analysis keeps the same memory as before the gap."""
    llm = FakeLLM()
    agent, _, _ = make(memory_dir, llm)
    agent.handle(utter("Max", "Ich rechne gerade die Marge."))
    system = llm.calls[0].system
    assert system == SYSTEM.format(memory=Memory(memory_dir).as_context())
    assert "Decision: Das Lumen-Abo kostet 30 Euro im Monat" in system and "Ich hätte 25 Euro im Monat vorgeschlagen" in system


def test_the_meeting_prompt_stays_byte_identical_between_batches(memory_dir):
    llm = FakeLLM()
    agent, _, clock = make(memory_dir, llm)
    agent.handle(utter("Jonas", "Hallo zusammen."))
    clock.now += 30
    agent.handle(utter("Max", "Wir waren doch bei 25 Euro im Monat."))
    clock.now += 30
    agent.handle(utter("Lisa", "Ich schicke euch bis Mittwoch die Folien."))
    assert len(llm.calls) == 3 and len({c.system.encode() for c in llm.calls}) == 1
    assert llm.calls[0].user != llm.calls[1].user


def _crowded(memory_dir):
    """The demo meetings and 30 weeklies full of other Euro figures."""
    memory = Memory(memory_dir)
    day = dt.date(2026, 10, 5)
    for i in range(30):
        memory.save(Meeting(id=f"{day}-weekly", title="Weekly", date=day.isoformat(), summary="Stand Lumen-Abo.",
                            transcript=[Line("Lisa", f"Die Supportkosten pro Nutzer liegen gerade bei {3 + i % 7} Euro im Monat.", 10),
                                        Line("Max", "Das Budget für Anzeigen liegt bei 800 Euro im Monat, mehr geht nicht.", 20),
                                        Line("Jonas", "Wir haben 120 neue Testnutzer seit Montag.", 30)]))
        day -= dt.timedelta(days=7)
    return memory


def test_recall_in_a_long_batch_keeps_each_utterances_best_line(memory_dir):
    llm = FakeLLM()
    agent, _, clock = make(_crowded(memory_dir), llm)
    agent.handle(utter("Jonas", "Hallo."))
    talk = ["Die Supportkosten liegen jetzt bei 6 Euro im Monat.", "Das Budget für Anzeigen bleibt bei 800 Euro im Monat.",
            "Wir haben wieder 120 neue Testnutzer.", "Wir waren doch bei 25 Euro im Monat, oder?"]
    for text in talk:
        agent.handle(utter("Max", text))
    clock.now += 30
    agent.flush()
    recall = llm.calls[1].user.split("# Earlier lines with the same words\n", 1)[1].split("\n\n", 1)[0].splitlines()
    assert ["Supportkosten" in recall[0], "Anzeigen" in recall[1], "Testnutzer" in recall[2], "25 Euro" in recall[3]] \
        == [True] * 4  # each utterance's best line first, then each one's second
    assert len(recall) <= 16 and sum(len(line) + 1 for line in recall) <= 4000 + 1
    assert "Lumen-Abo kostet 30 Euro im Monat." in llm.calls[1].system  # and the decision's line in the memory
