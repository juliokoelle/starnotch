"""The one place that talks to Claude: a JSON-in, JSON-out call with a schema.

The key comes from the environment (ANTHROPIC_API_KEY or an `ant auth login` profile), never from a file here.
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any, Protocol

import anthropic

MODEL = os.environ.get("STARNOTCH_MODEL", "claude-sonnet-5-5")
EFFORT = os.environ.get("STARNOTCH_EFFORT", "low")
FALLBACK_BETA = "server-side-fallback-2026-07-01"


class JSONModel(Protocol):
    def json(self, system: str, user: str, schema: dict[str, Any], max_tokens: int = 4000) -> dict[str, Any] | None: ...


class Claude:
    """Structured-output calls to Claude. Returns None on a refusal or an unreadable answer."""

    def __init__(self, model: str = MODEL, effort: str = EFFORT, client: anthropic.Anthropic | None = None):
        self.model = model
        self.effort = effort
        self.client = client or anthropic.Anthropic(max_retries=1, timeout=30)  # live: better a rule now than Claude late
        # Server-side fallback re-runs a declined request on another model. Switched off if the API rejects it.
        self.fallbacks = os.environ.get("STARNOTCH_NO_FALLBACK") is None

    def json(self, system: str, user: str, schema: dict[str, Any], max_tokens: int = 4000) -> dict[str, Any] | None:
        request: dict[str, Any] = dict(
            model=self.model,
            max_tokens=max_tokens,
            system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
            messages=[{"role": "user", "content": user}],
            output_config={"effort": self.effort, "format": {"type": "json_schema", "schema": schema}},
        )
        try:
            response = self._create(request)
        except anthropic.BadRequestError as error:
            if not self.fallbacks or "fallback" not in str(error).lower():
                raise
            print(f"claude: fallbacks rejected, continuing without: {error}", file=sys.stderr)
            self.fallbacks = False
            response = self._create(request)
        if response.stop_reason in ("refusal", "max_tokens"):
            return None
        text = next((b.text for b in response.content if b.type == "text"), "")
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return None
        return data if isinstance(data, dict) else None

    def _create(self, request: dict[str, Any]):
        if self.fallbacks:
            return self.client.beta.messages.create(**request, betas=[FALLBACK_BETA], fallbacks="default")
        return self.client.beta.messages.create(**request)
