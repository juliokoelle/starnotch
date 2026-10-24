"""Fetches meetings from Jamie's MCP server into the meeting memory.

    uv run python jamie_sync.py                  # first run opens the browser for the Jamie login
    uv run python jamie_sync.py --limit 20 --memory demo/jamie
    uv run python jamie_sync.py --query "Preis"   # only what search_meetings finds
    uv run python jamie_sync.py --list-tools     # prints the server's tools and their input schemas

Jamie's tools (list_meetings, get_meeting, search_meetings, list_tasks) are called with whatever argument names
their input schemas declare, and their answers are mapped onto memory.py's schema field by field, so small
differences in Jamie's JSON don't break the sync. Prints one JSON line per saved meeting, then a summary line.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys
import webbrowser
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

from memory import DEFAULT_DIR, Commitment, Decision, Line, Meeting, Memory, _seconds

JAMIE_URL = "https://mcp.meetjamie.ai/mcp"
TOKEN_FILE = DEFAULT_DIR.parent / "jamie-oauth.json"
CALLBACK_PORT = 47791  # next to the app's ports; 8765 is a common dev-server port

# Our name for an argument -> names a tool's input schema may use for it
ARG_ALIASES = {
    "id": ["meeting_id", "meetingId", "id", "uuid"],
    "limit": ["limit", "page_size", "pageSize", "max_results", "count", "n"],
    "since": ["since", "from", "start_date", "startDate", "after", "from_date"],
    "query": ["query", "q", "search", "text"],
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


def transcript_of(value: Any) -> list[Line]:
    if isinstance(value, dict):
        value = first(value, "segments", "utterances", "entries", "lines", "transcript", "text", default=[])
    if isinstance(value, str):
        lines = []
        for raw in value.splitlines():
            match = SPEAKER_LINE.match(raw)
            if match:
                lines.append(Line(match.group(2).strip(), match.group(3).strip(), _seconds(match.group(1))))
            elif raw.strip():
                lines.append(Line("", raw.strip()))
        return lines
    lines = []
    for item in value or []:
        if isinstance(item, str):
            lines.append(Line("", item))
            continue
        speaker = first(item, "speaker", "speaker_name", "speakerName", "name", default="")
        lines.append(Line(
            speaker=person(speaker),
            text=text_of(first(item, "text", "content", "sentence", "words", default="")),
            t=_seconds(first(item, "t", "start", "start_time", "startTime", "offset", "timestamp", default=0)),
        ))
    return [line for line in lines if line.text]


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


def meeting_of(raw: dict[str, Any], tasks: list[Any] = ()) -> Meeting:
    """Jamie's meeting JSON (list entry merged with get_meeting) -> memory.Meeting."""
    jamie_id = str(first(raw, "id", "meeting_id", "meetingId", "uuid", default=""))
    if not jamie_id:
        raise ValueError("meeting without id")
    participants = [person(p) for p in first(raw, "participants", "attendees", "speakers", default=[]) or []]
    decisions = [Decision(text=text_of(d)) if not isinstance(d, dict) else
                 Decision(text=text_of(first(d, "text", "title", "decision", "description", default="")),
                          quote=text_of(first(d, "quote", "source", default="")))
                 for d in first(raw, "decisions", "key_decisions", "keyDecisions", default=[]) or []]
    own = list(first(raw, "commitments", "action_items", "actionItems", "tasks", "todos", default=[]) or [])
    own += [t for t in tasks if str(first(t, "meeting_id", "meetingId", default="")) == jamie_id]
    commitments, seen = [], set()
    for item in own:
        c = commitment_of(item)
        if c.what and (c.who, c.what) not in seen:
            seen.add((c.who, c.what))
            commitments.append(c)
    date = str(first(raw, "date", "start_time", "startTime", "started_at", "startedAt", "created_at", "createdAt", default=""))
    return Meeting(
        id=f"jamie-{jamie_id}",
        title=text_of(first(raw, "title", "name", "subject", default="")) or "Meeting",
        date=date[:10],
        participants=[p for p in participants if p],
        transcript=transcript_of(first(raw, "transcript", "transcription", "segments", default=[])),
        summary=text_of(first(raw, "summary", "short_summary", "overview", "notes", default="")),
        decisions=[d for d in decisions if d.text],
        commitments=commitments,
    )


# Syncing

async def sync(session: Any, memory: Memory, limit: int = 50, since: str | None = None, query: str | None = None,
               log=lambda obj: print(json.dumps(obj, ensure_ascii=False), flush=True)) -> list[Meeting]:
    tools = {t.name: t for t in (await session.list_tools()).tools}
    if "list_meetings" not in tools:
        raise RuntimeError(f"Jamie has no list_meetings tool (tools: {', '.join(sorted(tools))})")

    async def call(name: str, **wanted: Any) -> Any:
        return result_data(await session.call_tool(name, tool_args(tools[name], wanted)))

    if query and "search_meetings" in tools:
        listed = as_list(await call("search_meetings", query=query, limit=limit))[:limit]
    else:
        listed = as_list(await call("list_meetings", limit=limit, since=since))[:limit]
    tasks: list[Any] = []
    if "list_tasks" in tools:
        try:
            tasks = as_list(await call("list_tasks", limit=100))  # Jamie allows at most 100
        except Exception as error:  # tasks are a bonus; meetings still sync
            log({"type": "status", "state": "warning", "message": f"list_tasks: {error}"})
    saved = []
    for entry in listed:
        entry = entry if isinstance(entry, dict) else {"id": entry}
        meeting_id = first(entry, "id", "meeting_id", "meetingId", "uuid")
        detail: Any = {}
        if meeting_id and "get_meeting" in tools:
            try:
                detail = await call("get_meeting", id=meeting_id)
            except Exception as error:
                log({"type": "status", "state": "warning", "message": f"get_meeting {meeting_id}: {error}"})
        if isinstance(detail, dict) and isinstance(detail.get("meeting"), dict):
            detail = {**detail["meeting"], **{k: v for k, v in detail.items() if k != "meeting"}}
        merged = {**entry, **detail} if isinstance(detail, dict) else entry
        try:
            meeting = meeting_of(merged, tasks)
        except ValueError as error:
            log({"type": "status", "state": "warning", "message": f"skipped: {error}"})
            continue
        path = memory.save(meeting)
        saved.append(meeting)
        log({"type": "synced", "meeting_id": meeting.id, "title": meeting.title, "date": meeting.date,
             "lines": len(meeting.transcript), "path": str(path)})
    return saved


# OAuth with a browser login

class FileTokenStorage:
    """Tokens and the registered client in one JSON file, readable only by the user."""

    def __init__(self, path: Path = TOKEN_FILE):
        self.path = path

    def _read(self) -> dict[str, Any]:
        try:
            return json.loads(self.path.read_text())
        except (OSError, ValueError):
            return {}

    def _write(self, key: str, value: dict[str, Any]) -> None:
        data = self._read()
        data[key] = value
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle)

    async def get_tokens(self):
        from mcp.shared.auth import OAuthToken

        data = self._read().get("tokens")
        return OAuthToken.model_validate(data) if data else None

    async def set_tokens(self, tokens) -> None:
        self._write("tokens", tokens.model_dump(mode="json", exclude_none=True))

    async def get_client_info(self):
        from mcp.shared.auth import OAuthClientInformationFull

        data = self._read().get("client")
        return OAuthClientInformationFull.model_validate(data) if data else None

    async def set_client_info(self, client_info) -> None:
        self._write("client", client_info.model_dump(mode="json", exclude_none=True))


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


def oauth_provider(url: str, port: int = CALLBACK_PORT):
    from mcp.client.auth import OAuthClientProvider
    from mcp.shared.auth import OAuthClientMetadata

    async def open_browser(authorization_url: str) -> None:
        print(json.dumps({"type": "status", "state": "login", "url": authorization_url}), flush=True)
        webbrowser.open(authorization_url)

    return OAuthClientProvider(
        server_url=url,
        client_metadata=OAuthClientMetadata(
            client_name="Starnotch",
            redirect_uris=[f"http://127.0.0.1:{port}/callback"],
            grant_types=["authorization_code", "refresh_token"],
            response_types=["code"],
            token_endpoint_auth_method="none",
        ),
        storage=FileTokenStorage(),
        redirect_handler=open_browser,
        callback_handler=lambda: wait_for_callback(port),
    )


async def connect_and_run(url: str, job) -> Any:
    import httpx2
    from mcp.client import ClientSession
    from mcp.client.streamable_http import streamable_http_client

    async with httpx2.AsyncClient(auth=oauth_provider(url), timeout=httpx2.Timeout(60, read=300)) as http:
        async with streamable_http_client(url, http_client=http) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                return await job(session)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Sync Jamie meetings into the Starnotch meeting memory")
    parser.add_argument("--memory", help="memory folder (default: ~/Library/Application Support/Starnotch/memory)")
    parser.add_argument("--limit", type=int, default=50, help="newest meetings to fetch (default 50)")
    parser.add_argument("--since", help="only meetings from this date on, YYYY-MM-DD (if Jamie's tool takes it)")
    parser.add_argument("--query", help="only meetings Jamie's search_meetings finds for this text")
    parser.add_argument("--url", default=os.environ.get("JAMIE_MCP_URL", JAMIE_URL))
    parser.add_argument("--list-tools", action="store_true", help="print Jamie's tools and exit")
    args = parser.parse_args(argv)

    async def job(session):
        if args.list_tools:
            for tool in (await session.list_tools()).tools:
                print(json.dumps({"name": tool.name, "description": tool.description,
                                  "input_schema": tool.input_schema}, ensure_ascii=False))
            return []
        return await sync(session, Memory(args.memory), args.limit, args.since, args.query)

    try:
        saved = asyncio.run(connect_and_run(args.url, job))
    except Exception as error:
        print(json.dumps({"type": "error", "message": f"jamie sync: {error}"}), flush=True)
        return 1
    if not args.list_tools:
        print(json.dumps({"type": "status", "state": "synced", "meetings": len(saved)}), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
