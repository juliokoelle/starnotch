import json
import socket
import threading

from mcp import Client

import mcp_server


class FakeNotch:
    def __init__(self):
        self.posted = []

    def post(self, status):
        self.posted.append(status)
        return "http"


def fake_app(path, behavior, answer=None):
    """The app's end of the approvals socket: reads one request, answers with `behavior` (None: no answer)."""
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path))
    server.listen(1)
    seen = {}

    def run():
        conn, _ = server.accept()
        data = b""
        while not data.endswith(b"\n"):
            data += conn.recv(4096)
        seen["request"] = json.loads(data)
        if behavior:
            reply = {"hookSpecificOutput": {"decision": {"behavior": behavior}, "hookEventName": "PermissionRequest"}}
            if answer is not None:
                reply["starnotch_answer"] = answer
            conn.sendall(json.dumps(reply).encode())
        conn.close()
        server.close()

    threading.Thread(target=run, daemon=True).start()
    return seen


async def call(server, tool, args):
    async with Client(server) as client:
        result = await client.call_tool(tool, args)
    return result.content[0].text


async def test_confirm_yes(tmp_path):
    path = tmp_path / "approvals.sock"
    seen = fake_app(path, "allow")
    answer = await call(mcp_server.build(sock=path), "confirm", {"question": "Deploy to production?", "details": "3 commits"})
    assert answer == "yes"
    request = seen["request"]
    assert request["hook_event_name"] == "PermissionRequest"
    assert request["starnotch_provider"] == "mcp"
    assert request["tool_input"]["description"] == "Deploy to production?\n\n3 commits"


async def test_confirm_no_and_unanswered(tmp_path):
    path = tmp_path / "a.sock"
    fake_app(path, "deny")
    assert await call(mcp_server.build(sock=path), "confirm", {"question": "Delete it?"}) == "no"
    path = tmp_path / "b.sock"
    fake_app(path, None)
    assert await call(mcp_server.build(sock=path), "confirm", {"question": "Delete it?"}) == "no answer"


async def test_confirm_without_app():
    answer = await call(mcp_server.build(sock=False), "confirm", {"question": "Go?"})
    assert answer.startswith("no answer")


async def test_notify():
    notch = FakeNotch()
    text = await call(mcp_server.build(notch=notch), "notify",
                      {"title": "Build done", "detail": "42 tests", "tint": "ok", "url": "https://example.com"})
    assert text == "shown in the notch (http)"
    assert notch.posted == [{"title": "Build done", "detail": "42 tests", "tint": "ok", "seconds": 6,
                             "icon": "sparkles", "url": "https://example.com"}]


async def test_notify_cleans_input():
    notch = FakeNotch()
    await call(mcp_server.build(notch=notch), "notify", {"title": "x" * 200, "tint": "purple", "url": "file:///etc"})
    status = notch.posted[0]
    assert len(status["title"]) == 80 and status["tint"] == "accent" and "url" not in status


def test_answer_from():
    assert mcp_server.answer_from(b"") == "no answer"
    assert mcp_server.answer_from(b'{"hookSpecificOutput":{"decision":{"behavior":"allow"}}}') == "yes"


def test_socket_path_rejects_open_folder(tmp_path, monkeypatch):
    folder = tmp_path / "Starnotch"
    folder.mkdir(mode=0o755)
    path = folder / "approvals.sock"
    s = socket.socket(socket.AF_UNIX)
    s.bind(str(path))
    monkeypatch.setenv("STARNOTCH_SOCKET", str(path))
    assert mcp_server.socket_path() is None
    folder.chmod(0o700)
    assert mcp_server.socket_path() == path
    s.close()


async def test_ask_with_options(tmp_path):
    path = tmp_path / "ask.sock"
    seen = fake_app(path, "allow", answer="Staging")
    answer = await call(mcp_server.build(sock=path), "ask",
                        {"question": "Where should I deploy?", "options": ["Staging", "Production", " ", "x" * 80, "a", "b"],
                         "free_text": False})
    assert answer == "Staging"
    request = seen["request"]
    assert request["starnotch_options"] == ["Staging", "Production", "x" * 60, "a"]
    assert request["starnotch_free_text"] is False


async def test_ask_skipped_and_free_text_fallback(tmp_path):
    path = tmp_path / "skip.sock"
    seen = fake_app(path, "deny")
    answer = await call(mcp_server.build(sock=path), "ask", {"question": "Name?", "free_text": False})
    assert answer == "no answer"
    assert seen["request"]["starnotch_free_text"] is True  # no options: typing stays possible
