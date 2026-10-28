"""The usage ledger: Claude Code's real JSON results, API usage priced from the table, append and prune."""

import datetime as dt
import json
from pathlib import Path
from types import SimpleNamespace

import usage
from agent import Agent
from memory import Memory

FIXTURES = Path(__file__).resolve().parent / "fixtures"
NOW = dt.datetime(2026, 10, 28, 9, 12, 3, tzinfo=dt.timezone.utc)


def fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def test_claude_code_result_cold_cache():
    # A first question on a full memory: the system prompt is written to the cache (Claude Code writes 1-hour entries).
    call = usage.from_claude_code(fixture("claude-code-ask-cold.json"), "sonnet")
    assert call == {"model": "claude-sonnet-5-5", "input_tokens": 2, "cache_creation_input_tokens": 32499,
                    "cache_read_input_tokens": 577, "output_tokens": 274, "duration_ms": 5121,
                    "cost_usd": 0.1327977}


def test_claude_code_result_warm_cache():
    # The next question reads the memory from the cache: about a twelfth of the first one's cost.
    call = usage.from_claude_code(fixture("claude-code-ask-cached.json"))
    assert call["cache_read_input_tokens"] == 32025 and call["cache_creation_input_tokens"] == 1115
    assert call["cost_usd"] == 0.0107465


def test_price_table_matches_claude_codes_own_cost():
    for name in ("claude-code-ask-cold.json", "claude-code-ask-cached.json"):
        result = fixture(name)
        u = result["usage"]
        assert u["cache_creation"]["ephemeral_5m_input_tokens"] == 0
        ours = usage.cost("claude-sonnet-5-5", u["input_tokens"], 0, u["cache_creation"]["ephemeral_1h_input_tokens"],
                          u["cache_read_input_tokens"], u["output_tokens"])
        assert abs(ours - result["total_cost_usd"]) < 1e-7


def test_a_bare_result_still_counts():
    call = usage.from_claude_code({"usage": {"input_tokens": 900}}, "sonnet")
    assert call["model"] == "sonnet" and call["input_tokens"] == 900 and call["cost_usd"] is None


def test_api_usage_is_priced():
    u = SimpleNamespace(input_tokens=1000, cache_creation_input_tokens=20_000, cache_read_input_tokens=0,
                        output_tokens=300, cache_creation=None)
    call = usage.from_api("claude-sonnet-5-5", u, 1234.5)
    # 1000 × $2 + 20,000 × $2.50 (5-minute writes) + 300 × $10, per million
    assert call["cost_usd"] == 0.055 and call["duration_ms"] == 1234
    warm = SimpleNamespace(input_tokens=1000, cache_creation_input_tokens=0, cache_read_input_tokens=20_000,
                           output_tokens=300)
    assert usage.from_api("claude-sonnet-5-5", warm, 0)["cost_usd"] == 0.007
    assert usage.from_api("claude-some-future-model", warm, 0)["cost_usd"] is None


def test_haiku_costs_more_past_100k_tokens():
    assert usage.cost("claude-haiku-5-5", 100_000) == 0.01
    assert usage.cost("claude-haiku-5-5", 100_001) == round(100_001 * 0.5 / 1e6, 7)


def test_ledger_appends_and_prunes(tmp_path):
    path = tmp_path / "usage.jsonl"
    old = {"time": "2026-07-01T10:00:00Z", "feature": "ask"}
    recent = {"time": "2026-08-15T10:00:00Z", "feature": "meeting"}
    path.write_text(json.dumps(old) + "\n" + json.dumps(recent) + "\nnot json\n", encoding="utf-8")
    ledger = usage.Ledger(path)
    call = usage.from_claude_code(fixture("claude-code-ask-cached.json"))
    ledger.record("ask", "claude-code", call, now=NOW)
    ledger.record("meeting", "claude-code", call, now=NOW)
    lines = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
    assert [line["time"] for line in lines] == ["2026-08-15T10:00:00Z", "2026-10-28T09:12:03Z", "2026-10-28T09:12:03Z"]
    assert lines[1] == {"time": "2026-10-28T09:12:03Z", "feature": "ask", "brain": "claude-code", **call}


def test_ledger_in_a_missing_folder(tmp_path):
    ledger = usage.Ledger(tmp_path / "new" / "usage.jsonl")
    ledger.record("ask", "api", {"input_tokens": 1}, now=NOW)
    assert (tmp_path / "new" / "usage.jsonl").exists()


class Spending:
    """A brain that spends tokens on every call, and fails when told to (after spending them)."""

    model = "claude-sonnet-5-5"

    def __init__(self, fail=False):
        self.fail = fail
        self.last_usage = None

    def json(self, system, user, schema, max_tokens=4000, **extra):
        self.last_usage = {"model": self.model, "input_tokens": 10, "cache_creation_input_tokens": 0,
                           "cache_read_input_tokens": 0, "output_tokens": 5, "duration_ms": 7, "cost_usd": 0.00007}
        if self.fail:
            raise RuntimeError("overloaded")
        if "contradictions" in schema["properties"]:
            return {"contradictions": [], "commitments": [], "questions": []}
        return {"answer": "30 Euro.", "sources": []}


def test_every_feature_lands_in_the_ledger(tmp_path, memory_dir):
    path = tmp_path / "usage.jsonl"
    agent = Agent(Memory(memory_dir), Spending(), lambda _: None, dt.date(2026, 10, 26), None, None, "claude-code",
                  usage=path)
    agent.handle({"cmd": "ask", "question": "Welcher Preis?", "id": 1})
    agent.handle({"cmd": "ask", "question": "Welcher Preis?", "id": "capture:c1"})
    agent.handle({"type": "utterance", "speaker": "Max", "text": "Hallo"})
    lines = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
    assert [(line["feature"], line["brain"], line["input_tokens"]) for line in lines] == [
        ("ask", "claude-code", 10), ("capture", "claude-code", 10), ("meeting", "claude-code", 10)]


def test_a_failed_call_that_spent_tokens_is_recorded(tmp_path, memory_dir):
    path = tmp_path / "usage.jsonl"
    agent = Agent(Memory(memory_dir), Spending(fail=True), lambda _: None, usage=path, brain="api")
    agent.handle({"cmd": "ask", "question": "Welcher Preis?", "id": 1})
    assert json.loads(path.read_text(encoding="utf-8"))["brain"] == "api"


def test_no_ledger_without_a_path(tmp_path, memory_dir):
    agent = Agent(Memory(memory_dir), Spending(), lambda _: None)
    agent.handle({"cmd": "ask", "question": "Welcher Preis?", "id": 1})
    assert agent.ledger is None
