"""The full text behind every card in the notch.

The notch has room for one short line, so notch_bridge links each card here: a small page on 127.0.0.1 that lists
every event of the session in full (the whole answer, both quotes of a contradiction, every source), newest first,
and the same events appended to a Markdown file that stays after the session.
"""

from __future__ import annotations

import datetime as dt
import html
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

PORT = 47790
TITLES = {"contradiction": "Widerspruch", "question": "Frage an die Runde", "commitment": "Zusage",
          "prep": "Vorbereitung", "answer": "Antwort"}


def _day(iso: str | None) -> str:
    parts = str(iso or "").split("-")
    return f"{parts[2][:2]}.{parts[1]}.{parts[0]}" if len(parts) == 3 else str(iso or "")


def _source(item: dict[str, Any]) -> str:
    meeting = item.get("meeting") or item.get("meeting_id") or ""
    return f"{meeting}, {_day(item.get('date'))}" if item.get("date") else str(meeting)


def lines_for(event: dict[str, Any]) -> list[tuple[str, str]]:
    """The event as (label, text) pairs, in reading order; the same for the page and the Markdown file."""
    kind = event.get("type")
    out: list[tuple[str, str]] = []
    if kind == "contradiction":
        before = event.get("before") or {}
        out.append(("", event.get("note", "")))
        said = f"„{event.get('now', '')}“" + (f" ({event['speaker']})" if event.get("speaker") else "")
        out.append(("Gerade gesagt", said))
        earlier = f"„{before.get('quote', '')}“" + (f" ({before['speaker']})" if before.get("speaker") else "")
        out.append((f"Vorher, {_source(before)}", earlier))
    elif kind == "question":
        out += [("", event.get("text", "")), ("Warum", event.get("reason", ""))]
    elif kind == "commitment":
        out.append(("", f"{event.get('who') or 'Jemand'}: {event.get('what', '')}"))
        out.append(("Fällig", _day(event.get("due")) if event.get("due") else "ohne Datum"))
        out.append(("Wörtlich", f"„{event.get('quote', '')}“"))
    elif kind == "answer":
        out += [("Frage", event.get("question", "")), ("", event.get("text", ""))]
        for source in event.get("sources") or []:
            who = f" ({source['speaker']})" if source.get("speaker") else ""
            out.append((f"Quelle, {_source(source)}", f"„{source.get('quote', '')}“{who}"))
        if not event.get("sources"):
            out.append(("Quelle", "keine im Gedächtnis"))
    elif kind == "prep":
        if event.get("participants"):
            out.append(("Teilnehmer", ", ".join(event["participants"])))
        last = event.get("last_meeting")
        if last:
            out.append((f"Letztes Meeting, {_source(last)}", last.get("summary", "")))
        for c in event.get("open_commitments") or []:
            due = f", fällig {_day(c['due'])}" + (" (überfällig)" if c.get("overdue") else "") if c.get("due") else ""
            out.append((f"Offen: {c.get('who', '')}{due}", f"{c.get('what', '')} – „{c.get('quote', '')}“ ({_source(c)})"))
        for d in event.get("decisions") or []:
            out.append((f"Entschieden, {_source(d)}", f"{d.get('text', '')} – „{d.get('quote', '')}“"))
        for c in event.get("captures") or []:
            due = f", fällig {c['due']}" if c.get("due") else ""
            out.append((f"Notiert ({c.get('route', '')}{due})", c.get("text", "")))
    return [(label, text) for label, text in out if text]


class Feed:
    """Events of one session: served as a page (started on the first event) and appended to a Markdown file."""

    def __init__(self, log: Path | None, port: int = PORT):
        self.log = log
        self.port = port
        self.events: list[tuple[str, dict[str, Any]]] = []
        self.server: ThreadingHTTPServer | None = None
        self.lock = threading.Lock()

    def add(self, event: dict[str, Any]) -> str:
        """Stores the event and returns the link to it on the page."""
        stamp = dt.datetime.now().strftime("%H:%M:%S")
        with self.lock:
            self.events.append((stamp, event))
            number = len(self.events)
        self._append_markdown(stamp, event)
        self._serve()
        return f"http://127.0.0.1:{self.port}/#e{number}"

    def _append_markdown(self, stamp: str, event: dict[str, Any]) -> None:
        if not self.log:
            return
        try:
            self.log.parent.mkdir(parents=True, exist_ok=True)
            new = not self.log.exists()
            with self.log.open("a", encoding="utf-8") as handle:
                if new:
                    handle.write("# Meeting-Agent\n\nAlles, was der Agent in der Notch gezeigt hat, in voller Länge.\n")
                handle.write(f"\n## {dt.date.today().isoformat()} {stamp} · {TITLES.get(event.get('type', ''), event.get('type', ''))}\n\n")
                for label, text in lines_for(event):
                    handle.write(f"- **{label}:** {text}\n" if label else f"{text}\n\n")
        except OSError:
            pass  # the page still has it

    def page(self) -> str:
        with self.lock:
            events = list(enumerate(self.events, start=1))
        cards = []
        for number, (stamp, event) in reversed(events):
            rows = "".join(
                f'<p class="lead">{html.escape(text)}</p>' if not label
                else f'<p><span class="label">{html.escape(label)}</span>{html.escape(text)}</p>'
                for label, text in lines_for(event)
            )
            kind = event.get("type", "")
            cards.append(f'<section id="e{number}" class="card {html.escape(kind)}"><h2>{html.escape(TITLES.get(kind, kind))}'
                         f'<span>{stamp}</span></h2>{rows}</section>')
        body = "".join(cards) or '<p class="empty">Noch nichts. Die Karten aus der Notch erscheinen hier in voller Länge.</p>'
        return PAGE.replace("{body}", body)

    def _serve(self) -> None:
        if self.server:
            return
        feed = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                data = feed.page().encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args: Any) -> None:
                pass

        for port in range(self.port, self.port + 10) if self.port else [0]:  # a second bridge in the pipeline takes the next port
            try:
                self.server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
                self.port = self.server.server_address[1]
                break
            except OSError:
                continue
        if self.server:
            threading.Thread(target=self.server.serve_forever, daemon=True).start()


PAGE = """<!doctype html><html lang="de"><head><meta charset="utf-8"><meta http-equiv="refresh" content="4">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Meeting-Agent</title><style>
:root{--bg:#0d0d0f;--card:#1a1a1e;--text:#f2f2f4;--dim:#9a9aa3;--critical:#ff6b6b;--waiting:#ffc04d;--ok:#5fd38d;--accent:#8ab4ff}
body{margin:0;padding:24px 16px;background:var(--bg);color:var(--text);font:15px/1.5 -apple-system,system-ui,sans-serif}
main{max-width:720px;margin:0 auto}h1{font-size:20px;margin:0 0 16px}
.card{background:var(--card);border-radius:14px;padding:14px 18px;margin:0 0 12px;border-left:4px solid var(--accent)}
.card:target{outline:2px solid var(--accent)}.contradiction{border-color:var(--critical)}.question{border-color:var(--waiting)}
.commitment{border-color:var(--ok)}h2{font-size:13px;text-transform:uppercase;letter-spacing:.04em;color:var(--dim);margin:0 0 6px;display:flex;justify-content:space-between}
p{margin:4px 0}.lead{font-size:17px;font-weight:600}.label{display:block;color:var(--dim);font-size:12.5px}.empty{color:var(--dim)}
</style></head><body><main><h1>Meeting-Agent</h1>{body}</main></body></html>"""
