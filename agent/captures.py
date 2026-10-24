"""What the user jotted down with Starnotch's quick capture (⌃⌥N): tasks, questions and notes.

The app appends every capture to `capture-queue.jsonl` in its folder, one JSON object per line:
{"id", "created" (ISO 8601), "route" (task|question|note), "text", "due" (YYYY-MM-DD or null),
"people" (slugs), "delivered"}. This module reads it; the agent puts the captures next to the meetings.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

from memory import DEFAULT_DIR

QUEUE = DEFAULT_DIR.parent / "capture-queue.jsonl"


@dataclass
class Capture:
    id: str
    created: str
    route: str
    text: str
    due: str | None = None
    people: list[str] = field(default_factory=list)

    @property
    def day(self) -> str:
        return self.created[:10]

    @property
    def is_question(self) -> bool:
        """Filed as a question, or a task that ends in "?" (quick capture starts on Task, people forget to switch)."""
        return self.route == "question" or (self.route == "task" and self.text.rstrip().endswith("?"))


def read(path: Path = QUEUE) -> list[Capture]:
    """All captures, oldest first; unreadable lines are skipped."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            raw = json.loads(line)
        except ValueError:
            continue
        if not isinstance(raw, dict) or not raw.get("text"):
            continue
        out.append(Capture(
            id=str(raw.get("id") or len(out)),
            created=str(raw.get("created") or ""),
            route=str(raw.get("route") or "note").lower(),
            text=str(raw["text"]).strip(),
            due=raw.get("due") or None,
            people=[str(p) for p in raw.get("people") or []],
        ))
    return out


def as_context(captures: list[Capture], limit: int = 60) -> str:
    """'- 2026-10-24 task (due 2026-10-28) [max]: Zahlen nachfragen' lines for a prompt, newest first."""
    lines = []
    for c in reversed(captures[-limit:]):
        due = f" (due {c.due})" if c.due else ""
        people = f" [{', '.join(c.people)}]" if c.people else ""
        lines.append(f"- {c.day} {c.route}{due}{people}: {c.text}")
    return "\n".join(lines)


def mentions(capture: Capture, name: str) -> bool:
    """Whether a capture is about a person: their slug is tagged, or the first name is in the text."""
    first = name.strip().split(" ")[0].lower() if name.strip() else ""
    if not first:
        return False
    return any(p.lower().split("-")[0] == first for p in capture.people) or first in re.findall(r"\w+", capture.text.lower())
