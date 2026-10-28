"""Fetches meetings from Jamie's MCP server into the meeting memory.

    uv run python jamie_sync.py                  # first run opens the browser for the Jamie login
    uv run python jamie_sync.py --limit 200 --memory demo/jamie
    uv run python jamie_sync.py --query "Preis"   # only what search_meetings finds
    uv run python jamie_sync.py --list-tools     # prints the server's tools and their input schemas
    uv run python jamie_sync.py --logout         # forgets the login, so the next run can sign in as someone else
    uv run python jamie_sync.py --no-login       # the app's automatic syncs: never opens the browser

Jamie's tools (list_meetings, get_meeting, get_meeting_transcript, search_meetings, list_tasks) are called with
whatever argument names their input schemas declare, and their answers are mapped onto memory.py's schema field by
field, so small differences in Jamie's JSON don't break the sync. list_meetings is paged until --limit, list_tasks
to its end; a transcript that get_meeting cuts short is read in full through get_meeting_transcript. A meeting whose Jamie data didn't change
since the last sync is skipped (fingerprints in <memory>/jamie-sync.state). Prints one JSON line per meeting, then a
summary line.
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import hashlib
import json
import os
import re
import sys
import tempfile
import time
import webbrowser
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

import privacy
from memory import DEFAULT_DIR, Commitment, Decision, Line, Meeting, Memory, _seconds

JAMIE_URL = "https://mcp.meetjamie.ai/mcp"
TOKEN_FILE = DEFAULT_DIR.parent / "jamie-oauth.json"
CALLBACK_PORT = 47791  # next to the app's ports; 8765 is a common dev-server port
STATE_FILE = "jamie-sync.state"  # in the memory folder; not *.json, so Memory doesn't take it for a meeting
MAPPING = 3  # raise when meeting_of maps differently: every meeting is then written again on the next sync
PAGE_SIZE = 100  # list_meetings and list_tasks take at most 100 per page
MAX_PAGES = 500  # against a server that never says a list or transcript is finished
PARALLEL = 4  # meetings fetched at the same time

# Our name for an argument -> names a tool's input schema may use for it
ARG_ALIASES = {
    "id": ["meeting_id", "meetingId", "id", "uuid"],
    "limit": ["limit", "page_size", "pageSize", "max_results", "count", "n"],
    "since": ["since", "from", "start_date", "startDate", "after", "from_date"],
    "query": ["query", "q", "search", "text"],
    "cursor": ["cursor", "page_token", "pageToken", "next_cursor", "nextCursor"],
}


# Reading tool results

def tool_args(tool: Any, wanted: dict[str, Any]) -> dict[str, Any]:
    """Maps {"id": ..., "limit": ...} onto the argument names the tool declares; drops what it doesn't take."""
    schema = getattr(tool, "input_schema", None) or {}
    properties = schema.get("properties") or {}
    args = {}
    for key, value in wanted.items():
        if value is None:
            continue
        name = next((alias for alias in ARG_ALIASES.get(key, [key]) if alias in properties), None)
        if name is None and key == "id" and len(schema.get("required") or []) == 1:
            name = schema["required"][0]  # the one required argument is the meeting's id
        if name:
            args[name] = value
    return args


def result_data(result: Any) -> Any:
    """structured content if present, else the text blocks parsed as JSON (or the raw text)."""
    if getattr(result, "is_error", False):
        text = " ".join(getattr(b, "text", "") for b in result.content or [])
        raise RuntimeError(f"Jamie tool error: {text[:300]}")
    structured = getattr(result, "structured_content", None)
    if structured:
        return _maybe_json(structured["result"]) if set(structured) == {"result"} else structured
    parsed = [_maybe_json(b.text) for b in (result.content or []) if getattr(b, "type", "") == "text"]
    return parsed[0] if len(parsed) == 1 else parsed


def _maybe_json(value: Any) -> Any:
    if not isinstance(value, str):
        return value
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return value


def as_list(data: Any, keys: tuple[str, ...] = ("meetings", "items", "data", "results", "tasks", "records")) -> list[Any]:
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for key in keys:
            if isinstance(data.get(key), list):
                return data[key]
        for key in keys:  # {"data": {"meetings": [...]}}
            if isinstance(data.get(key), dict):
                return as_list(data[key], keys)
        if first(data, "id", "meeting_id", "meetingId", "uuid"):  # a one-item list comes back as one block
            return [data]
    return []


def first(obj: Any, *keys: str, default: Any = None) -> Any:
    if not isinstance(obj, dict):
        return default
    for key in keys:
        value = obj.get(key)
        if value not in (None, "", []):
            return value
    return default


def text_of(value: Any) -> str:
    """A string from a string, or from a dict like {"text": ...} / {"markdown": ...} / a list of those."""
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, list):
        return "\n".join(t for t in (text_of(v) for v in value) if t)
    if isinstance(value, dict):
        return text_of(first(value, "text", "markdown", "content", "short", "overview", "summary", "title", "description"))
    return str(value)


def person(value: Any) -> str:
    if isinstance(value, str):
        return value.strip()
    return str(first(value, "name", "display_name", "displayName", "full_name", "email", default="")).strip()


SPEAKER_LINE = re.compile(r"^\s*(?:\[?(\d{1,2}:\d{2}(?::\d{2})?)\]?\s*)?([^:\n]{1,60}):\s+(.+)$")
# Jamie's transcript text: "Speaker 0", a blank line, "###### 00:00 - 00:08", a blank line, then what was said
BLOCK_TIME = re.compile(r"^#{1,6}\s*(\d{1,2}:\d{2}(?::\d{2})?)\s*[-–]\s*\d{1,2}:\d{2}(?::\d{2})?\s*$")
# A voice Jamie couldn't put a name to; "Speaker -1" is one it couldn't tell apart at all
GENERIC_SPEAKER = re.compile(r"^(speaker|sprecher)\s*-?\d+$", re.IGNORECASE)
UNKNOWN_SPEAKER = re.compile(r"^(speaker|sprecher)\s*-1$", re.IGNORECASE)


def transcript_of(value: Any, names: dict[str, str] | None = None) -> list[Line]:
    """Lines from Jamie's block text, from "Name: text" lines, or from a list of segments.
    `names` renames speaker labels ("Speaker 0" -> "Max")."""
    names = names or {}

    def speaker_name(label: str) -> str:
        label = label.strip()
        return "" if UNKNOWN_SPEAKER.match(label) else names.get(label, label)

    if isinstance(value, dict):
        value = first(value, "segments", "utterances", "entries", "lines", "transcript", "text", default=[])
    if isinstance(value, str):
        rows = [raw.strip() for raw in value.splitlines() if raw.strip()]
        if any(BLOCK_TIME.match(row) for row in rows):
            return _blocks(rows, speaker_name)
        lines = []
        for raw in rows:
            match = SPEAKER_LINE.match(raw)
            if match:
                lines.append(Line(speaker_name(match.group(2)), match.group(3).strip(), _seconds(match.group(1))))
            else:
                lines.append(Line("", raw))
        return lines
    lines = []
    for item in value or []:
        if isinstance(item, str):
            lines.append(Line("", item))
            continue
        speaker = first(item, "speaker", "speaker_name", "speakerName", "name", default="")
        lines.append(Line(
            speaker=speaker_name(person(speaker)),
            text=text_of(first(item, "text", "content", "sentence", "words", default="")),
            t=_seconds(first(item, "t", "start", "start_time", "startTime", "offset", "timestamp", default=0)),
        ))
    return [line for line in lines if line.text]


def _blocks(rows: list[str], speaker_name) -> list[Line]:
    """One Line per block: the row above a time heading is the speaker, the rows below it what was said."""
    lines: list[Line] = []
    i = 0
    while i < len(rows):
        heading = BLOCK_TIME.match(rows[i + 1]) if i + 1 < len(rows) and not BLOCK_TIME.match(rows[i]) else None
        if heading:  # "Speaker 0" over "###### 00:00 - 00:08"
            lines.append(Line(speaker_name(rows[i]), "", _seconds(heading.group(1))))
            i += 2
        elif BLOCK_TIME.match(rows[i]):  # a heading without speaker, e.g. at the top of a transcript page
            lines.append(Line("", "", _seconds(BLOCK_TIME.match(rows[i]).group(1))))
            i += 1
        else:
            if not lines:
                lines.append(Line("", ""))
            lines[-1].text = f"{lines[-1].text} {rows[i]}".strip()
            i += 1
    return [line for line in lines if line.text]


def speaker_names(participants: list[Any]) -> dict[str, str]:
    """{"Speaker 0": "Max"} for each participant Jamie has a name for, by the participant's id."""
    names = {}
    for p in participants or []:
        if isinstance(p, dict) and p.get("id") is not None:
            name = person(p)
            if name and not GENERIC_SPEAKER.match(name):
                names[f"Speaker {p['id']}"] = name
    return names


def markdown_sections(markdown: str) -> list[tuple[str, list[str]]]:
    """[(heading, lines under it until the next heading)]; text above the first heading has heading ""."""
    sections: list[tuple[str, list[str]]] = [("", [])]
    for raw in markdown.splitlines():
        heading = re.match(r"^#{1,6}\s+(.+?)\s*#*\s*$", raw)
        if heading:
            sections.append((clean_markdown(heading.group(1)), []))
        else:
            sections[-1][1].append(raw)
    return [(h, lines) for h, lines in sections if h or any(l.strip() for l in lines)]


def clean_markdown(text: str) -> str:
    """Without bold/italic markers and with single spaces; bullets and line breaks stay."""
    text = re.sub(r"\*{2,}|__", "", text)
    return "\n".join(re.sub(r"[ \t]+", " ", line).rstrip() for line in text.strip().splitlines()).strip()


def bullets(lines: list[str]) -> list[str]:
    """The top-level items of a markdown list (nested items belong to their parent and are dropped)."""
    items = []
    for raw in lines:
        match = re.match(r"^(?:[-*+]|\d+[.)])\s+(.+)$", raw)  # no indentation: top level only
        if match:
            items.append(match.group(1).strip())
    return items


def _heading_is(heading: str, pattern: re.Pattern[str]) -> bool:
    words = re.sub(r"[^\w\s-]", "", heading).strip()  # without emoji and colons
    return bool(pattern.fullmatch(words))


SUMMARY_HEAD = re.compile(r"(executive summary|summary|overview|tl;?dr|zusammenfassung|überblick|kurzfassung)", re.I)
DECISION_HEAD = re.compile(r"((key|important|wichtige|getroffene) )?(decisions?( made)?|entscheidungen|beschlüsse)", re.I)
ACTION_HEAD = re.compile(r"(action items?|next steps|to-?dos?|tasks|follow-?ups?|aufgaben|nächste schritte|maßnahmen)", re.I)


def commitment_from_bullet(text: str) -> Commitment:
    """'[x] **Lisa**: Folien schicken bis 2026-10-30' -> who, what, due and status from one summary bullet."""
    status = "open"
    box = re.match(r"^\[( |x|X)\]\s*(.*)$", text)
    if box:
        status, text = ("done" if box.group(1).lower() == "x" else "open"), box.group(2)
    who = ""
    named = re.match(r"^\*\*([^*]{1,40})\*\*\s*[:–-]\s*(.+)$", text) or re.match(r"^([^:*]{1,40}):\s+(.+)$", text)
    if named and len(named.group(1).split()) <= 4:
        who, text = named.group(1).strip(), named.group(2)
    due = re.search(r"\b(\d{4}-\d{2}-\d{2})\b", text)
    return Commitment(who=who, what=clean_markdown(text), due=due.group(1) if due else None, status=status)


def commitment_of(item: Any) -> Commitment:
    if isinstance(item, str):
        return Commitment(who="", what=item)
    done = first(item, "completed", "done", "is_completed", "isCompleted", default=False)
    status = str(first(item, "status", "state", default="")).lower()
    due = first(item, "due", "due_date", "dueDate", "deadline")
    return Commitment(
        who=person(first(item, "who", "assignee", "owner", "assigned_to", "assignedTo", default="")),
        what=text_of(first(item, "what", "title", "text", "description", "name", default="")),
        due=str(due)[:10] if due else None,
        quote=text_of(first(item, "quote", "source", "context", default="")),
        status="done" if done is True or status in ("done", "completed", "closed", "complete") else "open",
    )


def tasks_for(tasks: list[Any], jamie_id: str) -> list[Any]:
    return [t for t in tasks if str(first(t, "meeting_id", "meetingId", default="")) == jamie_id]


def meeting_of(raw: dict[str, Any], tasks: list[Any] = ()) -> Meeting:
    """Jamie's meeting JSON (list entry merged with get_meeting) -> memory.Meeting."""
    jamie_id = str(first(raw, "id", "meeting_id", "meetingId", "uuid", default=""))
    if not jamie_id:
        raise ValueError("meeting without id")
    people = first(raw, "participants", "attendees", "speakers", default=[]) or []
    event = raw.get("event") if isinstance(raw.get("event"), dict) else {}
    owner = str(first(raw.get("user"), "email", default="")).lower()  # the Jamie user: in every meeting, says nothing
    participants = []
    for p in [*people, *(first(event, "attendees", default=[]) or [])]:
        if isinstance(p, dict) and owner and str(p.get("email") or "").lower() == owner:
            continue
        name = person(p)
        if name and not GENERIC_SPEAKER.match(name) and name not in participants:
            participants.append(name)

    summary = first(raw, "summary", "short_summary", "overview", "notes", default="")
    markdown = summary if isinstance(summary, str) else str(first(summary, "markdown", "text", "content", default=""))
    sections = markdown_sections(markdown)
    overview = next((clean_markdown("\n".join(lines)) for h, lines in sections if _heading_is(h, SUMMARY_HEAD)), "")
    summary_text = overview or (text_of(first(summary, "short", "overview")) if isinstance(summary, dict) else "") \
        or clean_markdown(markdown) or text_of(summary)
    # The summary is its short part, for the prep card; the whole summary is kept as notes (the memory is the only copy).
    notes = markdown.strip() if clean_markdown(markdown) != summary_text else ""

    decisions = [Decision(text=text_of(d)) if not isinstance(d, dict) else
                 Decision(text=text_of(first(d, "text", "title", "decision", "description", default="")),
                          quote=text_of(first(d, "quote", "source", default="")))
                 for d in first(raw, "decisions", "key_decisions", "keyDecisions", default=[]) or []]
    decisions += [Decision(text=clean_markdown(b)) for h, lines in sections if _heading_is(h, DECISION_HEAD)
                  for b in bullets(lines)]
    own = list(first(raw, "commitments", "action_items", "actionItems", "tasks", "todos", default=[]) or [])
    own += tasks_for(list(tasks), jamie_id)
    items = [commitment_of(item) for item in own]
    if not items:  # Jamie's tasks know who, due and done; the summary's action items only when there are none
        items = [commitment_from_bullet(b) for h, lines in sections if _heading_is(h, ACTION_HEAD) for b in bullets(lines)]
    commitments, seen = [], set()
    for c in items:
        if c.what and (c.who, c.what) not in seen:
            seen.add((c.who, c.what))
            commitments.append(c)
    date = str(first(raw, "date", "start_time", "startTime", "started_at", "startedAt", "created_at", "createdAt", default=""))
    return Meeting(
        id=f"jamie-{jamie_id}",
        title=text_of(first(raw, "title", "name", "subject", default="")) or "Meeting",
        date=date[:10],
        participants=participants,
        transcript=transcript_of(first(raw, "transcript", "transcription", "segments", default=[]), speaker_names(people)),
        summary=summary_text,
        decisions=[d for d in decisions if d.text],
        commitments=commitments,
        notes=notes,
    )


def fingerprint(raw: dict[str, Any], tasks: list[Any]) -> str:
    """Changes when anything Jamie says about the meeting changes; the transcript counts by its size, since
    get_meeting returns only its start."""
    info = raw.get("transcriptInfo") if isinstance(raw.get("transcriptInfo"), dict) else {}
    transcript = json.dumps(raw.get("transcript"), ensure_ascii=False)
    size = first(info, "totalBytes", "total_bytes") or len(transcript.encode())
    rest = {k: v for k, v in raw.items() if k not in ("transcript", "transcriptInfo")}
    blob = json.dumps([MAPPING, rest, size, tasks], sort_keys=True, ensure_ascii=False, default=str)
    return hashlib.sha256(blob.encode()).hexdigest()[:16]


def truncated(raw: dict[str, Any]) -> bool:
    info = raw.get("transcriptInfo")
    return isinstance(info, dict) and info.get("truncated") is True


# Syncing

def load_state(memory: Memory) -> dict[str, str]:
    try:
        data = json.loads((memory.folder / STATE_FILE).read_text())
        return data.get("meetings", {}) if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def last_synced(folder: Path) -> dt.datetime | None:
    """When the last sync into `folder` finished: the state file is written only then (local time)."""
    try:
        return dt.datetime.fromtimestamp((Path(folder) / STATE_FILE).stat().st_mtime)
    except OSError:
        return None


def save_state(memory: Memory, seen: dict[str, str]) -> None:
    memory.folder.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=memory.folder, suffix=".tmp")
    with os.fdopen(fd, "w") as handle:
        json.dump({"meetings": seen}, handle, indent=1, sort_keys=True)
    os.replace(tmp, memory.folder / STATE_FILE)


async def sync(session: Any, memory: Memory, limit: int = 50, since: str | None = None, query: str | None = None,
               force: bool = False, log=lambda obj: print(json.dumps(obj, ensure_ascii=False), flush=True)) -> list[Meeting]:
    """Brings the newest `limit` meetings into `memory` and returns them (written or unchanged), newest first.
    Ends with the summary status line."""
    tools = {t.name: t for t in (await session.list_tools()).tools}
    if "list_meetings" not in tools:
        raise RuntimeError(f"Jamie has no list_meetings tool (tools: {', '.join(sorted(tools))})")

    def takes(name: str, key: str) -> bool:
        return bool(tool_args(tools[name], {key: "x"}))

    async def call(name: str, **wanted: Any) -> Any:
        return result_data(await session.call_tool(name, tool_args(tools[name], wanted)))

    if since and re.fullmatch(r"\d{4}-\d{2}-\d{2}", since):
        since = f"{since}T00:00:00Z"  # Jamie's date filters take a date-time
    if query and "search_meetings" in tools:
        listed = as_list(await call("search_meetings", query=query, limit=limit, since=since))[:limit]
    else:
        listed, cursor = [], None
        for _ in range(MAX_PAGES):
            page = await call("list_meetings", limit=min(PAGE_SIZE, limit - len(listed)), since=since, cursor=cursor)
            listed += as_list(page)
            following = first(page, "nextCursor", "next_cursor")
            if len(listed) >= limit or not following or following == cursor or not takes("list_meetings", "cursor"):
                break
            cursor = following
        listed = listed[:limit]
    # Every page of tasks: they belong to the fingerprint, so a cut list would rewrite older meetings without theirs.
    # None when they couldn't be read: stored meetings then stay as they are, new ones are written and redone next time.
    tasks: list[Any] | None = []
    if "list_tasks" in tools:
        try:
            cursor = None
            for _ in range(MAX_PAGES):
                page = await call("list_tasks", limit=PAGE_SIZE, cursor=cursor)
                tasks += as_list(page)
                following = first(page, "nextCursor", "next_cursor")
                if not following or following == cursor or not takes("list_tasks", "cursor"):
                    break
                cursor = following
        except Exception as error:  # tasks are a bonus; meetings still sync
            log({"type": "status", "state": "warning", "message": f"list_tasks: {error}"})
            tasks = None

    async def full_transcript(meeting_id: str) -> Any:
        """Every page of get_meeting_transcript, joined (a page may end in the middle of a line)."""
        pages, cursor = [], None
        for _ in range(MAX_PAGES):
            page = await call("get_meeting_transcript", id=meeting_id, cursor=cursor)
            pages.append(first(page, "transcript", "text", "content", default="") if isinstance(page, dict) else page)
            following = first(page, "nextCursor", "next_cursor")
            if first(page, "isFinal", "is_final") is True or not following or following == cursor:
                break
            cursor = following
        if all(isinstance(p, str) for p in pages):
            return "".join(pages)
        return [segment for p in pages for segment in (p if isinstance(p, list) else [p])]

    seen = load_state(memory)
    gate = asyncio.Semaphore(PARALLEL)
    updated = unchanged = stale = 0

    def keep(stored: Meeting) -> Meeting:
        """The copy from last time, counted and logged, when Jamie couldn't give the whole meeting now."""
        nonlocal stale
        stale += 1
        log({"type": "synced", "meeting_id": stored.id, "title": stored.title, "date": stored.date,
             "lines": len(stored.transcript), "path": str(memory.path_for(stored.id)), "stale": True})
        return stored

    async def bring(entry: Any) -> Meeting | None:
        nonlocal updated, unchanged
        entry = entry if isinstance(entry, dict) else {"id": entry}
        meeting_id = first(entry, "id", "meeting_id", "meetingId", "uuid")
        if not meeting_id:
            log({"type": "status", "state": "warning", "message": "skipped: meeting without id"})
            return None
        memory_id, detail = f"jamie-{meeting_id}", {}
        stored = memory.get(memory_id) if memory.path_for(memory_id).exists() else None
        if stored and tasks is None:
            return keep(stored)
        async with gate:
            if "get_meeting" in tools:
                try:
                    detail = await call("get_meeting", id=meeting_id)
                except Exception as error:
                    log({"type": "status", "state": "warning", "message": f"get_meeting {meeting_id}: {error}"})
                    if stored:  # keep the full copy from last time rather than overwrite it with the list entry
                        return keep(stored)
                    detail = None
            if isinstance(detail, dict) and isinstance(detail.get("meeting"), dict):
                detail = {**detail["meeting"], **{k: v for k, v in detail.items() if k != "meeting"}}
            merged = {**entry, **detail} if isinstance(detail, dict) else dict(entry)
            stamp = fingerprint(merged, tasks_for(tasks, str(meeting_id))) \
                if detail is not None and tasks is not None else None
            if stored and stamp and not force and seen.get(memory_id) == stamp:
                unchanged += 1
                log({"type": "synced", "meeting_id": memory_id, "title": stored.title, "date": stored.date,
                     "lines": len(stored.transcript), "path": str(memory.path_for(memory_id)), "unchanged": True})
                return stored
            partial = truncated(merged)
            if partial and "get_meeting_transcript" in tools:
                try:
                    merged["transcript"] = await full_transcript(str(meeting_id))
                    partial = False
                except Exception as error:  # the start of the transcript is still worth keeping; retried next time
                    log({"type": "status", "state": "warning", "message": f"get_meeting_transcript {meeting_id}: {error}"})
                    stamp = None
            note = first(merged.get("transcriptInfo"), "note")
            if note and not merged.get("transcript"):
                log({"type": "status", "state": "warning", "message": f"{meeting_id}: {text_of(note)}"})
        try:
            meeting = meeting_of(merged, tasks or [])
        except ValueError as error:
            log({"type": "status", "state": "warning", "message": f"skipped: {error}"})
            return None
        path = memory.save(meeting)
        if stamp:
            seen[memory_id] = stamp
        else:
            seen.pop(memory_id, None)
        updated += 1
        line = {"type": "synced", "meeting_id": meeting.id, "title": meeting.title, "date": meeting.date,
                "lines": len(meeting.transcript), "path": str(path)}
        log({**line, "partial": True} if partial else line)
        return meeting

    results = await asyncio.gather(*(bring(entry) for entry in listed))
    save_state(memory, seen)
    meetings = [m for m in results if m]
    if not meetings and not listed and not since and not query:
        log({"type": "status", "state": "synced", "meetings": 0, "hint": "empty_account"})
    else:
        done = {"type": "status", "state": "synced", "meetings": len(meetings), "updated": updated, "unchanged": unchanged}
        log({**done, "stale": stale} if stale else done)
    return meetings


# OAuth with a browser login

class FileTokenStorage:
    """Tokens and the registered client in one JSON file, readable only by the user."""

    def __init__(self, path: Path | None = None):
        self.path = path or TOKEN_FILE

    def _read(self) -> dict[str, Any]:
        try:
            return json.loads(self.path.read_text())
        except (OSError, ValueError):
            return {}

    def _write(self, **values: Any) -> None:
        data = {**self._read(), **values}
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle)

    async def get_tokens(self):
        from mcp.shared.auth import OAuthToken

        data = self._read().get("tokens")
        return OAuthToken.model_validate(data) if data else None

    async def set_tokens(self, tokens) -> None:
        expires = time.time() + int(tokens.expires_in) if tokens.expires_in else None
        self._write(tokens=tokens.model_dump(mode="json", exclude_none=True), expires_at=expires)

    def expires_at(self) -> float | None:
        """When the stored access token runs out (files from before this was kept: written + expires_in)."""
        data = self._read()
        if data.get("expires_at"):
            return float(data["expires_at"])
        expires_in = (data.get("tokens") or {}).get("expires_in")
        try:
            return self.path.stat().st_mtime + int(expires_in) if expires_in else None
        except (OSError, ValueError):
            return None

    async def get_client_info(self):
        from mcp.shared.auth import OAuthClientInformationFull

        data = self._read().get("client")
        return OAuthClientInformationFull.model_validate(data) if data else None

    async def set_client_info(self, client_info) -> None:
        self._write(client=client_info.model_dump(mode="json", exclude_none=True))


def logout(path: Path | None = None) -> bool:
    """Forgets the Jamie login (tokens and registered client). True if there was one."""
    try:
        (path or TOKEN_FILE).unlink()
        return True
    except FileNotFoundError:
        return False


async def wait_for_callback(port: int = CALLBACK_PORT, timeout: float = 300):
    """Serves one request on 127.0.0.1:<port>/callback and returns the authorization code."""
    from mcp.shared.auth import AuthorizationCodeResult

    done: asyncio.Future = asyncio.get_running_loop().create_future()

    async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        request = (await reader.readline()).decode(errors="replace").split(" ")
        query = parse_qs(urlparse(request[1] if len(request) > 1 else "/").query)
        ok = "code" in query
        body = "Starnotch ist mit Jamie verbunden. Du kannst das Fenster schliessen." if ok else "Kein Code erhalten."
        writer.write(f"HTTP/1.1 {200 if ok else 400} OK\r\nContent-Type: text/plain; charset=utf-8\r\n"
                     f"Connection: close\r\n\r\n{body}".encode())
        await writer.drain()
        writer.close()
        if ok and not done.done():
            done.set_result(AuthorizationCodeResult(code=query["code"][0], state=(query.get("state") or [None])[0],
                                                    iss=(query.get("iss") or [None])[0]))
        elif "error" in query and not done.done():
            done.set_exception(RuntimeError(f"Jamie login failed: {query['error'][0]}"))

    server = await asyncio.start_server(handle, "127.0.0.1", port)
    async with server:
        return await asyncio.wait_for(done, timeout)


class LoginRequired(Exception):
    """Jamie wants a new browser login, and this run may not open one (`--no-login`)."""


def login_required(error: BaseException) -> bool:
    """True when `error`, or one it wraps (the MCP client raises from task groups), is LoginRequired."""
    if isinstance(error, LoginRequired):
        return True
    if isinstance(error, BaseExceptionGroup) and any(login_required(e) for e in error.exceptions):
        return True
    cause = error.__cause__ or error.__context__
    return cause is not None and login_required(cause)


def reason(error: BaseException) -> str:
    """What went wrong, for the app: the first error inside the task groups the MCP client raises from, and a short
    sentence when Jamie can't be reached at all (offline, or the network not back after a wake)."""
    import httpx2

    while isinstance(error, BaseExceptionGroup) and error.exceptions:
        error = error.exceptions[0]
    if isinstance(error, (httpx2.NetworkError, httpx2.ConnectTimeout)):
        return "Jamie isn't reachable; check your internet connection"
    return str(error)


def oauth_provider(url: str, port: int = CALLBACK_PORT, interactive: bool = True):
    from mcp.client.auth import OAuthClientProvider
    from mcp.shared.auth import OAuthClientMetadata

    async def open_browser(authorization_url: str) -> None:
        if not interactive:
            print(json.dumps({"type": "status", "state": "login_required"}), flush=True)
            raise LoginRequired()
        print(json.dumps({"type": "status", "state": "login", "url": authorization_url}), flush=True)
        webbrowser.open(authorization_url)

    storage = FileTokenStorage()
    provider = OAuthClientProvider(
        server_url=url,
        client_metadata=OAuthClientMetadata(
            client_name="Starnotch",
            redirect_uris=[f"http://127.0.0.1:{port}/callback"],
            grant_types=["authorization_code", "refresh_token"],
            response_types=["code"],
            token_endpoint_auth_method="none",
        ),
        storage=storage,
        redirect_handler=open_browser,
        callback_handler=lambda: wait_for_callback(port),
    )
    # The SDK doesn't know when stored tokens run out, so an expired one would get a 401 and a new browser
    # login; with the expiry it uses the refresh token instead.
    provider.context.token_expiry_time = storage.expires_at()
    return provider


async def discover_token_endpoint(provider, http) -> None:
    """The authorization server's metadata, before the SDK may refresh a token: when it starts expired, runs out
    during a long sync, or has no known expiry. Without it the SDK posts to <origin>/token, which Jamie doesn't
    serve (its endpoint is /oauth/token), and falls back to a browser login. Two small GETs per sync."""
    from mcp.shared.auth import OAuthMetadata

    context = provider.context
    base = context.get_authorization_base_url(context.server_url)
    try:
        resource = (await http.get(f"{base}/.well-known/oauth-protected-resource")).json()
        server = str((resource.get("authorization_servers") or [base])[0]).rstrip("/")
        response = await http.get(f"{server}/.well-known/oauth-authorization-server")
        context.oauth_metadata = OAuthMetadata.model_validate_json(response.content)
    except Exception:  # then the SDK's own way: a new login if the refresh fails
        pass


async def connect_and_run(url: str, job, interactive: bool = True) -> Any:
    import httpx2
    from mcp.client import ClientSession
    from mcp.client.streamable_http import streamable_http_client

    provider = oauth_provider(url, interactive=interactive)
    async with httpx2.AsyncClient(timeout=10) as plain:
        await discover_token_endpoint(provider, plain)
    async with httpx2.AsyncClient(auth=provider, timeout=httpx2.Timeout(60, read=300)) as http:
        async with streamable_http_client(url, http_client=http) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                return await job(session)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Sync Jamie meetings into the Starnotch meeting memory")
    parser.add_argument("--memory", help="memory folder (default: ~/Library/Application Support/Starnotch/memory)")
    parser.add_argument("--limit", type=int, default=50, help="newest meetings to fetch, paged (default 50)")
    parser.add_argument("--since", help="only meetings from this date on, YYYY-MM-DD (if Jamie's tool takes it)")
    parser.add_argument("--query", help="only meetings Jamie's search_meetings finds for this text")
    parser.add_argument("--url", default=os.environ.get("JAMIE_MCP_URL", JAMIE_URL))
    parser.add_argument("--force", action="store_true", help="write every meeting again, also unchanged ones")
    parser.add_argument("--list-tools", action="store_true", help="print Jamie's tools and exit")
    parser.add_argument("--logout", action="store_true", help="forget the Jamie login and exit")
    parser.add_argument("--no-login", action="store_true",
                        help="never open the browser: without a usable login, say login_required and exit 2")
    args = parser.parse_args(argv)
    if args.logout:
        print(json.dumps({"type": "status", "state": "logged_out", "removed": logout()}), flush=True)
        return 0
    refused = privacy.load().why_not("meetings") if not args.list_tools else ""
    if refused:  # paused or switched off in Settings › Tara's memory: nothing comes in
        print(json.dumps({"type": "status", "state": "paused", "message": refused}), flush=True)
        return 0
    if args.no_login and not FileTokenStorage()._read().get("tokens"):  # registering the client alone writes the file
        print(json.dumps({"type": "status", "state": "login_required"}), flush=True)
        return 2

    async def job(session):
        if args.list_tools:
            for tool in (await session.list_tools()).tools:
                print(json.dumps({"name": tool.name, "description": tool.description,
                                  "input_schema": tool.input_schema}, ensure_ascii=False))
            return []
        return await sync(session, Memory(args.memory), max(1, args.limit), args.since, args.query, args.force)

    try:
        asyncio.run(connect_and_run(args.url, job, interactive=not args.no_login))
    except Exception as error:
        if login_required(error):  # its status line went out already
            return 2
        print(json.dumps({"type": "error", "message": f"jamie sync: {reason(error)}"}), flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
