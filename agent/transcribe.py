"""Live transcription with Reson8 Realtime over a WebSocket; prints one JSON line per finished utterance.

    uv run python transcribe.py --file meeting.wav            # demo: streams the file in real time
    uv run python transcribe.py --mic                         # needs: uv sync --extra mic
    uv run python transcribe.py --file meeting.wav --names Max,Lisa,Jonas | uv run python agent.py

Output: {"type":"utterance","speaker":"Max","text":"...","t":12.3}, plus {"type":"status",...} and
{"type":"error",...} lines that agent.py ignores or passes on.

The key comes from RESON8_API_KEY. The endpoint and its audio parameters can be changed without code:
RESON8_URL (default below), RESON8_QUERY (extra query string, e.g. "language=de&diarize=true"),
RESON8_END (the JSON text sent after the last audio, default {"type":"finalize"}).
Answers are read field by field (text/transcript, speaker, start, is_final/type, words[]),
so a final transcript in any of the usual shapes becomes an utterance.
"""

from __future__ import annotations

import argparse
import array
import asyncio
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path
from typing import Any, AsyncIterator
from urllib.parse import urlencode

RESON8_URL = "wss://api.reson8.dev/v1/speech-to-text/realtime"
RATE = 16_000
CHUNK_SECONDS = 0.1
FINAL_TYPES = {"final", "transcript", "transcript.final", "final_transcript", "utterance", "turn", "end_of_turn",
               "turn.end", "segment"}
PARTIAL_TYPES = {"partial", "interim", "transcript.partial", "partial_transcript", "delta"}


def emit(obj: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


# Audio

def load_pcm(path: Path) -> tuple[bytes, int]:
    """16-bit mono PCM and its sample rate. WAV is read directly; anything else goes through ffmpeg or afconvert."""
    if path.suffix.lower() == ".wav":
        try:
            with wave.open(str(path), "rb") as w:
                if w.getsampwidth() == 2:
                    frames, channels, rate = w.readframes(w.getnframes()), w.getnchannels(), w.getframerate()
                    return downmix(frames, channels), rate
        except wave.Error:
            pass
    return convert(path), RATE


def downmix(frames: bytes, channels: int) -> bytes:
    if channels == 1:
        return frames
    samples = array.array("h", frames)
    mono = array.array("h", (sum(samples[i:i + channels]) // channels for i in range(0, len(samples), channels)))
    return mono.tobytes()


def convert(path: Path) -> bytes:
    if shutil.which("ffmpeg"):
        out = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "s16le", "-ac", "1", "-ar", str(RATE), "-"],
                             capture_output=True, check=True)
        return out.stdout
    if shutil.which("afconvert"):  # always there on macOS
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "audio.wav"
            subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", str(path), str(target)], check=True)
            with wave.open(str(target), "rb") as w:
                return w.readframes(w.getnframes())
    raise RuntimeError(f"can't read {path.name}: use a 16-bit WAV, or install ffmpeg")


async def file_chunks(pcm: bytes, rate: int, speed: float = 1.0) -> AsyncIterator[bytes]:
    """The file in 100 ms pieces, paced like a live microphone (speed 2 = twice as fast)."""
    size = int(rate * CHUNK_SECONDS) * 2
    start = time.monotonic()
    for index, offset in enumerate(range(0, len(pcm), size)):
        due = start + index * CHUNK_SECONDS / speed
        await asyncio.sleep(max(0.0, due - time.monotonic()))
        yield pcm[offset:offset + size]


async def mic_chunks(rate: int = RATE) -> AsyncIterator[bytes]:
    try:
        import sounddevice
    except ImportError as error:
        raise RuntimeError("microphone needs sounddevice: uv sync --extra mic") from error
    loop = asyncio.get_running_loop()
    inbox: asyncio.Queue[bytes] = asyncio.Queue()

    def callback(data, frames, timing, status) -> None:
        loop.call_soon_threadsafe(inbox.put_nowait, bytes(data))

    with sounddevice.RawInputStream(samplerate=rate, channels=1, dtype="int16",
                                    blocksize=int(rate * CHUNK_SECONDS), callback=callback):
        while True:
            yield await inbox.get()


# Reading Reson8's answers

def _first(obj: Any, *keys: str) -> Any:
    if isinstance(obj, dict):
        for key in keys:
            if obj.get(key) not in (None, ""):
                return obj[key]
    return None


def _seconds(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return round(float(value), 2)
    except (TypeError, ValueError):
        return None


class Speakers:
    """Reson8's speaker labels (0, "spk_1", ...) -> names given with --names, in order of first appearance."""

    def __init__(self, names: list[str] | None = None):
        self.names = names or []
        self.seen: dict[str, str] = {}

    def __call__(self, label: Any) -> str:
        if label is None or label == "":
            return ""
        key = str(label)
        if key not in self.seen:
            index = len(self.seen)
            if index < len(self.names):
                self.seen[key] = self.names[index]
            elif isinstance(label, int) or key.isdigit():
                self.seen[key] = f"Sprecher {int(key) + 1}"
            else:
                self.seen[key] = key
        return self.seen[key]


def utterances(message: dict[str, Any], speakers: Speakers, offset: float = 0.0) -> list[dict[str, Any]]:
    """Final utterances in one server message (a message with words from several speakers splits)."""
    for wrapper in ("data", "result", "transcript_event"):
        if isinstance(message.get(wrapper), dict) and not _first(message, "text", "transcript"):
            message = {**message, **message[wrapper]}
    kind = str(message.get("type") or message.get("event") or "").lower()
    final = message.get("is_final", message.get("final", message.get("isFinal")))
    if final is False or kind in PARTIAL_TYPES or (final is None and kind and kind not in FINAL_TYPES):
        return []
    alternatives = message.get("alternatives")
    best = alternatives[0] if isinstance(alternatives, list) and alternatives else {}
    words = message.get("words") or best.get("words") or []
    text = _first(message, "text", "transcript") or _first(best, "transcript", "text") or ""
    start = _seconds(_first(message, "start", "start_time", "startTime", "t", "offset"))

    runs: list[dict[str, Any]] = []
    if words and any(_first(w, "speaker", "speaker_id", "speakerId") is not None for w in words if isinstance(w, dict)):
        for w in words:
            if not isinstance(w, dict):
                continue
            who = speakers(_first(w, "speaker", "speaker_id", "speakerId"))
            word = str(_first(w, "punctuated_word", "word", "text") or "")
            if runs and runs[-1]["speaker"] == who:
                runs[-1]["text"] += " " + word
            else:
                runs.append({"speaker": who, "text": word, "t": _seconds(_first(w, "start", "start_time"))})
        if len(runs) == 1 and text:
            runs[0]["text"] = str(text)
    elif text:
        first_word = words[0] if words and isinstance(words[0], dict) else {}
        runs.append({
            "speaker": speakers(_first(message, "speaker", "speaker_id", "speakerId", "speaker_label", "channel")),
            "text": str(text),
            "t": start if start is not None else _seconds(_first(first_word, "start", "start_time")),
        })
    out = []
    for run in runs:
        clean = " ".join(run["text"].split())
        if clean:
            t = None if run["t"] is None else round(run["t"] + offset, 2)
            out.append({"type": "utterance", "speaker": run["speaker"], "text": clean, "t": t})
    return out


# Streaming

def endpoint(url: str, rate: int, extra: str = "") -> str:
    query = urlencode({"encoding": "pcm_s16le", "sample_rate": rate, "channels": 1})
    joined = f"{url}{'&' if '?' in url else '?'}{query}"
    return f"{joined}&{extra.lstrip('&?')}" if extra else joined


async def stream(chunks: AsyncIterator[bytes], rate: int, key: str, url: str = RESON8_URL,
                 names: list[str] | None = None, extra_query: str = "", end_message: str = '{"type": "finalize"}',
                 linger: float = 5.0, out=emit, raw_log=None) -> int:
    """Sends audio while printing utterances as they come back. Returns how many utterances came.

    raw_log, if given, gets every text message from the server (to see Reson8's real fields)."""
    from websockets.asyncio.client import connect
    from websockets.exceptions import ConnectionClosedOK

    speakers = Speakers(names)
    count = 0
    sent = 0.0  # seconds of audio sent: the time of an utterance when the server sends none
    async with connect(endpoint(url, rate, extra_query), additional_headers={"Authorization": f"Bearer {key}"},
                       max_size=None, open_timeout=15) as ws:
        out({"type": "status", "state": "connected", "sample_rate": rate})

        async def send() -> None:
            nonlocal sent
            async for chunk in chunks:
                await ws.send(chunk)
                sent += len(chunk) / 2 / rate
            if end_message:
                await ws.send(end_message)

        sender = asyncio.create_task(send())
        loop = asyncio.get_running_loop()
        deadline = None  # set once the audio is out: then wait at most `linger` seconds in total
        try:
            while True:
                if sender.done() and deadline is None:
                    deadline = loop.time() + linger
                timeout = None if deadline is None else max(0.0, deadline - loop.time())
                if deadline is None:
                    timeout = 1.0  # wake up now and then to notice the end of the audio
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout)
                except (asyncio.TimeoutError, TimeoutError):
                    if deadline is not None:
                        break  # audio is done; the server had `linger` seconds for the last words
                    continue
                if isinstance(raw, bytes):
                    continue
                if raw_log:
                    raw_log(raw)
                try:
                    message = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if not isinstance(message, dict):
                    continue
                if str(message.get("type", "")).lower() == "error" or message.get("error"):
                    out({"type": "error", "message": f"reson8: {message.get('message') or message.get('error')}"})
                    continue
                for utterance in utterances(message, speakers):
                    if utterance["t"] is None:
                        utterance["t"] = round(sent, 1)
                    out(utterance)
                    count += 1
                if str(message.get("type", "")).lower() in ("done", "closed", "session.closed", "end"):
                    break
        except ConnectionClosedOK:
            pass  # the server closed the session after the last transcript
        finally:
            sender.cancel()
    out({"type": "status", "state": "done", "utterances": count})
    return count


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Reson8 Realtime -> utterance JSON lines on stdout")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--file", type=Path, help="audio file streamed in real time (demo mode)")
    source.add_argument("--mic", action="store_true", help="the default microphone")
    parser.add_argument("--speed", type=float, default=1.0, help="file only: faster than real time")
    parser.add_argument("--tail", type=float, default=2.5, help="file only: seconds of silence sent after the file")
    parser.add_argument("--names", help="names for the speakers in order of appearance, e.g. Max,Lisa,Jonas")
    parser.add_argument("--language", help="adds language=<code> to the connection, e.g. de")
    parser.add_argument("--raw", action="store_true", help="print every message from Reson8 to stderr")
    parser.add_argument("--url", default=os.environ.get("RESON8_URL", RESON8_URL))
    args = parser.parse_args(argv)

    key = os.environ.get("RESON8_API_KEY")
    if not key:
        emit({"type": "error", "message": "RESON8_API_KEY is not set"})
        return 2
    names = [n.strip() for n in args.names.split(",")] if args.names else None
    try:
        if args.file:
            pcm, rate = load_pcm(args.file)
            # Silence after the file: Reson8 closes a sentence on a pause, so the last one comes out too.
            pcm += b"\x00\x00" * int(rate * args.tail)
            chunks = file_chunks(pcm, rate, args.speed)
        else:
            rate, chunks = RATE, mic_chunks()
        extra = "&".join(q for q in (os.environ.get("RESON8_QUERY", ""),
                                     f"language={args.language}" if args.language else "") if q)
        raw_log = (lambda text: print(text, file=sys.stderr, flush=True)) if args.raw else None
        asyncio.run(stream(chunks, rate, key, args.url, names, extra,
                           os.environ.get("RESON8_END", '{"type": "finalize"}'), raw_log=raw_log))
    except KeyboardInterrupt:
        return 0
    except Exception as error:
        emit({"type": "error", "message": f"transcribe: {error}"})
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
