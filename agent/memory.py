"""Meeting memory: one JSON file per meeting in a folder.

Schema of a meeting file (all keys optional except id):

    {
      "id": "2026-10-12-kickoff",
      "title": "Kickoff",
      "date": "2026-10-12",                       # ISO date
      "participants": ["Max", "Lisa"],
      "transcript": [{"speaker": "Max", "t": 12.5, "text": "..."}],   # t: seconds from start
      "summary": "...",                           # short, shown on the prep card
      "notes": "...",                             # a source's full notes (Jamie's whole summary) when longer
      "decisions": [{"text": "Price is 30 Euro", "quote": "...", "speaker": "Lisa", "t": 80.0}],
      "commitments": [{"who": "Max", "what": "send numbers", "due": "2026-10-16",
                       "quote": "...", "status": "open"}]          # status: open | done
    }
"""

from __future__ import annotations

import json
import os
import re
import tempfile
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable

DEFAULT_DIR = Path.home() / "Library" / "Application Support" / "Starnotch" / "memory"


@dataclass
class Line:
    speaker: str
    text: str
    t: float = 0.0


@dataclass
class Decision:
    text: str
    quote: str = ""
    speaker: str = ""
    t: float | None = None


@dataclass
class Commitment:
    who: str
    what: str
    due: str | None = None
    quote: str = ""
    status: str = "open"


@dataclass
class Meeting:
    id: str
    title: str = ""
    date: str = ""
    participants: list[str] = field(default_factory=list)
    transcript: list[Line] = field(default_factory=list)
    summary: str = ""
    decisions: list[Decision] = field(default_factory=list)
    commitments: list[Commitment] = field(default_factory=list)
    notes: str = ""

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "Meeting":
        if not data.get("id"):
            raise ValueError("meeting without id")
        return cls(
            id=str(data["id"]),
            title=str(data.get("title") or ""),
            date=str(data.get("date") or "")[:10],
            participants=[str(p) for p in data.get("participants") or []],
            transcript=[_line(x) for x in data.get("transcript") or []],
            summary=str(data.get("summary") or ""),
            decisions=[_decision(x) for x in data.get("decisions") or []],
            commitments=[_commitment(x) for x in data.get("commitments") or []],
            notes=str(data.get("notes") or ""),
        )

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    def label(self) -> str:
        """'Kickoff (2026-10-12)'."""
        return f"{self.title or self.id} ({self.date})" if self.date else (self.title or self.id)


def _line(x: Any) -> Line:
    if isinstance(x, str):
        return Line(speaker="", text=x)
    return Line(speaker=str(x.get("speaker") or ""), text=str(x.get("text") or ""), t=_seconds(x.get("t")))


def _decision(x: Any) -> Decision:
    if isinstance(x, str):
        return Decision(text=x)
    t = x.get("t")
    return Decision(text=str(x.get("text") or ""), quote=str(x.get("quote") or ""),
                    speaker=str(x.get("speaker") or ""), t=None if t is None else _seconds(t))


def _commitment(x: Any) -> Commitment:
    if isinstance(x, str):
        return Commitment(who="", what=x)
    status = str(x.get("status") or "open").lower()
    return Commitment(who=str(x.get("who") or ""), what=str(x.get("what") or ""), due=x.get("due") or None,
                      quote=str(x.get("quote") or ""), status="done" if status == "done" else "open")


def _seconds(value: Any) -> float:
    """12.5, "12.5", "01:02" or "1:02:03" -> seconds."""
    if value is None or value == "":
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).strip()
    if ":" in text:
        total = 0.0
        for part in text.split(":"):
            total = total * 60 + float(part or 0)
        return total
    try:
        return float(text)
    except ValueError:
        return 0.0


def _words(text: str) -> set[str]:
    return {w for w in re.findall(r"[\wäöüß€]+", text.lower()) if len(w) > 2 or w.isdigit() or w == "€"}


def _bare(quote: str, speaker: str) -> str:
    """A quote without a leading "Speaker: " (models copy the line as the material prints it); "\0" when it has
    none or too little follows it (under three words and 12 characters, like "Lisa: Ja"), so it matches no text."""
    head, sep, rest = quote.partition(":")
    rest = rest.strip().strip('"„“').strip()
    enough = len(rest) >= 12 or len(rest.split()) >= 3
    return rest.lower() if sep and enough and head.strip().lower() == speaker.strip().lower() else "\0"


def _same_person(a: str, b: str) -> bool:
    a, b = a.strip().lower(), b.strip().lower()
    return bool(a and b) and (a == b or a.split()[0] == b.split()[0])


@dataclass
class Hit:
    meeting: Meeting
    line: Line
    score: float


class Memory:
    """All meetings in a folder, newest last."""

    def __init__(self, folder: str | os.PathLike[str] | None = None):
        self.folder = Path(folder).expanduser() if folder else DEFAULT_DIR
        self.meetings: list[Meeting] = []
        self.errors: list[str] = []
        self.load()

    def load(self) -> None:
        self.meetings, self.errors = [], []
        if not self.folder.is_dir():
            return
        for path in sorted(self.folder.glob("*.json")):
            try:
                self.meetings.append(Meeting.from_dict(json.loads(path.read_text(encoding="utf-8"))))
            except (OSError, ValueError, AttributeError, TypeError) as error:
                self.errors.append(f"{path.name}: {error}")
        self.meetings.sort(key=lambda m: (m.date, m.id))

    def get(self, meeting_id: str) -> Meeting | None:
        return next((m for m in self.meetings if m.id == meeting_id), None)

    def path_for(self, meeting_id: str) -> Path:
        """<folder>/<id>.json, with the id made safe for a file name."""
        safe = re.sub(r"[^\w.-]+", "-", meeting_id).strip("-") or "meeting"
        return self.folder / f"{safe}.json"

    def save(self, meeting: Meeting) -> Path:
        """Writes atomically to <folder>/<id>.json and updates the in-memory list."""
        self.folder.mkdir(parents=True, exist_ok=True)
        path = self.path_for(meeting.id)
        fd, tmp = tempfile.mkstemp(dir=self.folder, suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(meeting.to_dict(), handle, ensure_ascii=False, indent=2)
        os.replace(tmp, path)
        self.meetings = [m for m in self.meetings if m.id != meeting.id] + [meeting]
        self.meetings.sort(key=lambda m: (m.date, m.id))
        return path

    def with_participants(self, names: Iterable[str]) -> list[Meeting]:
        names = [n for n in names if n]
        if not names:
            return list(self.meetings)
        return [m for m in self.meetings if any(_same_person(p, n) for p in m.participants for n in names)]

    def decisions(self, names: Iterable[str] = ()) -> list[tuple[Meeting, Decision]]:
        return [(m, d) for m in self.with_participants(names) for d in m.decisions]

    def open_commitments(self, names: Iterable[str] = ()) -> list[tuple[Meeting, Commitment]]:
        """Open commitments; with names, only those the named people made."""
        names = list(names)
        out = []
        for m in self.meetings:
            for c in m.commitments:
                if c.status == "open" and (not names or any(_same_person(c.who, n) for n in names)):
                    out.append((m, c))
        return out

    def search(self, text: str, limit: int = 5) -> list[Hit]:
        """Transcript lines sharing the most words with `text` (numbers count double)."""
        query = _words(text)
        if not query:
            return []
        hits = []
        for m in self.meetings:
            for line in m.transcript:
                common = query & _words(line.text)
                if common:
                    score = sum(2.0 if w.isdigit() else 1.0 for w in common)
                    hits.append(Hit(m, line, score))
        hits.sort(key=lambda h: (-h.score, h.meeting.date))
        return hits[:limit]

    def find_quote(self, quote: str) -> tuple[Meeting, Line] | None:
        """The transcript line that best contains `quote` (exact substring first, then word overlap)."""
        needle = quote.strip().strip('"„“').lower()
        if not needle:
            return None
        for m in reversed(self.meetings):
            for line in m.transcript:
                if needle in line.text.lower() or (line.speaker and _bare(needle, line.speaker) in line.text.lower()):
                    return m, line
        best = self.search(quote, limit=1)
        if best and best[0].score >= max(2.0, len(_words(quote)) * 0.5):
            return best[0].meeting, best[0].line
        return None

    def as_context(self, max_chars: int = 60_000) -> str:
        """Compact text of every meeting for a prompt, newest first, in at most max_chars.

        The facts of every meeting (summary, decisions, commitments) always come along, so an old decision can
        still be contradicted. Notes and transcripts share the rest: an equal part per meeting, and what a short
        one leaves over goes to the others. One longer than its part keeps its notes and the lines with numbers
        first (that's what contradictions turn on), then the earliest lines, in their order with "…" for the gaps.
        """
        newest = list(reversed(self.meetings))
        facts = [_facts(m) for m in newest]
        details = [_details(m) for m in newest]
        room = max_chars - sum(len(f) + 2 for f in facts)
        shares = _shares([sum(len(text) + 1 for _, text in rows) for rows in details], room)
        blocks = ["\n".join([f, *_excerpt(rows, share)]) for f, rows, share in zip(facts, details, shares)]
        return "\n\n".join(blocks)[:max_chars]


def _facts(m: Meeting) -> str:
    parts = [f"## Meeting id={m.id} | {m.title} | {m.date} | participants: {', '.join(m.participants)}"]
    if m.summary:
        parts.append(f"Summary: {m.summary}")
    for d in m.decisions:
        parts.append(f"Decision: {d.text}" + (f' — quote: "{d.quote}"' if d.quote else ""))
    for c in m.commitments:
        due = f" (due {c.due})" if c.due else ""
        parts.append(f"Commitment [{c.status}]: {c.who}: {c.what}{due}" + (f' — quote: "{c.quote}"' if c.quote else ""))
    return "\n".join(parts)


def _details(m: Meeting) -> list[tuple[int, str]]:
    """(rank, line) of a meeting's notes and transcript; rank 0 is kept first, 2 last."""
    rows = [(0, "Notes:")] + [(0, line) for line in m.notes.splitlines() if line.strip()] if m.notes.strip() else []
    if m.transcript:
        rows.append((0, "Transcript:"))
        for line in m.transcript:
            rows.append((1 if re.search(r"\d", line.text) else 2, f"[{_clock(line.t)}] {line.speaker}: {line.text}"))
    return rows


def _shares(sizes: list[int], room: int) -> list[int]:
    """Splits room into equal parts, smallest size first, so what one doesn't need goes to the rest."""
    shares, left = [0] * len(sizes), max(room, 0)
    order = sorted(range(len(sizes)), key=lambda i: sizes[i])
    for n, i in enumerate(order):
        shares[i] = min(sizes[i], left // (len(order) - n))
        left -= shares[i]
    return shares


def _excerpt(rows: list[tuple[int, str]], room: int) -> list[str]:
    """All lines if they fit in room chars, else the best-ranked that do, in their order, "…" where lines are left out."""
    if sum(len(text) + 1 for _, text in rows) <= room:
        return [text for _, text in rows]
    keep, used = set(), 0
    for i in sorted(range(len(rows)), key=lambda i: (rows[i][0], i)):
        cost = len(rows[i][1]) + 3  # the line, its break and a possible "…" after it
        if used + cost <= room:
            keep.add(i)
            used += cost
    out: list[str] = []
    for i, (_, text) in enumerate(rows):
        if i in keep:
            out.append(text)
        elif out[-1:] != ["…"]:
            out.append("…")
    return out if keep else []


def _clock(seconds: float) -> str:
    s = int(seconds)
    return f"{s // 60:02d}:{s % 60:02d}" if s < 3600 else f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}"
