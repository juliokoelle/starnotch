import json

from memory import Meeting, Memory, _seconds


def test_loads_demo_meetings_sorted(memory_dir):
    memory = Memory(memory_dir)
    assert [m.id for m in memory.meetings] == ["2026-10-12-kickoff", "2026-10-19-weekly"]
    assert memory.errors == []


def test_missing_folder_is_empty(tmp_path):
    memory = Memory(tmp_path / "nope")
    assert memory.meetings == []


def test_broken_file_is_reported_not_fatal(memory_dir):
    (memory_dir / "broken.json").write_text("{not json")
    (memory_dir / "noid.json").write_text('{"title": "x"}')
    memory = Memory(memory_dir)
    assert len(memory.meetings) == 2
    assert len(memory.errors) == 2


def test_open_commitments_by_person(memory_dir):
    memory = Memory(memory_dir)
    max_open = memory.open_commitments(["Max"])
    assert [(c.who, c.due) for _, c in max_open] == [("Max", "2026-10-16")]
    # Lisa booked the room: done, so nothing is open for her
    assert memory.open_commitments(["lisa"]) == []


def test_decisions_and_participants(memory_dir):
    memory = Memory(memory_dir)
    assert len(memory.decisions(["Max"])) == 2
    assert memory.decisions(["Unbekannt"]) == []


def test_search_prefers_numbers(memory_dir):
    hits = Memory(memory_dir).search("wir waren doch bei 25 Euro")
    assert hits and "25 Euro" in hits[0].line.text


def test_find_quote(memory_dir):
    memory = Memory(memory_dir)
    meeting, line = memory.find_quote("kostet 30 Euro im Monat")
    assert meeting.id == "2026-10-12-kickoff" and line.speaker == "Jonas"
    assert memory.find_quote("völlig anderes Thema Wetter") is None


def test_save_roundtrip(tmp_path):
    memory = Memory(tmp_path)
    meeting = Meeting.from_dict({
        "id": "a/b c", "title": "T", "date": "2026-01-02T10:00:00",
        "transcript": [{"speaker": "A", "t": "01:05", "text": "Hallo"}, "lose Zeile"],
        "decisions": ["D1"], "commitments": [{"who": "A", "what": "x", "status": "DONE"}],
    })
    path = memory.save(meeting)
    assert path.name == "a-b-c.json"
    data = json.loads(path.read_text())
    assert data["date"] == "2026-01-02"
    assert data["transcript"][0]["t"] == 65.0
    assert data["decisions"][0]["text"] == "D1"
    assert data["commitments"][0]["status"] == "done"
    assert Memory(tmp_path).get("a/b c").title == "T"


def test_seconds():
    assert _seconds("1:02:03") == 3723
    assert _seconds("12.5") == 12.5
    assert _seconds(None) == 0
    assert _seconds("abc") == 0


def test_context_has_ids_and_quotes(memory_dir):
    text = Memory(memory_dir).as_context()
    assert "id=2026-10-12-kickoff" in text and "30 Euro" in text
    assert text.index("2026-10-19-weekly") < text.index("2026-10-12-kickoff")
