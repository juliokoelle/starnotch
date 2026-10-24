"""jamie_sync against a fake Jamie: a real MCP server in-process, plus the field mapping on its own."""

import json
from types import SimpleNamespace

import pytest
from mcp import Client
from mcp.server.mcpserver import MCPServer
from mcp.types import CallToolResult, TextContent

import jamie_sync
from jamie_sync import as_list, meeting_of, result_data, tool_args, transcript_of
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
    assert [x["type"] for x in logged] == ["synced", "synced"]

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
