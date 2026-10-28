import datetime as dt
import json

import agent as agent_module
import connectors as linked
import jamie_sync
import privacy
from agent import Agent
from memory import Memory

NOW = dt.datetime(2026, 10, 28, 20, 0, tzinfo=dt.timezone.utc)


def write(path, **data):
    path.write_text(json.dumps(data), encoding="utf-8")


def test_missing_or_broken_file_means_everything_on(tmp_path):
    p = privacy.load(tmp_path / "nope.json")
    assert not p.is_paused(NOW) and all(p.records(s, NOW) for s in privacy.SOURCES)
    (tmp_path / "bad.json").write_text("{", encoding="utf-8")
    assert privacy.load(tmp_path / "bad.json").records("meetings", NOW)


def test_pause_until_a_time_and_until_resumed(tmp_path):
    file = tmp_path / "privacy.json"
    write(file, paused=True, paused_until="2026-10-28T21:00:00Z", off=["clipboard", "screen"])
    p = privacy.load(file)
    assert p.is_paused(NOW) and not p.is_paused(NOW + dt.timedelta(hours=2))
    assert not p.records("meetings", NOW) and p.shares("meetings")
    assert p.off == {"clipboard"}
    assert p.why_not("meetings", NOW) == "Tara's memory is paused"
    write(file, paused=True, paused_until=None)
    assert privacy.load(file).is_paused(NOW + dt.timedelta(days=400))


def test_connector_files_answer_to_their_source():
    assert privacy.connector_source("calendar") == "meetings"
    assert privacy.connector_source("vault") == "notes"


def make(memory_dir, tmp_path, out):
    queue = tmp_path / "capture-queue.jsonl"
    queue.write_text(json.dumps({"id": "c1", "created": "2026-10-24T09:00:00Z", "route": "task",
                                 "text": "Zahlen von Max nachfragen", "due": "2026-10-27"}) + "\n", encoding="utf-8")
    folder = tmp_path / "connectors"
    folder.mkdir()
    write(folder / "vault.json", tasks=[{"title": "Landingpage Text", "due": "2026-10-28"}])
    write(folder / "calendar.json", name="Calendar", today=[{"title": "Design review", "date": "2026-10-28T10:00"}])
    return Agent(Memory(memory_dir), None, out.append, dt.date(2026, 10, 28), queue, folder)


def test_sources_switched_off_are_left_out_of_answers(memory_dir, tmp_path, monkeypatch):
    out = []
    agent = make(memory_dir, tmp_path, out)
    assert agent.memory.meetings and agent.captures() and {i.source for i in agent.notes()} == {"Calendar", "vault"}
    write(tmp_path / "privacy.json", off=["meetings", "captures"])
    assert agent.memory.meetings == [] and agent.captures() == []
    assert {i.source for i in agent.notes()} == {"vault"}  # the calendar is a meeting source
    write(tmp_path / "privacy.json", off=["notes"])
    assert {i.source for i in agent.notes()} == {"Calendar"}
    agent.handle({"cmd": "prep", "participants": ["Max"], "id": 1})
    assert out[-1]["decisions"]  # meetings are on again


def test_nothing_is_saved_or_heard_while_paused(memory_dir, tmp_path):
    out = []
    agent = make(memory_dir, tmp_path, out)
    write(tmp_path / "privacy.json", paused=True, paused_until=None)
    agent.hear([{"speaker": "Max", "text": "Wir nehmen 25 Euro", "t": 1}])
    assert agent.waiting == []
    agent.handle({"cmd": "save", "title": "Secret", "id": 7})
    assert out[-1]["state"] == "not_saved" and "paused" in out[-1]["message"]
    assert not any("secret" in p.name for p in memory_dir.iterdir())
    write(tmp_path / "privacy.json", paused=False)
    agent.hear([{"speaker": "Max", "text": "Wir nehmen 30 Euro", "t": 2}])
    agent.handle({"cmd": "save", "title": "Open", "id": 8})
    assert out[-1]["state"] == "saved"


def test_jamie_sync_does_nothing_while_paused(tmp_path, capsys, monkeypatch):
    write(tmp_path / "privacy.json", paused=True)
    called = []
    monkeypatch.setattr(jamie_sync, "connect_and_run", lambda *a, **k: called.append(a))
    assert jamie_sync.main(["--memory", str(tmp_path / "memory")]) == 0
    line = json.loads(capsys.readouterr().out.strip())
    assert line["state"] == "paused" and called == []


def test_connectors_read_with_allow(tmp_path):
    write(tmp_path / "a.json", items=[{"title": "x"}])
    write(tmp_path / "b.json", items=[{"title": "y"}])
    assert [i.title for i in linked.read(tmp_path, allow=lambda stem: stem != "a")] == ["y"]
