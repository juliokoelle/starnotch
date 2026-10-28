"""Tara's memory as an MCP server: any AI app on this Mac can look things up in it, read only.

    uv run --directory "$HOME/Library/Application Support/Starnotch/agent" python memory_mcp.py

Starnotch registers it as `starnotch-memory` in Claude Desktop, Claude Code, Cursor and ChatGPT's Mac app (its own setup step, or
Settings › Tara's memory › Choose apps…). Tools:

- search_memory: meetings, quick captures, notes and agent sessions that share words with a query.
- get_meeting: one meeting in full (summary, decisions, commitments, notes, transcript).
- open_commitments: what people promised in meetings and the tasks you captured, still open.
- recent_decisions: decisions from the meetings of the last days.
- today: today's calendar, tasks due or overdue, commitments due.

Today's calendar comes from `calendar-today.json`, which the app writes into its folder while an AI app is set up and
meetings may be recorded; only events of the local day count, and a file from an earlier day counts as none.

Every result names where it comes from (`source`, `id`, and a `link` when there is one). Nothing here writes. The
privacy switches (Settings › Tara's memory, `privacy.json`) are read on every call: a source that is off is left
out and said so in `left_out`; a pause only stops new recordings, so what Tara has stays searchable.
"""

from __future__ import annotations

import datetime as dt
import json
import re
from pathlib import Path
from typing import Any

from mcp.server.mcpserver import MCPServer
from mcp.types import ToolAnnotations

import captures as quick
import connectors as linked
import privacy as switches
from memory import DEFAULT_DIR, Meeting, Memory, _words

CLAUDE_PROJECTS = Path.home() / ".claude" / "projects"
CALENDAR = DEFAULT_DIR.parent / "calendar-today.json"
MAX_TRANSCRIPT_CHARS = 40_000
READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)


def _score(query: set[str], text: str) -> float:
    common = query & _words(text)
    return sum(2.0 if w.isdigit() else 1.0 for w in common)


def _short(text: str, limit: int = 300) -> str:
    text = " ".join(str(text or "").split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def _meeting_source(m: Meeting) -> dict[str, Any]:
    return {"source": "meeting", "id": m.id, "title": m.title or m.id, "date": m.date}


def _capture_source(c: quick.Capture) -> dict[str, Any]:
    return {"source": "capture", "id": c.id, "title": _short(c.text, 80), "date": c.day, "kind": c.route}


def _item_source(item: linked.Item) -> dict[str, Any]:
    out = {"source": "note", "id": item.id, "title": item.title, "date": item.date, "from": item.source}
    if item.url:
        out["link"] = item.url
    return out


def recent_sessions(root: Path, now: dt.datetime, days: float = 7, limit: int = 20) -> list[dict[str, Any]]:
    """Claude Code sessions changed in the last days, newest first: title, folder, when. Only the session's title
    (the user's or the generated one, else the folder's name) and folder are read from the head and tail of each
    transcript, never what was said."""
    found = []
    try:
        folders = [d for d in root.iterdir() if d.is_dir()]
    except OSError:
        return []
    for folder in folders:
        for file in folder.glob("*.jsonl"):
            try:
                mtime = dt.datetime.fromtimestamp(file.stat().st_mtime, dt.timezone.utc)
            except OSError:
                continue
            if (now - mtime).total_seconds() < days * 86_400:
                found.append((mtime, file))
    out = []
    for mtime, file in sorted(found, reverse=True):
        if len(out) >= limit:
            break
        title, cwd = _session_title(file)
        title = title or Path(cwd).name
        if title and cwd:
            out.append({"source": "session", "id": file.stem, "title": title, "folder": cwd,
                        "date": mtime.isoformat(timespec="minutes"), "tool": "Claude Code"})
    return out


def _session_title(file: Path) -> tuple[str, str]:
    """The user's name for the session, else the generated one (empty when it has neither); and its folder."""
    custom = ai = cwd = ""
    try:
        with file.open("rb") as handle:
            head = handle.read(64 * 1024)
            handle.seek(0, 2)
            size = handle.tell()
            handle.seek(max(0, size - 64 * 1024))
            tail = handle.read()
    except OSError:
        return "", ""
    for chunk in (head, tail):
        for raw in chunk.decode("utf-8", "replace").splitlines():
            try:
                record = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(record, dict):
                continue
            kind = record.get("type")
            if kind == "custom-title" and isinstance(record.get("customTitle"), str):
                custom = record["customTitle"]
            elif kind == "ai-title" and isinstance(record.get("aiTitle"), str):
                ai = record["aiTitle"]
            if isinstance(record.get("cwd"), str):
                cwd = record["cwd"]
    return custom or ai, cwd


class Library:
    """Everything the tools read, from the app's folder (or the folders tests pass)."""

    def __init__(self, memory_dir: Path | None = None, captures: Path | None = None, connectors: Path | None = None,
                 claude_projects: Path | None = None, privacy_file: Path | None = None,
                 now: dt.datetime | None = None, calendar: Path | None = None):
        self.memory_dir = memory_dir or DEFAULT_DIR
        self.captures_path = captures or quick.QUEUE
        self.connectors_path = connectors or linked.FOLDER
        self.claude_projects = claude_projects or CLAUDE_PROJECTS
        self.privacy_file = privacy_file
        self.calendar_path = calendar or CALENDAR
        self.fixed_now = now

    @property
    def now(self) -> dt.datetime:
        return self.fixed_now or dt.datetime.now(dt.timezone.utc)

    @property
    def today(self) -> dt.date:
        return (self.fixed_now or dt.datetime.now()).date()

    def privacy(self) -> switches.Privacy:
        return switches.load(self.privacy_file)

    def meetings(self, p: switches.Privacy) -> list[Meeting]:
        return Memory(self.memory_dir).meetings if p.shares("meetings") else []

    def captures(self, p: switches.Privacy) -> list[quick.Capture]:
        return quick.read(self.captures_path) if p.shares("captures") else []

    def items(self, p: switches.Privacy) -> list[linked.Item]:
        return linked.read(self.connectors_path) if p.shares("notes") else []

    def calendar(self, p: switches.Privacy) -> tuple[list[dict[str, Any]], str]:
        """Today's events from the app's calendar file, and a note when there are none to trust (file missing or from
        an earlier day). Only events that start today (local) count."""
        if not p.shares("meetings"):
            return [], ""
        try:
            data = json.loads(self.calendar_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return [], "Starnotch hasn't written today's calendar (no AI app set up before, Calendar access off, or not open yet)."
        today = self.today.isoformat()
        updated = str(data.get("updated") or "") if isinstance(data, dict) else ""
        if updated[:10] != today:
            why = "Tara's memory is paused" if p.is_paused() else "Starnotch wasn't open today"
            return [], f"The calendar Starnotch wrote is from {updated[:10] or 'an earlier day'} ({why}), so today's events are unknown."
        events = []
        for e in data.get("today") or []:
            if not isinstance(e, dict) or not str(e.get("date") or "").startswith(today):
                continue
            event = {"title": str(e.get("title") or ""), "start": e.get("date"), "end": e.get("end"), "source": "calendar"}
            for key in ("location", "attendees"):
                if e.get(key):
                    event[key] = e[key]
            if e.get("url"):
                event["link"] = e["url"]
            events.append(event)
        return events, ""

    def sessions(self, p: switches.Privacy) -> list[dict[str, Any]]:
        return recent_sessions(self.claude_projects, self.now) if p.shares("sessions") else []

    def envelope(self, p: switches.Privacy, wanted: tuple[str, ...], **rest: Any) -> dict[str, Any]:
        """The fields every answer carries: what was left out and whether Tara is paused."""
        out = dict(rest)
        left = [s for s in wanted if not p.shares(s)]
        if left:
            out["left_out"] = left
            out["note"] = "The user switched these sources off in Starnotch (Settings › Tara's memory)."
        if p.is_paused():
            out["paused"] = True
        return out


def search(lib: Library, query: str, sources: list[str] | None = None, limit: int = 8) -> dict[str, Any]:
    p = lib.privacy()
    asked = tuple(s for s in (sources or ["meetings", "captures", "notes", "sessions"])
                  if s in ("meetings", "captures", "notes", "sessions"))
    words = _words(query)
    hits: list[tuple[float, str, dict[str, Any]]] = []
    if words and "meetings" in asked:
        for m in lib.meetings(p):
            facts = [("summary", m.summary)] + [("decision", d.text + " " + d.quote) for d in m.decisions] \
                + [("commitment", f"{c.who} {c.what} {c.quote}") for c in m.commitments] + [("title", m.title)]
            for kind, text in facts:
                score = _score(words, text)
                if score:
                    hits.append((score + 0.5, m.date, {**_meeting_source(m), "match": kind, "text": _short(text)}))
            for line in m.transcript:
                score = _score(words, line.text)
                if score:
                    hits.append((score, m.date, {**_meeting_source(m), "match": "transcript",
                                                 "text": _short(f"{line.speaker}: {line.text}" if line.speaker else line.text),
                                                 "at_seconds": line.t}))
    if words and "captures" in asked:
        for c in lib.captures(p):
            score = _score(words, c.text)
            if score:
                hits.append((score, c.day, {**_capture_source(c), "text": _short(c.text)}))
    if words and "notes" in asked:
        for item in lib.items(p):
            score = _score(words, item.title + " " + item.body)
            if score:
                hits.append((score, item.date, {**_item_source(item), "text": _short(item.body or item.title)}))
    if words and "sessions" in asked:
        for s in lib.sessions(p):
            score = _score(words, s["title"] + " " + Path(s["folder"]).name)
            if score:
                hits.append((score, s["date"], s))
    # the best first; on a tie, the newer first
    hits.sort(key=lambda h: (h[0], str(h[1] or "")), reverse=True)
    results = [h[2] for h in hits[: max(1, min(limit, 30))]]
    return lib.envelope(p, asked, query=query, results=results,
                        **({} if results else {"message": "Nothing in Tara's memory shares words with this."}))


def meeting(lib: Library, meeting_id: str) -> dict[str, Any]:
    p = lib.privacy()
    if not p.shares("meetings"):
        return lib.envelope(p, ("meetings",), error="Meetings are switched off in Starnotch.")
    found = next((m for m in lib.meetings(p) if m.id == meeting_id), None)
    if found is None:
        known = [m.id for m in reversed(lib.meetings(p))][:20]
        return {"error": f"No meeting with id {meeting_id!r}.", "recent_ids": known}
    lines, used, cut = [], 0, False
    for line in found.transcript:
        text = f"{line.speaker}: {line.text}" if line.speaker else line.text
        if used + len(text) > MAX_TRANSCRIPT_CHARS:
            cut = True
            break
        lines.append({"t": line.t, "speaker": line.speaker, "text": line.text})
        used += len(text)
    out = {**_meeting_source(found), "participants": found.participants, "summary": found.summary, "notes": found.notes,
           "decisions": [d.__dict__ for d in found.decisions], "commitments": [c.__dict__ for c in found.commitments],
           "transcript": lines}
    if cut:
        out["transcript_cut"] = f"The first {len(lines)} of {len(found.transcript)} lines."
    return lib.envelope(p, ("meetings",), **out)


def commitments(lib: Library, person: str = "") -> dict[str, Any]:
    p = lib.privacy()
    today = lib.today.isoformat()
    first = person.strip().split(" ")[0].lower() if person.strip() else ""
    items = []
    for m in reversed(lib.meetings(p)):
        for c in m.commitments:
            if c.status != "open" or (first and (c.who.strip().split(" ")[0].lower() if c.who.strip() else "") != first):
                continue
            items.append({"who": c.who, "what": c.what, "due": c.due, "overdue": bool(c.due) and str(c.due) < today,
                          "quote": c.quote, **_meeting_source(m)})
    for c in reversed(lib.captures(p)):
        if c.route != "task" or (first and not quick.mentions(c, person)):
            continue
        items.append({"who": "you", "what": c.text, "due": c.due, "overdue": bool(c.due) and str(c.due) < today,
                      **_capture_source(c)})
    return lib.envelope(p, ("meetings", "captures"), person=person or None, open=items)


def decisions(lib: Library, days: int = 30, person: str = "") -> dict[str, Any]:
    p = lib.privacy()
    since = (lib.today - dt.timedelta(days=max(1, days))).isoformat()
    memory = Memory.empty(lib.memory_dir)
    memory.meetings = lib.meetings(p)
    rows = [(m, d) for m, d in memory.decisions([person] if person.strip() else [])]
    out = [{"decision": d.text, "quote": d.quote, "speaker": d.speaker, **_meeting_source(m)}
           for m, d in reversed(rows) if (m.date or "") >= since]
    return lib.envelope(p, ("meetings",), since=since, decisions=out)


def today_view(lib: Library) -> dict[str, Any]:
    p = lib.privacy()
    today = lib.today.isoformat()
    items = lib.items(p)
    events, calendar_note = lib.calendar(p)
    tasks = []
    for i in items:
        if i.group != "tasks":
            continue
        due = (i.date or "")[:10]
        if due and due <= today:
            tasks.append({"task": i.title, "due": due, "overdue": due < today, **_item_source(i)})
    for c in lib.captures(p):
        if c.route == "task" and c.due and str(c.due) <= today:
            tasks.append({"task": c.text, "due": c.due, "overdue": str(c.due) < today, **_capture_source(c)})
    promised = [row for row in commitments(lib)["open"] if row.get("source") == "meeting" and row.get("due")
                and str(row["due"]) <= today]
    out = lib.envelope(p, ("meetings", "captures", "notes"), date=today, events=events, tasks=tasks,
                       commitments_due=promised)
    if calendar_note:
        out["calendar"] = calendar_note
    return out


def build(lib: Library | None = None) -> MCPServer:
    """The server; `lib` is the seam for tests."""
    library = lib or Library()
    server = MCPServer(
        "starnotch-memory",
        instructions=("Tara's memory from Starnotch, on the user's Mac: their meetings (transcripts, decisions, "
                      "commitments), the tasks and notes they captured, their notes vault, today's calendar and their "
                      "recent agent sessions. Read only. Use it when the user refers to something they discussed, "
                      "promised, decided or noted, or asks about their day. Cite the source and id of what you use. "
                      "Sources the user switched off are listed in left_out; don't guess what they hold."),
    )

    @server.tool(annotations=READ_ONLY)
    def search_memory(query: str, sources: list[str] | None = None, limit: int = 8) -> dict[str, Any]:
        """Search Tara's memory for words: meetings (summaries, decisions, commitments, transcript lines), quick
        captures, notes and recent agent sessions. sources: any of meetings, captures, notes, sessions (default
        all). Returns the best matches first, each with source, id, title, date and the matching text."""
        return search(library, query, sources, limit)

    @server.tool(annotations=READ_ONLY)
    def get_meeting(meeting_id: str) -> dict[str, Any]:
        """One meeting in full: participants, summary, notes, decisions and commitments with quotes, and the
        transcript (cut at about 40,000 characters). meeting_id comes from search_memory or the other tools."""
        return meeting(library, meeting_id)

    @server.tool(annotations=READ_ONLY)
    def open_commitments(person: str = "") -> dict[str, Any]:
        """What is still open: promises people made in meetings, and tasks the user captured. person: only what
        that person promised (first name is enough). Each item has who, what, due, overdue and its source."""
        return commitments(library, person)

    @server.tool(annotations=READ_ONLY)
    def recent_decisions(days: int = 30, person: str = "") -> dict[str, Any]:
        """Decisions from the meetings of the last `days` days, newest first, each with its quote and meeting.
        person: only meetings that person was in."""
        return decisions(library, days, person)

    @server.tool(annotations=READ_ONLY)
    def today() -> dict[str, Any]:
        """The user's day: today's calendar events, tasks due today or overdue (notes vault and captures), and
        commitments from meetings that are due."""
        return today_view(library)

    return server


if __name__ == "__main__":
    build().run()
