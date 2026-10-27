"""The proactive meeting agent: reads utterances and commands on stdin, writes JSON lines on stdout.

    uv run python transcribe.py --file talk.wav | uv run python agent.py
    uv run python agent.py --memory demo/meetings --today 2026-10-26

See PROTOCOL.md for every message.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import queue
import re
import signal
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, TextIO

import captures as quick
from memory import Commitment, Line, Meeting, Memory

WINDOW = 12  # utterances of the running meeting the model sees around the new ones
REST = 60  # seconds on the rules after a failed Claude call: better a rule now than Claude late, batch after batch

SYSTEM = """You listen along to a live meeting and compare it with the team's meeting memory below.
Report, as JSON, only what helps the people in the meeting right now:

- contradictions: something said now conflicts with an earlier decision or statement in the memory
  (a different number, a reversed decision, a wrong claim about what was agreed). Quote the new words exactly
  in now_quote, and the earlier words exactly as they stand in the memory in before_quote, with that meeting's id.
  A changed decision that people make knowingly is not a contradiction; a misremembered one is.
- commitments: someone in the live meeting promises to do something ("I'll send...", "ich schicke ... bis ...").
  who is the speaker (or the person named), what is short, due is an ISO date (YYYY-MM-DD) resolved from today's date, or "".
- questions: at most one question worth asking now that the memory can ground, such as an open commitment by
  someone who is speaking, or a decision that seems forgotten. Usually there is none.

Leave a list empty when nothing qualifies, and never repeat an item listed under "Already reported".
Write note, what and question text in the language of the meeting. They appear as one line in a notification,
so keep each under 60 characters, e.g. note "Beschlossen sind 30 Euro, nicht 25" (the quotes carry the details).

# Meeting memory

{memory}"""

ANALYSIS_SCHEMA = {
    "type": "object",
    "properties": {
        "contradictions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "now_quote": {"type": "string"},
                    "before_quote": {"type": "string"},
                    "meeting_id": {"type": "string"},
                    "note": {"type": "string"},
                },
                "required": ["now_quote", "before_quote", "meeting_id", "note"],
                "additionalProperties": False,
            },
        },
        "commitments": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "who": {"type": "string"},
                    "what": {"type": "string"},
                    "due": {"type": "string"},
                    "quote": {"type": "string"},
                },
                "required": ["who", "what", "due", "quote"],
                "additionalProperties": False,
            },
        },
        "questions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"text": {"type": "string"}, "reason": {"type": "string"}},
                "required": ["text", "reason"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["contradictions", "commitments", "questions"],
    "additionalProperties": False,
}

ASK_SYSTEM = """Answer questions about the team's meetings from the meeting memory below, and only from it.
Answer in the language of the question, in one to three sentences. Back the answer with sources: the meeting id
and the exact words from that meeting. If the memory does not answer it, say so and give no sources.

# Meeting memory

{memory}"""

ASK_SCHEMA = {
    "type": "object",
    "properties": {
        "answer": {"type": "string"},
        "sources": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"meeting_id": {"type": "string"}, "quote": {"type": "string"}},
                "required": ["meeting_id", "quote"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["answer", "sources"],
    "additionalProperties": False,
}

WEEKDAYS = {
    "montag": 0, "dienstag": 1, "mittwoch": 2, "donnerstag": 3, "freitag": 4, "samstag": 5, "sonntag": 6,
    "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3, "friday": 4, "saturday": 5, "sunday": 6,
}
UNIT = r"(euro|eur|€|prozent|%|dollar|\$)"
NUMBER_UNIT = re.compile(r"(\d+(?:[.,]\d+)?)\s*" + UNIT, re.IGNORECASE)
PROMISE = re.compile(
    r"\b(?:ich|wir)\s+(?:schicke?|sende|mache|buche|schreibe|liefere|bereite|übernehme|kümmere mich um|melde mich)\b"
    r"|\b(?:i'll|i will|we'll)\s+\w+",
    re.IGNORECASE,
)
DUE = re.compile(r"\b(?:bis|by)\s+(?:zum\s+|nächsten?\s+|next\s+)?(\w+)", re.IGNORECASE)


@dataclass
class Utterance:
    speaker: str
    text: str
    t: float = 0.0


def next_weekday(today: dt.date, name: str) -> str | None:
    """'Freitag' -> the next Friday after today (today itself counts only as 'heute')."""
    word = name.lower()
    if word in ("heute", "today"):
        return today.isoformat()
    if word in ("morgen", "tomorrow"):
        return (today + dt.timedelta(days=1)).isoformat()
    if word not in WEEKDAYS:
        return None
    days = (WEEKDAYS[word] - today.weekday()) % 7 or 7
    return (today + dt.timedelta(days=days)).isoformat()


def _norm(text: str) -> str:
    return re.sub(r"\W+", " ", text.lower()).strip()


class Agent:
    def __init__(self, memory: Memory, llm: Any | None, emit: Callable[[dict[str, Any]], None],
                 today: dt.date | None = None, captures: Path | None = None):
        self.memory = memory
        self.captures_path = captures
        self.llm = llm
        self.emit = emit
        self.today = today or dt.date.today()
        self.live: list[Utterance] = []
        self.commitments: list[Commitment] = []
        self.reported: set[str] = set()
        self.reported_text: list[str] = []
        self.warned = False
        self.resting_until = 0.0  # time.monotonic() until which Claude isn't asked

    # Commands

    def handle(self, message: dict[str, Any]) -> None:
        """One stdin message: an utterance or a command."""
        if message.get("type") == "utterance":
            self.hear([message])
            return
        cmd = message.get("cmd")
        reply_to = message.get("id")
        try:
            if cmd == "prep":
                out = self.prep(list(message.get("participants") or []))
            elif cmd == "ask":
                out = self.ask(str(message.get("question") or ""))
            elif cmd == "reload":
                self.memory.load()
                out = {"type": "status", "state": "reloaded", "meetings": len(self.memory.meetings)}
            elif cmd == "save":
                out = self.save(message)
            elif cmd == "reset":
                self.live, self.commitments, self.reported, self.reported_text = [], [], set(), []
                out = {"type": "status", "state": "reset"}
            elif message.get("type") in ("status", "partial"):
                return  # transcriber chatter piped through
            else:
                out = {"type": "error", "message": f"unknown message: {json.dumps(message, ensure_ascii=False)[:200]}"}
        except Exception as error:  # one bad command must not end the sidecar
            out = {"type": "error", "message": f"{cmd}: {error}"}
        if reply_to is not None:
            out["reply_to"] = reply_to
        self.emit(out)

    def captures(self) -> list[quick.Capture]:
        return quick.read(self.captures_path) if self.captures_path else []

    def context(self) -> str:
        """The meetings, plus what the user noted with quick capture (it's theirs, so it counts as memory too)."""
        text = self.memory.as_context()
        noted = quick.as_context(self.captures())
        return text + ("\n\n# Quick capture: the user's own tasks, questions and notes\n" + noted if noted else "")

    def prep(self, participants: list[str]) -> dict[str, Any]:
        meetings = self.memory.with_participants(participants)
        ids = {m.id for m in meetings}
        decisions = [
            {"text": d.text, "quote": d.quote, "speaker": d.speaker, **self._source(m)}
            for m, d in reversed(self.memory.decisions(participants))
        ][:6]
        open_items = []
        for m, c in reversed(self.memory.open_commitments()):
            if m.id in ids or any(_norm(c.who).split()[:1] == _norm(p).split()[:1] for p in participants):
                overdue = bool(c.due) and c.due < self.today.isoformat()
                open_items.append({"who": c.who, "what": c.what, "due": c.due, "overdue": overdue,
                                   "quote": c.quote, **self._source(m)})
        noted = [
            {"route": c.route, "text": c.text, "due": c.due, "created": c.created,
             "overdue": bool(c.due) and c.due < self.today.isoformat()}
            for c in reversed(self.captures())
            if c.route in ("task", "question") and any(quick.mentions(c, p) for p in participants)
        ][:6]
        last = meetings[-1] if meetings else None
        return {
            "type": "prep",
            "participants": participants,
            "meetings": [self._source(m) for m in reversed(meetings)],
            "last_meeting": {**self._source(last), "summary": last.summary} if last else None,
            "decisions": decisions,
            "open_commitments": open_items,
            "captures": noted,
        }

    def ask(self, question: str) -> dict[str, Any]:
        if not question.strip():
            return {"type": "error", "message": "ask: empty question"}
        result = None
        if self._thinking():
            try:
                result = self.llm.json(ASK_SYSTEM.format(memory=self.context()), question, ASK_SCHEMA, 2000)
            except Exception as error:
                self._warn(error)
        if result is None:
            result = self._offline_answer(question)
        sources = []
        for s in result.get("sources") or []:
            found = self._locate(s.get("quote", ""), s.get("meeting_id", ""))
            if found:
                meeting, quote, speaker = found
                sources.append({"quote": quote, "speaker": speaker, **self._source(meeting)})
        return {"type": "answer", "question": question, "text": result.get("answer", ""), "sources": sources}

    def _offline_answer(self, question: str) -> dict[str, Any]:
        """The newest decision sharing words with the question, else the best transcript line."""
        words = set(_norm(question).split())
        for m, d in reversed(self.memory.decisions()):
            if len(words & set(_norm(d.text + " " + d.quote).split())) >= 2:
                return {"answer": d.text, "sources": [{"meeting_id": m.id, "quote": d.quote or d.text}]}
        hits = self.memory.search(question, limit=1)
        if not hits:
            return {"answer": "Dazu steht nichts im Gedächtnis.", "sources": []}
        return {"answer": hits[0].line.text, "sources": [{"meeting_id": hits[0].meeting.id, "quote": hits[0].line.text}]}

    def save(self, message: dict[str, Any]) -> dict[str, Any]:
        date = str(message.get("date") or self.today.isoformat())
        title = str(message.get("title") or "Meeting")
        meeting = Meeting(
            id=str(message.get("meeting_id") or f"{date}-{_norm(title).replace(' ', '-') or 'meeting'}"),
            title=title,
            date=date,
            participants=sorted({u.speaker for u in self.live if u.speaker}),
            transcript=[Line(u.speaker, u.text, u.t) for u in self.live],
            commitments=list(self.commitments),
        )
        path = self.memory.save(meeting)
        return {"type": "status", "state": "saved", "meeting_id": meeting.id, "path": str(path)}

    # Listening

    def hear(self, raw: list[dict[str, Any]]) -> None:
        new = [Utterance(str(r.get("speaker") or ""), str(r.get("text") or "").strip(), float(r.get("t") or 0))
               for r in raw]
        new = [u for u in new if u.text]
        if not new:
            return
        before = self.live[-WINDOW:]
        self.live += new
        result = None
        if self._thinking():
            try:
                result = self.llm.json(SYSTEM.format(memory=self.context()),
                                       self._analysis_prompt(before, new), ANALYSIS_SCHEMA)
            except Exception as error:
                self._warn(error)
        if result is None:
            result = self._heuristics(new)
        self._report(result, new)

    def _analysis_prompt(self, before: list[Utterance], new: list[Utterance]) -> str:
        today = self.today
        lines = [f"Today is {today.strftime('%A')}, {today.isoformat()}.", "", "# Live meeting so far"]
        lines += [f"{u.speaker}: {u.text}" for u in before] or ["(nothing yet)"]
        lines += ["", "# New utterances"] + [f"{u.speaker}: {u.text}" for u in new]
        lines += ["", "# Already reported"] + (self.reported_text[-20:] or ["(nothing)"])
        return "\n".join(lines)

    def _report(self, result: dict[str, Any], new: list[Utterance]) -> None:
        for c in result.get("contradictions") or []:
            found = self._locate(c.get("before_quote", ""), c.get("meeting_id", ""))
            if not found:
                continue  # the model quoted something that isn't in the memory
            meeting, quote, speaker = found
            if not self._fresh("contradiction", quote, label=f'{c.get("now_quote", "")} / {quote}'):
                continue  # one alert per earlier quote, however the model words the new one
            said = self._speaker_of(c.get("now_quote", ""), new)
            self.emit({
                "type": "contradiction",
                "now": c.get("now_quote", ""),
                "speaker": said.speaker if said else "",
                "t": said.t if said else None,
                "before": {"quote": quote, "speaker": speaker, **self._source(meeting)},
                "note": c.get("note", ""),
            })
        for c in result.get("commitments") or []:
            if not c.get("what") or not self._fresh("commitment", c.get("who", ""), c.get("what", "")):
                continue
            due = c.get("due") or None
            self.commitments.append(Commitment(c.get("who", ""), c["what"], due, c.get("quote", "")))
            self.emit({"type": "commitment", "who": c.get("who", ""), "what": c["what"], "due": due,
                       "quote": c.get("quote", "")})
        for q in (result.get("questions") or [])[:1]:
            if q.get("text") and self._fresh("question", q["text"]):
                self.emit({"type": "question", "text": q["text"], "reason": q.get("reason", "")})

    def _fresh(self, kind: str, *parts: str, label: str = "") -> bool:
        key = kind + "|" + "|".join(_norm(p) for p in parts)
        if key in self.reported:
            return False
        self.reported.add(key)
        self.reported_text.append(f"{kind}: " + (label or " / ".join(parts)))
        return True

    def _locate(self, quote: str, meeting_id: str) -> tuple[Meeting, str, str] | None:
        """(meeting, quote as stored, speaker) for a quote the model gave, or None if it isn't in the memory."""
        found = self.memory.find_quote(quote)
        if found:
            meeting, line = found
            return meeting, line.text, line.speaker
        meeting = self.memory.get(meeting_id)
        if meeting:
            needle = _norm(quote)
            for d in meeting.decisions:
                if needle and (needle in _norm(d.quote) or needle in _norm(d.text)):
                    return meeting, d.quote or d.text, d.speaker
            for c in meeting.commitments:
                if needle and needle in _norm(c.quote):
                    return meeting, c.quote, c.who
        return None

    @staticmethod
    def _speaker_of(quote: str, new: list[Utterance]) -> Utterance | None:
        needle = _norm(quote)
        return next((u for u in new if needle and needle in _norm(u.text)), new[-1] if new else None)

    @staticmethod
    def _source(meeting: Meeting) -> dict[str, Any]:
        return {"meeting": meeting.title or meeting.id, "meeting_id": meeting.id, "date": meeting.date}

    def _thinking(self) -> bool:
        return self.llm is not None and time.monotonic() >= self.resting_until

    def _warn(self, error: Exception) -> None:
        if type(error).__name__ in ("AuthenticationError", "PermissionDeniedError", "TypeError", "ClaudeCodeUnavailable"):
            self.llm = None  # no or bad credentials: stop waiting on Claude for every line
        else:  # slow, overloaded or throttled: the rules for a while, then Claude again
            self.resting_until = time.monotonic() + REST
        if not self.warned:
            self.emit({"type": "status", "state": "offline", "message": f"Claude unavailable, using rules: {error}"})
            self.warned = True

    # Without Claude: simple rules, enough for the demo

    def _heuristics(self, new: list[Utterance]) -> dict[str, Any]:
        out: dict[str, list[dict[str, str]]] = {"contradictions": [], "commitments": [], "questions": []}
        for u in new:
            for number, unit in NUMBER_UNIT.findall(u.text):
                unit = _unit(unit)
                for m, d in reversed(self.memory.decisions()):
                    source = d.quote or d.text
                    stated = {n for n, un in NUMBER_UNIT.findall(source) if _unit(un) == unit}
                    if stated and number not in stated:
                        out["contradictions"].append({
                            "now_quote": u.text, "before_quote": source, "meeting_id": m.id,
                            "note": f"Entschieden waren {', '.join(sorted(stated))} {unit}, nicht {number} {unit}.",
                        })
                        break
            if PROMISE.search(u.text):
                due_word = DUE.search(u.text)
                due = next_weekday(self.today, due_word.group(1)) if due_word else None
                what = re.sub(r"\s+", " ", DUE.sub("", u.text)).strip(" .!")
                out["commitments"].append({"who": u.speaker, "what": what, "due": due or "", "quote": u.text})
            for m, c in self.memory.open_commitments([u.speaker]) if u.speaker else []:
                if c.due and c.due < self.today.isoformat():
                    out["questions"].append({
                        "text": f"{c.who}, {c.what}: das war bis {c.due} zugesagt. Wie ist der Stand?",
                        "reason": f"Offene Zusage aus {m.label()}",
                    })
        return out


def _unit(unit: str) -> str:
    unit = unit.lower()
    return {"eur": "Euro", "€": "Euro", "euro": "Euro", "%": "Prozent", "prozent": "Prozent", "$": "Dollar"}.get(unit, unit)


def _reader(stream: TextIO, inbox: "queue.Queue[str | None]") -> None:
    for line in stream:
        inbox.put(line)
    inbox.put(None)


def watch_captures(path: Path, inbox: "queue.Queue[str | None]", interval: float = 1.5,
                   stop: threading.Event | None = None) -> None:
    """New quick-capture questions become `ask` commands, so the answer pops up in the notch."""
    seen = {c.id for c in quick.read(path)}
    mtime = None
    while not (stop and stop.is_set()):
        try:
            current = path.stat().st_mtime
        except OSError:
            current = None
        if current != mtime:
            mtime = current
            for c in quick.read(path):
                if c.id not in seen:
                    seen.add(c.id)
                    if c.is_question:
                        inbox.put(json.dumps({"cmd": "ask", "question": c.text, "id": f"capture:{c.id}"}))
        time.sleep(interval)


def run(agent: Agent, stream: TextIO, watch: Path | None = None) -> None:
    """Reads stdin on a thread; utterances that pile up while Claude thinks go out together in one call.
    With `watch`, questions typed into quick capture are answered too."""
    inbox: "queue.Queue[str | None]" = queue.Queue()
    threading.Thread(target=_reader, args=(stream, inbox), daemon=True).start()
    if watch:
        threading.Thread(target=watch_captures, args=(watch, inbox), daemon=True).start()
    done = False
    while not done:
        batch = [inbox.get()]
        while not inbox.empty():
            batch.append(inbox.get_nowait())
        heard: list[dict[str, Any]] = []
        for line in batch:
            if line is None:
                done = True
                break
            if not line.strip():
                continue
            try:
                message = json.loads(line)
                if not isinstance(message, dict):
                    raise ValueError("not an object")
            except ValueError as error:
                message = {"type": "error", "message": f"bad json: {error}"}
            if message.get("type") == "utterance":
                heard.append(message)
                continue
            if heard:  # keep replies in input order
                agent.hear(heard)
                heard = []
            if message.get("type") == "error":
                agent.emit(message)
            else:
                agent.handle(message)
        if heard:
            agent.hear(heard)


def make_emit(out: TextIO) -> Callable[[dict[str, Any]], None]:
    lock = threading.Lock()

    def emit(obj: dict[str, Any]) -> None:
        with lock:
            out.write(json.dumps(obj, ensure_ascii=False) + "\n")
            out.flush()

    return emit


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Starnotch meeting agent (JSON lines on stdin/stdout)")
    parser.add_argument("--memory", help="folder of meeting JSON files (default: ~/Library/Application Support/Starnotch/memory)")
    parser.add_argument("--today", help="date to resolve 'bis Freitag' against, YYYY-MM-DD (default: today)")
    parser.add_argument("--offline", action="store_true", help="no Claude, only the built-in rules (as STARNOTCH_BRAIN=rules)")
    parser.add_argument("--captures", default=str(quick.QUEUE),
                        help="Starnotch's quick-capture queue (default: capture-queue.jsonl in its folder); '' to ignore")
    parser.add_argument("--watch-captures", action="store_true",
                        help="answer questions typed into quick capture as they arrive")
    args = parser.parse_args(argv)

    # The app ends a meeting with SIGTERM; as an exception it lets a running Claude call clean up its prompt file.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(128 + signal.SIGTERM))
    emit = make_emit(sys.stdout)
    memory = Memory(args.memory)
    brain, llm = "rules", None
    if not args.offline:
        from claude import make_brain

        brain, llm, why = make_brain()
        if why:  # no login or no key: keep going on rules
            emit({"type": "status", "state": "offline", "message": why})
    today = dt.date.fromisoformat(args.today) if args.today else None
    captures = Path(args.captures).expanduser() if args.captures else None
    agent = Agent(memory, llm, emit, today, captures)
    emit({"type": "ready", "meetings": len(memory.meetings), "memory": str(memory.folder),
          "brain": brain, "model": getattr(llm, "model", None), "errors": memory.errors})
    run(agent, sys.stdin, captures if args.watch_captures else None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
