"""Tara's privacy switches, as the app writes them to `privacy.json` in its folder (Settings › Tara's memory).

    {"paused": true, "paused_until": "2026-10-28T21:00:00Z" | null, "off": ["clipboard"], "on": ["apps"],
     "ignored_apps": [...]}

`paused_until` null with `paused` true is a pause until the user resumes it. A pause stops recording only (no new
meetings, Jamie syncs or transcripts); a source in `off` is neither recorded nor used in answers or handed to AI apps.
A missing or unreadable file means everything is on and nothing is paused, so the sidecar works without the app;
only the opt-in sources (time per app, screen context), which are off until the user switches them on in the app,
stay off. An opt-in source counts as on only when `on` lists it and `off` doesn't (as `MemorySource.isOptIn`).
`STARNOTCH_PRIVACY` names another file (tests, a second build).
"""

from __future__ import annotations

import datetime as dt
import json
import os
from dataclasses import dataclass, field
from pathlib import Path

from memory import DEFAULT_DIR

FILE = DEFAULT_DIR.parent / "privacy.json"
SOURCES = ("meetings", "captures", "notes", "clipboard", "sessions", "apps", "screen")
OPT_IN = frozenset({"apps", "screen"})  # off unless the app lists them in `on`


@dataclass
class Privacy:
    paused: bool = False
    paused_until: dt.datetime | None = None
    off: set[str] = field(default_factory=lambda: set(OPT_IN))

    def is_paused(self, now: dt.datetime | None = None) -> bool:
        if not self.paused:
            return False
        if self.paused_until is None:
            return True
        return (now or dt.datetime.now(dt.timezone.utc)) < self.paused_until

    def shares(self, source: str) -> bool:
        """Tara may use what she has from this source in answers and hand it to AI apps."""
        return source not in self.off

    def records(self, source: str, now: dt.datetime | None = None) -> bool:
        """Tara may record something new from this source now."""
        return self.shares(source) and not self.is_paused(now)

    def why_not(self, source: str, now: dt.datetime | None = None) -> str:
        """One line for a refused recording; empty when it may record."""
        if not self.shares(source):
            return f"{source} is switched off in Settings › Tara's memory"
        if self.is_paused(now):
            return "Tara's memory is paused"
        return ""


def path() -> Path:
    raw = os.environ.get("STARNOTCH_PRIVACY")
    return Path(raw).expanduser() if raw else FILE


def load(file: Path | None = None) -> Privacy:
    """The switches as they are now (read on every use: the app changes them while the sidecar runs)."""
    try:
        data = json.loads((file or path()).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return Privacy()
    if not isinstance(data, dict):
        return Privacy()
    until = None
    raw = data.get("paused_until")
    if isinstance(raw, str) and raw:
        try:
            until = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
            if until.tzinfo is None:
                until = until.replace(tzinfo=dt.timezone.utc)
        except ValueError:
            until = None
    on = {str(s) for s in data.get("on") or []} if isinstance(data.get("on"), list) else set()
    off = {str(s) for s in data.get("off") or [] if str(s) in SOURCES} | (OPT_IN - on)
    return Privacy(paused=bool(data.get("paused")), paused_until=until, off=off)
