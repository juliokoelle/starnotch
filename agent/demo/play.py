"""Plays the third demo meeting as utterance lines, like transcribe.py would print them.

    uv run python demo/play.py | uv run python agent.py --memory demo/meetings --today 2026-10-26
    uv run python demo/play.py --commands --speed 3   # with a prep card first and a question at the end
"""

from __future__ import annotations

import argparse
import json
import sys
import time

PARTICIPANTS = ["Max", "Lisa", "Jonas"]

# Monday 2026-10-26, one week after the weekly. Max misremembers the price.
TALK = [
    ("Jonas", 2.0, "Hallo zusammen, kurzer Check vor dem Launch-Workshop am Donnerstag."),
    ("Lisa", 9.0, "Die Landingpage ist seit Freitag live, das lief gut."),
    ("Max", 17.0, "Danke. Ich rechne gerade die Marge für die Präsentation."),
    ("Max", 24.0, "Wir waren doch bei 25 Euro im Monat, oder? Damit sieht die Marge ziemlich knapp aus."),
    ("Jonas", 33.0, "Hm, lass uns das kurz klären."),
    ("Lisa", 40.0, "Ich schicke euch bis Mittwoch die Folien für den Workshop."),
    ("Jonas", 48.0, "Gut. Dann sehen wir uns Donnerstag im Raum Ahorn."),
]


def line(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--speed", type=float, default=1.0, help="faster than real time, e.g. 4")
    parser.add_argument("--commands", action="store_true", help="send a prep command first and an ask command last")
    parser.add_argument("--linger", type=float, default=20.0, help="seconds to keep stdin open at the end")
    args = parser.parse_args()

    if args.commands:
        line({"cmd": "prep", "participants": PARTICIPANTS, "id": "prep-1"})
    start = time.monotonic()
    for speaker, t, text in TALK:
        wait = t / args.speed - (time.monotonic() - start)
        if wait > 0:
            time.sleep(wait)
        line({"type": "utterance", "speaker": speaker, "text": text, "t": t})
    if args.commands:
        line({"cmd": "ask", "question": "Welchen Preis haben wir für das Lumen-Abo beschlossen?", "id": "ask-1"})
    # The agent reads until stdin closes; give it time to answer the last lines.
    time.sleep(args.linger / max(args.speed, 1.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
