import datetime as dt
from types import SimpleNamespace

import anthropic
import pytest

from agent import ANALYSIS_SCHEMA, ASK_SCHEMA, Agent, next_weekday
from claude import Claude
from memory import Memory

TODAY = dt.date(2026, 10, 26)  # Monday


class FakeLLM:
    """Stands in for claude.Claude: returns queued answers and records each call."""

    def __init__(self, *answers):
        self.answers = list(answers)
        self.calls = []

    def json(self, system, user, schema, max_tokens=4000):
        self.calls.append(SimpleNamespace(system=system, user=user, schema=schema))
        answer = self.answers.pop(0) if self.answers else {"contradictions": [], "commitments": [], "questions": []}
        if isinstance(answer, Exception):
            raise answer
        return answer


def make(memory_dir, llm):
    out = []
    return Agent(Memory(memory_dir), llm, out.append, TODAY), out


def utter(speaker, text, t=0.0):
    return {"type": "utterance", "speaker": speaker, "text": text, "t": t}


PRICE_SLIP = {
    "contradictions": [{
        "now_quote": "Wir waren doch bei 25 Euro",
        "before_quote": "Das Lumen-Abo kostet 30 Euro im Monat.",
        "meeting_id": "2026-10-12-kickoff",
        "note": "Im Kickoff wurden 30 Euro entschieden, 25 Euro wurden verworfen.",
    }],
    "commitments": [],
    "questions": [],
}


def test_contradiction_with_source(memory_dir):
    llm = FakeLLM(PRICE_SLIP)
    agent, out = make(memory_dir, llm)
    agent.handle(utter("Max", "Wir waren doch bei 25 Euro im Monat, oder?", 24))
    assert out == [{
        "type": "contradiction",
        "now": "Wir waren doch bei 25 Euro",
        "speaker": "Max",
        "t": 24.0,
        "before": {
            "quote": "Okay, dann entscheiden wir: Das Lumen-Abo kostet 30 Euro im Monat.",
            "speaker": "Jonas",
            "meeting": "Kickoff Lumen-Abo",
            "meeting_id": "2026-10-12-kickoff",
            "date": "2026-10-12",
        },
        "note": "Im Kickoff wurden 30 Euro entschieden, 25 Euro wurden verworfen.",
    }]
    call = llm.calls[0]
    assert call.schema is ANALYSIS_SCHEMA
    assert "id=2026-10-12-kickoff" in call.system  # memory goes in the system prompt
    assert "2026-10-26" in call.user and "Wir waren doch bei 25 Euro" in call.user


def test_invented_quote_is_dropped(memory_dir):
    fake = {**PRICE_SLIP, "contradictions": [{**PRICE_SLIP["contradictions"][0],
                                              "before_quote": "Wir nehmen 99 Dollar pro Woche für Haustiere",
                                              "meeting_id": "gibt-es-nicht"}]}
    agent, out = make(memory_dir, FakeLLM(fake))
    agent.handle(utter("Max", "Wir waren doch bei 25 Euro"))
    assert out == []


def test_same_item_reported_once(memory_dir):
    agent, out = make(memory_dir, FakeLLM(PRICE_SLIP, PRICE_SLIP))
    agent.handle(utter("Max", "Wir waren doch bei 25 Euro"))
    agent.handle(utter("Max", "Also 25 Euro, wie gesagt"))
    assert [o["type"] for o in out] == ["contradiction"]
    assert "contradiction:" in agent._analysis_prompt([], [])  # listed under "Already reported"


def test_commitment_and_one_question(memory_dir):
    answer = {
        "contradictions": [],
        "commitments": [{"who": "Lisa", "what": "Folien schicken", "due": "2026-10-28", "quote": "Ich schicke euch bis Mittwoch die Folien."}],
        "questions": [{"text": "Max, wo bleiben die Margenzahlen?", "reason": "seit 16.10. offen"},
                      {"text": "zweite Frage", "reason": ""}],
    }
    agent, out = make(memory_dir, FakeLLM(answer))
    agent.handle(utter("Lisa", "Ich schicke euch bis Mittwoch die Folien."))
    assert out == [
        {"type": "commitment", "who": "Lisa", "what": "Folien schicken", "due": "2026-10-28",
         "quote": "Ich schicke euch bis Mittwoch die Folien."},
        {"type": "question", "text": "Max, wo bleiben die Margenzahlen?", "reason": "seit 16.10. offen"},
    ]
    assert agent.commitments[0].who == "Lisa"


def test_llm_error_falls_back_to_rules(memory_dir):
    agent, out = make(memory_dir, FakeLLM(RuntimeError("boom")))
    agent.handle(utter("Max", "Wir waren doch bei 25 Euro im Monat, oder?"))
    assert out[0]["type"] == "status" and out[0]["state"] == "offline"
    assert out[1]["type"] == "contradiction"
    assert out[1]["before"]["quote"].endswith("30 Euro, die Landingpage geht damit diese Woche live.")


def test_reworded_contradiction_is_not_repeated(memory_dir):
    again = {**PRICE_SLIP, "contradictions": [{**PRICE_SLIP["contradictions"][0], "now_quote": "also 25 Euro"}]}
    agent, out = make(memory_dir, FakeLLM(PRICE_SLIP, again))
    agent.handle(utter("Max", "Wir waren doch bei 25 Euro"))
    agent.handle(utter("Max", "also 25 Euro"))
    assert [o["type"] for o in out] == ["contradiction"]


def test_auth_error_stops_calling_claude(memory_dir):
    class AuthenticationError(Exception):
        pass

    llm = FakeLLM(AuthenticationError("no key"))
    agent, out = make(memory_dir, llm)
    agent.handle(utter("Jonas", "Hallo"))
    agent.handle(utter("Jonas", "Weiter"))
    assert len(llm.calls) == 1 and agent.llm is None
    assert [o["state"] for o in out if o["type"] == "status"] == ["offline"]


def test_rules_without_llm(memory_dir):
    agent, out = make(memory_dir, None)
    agent.handle(utter("Lisa", "Ich schicke euch bis Mittwoch die Folien."))
    agent.handle(utter("Max", "Ich rechne gerade die Marge."))
    agent.handle(utter("Jonas", "30 Euro passt."))
    assert out[0] == {"type": "commitment", "who": "Lisa", "what": "Ich schicke euch die Folien", "due": "2026-10-28",
                      "quote": "Ich schicke euch bis Mittwoch die Folien."}
    assert out[1]["type"] == "question" and "2026-10-16" in out[1]["text"]
    assert len(out) == 2  # 30 Euro matches the decision: no contradiction


def test_prep_card(memory_dir):
    agent, out = make(memory_dir, FakeLLM())
    agent.handle({"cmd": "prep", "participants": ["Max"], "id": 7})
    card = out[0]
    assert card["type"] == "prep" and card["reply_to"] == 7
    assert [d["meeting_id"] for d in card["decisions"]] == ["2026-10-19-weekly", "2026-10-12-kickoff"]
    assert card["open_commitments"] == [{
        "who": "Max", "what": "Zahlen zur Marge an das Team schicken", "due": "2026-10-16", "overdue": True,
        "quote": "Ich schicke euch die Zahlen zur Marge bis Freitag.",
        "meeting": "Kickoff Lumen-Abo", "meeting_id": "2026-10-12-kickoff", "date": "2026-10-12",
    }]
    assert card["last_meeting"]["meeting_id"] == "2026-10-19-weekly"


def test_prep_for_strangers_is_empty(memory_dir):
    agent, out = make(memory_dir, FakeLLM())
    agent.handle({"cmd": "prep", "participants": ["Niemand"]})
    assert out[0]["decisions"] == [] and out[0]["open_commitments"] == [] and out[0]["last_meeting"] is None


def test_ask_with_source(memory_dir):
    llm = FakeLLM({"answer": "30 Euro im Monat.", "sources": [{"meeting_id": "2026-10-12-kickoff", "quote": "kostet 30 Euro im Monat"}]})
    agent, out = make(memory_dir, llm)
    agent.handle({"cmd": "ask", "question": "Welcher Preis?", "id": "q1"})
    assert out == [{
        "type": "answer", "question": "Welcher Preis?", "text": "30 Euro im Monat.", "reply_to": "q1",
        "sources": [{"quote": "Okay, dann entscheiden wir: Das Lumen-Abo kostet 30 Euro im Monat.", "speaker": "Jonas",
                     "meeting": "Kickoff Lumen-Abo", "meeting_id": "2026-10-12-kickoff", "date": "2026-10-12"}],
    }]
    assert llm.calls[0].schema is ASK_SCHEMA and llm.calls[0].user == "Welcher Preis?"


def test_save_live_meeting(memory_dir):
    agent, out = make(memory_dir, None)
    agent.handle(utter("Lisa", "Ich schicke euch bis Mittwoch die Folien.", 3))
    agent.handle({"cmd": "save", "title": "Launch Check"})
    assert out[-1]["state"] == "saved" and out[-1]["meeting_id"] == "2026-10-26-launch-check"
    saved = Memory(memory_dir).get("2026-10-26-launch-check")
    assert saved.participants == ["Lisa"] and saved.commitments[0].due == "2026-10-28"


def test_next_weekday():
    assert next_weekday(TODAY, "Mittwoch") == "2026-10-28"
    assert next_weekday(TODAY, "Montag") == "2026-11-02"
    assert next_weekday(TODAY, "friday") == "2026-10-30"
    assert next_weekday(TODAY, "morgen") == "2026-10-27"
    assert next_weekday(TODAY, "irgendwann") is None


# claude.Claude against a fake Anthropic client

def _response(text, stop="end_turn"):
    return SimpleNamespace(stop_reason=stop, content=[SimpleNamespace(type="thinking"), SimpleNamespace(type="text", text=text)])


class FakeMessages:
    def __init__(self, *results):
        self.results = list(results)
        self.requests = []

    def create(self, **request):
        self.requests.append(request)
        result = self.results.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


def fake_client(*results):
    messages = FakeMessages(*results)
    return SimpleNamespace(beta=SimpleNamespace(messages=messages)), messages


def test_claude_request_shape():
    client, messages = fake_client(_response('{"a": 1}'))
    assert Claude(client=client).json("sys", "hi", {"type": "object"}) == {"a": 1}
    request = messages.requests[0]
    assert request["model"] == "claude-sonnet-5-5"
    assert request["output_config"] == {"effort": "low", "format": {"type": "json_schema", "schema": {"type": "object"}}}
    assert request["fallbacks"] == "default" and request["betas"] == ["server-side-fallback-2026-07-01"]
    assert request["system"][0]["cache_control"] == {"type": "ephemeral"}


def test_claude_refusal_is_none():
    client, _ = fake_client(_response("", stop="refusal"))
    assert Claude(client=client).json("s", "u", {}) is None


def test_claude_drops_fallbacks_when_rejected():
    import httpx2 as httpx_mod  # the SDK's HTTP layer

    request = httpx_mod.Request("POST", "https://api.anthropic.com/v1/messages")
    error = anthropic.BadRequestError("fallbacks: not supported", response=httpx_mod.Response(400, request=request), body=None)
    client, messages = fake_client(error, _response('{"ok": true}'))
    claude = Claude(client=client)
    assert claude.json("s", "u", {}) == {"ok": True}
    assert "fallbacks" not in messages.requests[1] and claude.fallbacks is False
