"""macOS only: speaks the third demo meeting with `say` into demo/live.wav (16 kHz mono) for transcribe.py.

    uv run python demo/make_audio.py
    uv run python transcribe.py --file demo/live.wav --names Jonas,Lisa,Max | uv run python agent.py --memory demo/meetings --today 2026-10-26

Voices are German system voices; change VOICES if one is missing (`say -v '?' | grep de_`).
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from play import TALK  # noqa: E402

VOICES = {"Jonas": "Markus", "Lisa": "Anna", "Max": "Yannick"}
RATE = 16_000
OUT = Path(__file__).resolve().parent / "live.wav"


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp, wave.open(str(OUT), "wb") as out:
        out.setnchannels(1), out.setsampwidth(2), out.setframerate(RATE)
        written = 0.0
        for index, (speaker, t, text) in enumerate(TALK):
            aiff, wav = Path(tmp) / f"{index}.aiff", Path(tmp) / f"{index}.wav"
            subprocess.run(["say", "-v", VOICES.get(speaker, "Anna"), "-o", str(aiff), text], check=True)
            subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", str(aiff), str(wav)], check=True)
            silence = max(0.4, t - written)  # keep the script's timing, at least a short pause
            out.writeframes(b"\x00\x00" * int(silence * RATE))
            with wave.open(str(wav), "rb") as line:
                frames = line.readframes(line.getnframes())
            out.writeframes(frames)
            written += silence + len(frames) / 2 / RATE
    print(f"wrote {OUT} ({written:.0f} s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
