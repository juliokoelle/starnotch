"""jamie_sync against a fake Jamie: a real MCP server in-process, plus the field mapping on its own."""

import json
import os
import time
from types import SimpleNamespace

import pytest
from mcp import Client
from mcp.server.mcpserver import MCPServer
from mcp.types import CallToolResult, TextContent

import jamie_sync
from jamie_sync import FileTokenStorage, as_list, meeting_of, result_data, tool_args, transcript_of
from memory import Memory

MEETINGS = {
    "m1": {
        "id": "m1", "title": "Planung Q4", "start_time": "2026-10-05T09:00:00Z",
        "attendees": [{"name": "Max", "email": "max@example.com"}, {"name": "Lisa"}],
        "summary": {"short": "Budget besprochen."},
        "transcript": [
            {"speaker": {"name": "Max"}, "start": "00:00:05", "text": "Wir planen 40 Euro Budget."},
            {"speaker_name": "Lisa", "start_time": 12.0, "content": "Ich prüfe das bis Freitag."},
        ],
        "decisions": ["Budget 40 Euro"],
    },
    "m2": {
        "id": "m2", "title": "Kurzer Sync", "date": "2026-10-07",
        "participants": ["Jonas"],
        "transcript": "[00:01] Jonas: Alles im Plan.\nOhne Sprecher",
        "action_items": [{"assignee": "Jonas", "title": "Protokoll senden", "completed": True}],
    },
}
TASKS = [
    {"meeting_id": "m1", "assignee": {"name": "Lisa"}, "title": "Budget prüfen", "due_date": "2026-10-09T00:00:00Z", "status": "open"},
    {"meeting_id": "other", "assignee": "Max", "title": "nicht zugeordnet"},
]


def fake_jamie() -> MCPServer:
    server = MCPServer("fake-jamie")

    @server.tool()
    def list_meetings(limit: int = 20) -> dict:
        """Newest meetings."""
        return {"meetings": [{"id": m["id"], "title": m["title"]} for m in MEETINGS.values()][:limit]}

    @server.tool()
    def get_meeting(meeting_id: str) -> dict:
        """One meeting with transcript."""
        return {"meeting": MEETINGS[meeting_id]}

    @server.tool()
    def search_meetings(query: str) -> list:
        """Search."""
        return [{"id": m["id"]} for m in MEETINGS.values() if query.lower() in m["title"].lower()]

    @server.tool()
    def list_tasks() -> str:
        """All tasks, as JSON text."""
        return json.dumps({"tasks": TASKS})

    return server


async def test_sync_against_fake_server(tmp_path):
    logged = []
    async with Client(fake_jamie()) as client:
        saved = await jamie_sync.sync(client.session, Memory(tmp_path), limit=10, log=logged.append)
    assert [m.id for m in saved] == ["jamie-m1", "jamie-m2"]
    assert [x["type"] for x in logged] == ["synced", "synced", "status"]
    assert logged[-1] == {"type": "status", "state": "synced", "meetings": 2, "updated": 2, "unchanged": 0}

    memory = Memory(tmp_path)
    m1 = memory.get("jamie-m1")
    assert (m1.title, m1.date, m1.participants, m1.summary) == ("Planung Q4", "2026-10-05", ["Max", "Lisa"], "Budget besprochen.")
    assert [(l.speaker, l.t, l.text) for l in m1.transcript] == [
        ("Max", 5.0, "Wir planen 40 Euro Budget."), ("Lisa", 12.0, "Ich prüfe das bis Freitag.")]
    assert [d.text for d in m1.decisions] == ["Budget 40 Euro"]
    assert [(c.who, c.what, c.due, c.status) for c in m1.commitments] == [("Lisa", "Budget prüfen", "2026-10-09", "open")]

    m2 = memory.get("jamie-m2")
    assert [(l.speaker, l.t, l.text) for l in m2.transcript] == [("Jonas", 1.0, "Alles im Plan."), ("", 0.0, "Ohne Sprecher")]
    assert m2.commitments[0].status == "done"


async def test_limit_is_passed_and_applied(tmp_path):
    async with Client(fake_jamie()) as client:
        saved = await jamie_sync.sync(client.session, Memory(tmp_path), limit=1, log=lambda _: None)
    assert [m.id for m in saved] == ["jamie-m1"]


async def test_query_uses_search(tmp_path):
    async with Client(fake_jamie()) as client:
        saved = await jamie_sync.sync(client.session, Memory(tmp_path), query="sync", log=lambda _: None)
    assert [m.id for m in saved] == ["jamie-m2"]


async def test_missing_list_tool_is_an_error(tmp_path):
    server = MCPServer("empty")

    @server.tool()
    def hello() -> str:
        return "hi"

    async with Client(server) as client:
        with pytest.raises(RuntimeError, match="no list_meetings"):
            await jamie_sync.sync(client.session, Memory(tmp_path), log=lambda _: None)


def test_tool_args_follow_schema():
    tool = SimpleNamespace(input_schema={"properties": {"meetingId": {}, "page_size": {}}, "required": ["meetingId"]})
    assert tool_args(tool, {"id": "x", "limit": 5, "since": "2026-01-01"}) == {"meetingId": "x", "page_size": 5}
    only_required = SimpleNamespace(input_schema={"properties": {"ref": {}}, "required": ["ref"]})
    assert tool_args(only_required, {"id": "x"}) == {"ref": "x"}
    assert tool_args(SimpleNamespace(input_schema=None), {"limit": 3}) == {}


def test_result_data_shapes():
    text = CallToolResult(content=[TextContent(type="text", text='{"items": [1]}')])
    assert as_list(result_data(text)) == [1]
    plain = CallToolResult(content=[TextContent(type="text", text="kein json")])
    assert result_data(plain) == "kein json"
    structured = CallToolResult(content=[], structured_content={"result": [{"id": "a"}]})
    assert result_data(structured) == [{"id": "a"}]
    with pytest.raises(RuntimeError, match="kaputt"):
        result_data(CallToolResult(content=[TextContent(type="text", text="kaputt")], is_error=True))


def test_as_list_nested():
    assert as_list({"data": {"meetings": [1, 2]}}) == [1, 2]
    assert as_list("x") == []


def test_meeting_needs_id():
    with pytest.raises(ValueError):
        meeting_of({"title": "ohne id"})


def test_transcript_dict_wrapper():
    assert [l.text for l in transcript_of({"segments": [{"speaker": "A", "text": "x"}]})] == ["x"]


# A fake shaped like the real Jamie (argument names, cursors, truncation as `--list-tools` shows them)

def jamie_text(blocks: list[tuple[str, str, str]]) -> str:
    """Jamie's transcript text: speaker, blank line, '###### start - end', blank line, what was said."""
    return "\n\n".join(f"{speaker}\n\n###### {start} - 00:00\n\n{text}" for speaker, start, text in blocks) + "\n"


LONG = jamie_text([("Speaker 0", "00:00", "Hallo zusammen."), ("Speaker -1", "00:08", "Ja?"),
                   ("Speaker 1", "00:10", "Wir bleiben bei 30 Euro. " * 4), ("Speaker 0", "01:02", "Gut, so machen wir es.")])
SUMMARY = """## Executive Summary

- **Preis** bleibt bei ****30 Euro****.

## Full Summary

### Preis

- Lange Diskussion.
    - Details.

## Key Decisions

- Preis bleibt bei 30 Euro
- Launch im November

## Action Items

- **Lisa**: Folien schicken bis 2026-10-30
- [x] Raum buchen
"""


class Jamie:
    """Paged meetings, a truncating get_meeting and a paged get_meeting_transcript; counts the calls."""

    def __init__(self, count: int = 5, page: int = 2, cut: int = 60, chunk: int = 50):
        self.meetings = [{"id": f"j{i}", "title": f"Meeting {i}", "startTime": f"2026-10-{20 - i:02d}T09:00:00.000Z",
                          "transcript": LONG, "summary": {"markdown": SUMMARY, "short": "Preis bestätigt."},
                          "participants": [{"id": "0", "name": "Max", "email": "max@example.com"},
                                           {"id": "1", "name": "Speaker 1", "email": None},
                                           {"id": "2", "name": "Nora", "email": "nora@example.com"}],
                          "user": {"id": "u", "email": "nora@example.com"},
                          "event": {"attendees": [{"name": "Lisa", "email": "lisa@example.com"}]},
                          "tasks": []} for i in range(count)]
        self.page, self.cut, self.chunk = page, cut, chunk
        self.calls: list[tuple[str, dict]] = []
        self.broken: set[str] = set()
        self.tasks: list[dict] = []  # served in pages of `page`
        self.tasks_broken = False

    def server(self) -> MCPServer:
        server = MCPServer("jamie")

        @server.tool()
        def list_meetings(limit: int = 50, cursor: str = "", startDate: str | None = None) -> dict:
            """Meetings, newest first, with a cursor."""
            self.calls.append(("list_meetings", {"limit": limit, "cursor": cursor, "startDate": startDate}))
            start = int(cursor or 0)
            end = start + min(limit, self.page)
            entries = [{k: m[k] for k in ("id", "title", "startTime")} for m in self.meetings[start:end]]
            return {"meetings": entries, "nextCursor": str(end) if end < len(self.meetings) else None}

        @server.tool()
        def get_meeting(meetingId: str) -> dict:
            """One meeting; long transcripts cut at `cut` bytes."""
            self.calls.append(("get_meeting", {"meetingId": meetingId}))
            if meetingId in self.broken:
                raise ValueError("server hiccup")
            m = next(m for m in self.meetings if m["id"] == meetingId)
            data = m["transcript"].encode()
            if len(data) <= self.cut:
                return dict(m)
            info = {"truncated": True, "totalBytes": len(data), "returnedBytes": self.cut, "nextCursor": "x"}
            return {**m, "transcript": data[:self.cut].decode(errors="ignore"), "transcriptInfo": info}

        @server.tool()
        def get_meeting_transcript(meetingId: str, cursor: str | None = None) -> dict:
            """The transcript in pages of `chunk` characters; a page may end mid-line."""
            self.calls.append(("get_meeting_transcript", {"meetingId": meetingId, "cursor": cursor}))
            text = next(m for m in self.meetings if m["id"] == meetingId)["transcript"]
            start = int(cursor or 0)
            end = min(start + self.chunk, len(text))
            return {"meetingId": meetingId, "transcript": text[start:end], "isFinal": end >= len(text),
                    "nextCursor": str(end) if end < len(text) else None}

        @server.tool()
        def list_tasks(limit: int = 50, cursor: str = "") -> dict:
            """Tasks, newest first, with a cursor."""
            self.calls.append(("list_tasks", {"limit": limit, "cursor": cursor}))
            if self.tasks_broken:
                raise ValueError("tasks hiccup")
            start = int(cursor or 0)
            end = start + min(limit, self.page)
            return {"tasks": self.tasks[start:end], "nextCursor": str(end) if end < len(self.tasks) else None}

        return server

    def count(self, name: str) -> int:
        return sum(1 for n, _ in self.calls if n == name)


async def run(jamie: Jamie, folder, **kwargs) -> tuple[list, list]:
    logged: list = []
    async with Client(jamie.server()) as client:
        saved = await jamie_sync.sync(client.session, Memory(folder), log=logged.append, **kwargs)
    return saved, logged


async def test_list_meetings_is_paged_until_the_limit(tmp_path):
    jamie = Jamie(count=5, page=2)
    saved, _ = await run(jamie, tmp_path, limit=3)
    assert [m.id for m in saved] == ["jamie-j0", "jamie-j1", "jamie-j2"]
    assert [c["cursor"] for n, c in jamie.calls if n == "list_meetings"] == ["", "2"]

    jamie = Jamie(count=5, page=2)
    saved, _ = await run(jamie, tmp_path / "all", limit=50, since="2026-10-01")
    assert len(saved) == 5
    pages = [c for n, c in jamie.calls if n == "list_meetings"]
    assert [c["cursor"] for c in pages] == ["", "2", "4"]  # stops when nextCursor is null
    assert pages[0]["startDate"] == "2026-10-01T00:00:00Z"  # Jamie's filter takes a date-time


async def test_truncated_transcript_is_read_in_full(tmp_path):
    jamie = Jamie(count=1, cut=60, chunk=50)
    saved, logged = await run(jamie, tmp_path)
    lines = [(l.speaker, l.t, l.text) for l in saved[0].transcript]
    assert lines == [("Max", 0.0, "Hallo zusammen."), ("", 8.0, "Ja?"),
                     ("Speaker 1", 10.0, ("Wir bleiben bei 30 Euro. " * 4).strip()), ("Max", 62.0, "Gut, so machen wir es.")]
    assert jamie.count("get_meeting_transcript") == -(-len(LONG) // 50)  # every page, joined across mid-line cuts
    assert "partial" not in logged[0] and logged[0]["lines"] == 4
    assert Memory(tmp_path).get("jamie-j0").transcript[-1].text == "Gut, so machen wir es."


async def test_short_transcript_needs_no_paging(tmp_path):
    jamie = Jamie(count=1, cut=10_000)
    saved, _ = await run(jamie, tmp_path)
    assert len(saved[0].transcript) == 4 and jamie.count("get_meeting_transcript") == 0


async def test_resync_skips_unchanged_meetings(tmp_path):
    jamie = Jamie(count=2)
    await run(jamie, tmp_path)
    first_pages = jamie.count("get_meeting_transcript")
    written = {p.name: p.stat().st_mtime_ns for p in tmp_path.glob("*.json")}

    saved, logged = await run(jamie, tmp_path)
    assert [m.id for m in saved] == ["jamie-j0", "jamie-j1"]
    assert jamie.count("get_meeting_transcript") == first_pages  # nothing read again
    assert {p.name: p.stat().st_mtime_ns for p in tmp_path.glob("*.json")} == written
    assert all(x.get("unchanged") for x in logged if x["type"] == "synced")
    assert logged[-1] == {"type": "status", "state": "synced", "meetings": 2, "updated": 0, "unchanged": 2}

    jamie.meetings[1]["transcript"] += "Speaker 0\n\n###### 02:00 - 02:05\n\nNoch etwas.\n"
    saved, logged = await run(jamie, tmp_path)
    assert [x["meeting_id"] for x in logged if x["type"] == "synced" and not x.get("unchanged")] == ["jamie-j1"]
    assert saved[1].transcript[-1].text == "Noch etwas."

    _, logged = await run(jamie, tmp_path, force=True)
    assert logged[-1]["updated"] == 2


async def test_a_failed_get_meeting_keeps_the_stored_copy(tmp_path):
    jamie = Jamie(count=1)
    await run(jamie, tmp_path)
    jamie.broken.add("j0")
    saved, logged = await run(jamie, tmp_path)
    assert len(saved[0].transcript) == 4  # not overwritten by the bare list entry
    assert logged[0]["state"] == "warning" and logged[0]["message"].startswith("get_meeting j0:")
    assert logged[1]["type"] == "synced" and logged[1]["stale"] is True  # counted like any other meeting
    assert logged[-1] == {"type": "status", "state": "synced", "meetings": 1, "updated": 0, "unchanged": 0, "stale": 1}


async def test_every_page_of_tasks_is_read(tmp_path):
    jamie = Jamie(count=2, page=2)
    jamie.tasks = [{"text": f"Aufgabe {n}", "meetingId": "j1", "assignee": {"name": "Lisa"}} for n in range(5)]
    saved, _ = await run(jamie, tmp_path)
    assert [c.what for c in saved[1].commitments] == [f"Aufgabe {n}" for n in range(5)]
    assert [c["cursor"] for n, c in jamie.calls if n == "list_tasks"] == ["", "2", "4"]


async def test_unreadable_tasks_keep_stored_meetings(tmp_path):
    jamie = Jamie(count=1)
    jamie.tasks = [{"text": "Folien", "meetingId": "j0"}]
    await run(jamie, tmp_path)
    jamie.tasks_broken = True
    saved, logged = await run(jamie, tmp_path)
    assert [c.what for c in saved[0].commitments] == ["Folien"]  # not rewritten without its tasks
    assert Memory(tmp_path).get("jamie-j0").commitments[0].what == "Folien"
    assert logged[-1]["stale"] == 1


async def test_empty_account_says_so(tmp_path):
    saved, logged = await run(Jamie(count=0), tmp_path)
    assert saved == []
    assert logged == [{"type": "status", "state": "synced", "meetings": 0, "hint": "empty_account"}]
    _, logged = await run(Jamie(count=0), tmp_path, since="2026-10-01")  # a filter that matches nothing isn't that
    assert "hint" not in logged[-1]


async def test_summary_participants_decisions_and_action_items(tmp_path):
    saved, _ = await run(Jamie(count=1), tmp_path)
    m = saved[0]
    assert m.participants == ["Max", "Lisa"]  # no "Speaker 1", not the Jamie user, plus calendar attendees
    assert m.summary == "- Preis bleibt bei 30 Euro."
    assert m.notes == SUMMARY.strip()  # the whole summary is kept; the memory is the only copy
    assert "### Preis" in Memory(tmp_path).as_context()
    assert [d.text for d in m.decisions] == ["Preis bleibt bei 30 Euro", "Launch im November"]
    assert [(c.who, c.what, c.due, c.status) for c in m.commitments] == [
        ("Lisa", "Folien schicken bis 2026-10-30", "2026-10-30", "open"), ("", "Raum buchen", None, "done")]


def test_jamie_tasks_win_over_summary_action_items():
    raw = {"id": "x", "summary": {"markdown": SUMMARY},
           "tasks": [{"text": "Folien schicken", "assignee": {"name": "Lisa"}, "dueDate": "2026-10-30", "completed": False}]}
    assert [(c.who, c.what) for c in meeting_of(raw).commitments] == [("Lisa", "Folien schicken")]


def test_summary_falls_back_to_short_then_markdown():
    assert meeting_of({"id": "a", "summary": {"markdown": "Nur Text **fett**.", "short": "Kurz."}}).summary == "Kurz."
    assert meeting_of({"id": "b", "summary": "Nur Text **fett**."}).summary == "Nur Text fett."
    assert meeting_of({"id": "a", "summary": {"markdown": "Nur Text **fett**.", "short": "Kurz."}}).notes == "Nur Text **fett**."
    assert meeting_of({"id": "b", "summary": "Nur Text **fett**."}).notes == ""  # the summary is already all of it


def test_logout_removes_the_token_file(tmp_path, monkeypatch, capsys):
    token = tmp_path / "jamie-oauth.json"
    token.write_text("{}")
    monkeypatch.setattr(jamie_sync, "TOKEN_FILE", token)
    assert jamie_sync.main(["--logout"]) == 0
    assert not token.exists()
    assert json.loads(capsys.readouterr().out) == {"type": "status", "state": "logged_out", "removed": True}
    jamie_sync.main(["--logout"])
    assert json.loads(capsys.readouterr().out)["removed"] is False


async def test_token_storage_remembers_when_the_token_runs_out(tmp_path):
    from mcp.shared.auth import OAuthToken

    storage = FileTokenStorage(tmp_path / "t.json")
    assert storage.expires_at() is None
    await storage.set_tokens(OAuthToken(access_token="a", refresh_token="r", expires_in=3600))
    assert abs(storage.expires_at() - (time.time() + 3600)) < 5
    assert (await storage.get_tokens()).refresh_token == "r"
    assert oct((tmp_path / "t.json").stat().st_mode & 0o777) == "0o600"

    old = tmp_path / "old.json"  # written before expires_at was kept: file time + expires_in
    old.write_text(json.dumps({"tokens": {"access_token": "a", "token_type": "Bearer", "expires_in": 3600}}))
    os.utime(old, (1_000_000, 1_000_000))
    assert FileTokenStorage(old).expires_at() == 1_003_600


async def test_last_synced_is_when_the_last_sync_finished(tmp_path):
    assert jamie_sync.last_synced(tmp_path) is None
    before = time.time()
    await run(Jamie(count=1), tmp_path)
    assert jamie_sync.last_synced(tmp_path).timestamp() >= before - 1


def test_no_login_without_a_saved_login_stops_before_connecting(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(jamie_sync, "TOKEN_FILE", tmp_path / "jamie-oauth.json")
    monkeypatch.setattr(jamie_sync, "connect_and_run", lambda *a, **k: pytest.fail("must not connect"))
    assert jamie_sync.main(["--no-login", "--memory", str(tmp_path / "memory")]) == 2
    assert json.loads(capsys.readouterr().out) == {"type": "status", "state": "login_required"}


async def test_no_login_never_opens_the_browser(monkeypatch, capsys):
    monkeypatch.setattr(jamie_sync.webbrowser, "open", lambda url: pytest.fail("opened the browser"))
    provider = jamie_sync.oauth_provider("https://jamie.example/mcp", interactive=False)
    with pytest.raises(jamie_sync.LoginRequired):
        await provider.context.redirect_handler("https://jamie.example/authorize?x=1")
    assert json.loads(capsys.readouterr().out) == {"type": "status", "state": "login_required"}


def test_an_expired_login_ends_quietly_with_its_own_exit_code(tmp_path, monkeypatch, capsys):
    token = tmp_path / "jamie-oauth.json"
    token.write_text(json.dumps({"tokens": {"access_token": "a", "token_type": "Bearer"}}))
    monkeypatch.setattr(jamie_sync, "TOKEN_FILE", token)

    async def wrapped(*args, **kwargs):  # the MCP client raises from its task groups
        try:
            raise jamie_sync.LoginRequired()
        except jamie_sync.LoginRequired as error:
            raise ExceptionGroup("task group", [RuntimeError("cancelled")]) from error

    monkeypatch.setattr(jamie_sync, "connect_and_run", wrapped)
    assert jamie_sync.main(["--no-login", "--memory", str(tmp_path / "memory")]) == 2
    assert capsys.readouterr().out == ""  # no error line: the status line went out from the redirect

    async def offline(*args, **kwargs):
        raise RuntimeError("offline")

    monkeypatch.setattr(jamie_sync, "connect_and_run", offline)
    assert jamie_sync.main(["--no-login", "--memory", str(tmp_path / "memory")]) == 1
    assert json.loads(capsys.readouterr().out)["message"] == "jamie sync: offline"


def test_a_login_abandoned_in_the_browser_is_no_saved_login(tmp_path, monkeypatch, capsys):
    token = tmp_path / "jamie-oauth.json"
    token.write_text(json.dumps({"client": {"client_id": "c1"}}))  # registered, but the browser login never finished
    monkeypatch.setattr(jamie_sync, "TOKEN_FILE", token)
    monkeypatch.setattr(jamie_sync, "connect_and_run", lambda *a, **k: pytest.fail("must not connect"))
    assert jamie_sync.main(["--no-login", "--memory", str(tmp_path / "memory")]) == 2
    assert json.loads(capsys.readouterr().out) == {"type": "status", "state": "login_required"}


def test_offline_says_jamie_isnt_reachable(tmp_path, monkeypatch, capsys):
    import httpx2

    token = tmp_path / "jamie-oauth.json"
    token.write_text(json.dumps({"tokens": {"access_token": "a", "token_type": "Bearer"}}))
    monkeypatch.setattr(jamie_sync, "TOKEN_FILE", token)

    async def offline(*args, **kwargs):  # the MCP client raises from its task groups
        raise ExceptionGroup("unhandled errors in a TaskGroup", [httpx2.ConnectError("nodename nor servname provided")])

    monkeypatch.setattr(jamie_sync, "connect_and_run", offline)
    assert jamie_sync.main(["--no-login", "--memory", str(tmp_path / "memory")]) == 1
    assert json.loads(capsys.readouterr().out)["message"] == \
        "jamie sync: Jamie isn't reachable; check your internet connection"

    async def broken(*args, **kwargs):
        raise ExceptionGroup("unhandled errors in a TaskGroup", [RuntimeError("Jamie has no list_meetings tool")])

    monkeypatch.setattr(jamie_sync, "connect_and_run", broken)
    assert jamie_sync.main(["--no-login", "--memory", str(tmp_path / "memory")]) == 1
    assert json.loads(capsys.readouterr().out)["message"] == "jamie sync: Jamie has no list_meetings tool"
