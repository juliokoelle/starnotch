"""Quick-capture notes: reading the app's queue, prep cards, context, and questions answered as they arrive."""

import datetime as dt
import json
import queue
import threading
import time

import captures as quick
from agent import Agent, watch_captures
from memory import Memory


def write(path, *items):
    with path.open("a") as handle:
        for item in items:
            handle.write(json.dumps(item) + "\n")


ITEMS = [
    {"id": "a", "created": "2026-10-20T09:00:00Z", "route": "task", "text": "Max wegen Margenzahlen anstupsen",
     "due": "2026-10-23", "people": [], "delivered": True},
    {"id": "b", "created": "2026-10-21T10:00:00Z", "route": "note", "text": "Raum Ahorn hat keinen Beamer",
     "due": None, "people": ["lisa-muster"], "delivered": True},
    {"id": "c", "created": "2026-10-22T11:00:00Z", "route": "question", "text": "Welcher Preis gilt?", "due": None,
     "people": ["lisa-muster"], "delivered": False},
]


def test_read_and_context(tmp_path):
    path = tmp_path / "q.jsonl"
    write(path, *ITEMS)
    path.open("a").write("kaputt\n{}\n")
    items = quick.read(path)
    assert [c.id for c in items] == ["a", "b", "c"] and items[0].day == "2026-10-20"
    text = quick.as_context(items)
    assert text.splitlines()[0] == "- 2026-10-22 question [lisa-muster]: Welcher Preis gilt?"
    assert "task (due 2026-10-23): Max wegen" in text
    assert quick.read(tmp_path / "fehlt.jsonl") == []


def test_mentions():
    a, b = (quick.Capture(**{k: v for k, v in i.items() if k != "delivered"}) for i in ITEMS[:2])
    assert quick.mentions(a, "Max") and not quick.mentions(a, "Lisa")
    assert quick.mentions(b, "Lisa Muster") and not quick.mentions(b, "")


def test_prep_and_context_include_captures(memory_dir, tmp_path):
    path = tmp_path / "q.jsonl"
    write(path, *ITEMS)
    out = []
    agent = Agent(Memory(memory_dir), None, out.append, dt.date(2026, 10, 26), path)
    agent.handle({"cmd": "prep", "participants": ["Max"]})
    assert out[0]["captures"] == [{"route": "task", "text": "Max wegen Margenzahlen anstupsen", "due": "2026-10-23",
                                   "created": "2026-10-20T09:00:00Z", "overdue": True}]
    assert "# Quick capture" in agent.context() and "Raum Ahorn" in agent.context()


def test_prep_without_captures_file(memory_dir):
    out = []
    Agent(Memory(memory_dir), None, out.append, dt.date(2026, 10, 26)).handle({"cmd": "prep", "participants": ["Max"]})
    assert out[0]["captures"] == []


def test_watch_turns_new_questions_into_ask(tmp_path):
    path = tmp_path / "q.jsonl"
    write(path, ITEMS[0])  # already there before the agent started: not asked
    inbox, stop = queue.Queue(), threading.Event()
    thread = threading.Thread(target=watch_captures, args=(path, inbox, 0.05, stop), daemon=True)
    thread.start()
    time.sleep(0.15)
    write(path, ITEMS[1], ITEMS[2], {**ITEMS[0], "id": "d", "text": "Wann ist der Workshop?"})
    deadline = time.time() + 3
    while inbox.empty() and time.time() < deadline:
        time.sleep(0.05)
    stop.set()
    assert json.loads(inbox.get_nowait()) == {"cmd": "ask", "question": "Welcher Preis gilt?", "id": "capture:c"}
    deadline = time.time() + 3
    while inbox.empty() and time.time() < deadline:
        time.sleep(0.05)
    # a task that ends in "?" counts as a question; the note doesn't
    assert json.loads(inbox.get_nowait())["question"] == "Wann ist der Workshop?"
    assert inbox.empty()
