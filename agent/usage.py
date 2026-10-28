"""Tara's usage ledger: one JSON line per brain call in `usage.jsonl` in Starnotch's folder.

    {"time": "2026-10-28T09:12:03Z", "feature": "ask", "brain": "claude-code", "model": "claude-sonnet-5-5",
     "input_tokens": 2, "cache_creation_input_tokens": 1115, "cache_read_input_tokens": 32025, "output_tokens": 308,
     "duration_ms": 4456, "cost_usd": 0.0107465}

feature: ask (Ask Tara), capture (a question typed into quick capture), meeting (the live analysis).
cost_usd is what the call costs at API list prices: Claude Code reports it (`total_cost_usd`); for the api brain it
is computed from PRICES. On a Claude plan nothing is billed per call: the tokens count against the plan's limits.
The app reads the file for Settings; lines older than KEEP_DAYS go when an agent first writes after it starts.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import tempfile
from pathlib import Path
from typing import Any, NamedTuple

from memory import DEFAULT_DIR

LEDGER = DEFAULT_DIR.parent / "usage.jsonl"
KEEP_DAYS = 90
TOKENS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")


class Price(NamedTuple):
    """USD per million tokens."""
    input: float
    write_5m: float
    write_1h: float
    read: float
    output: float


# List prices from platform.claude.com/docs/en/about-claude/pricing (read 2026-10-28). Haiku 5.5 costs more for a
# prompt over 100,000 tokens (cache reads and writes count toward that length).
PRICES = {
    "claude-sonnet-5-5": Price(2.00, 2.50, 4.00, 0.10, 10.00),
    "claude-opus-5-5": Price(4.00, 5.00, 8.00, 0.20, 20.00),
    "claude-haiku-5-5": Price(0.10, 0.125, 0.20, 0.01, 0.50),
}
HAIKU_LONG = Price(0.50, 0.625, 1.00, 0.05, 2.50)


def cost(model: str, input_tokens: int = 0, write_5m: int = 0, write_1h: int = 0, read: int = 0,
         output_tokens: int = 0) -> float | None:
    """USD at list prices; None for a model not in PRICES."""
    price = PRICES.get(model)
    if price is None:
        return None
    if model == "claude-haiku-5-5" and input_tokens + write_5m + write_1h + read > 100_000:
        price = HAIKU_LONG
    total = (input_tokens * price.input + write_5m * price.write_5m + write_1h * price.write_1h
             + read * price.read + output_tokens * price.output)
    return round(total / 1_000_000, 7)


def from_claude_code(result: dict[str, Any], fallback_model: str = "") -> dict[str, Any]:
    """The usage of one `claude -p --output-format json` result."""
    usage = result.get("usage") or {}
    models = result.get("modelUsage") or {}
    # The model that did the work: Claude Code may add a small helper call on another model.
    model = max(models, key=lambda m: sum(int(models[m].get(k) or 0) for k in
                                          ("inputTokens", "outputTokens", "cacheReadInputTokens",
                                           "cacheCreationInputTokens")), default="")
    spent = result.get("total_cost_usd")
    return {
        "model": (models.get(model) or {}).get("canonicalModel") or model or fallback_model,
        **{k: int(usage.get(k) or 0) for k in TOKENS},
        "duration_ms": int(result.get("duration_ms") or 0),
        "cost_usd": round(float(spent), 7) if isinstance(spent, (int, float)) else None,
    }


def from_api(model: str, usage: Any, duration_ms: float) -> dict[str, Any]:
    """The usage of one Messages API response (`response.usage`), priced from PRICES."""
    tokens = {k: int(getattr(usage, k, 0) or 0) for k in TOKENS}
    split = getattr(usage, "cache_creation", None)
    write_1h = int(getattr(split, "ephemeral_1h_input_tokens", 0) or 0)
    write_5m = tokens["cache_creation_input_tokens"] - write_1h  # without the split, the default 5-minute writes
    return {
        "model": model,
        **tokens,
        "duration_ms": int(duration_ms),
        "cost_usd": cost(model, tokens["input_tokens"], write_5m, write_1h, tokens["cache_read_input_tokens"],
                         tokens["output_tokens"]),
    }


class Ledger:
    """Appends to usage.jsonl. Several agents (Ask Tara, the meeting) may write at once: each line is one append."""

    def __init__(self, path: Path = LEDGER, keep_days: int = KEEP_DAYS):
        self.path = Path(path)
        self.keep_days = keep_days
        self.pruned = False

    def record(self, feature: str, brain: str, call: dict[str, Any], now: dt.datetime | None = None) -> None:
        now = now or dt.datetime.now(dt.timezone.utc)
        if not self.pruned:
            self.pruned = True
            self.prune(now)
        line = {"time": now.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "feature": feature,
                "brain": brain, **call}
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(line, ensure_ascii=False) + "\n")
        except OSError:
            pass  # a ledger that can't be written must not cost Tara her answer

    def prune(self, now: dt.datetime | None = None) -> None:
        """Drops lines older than keep_days (and lines that aren't JSON); rewrites only when something goes."""
        now = now or dt.datetime.now(dt.timezone.utc)
        cutoff = (now - dt.timedelta(days=self.keep_days)).astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        try:
            lines = self.path.read_text(encoding="utf-8").splitlines()
        except OSError:
            return
        kept = [line for line in lines if _time(line) >= cutoff]
        if len(kept) == len(lines):
            return
        try:
            fd, tmp = tempfile.mkstemp(dir=self.path.parent, suffix=".tmp")
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write("".join(line + "\n" for line in kept))
            os.replace(tmp, self.path)
        except OSError:
            pass


def _time(line: str) -> str:
    try:
        value = json.loads(line).get("time")
    except (ValueError, AttributeError):
        return ""
    return value if isinstance(value, str) else ""
