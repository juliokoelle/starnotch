import json
import shutil
import sys
from pathlib import Path

import pytest

import claude

DEMO = Path(__file__).resolve().parent.parent / "demo" / "meetings"

# Plays the app's Apple Intelligence helper (Sources/AppleModel): `--status`, and one JSON request on stdin.
# FAKE_APPLE picks the act, FAKE_APPLE_ANSWER is the result it gives, FAKE_APPLE_LOG gets every request.
FAKE_APPLE = f"""#!{sys.executable}
import json, os, sys, time
mode = os.environ.get("FAKE_APPLE", "ok")
if sys.argv[1:] == ["--status"]:
    reasons = {{"notEnabled": "appleIntelligenceNotEnabled", "downloading": "modelNotReady",
               "unsupported": "deviceNotEligible"}}
    status = {{"available": False, "reason": reasons[mode], "message": mode}} if mode in reasons else {{"available": True}}
    print(json.dumps(status))
    sys.exit(0)
request = json.loads(sys.stdin.read())
with open(os.environ["FAKE_APPLE_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps(request) + "\\n")
if mode == "slow":
    time.sleep(5)
if mode == "rateLimitedOnce" and len(open(os.environ["FAKE_APPLE_LOG"], encoding="utf-8").readlines()) == 1:
    mode = "rateLimited"
if mode in ("rateLimited", "contextWindowExceeded", "guardrail", "unsupportedLanguage", "other"):
    print(json.dumps({{"error": {{"kind": mode, "message": mode + " happened"}}}}))
    sys.exit(1)
if mode == "unavailable":
    print(json.dumps({{"error": {{"kind": "unavailable", "reason": "modelNotReady", "message": "still downloading"}}}}))
    sys.exit(1)
if mode == "crash":
    print("boom", file=sys.stderr)
    sys.exit(2)
answer = os.environ.get("FAKE_APPLE_ANSWER")
print(json.dumps({{"result": json.loads(answer) if answer else {{"answer": "30 Euro.", "sources": []}}}}))
"""


@pytest.fixture(autouse=True)
def no_real_apple_helper(monkeypatch):
    """Tests never find the helper a local `swift build` left in .build, nor one the environment names."""
    monkeypatch.setattr(claude, "APPLE_HELPERS", ())
    monkeypatch.delenv("STARNOTCH_APPLE_HELPER", raising=False)


@pytest.fixture
def apple(tmp_path, monkeypatch):
    """A fake helper as STARNOTCH_APPLE_HELPER; returns a reader for the requests it got."""
    binary = tmp_path / "AppleModel"
    binary.write_text(FAKE_APPLE, encoding="utf-8")
    binary.chmod(0o755)
    log = tmp_path / "apple.jsonl"
    monkeypatch.setenv("STARNOTCH_APPLE_HELPER", str(binary))
    monkeypatch.setenv("FAKE_APPLE_LOG", str(log))
    monkeypatch.delenv("FAKE_APPLE", raising=False)
    monkeypatch.delenv("FAKE_APPLE_ANSWER", raising=False)

    def requests():
        return [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()] if log.exists() else []

    requests.binary = str(binary)
    return requests


@pytest.fixture
def memory_dir(tmp_path: Path) -> Path:
    """A copy of the demo meetings in a temp folder."""
    target = tmp_path / "memory"
    shutil.copytree(DEMO, target)
    return target
