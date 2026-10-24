"""notch_bridge: agent events -> statuses for Starnotch's local API, over HTTP or the URL scheme."""

import json
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

from notch_bridge import Notch, day, short, status_for

CONTRADICTION = {
    "type": "contradiction", "now": "Wir waren doch bei 25 Euro", "speaker": "Max", "t": 24.0,
    "before": {"quote": "Okay, dann entscheiden wir: Das Lumen-Abo kostet 30 Euro im Monat.", "speaker": "Jonas",
               "meeting": "Kickoff Lumen-Abo", "meeting_id": "2026-10-12-kickoff", "date": "2026-10-12"},
    "note": "Beschlossen sind 30 Euro, nicht 25 Euro.",
}


def test_contradiction_status():
    s = status_for(CONTRADICTION)
    assert s["title"] == "Beschlossen sind 30 Euro, nicht 25 Euro."
    assert s["detail"].startswith("Kickoff Lumen-Abo, 12.10.: „Okay, dann")
    assert len(s["detail"]) <= 110 and s["tint"] == "critical" and s["seconds"] == 10


def test_other_events():
    assert status_for({"type": "question", "text": "Max, wie ist der Stand?", "reason": "offen"})["tint"] == "waiting"
    c = status_for({"type": "commitment", "who": "Lisa", "what": "Folien schicken", "due": "2026-10-28"})
    assert (c["title"], c["detail"]) == ("Lisa: Folien schicken", "Zusage, bis 28.10.")
    p = status_for({"type": "prep", "decisions": [{}], "open_commitments": [
        {"who": "Max", "what": "Zahlen schicken", "due": "2026-10-16", "overdue": True}]})
    assert p["title"] == "Vorbereitung: 1 offene Zusagen" and p["detail"] == "Max: Zahlen schicken, seit 16.10. fällig"
    a = status_for({"type": "answer", "text": "30 Euro.", "sources": [CONTRADICTION["before"]]})
    assert a["detail"] == "Quelle: Kickoff Lumen-Abo, 12.10."
    assert status_for({"type": "ready", "meetings": 2, "model": None})["detail"] == "2 Meetings im Gedächtnis, ohne Claude"


def test_captions_only_when_asked():
    u = {"type": "utterance", "speaker": "Max", "text": "Hallo", "t": 1}
    assert status_for(u) is None
    assert status_for(u, captions=True)["title"] == "Max: Hallo"
    assert status_for({"type": "status", "state": "saved"}) is None


def test_helpers():
    assert short("a  b\nc", 10) == "a b c"
    assert short("x" * 20, 10) == "x" * 9 + "…"
    assert day("2026-10-12") == "12.10." and day("") == ""


def test_http_delivery():
    received = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            received.append((self.headers["Authorization"], json.loads(body)))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"ok":true}')

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.handle_request, daemon=True).start()
    notch = Notch(port=server.server_address[1], token="secret", opener=lambda link: None)
    assert notch.post({"title": "Hi"}) == "http"
    server.server_close()
    assert received == [("Bearer secret", {"title": "Hi"})]


def test_falls_back_to_link_and_stays_there():
    links = []
    notch = Notch(port=1, token="secret", opener=links.append)  # nothing listens on port 1
    assert notch.post({"title": "25 € statt 30 €", "seconds": 10}) == "link"
    assert notch.post({"title": "zweite"}) == "link" and notch.http_ok is False
    parsed = urllib.parse.urlparse(links[0])
    assert (parsed.scheme, parsed.netloc) == ("starnotch", "status")
    assert urllib.parse.parse_qs(parsed.query) == {"title": ["25 € statt 30 €"], "seconds": ["10"]}


def test_no_token_uses_link():
    links = []
    assert Notch(token="", opener=links.append).post({"title": "x"}) == "link"


# The full text behind the cards (feed.py)

import urllib.request

from feed import Feed, lines_for


def test_lines_keep_everything():
    lines = dict(lines_for(CONTRADICTION))
    assert lines[""] == "Beschlossen sind 30 Euro, nicht 25 Euro."
    assert lines["Gerade gesagt"] == "„Wir waren doch bei 25 Euro“ (Max)"
    assert lines["Vorher, Kickoff Lumen-Abo, 12.10.2026"].startswith("„Okay, dann entscheiden wir")
    answer = {"type": "answer", "question": "Was hat Max zugesagt?", "text": "Max hat zugesagt, die Zahlen zur Marge " * 5,
              "sources": [CONTRADICTION["before"]]}
    assert dict(lines_for(answer))[""] == answer["text"]  # not cut
    assert lines_for({"type": "ready"}) == []


def test_feed_page_and_markdown(tmp_path):
    feed = Feed(tmp_path / "Meeting-Agent.md", port=0)
    link = feed.add(CONTRADICTION)
    assert link == f"http://127.0.0.1:{feed.port}/#e1"
    feed.add({"type": "commitment", "who": "Lisa", "what": "Folien <b>", "due": "2026-10-28", "quote": "Ich schicke"})
    with urllib.request.urlopen(f"http://127.0.0.1:{feed.port}/", timeout=3) as response:
        page = response.read().decode()
    feed.server.shutdown()
    assert page.index('id="e2"') < page.index('id="e1"')  # newest first
    assert "Folien &lt;b&gt;" in page and "Okay, dann entscheiden wir" in page
    text = (tmp_path / "Meeting-Agent.md").read_text()
    assert text.startswith("# Meeting-Agent") and "Widerspruch" in text and "- **Fällig:** 28.10.2026" in text
