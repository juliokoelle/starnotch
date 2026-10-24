"""transcribe.py: reading Reson8-style messages, audio handling, and a full stream against a fake server."""

import asyncio
import json
import wave

from websockets.asyncio.server import serve

import transcribe
from transcribe import Speakers, downmix, endpoint, file_chunks, load_pcm, utterances


def test_final_text_message():
    out = utterances({"type": "final", "text": " Wir waren doch  bei 25 Euro ", "speaker": 0, "start": 24.04}, Speakers())
    assert out == [{"type": "utterance", "speaker": "Sprecher 1", "text": "Wir waren doch bei 25 Euro", "t": 24.04}]


def test_partials_are_skipped():
    s = Speakers()
    assert utterances({"type": "partial", "text": "Wir wa"}, s) == []
    assert utterances({"is_final": False, "text": "Wir wa"}, s) == []
    assert utterances({"type": "ready"}, s) == []


def test_words_split_by_speaker_with_names():
    message = {"is_final": True, "words": [
        {"word": "Hallo", "speaker": "spk_a", "start": 1.0},
        {"word": "zusammen.", "speaker": "spk_a", "start": 1.4},
        {"word": "Hi!", "speaker": "spk_b", "start": 2.2},
    ]}
    out = utterances(message, Speakers(["Jonas", "Lisa"]))
    assert [(u["speaker"], u["text"], u["t"]) for u in out] == [("Jonas", "Hallo zusammen.", 1.0), ("Lisa", "Hi!", 2.2)]


def test_alternatives_and_wrappers():
    out = utterances({"type": "transcript", "data": {"alternatives": [{"transcript": "Okay", "words": [{"start": 3}]}]}},
                     Speakers())
    assert out == [{"type": "utterance", "speaker": "", "text": "Okay", "t": 3.0}]


def test_time_unknown_is_none():
    assert utterances({"type": "final", "text": "x"}, Speakers())[0]["t"] is None


def test_speakers_stable():
    s = Speakers(["Max"])
    assert [s(1), s(2), s(1), s(None)] == ["Max", "Sprecher 3", "Max", ""]


def test_endpoint_query():
    assert endpoint("wss://x/rt", 16000) == "wss://x/rt?encoding=pcm_s16le&sample_rate=16000&channels=1"
    assert endpoint("wss://x/rt?a=1", 8000, "language=de").endswith("&channels=1&language=de")


def test_load_wav_and_downmix(tmp_path):
    path = tmp_path / "s.wav"
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2), w.setsampwidth(2), w.setframerate(8000)
        w.writeframes(b"\x02\x00\x04\x00" * 10)  # left 2, right 4
    pcm, rate = load_pcm(path)
    assert rate == 8000 and pcm == b"\x03\x00" * 10
    assert downmix(b"\x01\x00", 1) == b"\x01\x00"


async def test_file_chunks_are_paced():
    pcm = b"\x00\x00" * 1600 * 3  # 0.3 s at 16 kHz
    loop = asyncio.get_running_loop()
    start = loop.time()
    chunks = [c async for c in file_chunks(pcm, 16000, speed=2.0)]
    assert [len(c) for c in chunks] == [3200, 3200, 3200]
    assert loop.time() - start >= 0.09  # 3 chunks at 2x: ~0.1 s


async def test_stream_against_fake_reson8():
    seen = {}

    async def fake(ws):
        seen["path"] = ws.request.path
        seen["auth"] = ws.request.headers.get("Authorization")
        audio = 0
        async for message in ws:
            if isinstance(message, bytes):
                audio += len(message)
                if audio == 6400:
                    await ws.send(json.dumps({"type": "partial", "text": "Wir wa"}))
                    await ws.send(json.dumps({"type": "final", "text": "Wir waren doch bei 25 Euro.", "speaker": 1, "start": 0.1}))
                    await ws.send(json.dumps({"type": "final", "text": "Ohne Zeit."}))
            else:
                seen["end"] = json.loads(message)
                await ws.send(json.dumps({"type": "error", "message": "nur ein Test"}))
                await ws.send(json.dumps({"type": "done"}))

    async with serve(fake, "127.0.0.1", 0) as server:
        port = server.sockets[0].getsockname()[1]
        lines, raw = [], []
        count = await transcribe.stream(file_chunks(b"\x00\x00" * 4800, 16000, speed=10), 16000, "test-key",
                                        url=f"ws://127.0.0.1:{port}/rt", names=["Max"], out=lines.append, linger=2,
                                        raw_log=raw.append)
    assert count == 2
    assert len(raw) == 5
    assert 0.2 <= lines[2].pop("t") <= 0.3  # no time from the server: the audio sent so far
    assert seen["auth"] == "Bearer test-key"
    assert seen["path"] == "/rt?encoding=pcm_s16le&sample_rate=16000&channels=1"
    assert seen["end"] == {"type": "finalize"}
    assert lines == [
        {"type": "status", "state": "connected", "sample_rate": 16000},
        {"type": "utterance", "speaker": "Max", "text": "Wir waren doch bei 25 Euro.", "t": 0.1},
        {"type": "utterance", "speaker": "", "text": "Ohne Zeit."},
        {"type": "error", "message": "reson8: nur ein Test"},
        {"type": "status", "state": "done", "utterances": 2},
    ]


async def test_stream_ends_although_server_keeps_talking():
    async def chatty(ws):
        async def keepalive():
            while True:
                await ws.send(json.dumps({"type": "keepalive"}))
                await asyncio.sleep(0.05)

        task = asyncio.create_task(keepalive())
        try:
            async for _ in ws:
                pass
        finally:
            task.cancel()

    async with serve(chatty, "127.0.0.1", 0) as server:
        port = server.sockets[0].getsockname()[1]
        lines = []
        await asyncio.wait_for(transcribe.stream(file_chunks(b"\x00\x00" * 1600, 16000, speed=10), 16000, "k",
                                                 url=f"ws://127.0.0.1:{port}/rt", out=lines.append, linger=0.5), 5)
    assert lines[-1] == {"type": "status", "state": "done", "utterances": 0}


def test_cli_without_key(monkeypatch, capsys, tmp_path):
    monkeypatch.delenv("RESON8_API_KEY", raising=False)
    assert transcribe.main(["--file", str(tmp_path / "x.wav")]) == 2
    assert json.loads(capsys.readouterr().out)["type"] == "error"
