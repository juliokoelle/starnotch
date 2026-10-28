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
import connectors as linked
from jamie_sync import last_synced
import usage as ledger
from memory import Commitment, Line, Meeting, Memory, _words

WINDOW = 12  # utterances of the running meeting the model sees around the new ones
RECALL = 6  # earlier transcript lines that share words with the new ones, for transcripts the memory had to shorten
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

ASK_SYSTEM = """You are Tara, the user's assistant in the Mac's notch. You know their meetings, what they noted with quick
capture, and snapshots from their other tools (notes, tasks), all below. Answer their question from that, in the
language of the question, in at most three short sentences (under 300 characters): it shows in a small speech
bubble. Lead with the answer.

Back every fact from the material below with a source: kind "meeting" with the meeting id and the exact words from
that meeting, kind "capture" with the capture id and its text, or kind "note" with the item id in brackets (e.g.
vault:3) and the words you used from it. If the material does not answer a question about the user's own work, say so
plainly and give no sources. A general question that is not about their work you may answer briefly from general
knowledge, with no sources. A screenshot, when one comes along, shows the window the user asks about.
The conversation so far, when there is one, is context for follow-up questions. The question starts with today's
date and, when known, when Jamie last synced the meetings; asked about a meeting from today that isn't in the memory,
say when Jamie last synced instead of guessing.

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
                "properties": {
                    "kind": {"type": "string", "enum": ["meeting", "capture", "note"]},
                    "id": {"type": "string"},
                    "quote": {"type": "string"},
                },
                "required": ["kind", "id", "quote"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["answer", "sources"],
    "additionalProperties": False,
}
MATCH = 2  # shared content words (no stop words) a line needs before the rules offer it as an answer
HISTORY = 6  # earlier questions and answers of the conversation that come along in a follow-up
NO_BRAIN = {
    "de": "Ohne Claude finde ich nur Wörter in deinen Meetings und Notizen, und dazu steht dort nichts. "
          "Verbinde Claude Code in den Einstellungen, dann beantworte ich auch richtige Fragen.",
    "en": "Without Claude I can only look up words in your meetings and notes, and nothing there matches. "
          "Connect Claude Code in Settings and I can answer real questions.",
}
NO_ANSWER = {  # Claude is connected but gave no answer this time (a refusal, a failed call, an unreadable reply)
    "de": "Darauf habe ich gerade keine Antwort, und in deinen Meetings und Notizen steht dazu nichts.",
    "en": "I don't have an answer to that right now, and nothing in your meetings and notes matches.",
}
GERMAN = {"wie", "wer", "wann", "wo", "warum", "welche", "welcher", "welches", "welchen", "ich", "wir", "haben", "hat",
          "ist", "sind", "der", "die", "das", "und", "nicht", "mit", "noch", "schon", "bis", "heute", "mein", "meine"}
ENGLISH = {"what", "who", "when", "where", "why", "which", "how", "did", "do", "does", "is", "are", "the", "and", "we",
           "i", "have", "has", "today", "my", "was", "were"}

# Words that carry no topic: two of them must not make a meeting line look like the answer.
STOP = GERMAN | ENGLISH | {
    "was", "ein", "eine", "einen", "einem", "einer", "den", "dem", "des", "für", "von", "vom", "zum", "zur", "auf",
    "aus", "bei", "beim", "über", "unter", "nach", "vor", "oder", "aber", "auch", "denn", "dann", "wenn", "dass",
    "ihr", "sie", "uns", "unser", "unsere", "dein", "deine", "wird", "werden", "wurde", "war", "kann", "können",
    "soll", "sollen", "muss", "gibt", "steht", "morgen", "gestern", "jetzt", "eigentlich", "mal", "doch", "nur",
    "sehr", "viel", "alles", "etwas", "nichts", "man", "euch", "this", "that", "these", "those", "for", "with",
    "about", "from", "you", "your", "our", "will", "would", "can", "could", "should", "there", "any", "some", "been",
    "into", "tomorrow", "yesterday", "now", "much", "many", "all", "not", "but", "its", "it's", "what's", "they",
}

# A question about a decision ("Welchen Preis haben wir beschlossen?"): one topic word then finds the decision.
DECIDED = {"beschlossen", "entschieden", "entscheidung", "beschluss", "vereinbart", "abgemacht", "festgelegt",
           "decided", "decision", "agreed", "settled"}

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
                 today: dt.date | None = None, captures: Path | None = None, connectors: Path | None = None,
                 brain: str | None = None, usage: Path | None = None):
        self.memory = memory
        self.ledger = ledger.Ledger(usage) if usage else None
        self.captures_path = captures
        self.connectors_path = connectors
        self.brain = brain or ("rules" if llm is None else "claude")
        self.llm = llm
        self.emit = emit
        self.fixed_today = today
        self.live: list[Utterance] = []
        self.commitments: list[Commitment] = []
        self.reported: set[str] = set()
        self.reported_text: list[str] = []
        self.warned = False
        self.resting_until = 0.0  # time.monotonic() until which Claude isn't asked

    @property
    def today(self) -> dt.date:
        """The date given at start (demo, tests), else the real one: an agent kept warm overnight moves on."""
        return self.fixed_today or dt.date.today()

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
                out = self.ask(str(message.get("question") or ""), message.get("history"), message.get("image"),
                               answering=str(reply_to)[len("capture:"):] if str(reply_to).startswith("capture:") else None)
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

    def notes(self) -> list[linked.Item]:
        return linked.read(self.connectors_path) if self.connectors_path else []

    def ask_context(self, notes: list[linked.Item]) -> str:
        """For questions: the meetings, the captures with their ids, and the connector snapshots."""
        parts = [self.memory.as_context() or "(no meetings yet)"]
        noted = quick.as_context(self.captures(), ids=True)
        if noted:
            parts.append("# Quick capture: the user's own tasks, questions and notes\n" + noted)
        if notes:
            parts.append("# Snapshots from the user's other tools\n" + linked.as_context(notes))
        return "\n\n".join(parts)

    def ask_system(self, notes: list[linked.Item]) -> str:
        """Tara's instructions and the material. Nothing in it changes with the clock or a sync that brought nothing
        new, so Claude's prompt cache keeps it from question to question."""
        return ASK_SYSTEM.format(memory=self.ask_context(notes))

    def ask_moment(self) -> str:
        """Today's date and when Jamie last synced the meetings: it opens the question, not the cached system prompt."""
        synced = last_synced(self.memory.folder)
        line = (f" Jamie last synced the meetings at {synced:%Y-%m-%d %H:%M}; meetings Jamie had not finished by then "
                f"are not in the memory yet." if synced else "")
        return f"Today is {self.today:%A}, {self.today.isoformat()}.{line}\n\n"

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

    def ask(self, question: str, history: Any = None, image: Any = None, answering: str | None = None) -> dict[str, Any]:
        """A question to Tara: answered from the meetings, captures and connector snapshots, with sources.
        `history` is the conversation so far ([{"question", "answer"}], oldest first), `image` a screenshot's path,
        `answering` the id of the quick capture that asked it (the rules never offer it as its own answer).
        Someone waits for the answer, so Claude is asked even while meeting batches rest it, and a failure here
        doesn't rest it."""
        if not question.strip():
            return {"type": "error", "message": "ask: empty question"}
        notes = self.notes()
        result, brain = None, "rules"
        if self.llm is not None:
            recall = self._recall(question)
            prompt = self.ask_moment() + _conversation(history) + question
            if recall:
                prompt += "\n\n# Earlier lines with the same words\n" + "\n".join(recall)
            picture = Path(str(image)).expanduser() if image else None
            extra = {"images": [picture]} if picture and picture.is_file() else {}  # a picture that's gone: ask without
            try:
                result = self._think("capture" if answering else "ask", self.ask_system(notes),
                                     prompt, ASK_SCHEMA, 2000, **extra)
            except Exception as error:
                self._warn(error, rest=False)
            if result is not None:
                brain = self.brain
        if result is None:
            result = self._offline_answer(question, notes, answering)
            if self.llm is not None and not result["sources"]:
                brain = self.brain  # Claude is there and simply had no answer this time: not the rules talking
        sources: list[dict[str, Any]] = []
        for s in result.get("sources") or []:
            source = self._resolve(s, notes)
            if source and source not in sources:
                sources.append(source)
        return {"type": "answer", "question": question, "text": result.get("answer", ""), "sources": sources,
                "brain": brain}

    def _resolve(self, cited: dict[str, Any], notes: list[linked.Item]) -> dict[str, Any] | None:
        """A source the model cited, as the app shows it; None when it isn't in the material."""
        kind, ref, quote = cited.get("kind") or "meeting", str(cited.get("id") or cited.get("meeting_id") or ""), cited.get("quote", "")
        if kind == "capture":
            capture = next((c for c in self.captures() if c.id == ref), None)
            if not capture:
                return None
            return {"kind": "capture", "title": capture.text, "quote": capture.text, "date": capture.day, "id": capture.id}
        if kind == "note":
            item = linked.get(notes, ref)
            if not item:
                return None
            return {"kind": "note", "title": item.title, "quote": quote if quote and _norm(quote) in _norm(item.title + " " + item.body) else "",
                    "source": item.source, "date": item.date[:10], "url": item.url, "id": item.id}
        found = self._locate(quote, ref)
        if not found:
            return None
        meeting, text, speaker = found
        return {"kind": "meeting", "title": meeting.title or meeting.id, "quote": text, "speaker": speaker,
                **self._source(meeting)}

    def _offline_answer(self, question: str, notes: list[linked.Item] | None = None,
                        answering: str | None = None) -> dict[str, Any]:
        """Without Claude: the newest decision sharing content words with the question, else the transcript line,
        capture or note sharing the most (at least MATCH, stop words left out). Captured questions are no answers,
        least of all the one being asked. When nothing matches, an honest line about what Tara can do."""
        query = _content(question)
        topic, need = query - DECIDED, 1 if query & DECIDED else MATCH
        for m, d in reversed(self.memory.decisions()):
            if topic and len(topic & _content(d.text + " " + d.quote)) >= need:
                return {"answer": d.text, "sources": [{"kind": "meeting", "id": m.id, "quote": d.quote or d.text}]}
        best: tuple[float, dict[str, Any]] | None = None
        hits = self.memory.search(" ".join(sorted(query)), limit=1) if len(query) >= MATCH else []
        if hits and hits[0].score >= MATCH:
            best = (hits[0].score, {"answer": hits[0].line.text,
                                    "sources": [{"kind": "meeting", "id": hits[0].meeting.id, "quote": hits[0].line.text}]})
        asked = _norm(question)
        for c in self.captures():
            if c.id == answering or c.is_question or _norm(c.text) == asked:
                continue
            score = float(len(query & _content(c.text)))
            if score >= MATCH and (best is None or score > best[0]):
                best = (score, {"answer": c.text, "sources": [{"kind": "capture", "id": c.id, "quote": c.text}]})
        for item in notes or []:
            score = float(len(query & _content(item.title + " " + item.body)))
            if score >= MATCH and (best is None or score > best[0]):
                best = (score, {"answer": item.title, "sources": [{"kind": "note", "id": item.id, "quote": item.title}]})
        if best:
            return best[1]
        return {"answer": (NO_BRAIN if self.llm is None else NO_ANSWER)[_language(question)], "sources": []}

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
                result = self._think("meeting", SYSTEM.format(memory=self.context()),
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
        recall = self._recall(" ".join(u.text for u in new))
        if recall:
            lines += ["", "# Earlier lines with the same words"] + recall
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

    def _recall(self, text: str) -> list[str]:
        """Transcript lines from the memory sharing two or more words with `text`: the system prompt may only
        carry an excerpt of a long transcript, so the lines that matter now come along in the prompt."""
        return [f"[{h.meeting.id} | {h.meeting.date}] {h.line.speaker}: {h.line.text}"
                for h in self.memory.search(text, RECALL) if h.score >= 2]

    def _think(self, feature: str, system: str, prompt: str, schema: dict[str, Any], max_tokens: int = 4000,
               **extra: Any) -> dict[str, Any] | None:
        """One brain call; its tokens and cost go to the usage ledger, also when the call fails after spending them."""
        try:
            return self.llm.json(system, prompt, schema, max_tokens, **extra)
        finally:
            spent = getattr(self.llm, "last_usage", None)
            if spent and self.ledger:
                try:
                    self.ledger.record(feature, self.brain, spent)
                except Exception as error:  # a broken ledger must not cost Tara her answer
                    print(f"usage ledger: {error}", file=sys.stderr)

    def _thinking(self) -> bool:
        return self.llm is not None and time.monotonic() >= self.resting_until

    def _warn(self, error: Exception, rest: bool = True) -> None:
        if type(error).__name__ in ("AuthenticationError", "PermissionDeniedError", "TypeError", "ClaudeCodeUnavailable"):
            self.llm = None  # no or bad credentials: stop waiting on Claude for every line
        elif rest:  # slow, overloaded or throttled: the rules for a while, then Claude again
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


def _conversation(history: Any) -> str:
    """The last few questions and answers of the conversation, as the start of a follow-up's prompt."""
    turns = [t for t in history if isinstance(t, dict)][-HISTORY:] if isinstance(history, list) else []
    lines = []
    for turn in turns:
        question, answer = str(turn.get("question") or "").strip(), str(turn.get("answer") or "").strip()
        if question:
            lines += [f"User: {question[:600]}", f"Tara: {answer[:600]}"]
    return "# Conversation so far\n" + "\n".join(lines) + "\n\n# Question now\n" if lines else ""


def _content(text: str) -> set[str]:
    """The words of `text` that carry its topic: _words without stop words."""
    return _words(text) - STOP


def _language(text: str) -> str:
    """"de" or "en", from the question's words (umlauts tip a tie to German)."""
    words = re.findall(r"[a-zäöüß]+", text.lower())
    german, english = sum(w in GERMAN for w in words), sum(w in ENGLISH for w in words)
    if german != english:
        return "de" if german > english else "en"
    return "de" if re.search(r"[äöüß]", text.lower()) else "en"


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
    parser.add_argument("--connectors", default=str(linked.FOLDER),
                        help="folder of connector snapshots (*.json) for ask (default: connectors/ in Starnotch's folder); '' to ignore")
    parser.add_argument("--usage", default=str(ledger.LEDGER),
                        help="usage ledger, one line per brain call (default: usage.jsonl in Starnotch's folder); '' for none")
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
    connectors = Path(args.connectors).expanduser() if args.connectors else None
    usage = Path(args.usage).expanduser() if args.usage else None
    agent = Agent(memory, llm, emit, today, captures, connectors, brain, usage)
    emit({"type": "ready", "meetings": len(memory.meetings), "memory": str(memory.folder),
          "brain": brain, "model": getattr(llm, "model", None), "errors": memory.errors})
    run(agent, sys.stdin, captures if args.watch_captures else None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
