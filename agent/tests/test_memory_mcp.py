import datetime as dt
import json
import os
import time

from mcp import Client

import memory_mcp
from memory_mcp import Library

NOW = dt.datetime(2026, 10, 28, 9, 0)


def library(memory_dir, tmp_path):
    queue = tmp_path / "capture-queue.jsonl"
    queue.write_text("\n".join(json.dumps(c) for c in [
        {"id": "c1", "created": "2026-10-24T09:00:00Z", "route": "task", "text": "Zahlen von Max nachfragen", "due": "2026-10-27"},
        {"id": "c2", "created": "2026-10-25T09:00:00Z", "route": "note", "text": "Lumen Preis eventuell 35 Euro"},
    ]) + "\n", encoding="utf-8")
    folder = tmp_path / "connectors"
    folder.mkdir()
    (folder / "vault.json").write_text(json.dumps({"tasks": [
        {"title": "Landingpage Text schreiben", "due": "2026-10-28", "path": "/notes/Tasks.md"},
        {"title": "Steuer", "due": "2026-11-15"}]}), encoding="utf-8")
    (tmp_path / "calendar-today.json").write_text(json.dumps({"name": "Calendar", "updated": "2026-10-28T08:00:00+01:00", "today": [
        {"title": "Board meeting", "date": "2026-10-27T10:00:00+01:00", "end": "2026-10-27T11:00:00+01:00"},
        {"title": "Design review", "date": "2026-10-28T10:00:00+01:00", "end": "2026-10-28T10:30:00+01:00",
         "attendees": "Lena", "url": "https://meet.example/abc"}]}), encoding="utf-8")
    projects = tmp_path / "claude" / "projects" / "-Users-x-lumen"
    projects.mkdir(parents=True)
    session = projects / "0b7e2f0a-1111-2222-3333-444455556666.jsonl"
    session.write_text("\n".join(json.dumps(r) for r in [
        {"type": "user", "cwd": "/Users/x/lumen", "message": {"content": "Fix the pricing page"}},
        {"type": "ai-title", "aiTitle": "Lumen pricing page"},
    ]) + "\n", encoding="utf-8")
    now = time.time()
    os.utime(session, (now, now))
    return Library(memory_dir, queue, folder, tmp_path / "claude" / "projects", tmp_path / "privacy.json", now=NOW,
                   calendar=tmp_path / "calendar-today.json")


async def call(lib, tool, args=None):
    async with Client(memory_mcp.build(lib)) as client:
        result = await client.call_tool(tool, args or {})
    return json.loads(result.content[0].text)


async def test_search_finds_every_source_with_its_origin(memory_dir, tmp_path):
    lib = library(memory_dir, tmp_path)
    lib.fixed_now = dt.datetime.now(dt.timezone.utc)
    found = await call(lib, "search_memory", {"query": "Lumen Preis 30 Euro"})
    kinds = {r["source"] for r in found["results"]}
    assert "meeting" in kinds and "capture" in kinds
    assert all(r["id"] for r in found["results"])
    top = found["results"][0]
    assert top["source"] == "meeting" and "30" in top["text"]
    sessions = await call(lib, "search_memory", {"query": "pricing page", "sources": ["sessions"]})
    assert sessions["results"][0]["title"] == "Lumen pricing page"
    assert sessions["results"][0]["folder"] == "/Users/x/lumen"


async def test_search_leaves_out_what_is_switched_off(memory_dir, tmp_path):
    lib = library(memory_dir, tmp_path)
    (tmp_path / "privacy.json").write_text(json.dumps({"off": ["meetings", "sessions"], "paused": True}), encoding="utf-8")
    found = await call(lib, "search_memory", {"query": "Lumen Preis 30 Euro"})
    assert {r["source"] for r in found["results"]} == {"capture"}
    assert found["left_out"] == ["meetings", "sessions"] and found["paused"] is True
    meeting = await call(lib, "get_meeting", {"meeting_id": "2026-10-12-kickoff"})
    assert "error" in meeting and "transcript" not in meeting


async def test_get_meeting_in_full(memory_dir, tmp_path):
    lib = library(memory_dir, tmp_path)
    meeting = await call(lib, "get_meeting", {"meeting_id": "2026-10-12-kickoff"})
    assert meeting["source"] == "meeting" and meeting["participants"] == ["Max", "Lisa", "Jonas"]
    assert meeting["decisions"][0]["text"].startswith("Das Lumen-Abo kostet 30 Euro")
    assert meeting["transcript"]
    missing = await call(lib, "get_meeting", {"meeting_id": "nope"})
    assert "2026-10-19-weekly" in missing["recent_ids"]


async def test_open_commitments_and_decisions(memory_dir, tmp_path):
    lib = library(memory_dir, tmp_path)
    open_ = await call(lib, "open_commitments")
    whats = [(o["who"], o["what"], o["source"]) for o in open_["open"]]
    assert ("Max", "Zahlen zur Marge an das Team schicken", "meeting") in whats
    assert ("you", "Zahlen von Max nachfragen", "capture") in whats
    assert all(o["what"] != "Raum für den Launch-Workshop buchen" for o in open_["open"])  # done
    max_only = await call(lib, "open_commitments", {"person": "Max"})
    assert {o["who"] for o in max_only["open"]} <= {"Max", "you"}
    assert not [o for o in (await call(lib, "open_commitments", {"person": "Lisa"}))["open"] if o["who"] == "Max"]
    recent = await call(lib, "recent_decisions", {"days": 10})
    assert [d["id"] for d in recent["decisions"]] == ["2026-10-19-weekly"]  # the kickoff is 16 days back


async def test_today(memory_dir, tmp_path):
    lib = library(memory_dir, tmp_path)
    day = await call(lib, "today")
    assert day["date"] == "2026-10-28"
    assert [e["title"] for e in day["events"]] == ["Design review"]  # yesterday's board meeting isn't today's
    assert day["events"][0]["source"] == "calendar" and day["events"][0]["link"] == "https://meet.example/abc"
    assert "calendar" not in day
    tasks = {t["task"]: t for t in day["tasks"]}
    assert tasks["Landingpage Text schreiben"]["overdue"] is False and tasks["Landingpage Text schreiben"]["link"].startswith("file://")
    assert tasks["Zahlen von Max nachfragen"]["overdue"] is True
    assert "Steuer" not in tasks
    assert day["commitments_due"][0]["what"] == "Zahlen zur Marge an das Team schicken"
    (tmp_path / "privacy.json").write_text(json.dumps({"off": ["meetings"]}), encoding="utf-8")
    day = await call(lib, "today")
    assert day["events"] == [] and day["commitments_due"] == [] and day["left_out"] == ["meetings"]


async def test_today_trusts_no_calendar_from_an_earlier_day(memory_dir, tmp_path):
    lib = library(memory_dir, tmp_path)
    lib.fixed_now = dt.datetime(2026, 10, 29, 9, 0)
    (tmp_path / "privacy.json").write_text(json.dumps({"paused": True}), encoding="utf-8")
    day = await call(lib, "today")
    assert day["events"] == [] and "2026-10-28" in day["calendar"] and "paused" in day["calendar"]
    (tmp_path / "calendar-today.json").unlink()
    day = await call(lib, "today")
    assert day["events"] == [] and "hasn't written" in day["calendar"]


async def test_another_tools_calendar_in_connectors_is_a_note(memory_dir, tmp_path):
    lib = library(memory_dir, tmp_path)
    (tmp_path / "connectors" / "calendar.json").write_text(json.dumps({"today": [
        {"title": "Old offsite", "date": "2026-10-01T10:00"}]}), encoding="utf-8")
    day = await call(lib, "today")
    assert [e["title"] for e in day["events"]] == ["Design review"]
    found = await call(lib, "search_memory", {"query": "offsite", "sources": ["notes"]})
    assert found["results"][0]["source"] == "note"


def test_sessions_never_show_what_was_said(tmp_path):
    folder = tmp_path / "-Users-x-acme"
    folder.mkdir()
    (folder / "s.jsonl").write_text(json.dumps({"type": "user", "cwd": "/Users/x/acme",
                                                "message": {"content": "my secret plan for the deal"}}) + "\n", encoding="utf-8")
    rows = memory_mcp.recent_sessions(tmp_path, dt.datetime.now(dt.timezone.utc))
    assert rows[0]["title"] == "acme" and "secret" not in json.dumps(rows)


async def test_tools_are_read_only(memory_dir, tmp_path):
    async with Client(memory_mcp.build(library(memory_dir, tmp_path))) as client:
        tools = (await client.list_tools()).tools
    names = {"search_memory", "get_meeting", "open_commitments", "recent_decisions", "today"}
    assert {t.name for t in tools} == names
    assert all(t.annotations and t.annotations.read_only_hint for t in tools)


