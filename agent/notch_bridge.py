"""Shows agent.py's events in the Starnotch notch, through the app's local status API. No Swift change needed.

    uv run python demo/play.py --commands | uv run python agent.py --memory demo/meetings | uv run python notch_bridge.py
    ... | uv run python notch_bridge.py --captions     # also what is said, as a live caption

Every input line is passed through to stdout unchanged, so the bridge can sit anywhere in a pipeline.
A click on a card opens its full text (feed.py: a page on 127.0.0.1, and Meeting-Agent.md in the app's folder).

Delivery: POST to 127.0.0.1 (Settings › Local status API on; token from Application Support), else the
`starnotch://status?…` link, which needs no setting. The notch shows one line at a time, so titles are short.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

from feed import TITLES, Feed

SUPPORT = Path.home() / "Library" / "Application Support" / "Starnotch"
PORT = 47789


def short(text: str, limit: int) -> str:
    text = " ".join(str(text or "").split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def day(iso: str) -> str:
    """'2026-10-12' -> '12.10.'"""
    parts = str(iso or "").split("-")
    return f"{parts[2]}.{parts[1]}." if len(parts) == 3 else str(iso or "")


def source(before: dict[str, Any]) -> str:
    """'Kickoff Lumen-Abo, 12.10.'"""
    meeting = before.get("meeting") or before.get("meeting_id") or ""
    return f"{meeting}, {day(before.get('date', ''))}" if before.get("date") else str(meeting)


def status_for(event: dict[str, Any], captions: bool = False) -> dict[str, Any] | None:
    """One agent event -> one status for the notch (fields of the local status API), or None."""
    kind = event.get("type")
    if kind == "contradiction":
        before = event.get("before") or {}
        return {
            "title": short(event.get("note") or f"Widerspruch zu {source(before)}", 70),
            "detail": short(f"{source(before)}: „{before.get('quote', '')}“", 110),
            "icon": "exclamationmark.triangle.fill", "tint": "critical", "seconds": 10,
            "key": f"contradiction.{before.get('meeting_id', '')}",
        }
    if kind == "question":
        return {"title": short(event.get("text", ""), 70), "detail": short(event.get("reason", ""), 110),
                "icon": "questionmark.bubble.fill", "tint": "waiting", "seconds": 9, "key": "question"}
    if kind == "commitment":
        who = event.get("who") or "Zusage"
        due = f"bis {day(event['due'])}" if event.get("due") else "ohne Datum"
        return {"title": short(f"{who}: {event.get('what', '')}", 70), "detail": short(f"Zusage, {due}", 110),
                "icon": "checkmark.circle.fill", "tint": "ok", "seconds": 7,
                "key": f"commitment.{who}.{event.get('what', '')}"[:60]}
    if kind == "prep":
        open_items = event.get("open_commitments") or []
        overdue = [c for c in open_items if c.get("overdue")]
        first = (overdue or open_items or [None])[0]
        noted = event.get("captures") or []
        if first:
            detail = f"{first.get('who')}: {first.get('what')}" + (f", seit {day(first['due'])} fällig" if first.get("overdue") else "")
        elif noted:
            detail = f"Notiert: {noted[0].get('text', '')}"
        else:
            detail = f"{len(event.get('decisions') or [])} frühere Entscheidungen"
        return {"title": short(f"Vorbereitung: {len(open_items)} offene Zusagen", 70), "detail": short(detail, 110),
                "icon": "list.bullet.clipboard.fill", "tint": "accent", "seconds": 10, "key": "prep"}
    if kind == "answer":
        sources = event.get("sources") or []
        return {"title": short(event.get("text", ""), 70),
                "detail": short(f"Quelle: {source(sources[0])}" if sources else "Keine Quelle im Gedächtnis", 110),
                "icon": "text.bubble.fill", "tint": "accent", "seconds": 10, "key": "answer"}
    if kind == "ready":
        model = "mit Claude" if event.get("model") else "ohne Claude"
        return {"title": "Meeting-Agent bereit", "detail": f"{event.get('meetings', 0)} Meetings im Gedächtnis, {model}",
                "icon": "sparkles", "tint": "neutral", "seconds": 4, "key": "agent.status"}
    if kind == "status" and event.get("state") == "offline":
        return {"title": "Meeting-Agent ohne Claude", "detail": "arbeitet mit einfachen Regeln weiter",
                "icon": "bolt.horizontal.circle", "tint": "neutral", "seconds": 4, "key": "agent.status"}
    if kind == "utterance" and captions and event.get("text"):
        speaker = f"{event['speaker']}: " if event.get("speaker") else ""
        return {"title": short(speaker + event["text"], 70), "icon": "waveform", "tint": "neutral",
                "seconds": 4, "key": "caption"}
    return None


class Notch:
    """Posts statuses to the running app: HTTP if the local API answers, else the URL scheme."""

    def __init__(self, port: int = PORT, token: str | None = None, opener: Callable[[str], None] | None = None,
                 scheme: str = "starnotch"):
        self.url = f"http://127.0.0.1:{port}/status"
        self.token = token if token is not None else self._token()
        self.opener = opener or self._open
        self.scheme = scheme
        self.http_ok = bool(self.token)

    @staticmethod
    def _token() -> str:
        if os.environ.get("STARNOTCH_API_TOKEN"):
            return os.environ["STARNOTCH_API_TOKEN"]
        try:
            return (SUPPORT / "api-token").read_text().strip()
        except OSError:
            return ""

    @staticmethod
    def _open(link: str) -> None:
        # -g: don't bring the app forward. STARNOTCH_APP picks one copy when several are installed.
        app = os.environ.get("STARNOTCH_APP")
        subprocess.run(["open", "-g", *(["-a", app] if app else []), link], check=False, capture_output=True)

    def post(self, status: dict[str, Any]) -> str:
        """'http' or 'link', whichever delivered it."""
        if self.http_ok:
            request = urllib.request.Request(self.url, data=json.dumps(status).encode(), method="POST",
                                             headers={"Authorization": f"Bearer {self.token}",
                                                      "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(request, timeout=2):
                    return "http"
            except (urllib.error.URLError, OSError):
                self.http_ok = False  # API switched off or app not running: use the link from now on
        fields = {k: str(v) for k, v in status.items()}
        self.opener(f"{self.scheme}://status?{urllib.parse.urlencode(fields, quote_via=urllib.parse.quote)}")
        return "link"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="agent.py events -> Starnotch notch")
    parser.add_argument("--captions", action="store_true", help="show utterances as a live caption too")
    parser.add_argument("--port", type=int, default=int(os.environ.get("STARNOTCH_API_PORT", PORT)))
    parser.add_argument("--no-feed", action="store_true", help="no full-text page or Meeting-Agent.md")
    args = parser.parse_args(argv)
    notch = Notch(args.port)
    feed = None if args.no_feed else Feed(SUPPORT / "Meeting-Agent.md")
    for line in sys.stdin:
        sys.stdout.write(line)
        sys.stdout.flush()
        try:
            event = json.loads(line)
        except ValueError:
            continue
        status = status_for(event, args.captions) if isinstance(event, dict) else None
        if status:
            if feed and event.get("type") in TITLES:
                status["url"] = feed.add(event)  # a click on the card opens the whole text
            notch.post(status)
    return 0


if __name__ == "__main__":
    sys.exit(main())
