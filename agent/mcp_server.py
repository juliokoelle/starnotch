"""Starnotch as an MCP server: any agent can reach you in the notch.

    claude mcp add starnotch -- uv run --directory "$HOME/Library/Application Support/Starnotch/agent" python mcp_server.py

One install makes every MCP client a Starnotch client (Claude Code, Codex, Cursor, Gemini CLI,
VS Code, Claude Desktop). Two tools:

- notify: one line in the notch ("Deploy done", "Tests failed"), clickable with a link.
- confirm: a yes/no question as a card in the notch; returns "yes", "no" or "no answer".

Questions go through the app's approvals socket (the same one the Claude Code plugin uses), so they
queue with permission requests and never answer themselves: only a click says yes. Notifications
use the local status API when it is on, else the starnotch:// link (notch_bridge.Notch).
"""

from __future__ import annotations

import asyncio
import json
import os
import socket
import stat
import uuid
from pathlib import Path
from typing import Any

from mcp.server.mcpserver import Context, MCPServer

from notch_bridge import SUPPORT, Notch

TINTS = ("accent", "ok", "waiting", "critical", "neutral")
WAIT = 70.0  # the app gives up after 60 s; a little longer here so its "no answer" arrives


def socket_path() -> Path | None:
    """The app's approvals socket, if it is safe to talk to: our own folder (0700) and socket."""
    raw = os.environ.get("STARNOTCH_SOCKET")
    candidates = [Path(raw)] if raw else [SUPPORT / "approvals.sock", SUPPORT.parent / "NotchSwitcher" / "approvals.sock"]
    for path in candidates:
        try:
            folder, sock = path.parent.stat(), path.stat()
        except OSError:
            continue
        if (stat.S_ISSOCK(sock.st_mode) and sock.st_uid == os.getuid() and folder.st_uid == os.getuid()
                and stat.S_IMODE(folder.st_mode) == 0o700):
            return path
    return None


def request_for(question: str, details: str, client: str, cwd: str | None) -> dict[str, Any]:
    """The question as the PermissionRequest the app's approvals socket expects."""
    text = question.strip() + (f"\n\n{details.strip()}" if details.strip() else "")
    return {
        "hook_event_name": "PermissionRequest",
        "starnotch_provider": "mcp",
        "session_id": f"mcp-{uuid.uuid4().hex[:12]}",
        "cwd": cwd,
        "tool_name": client,
        "tool_input": {"description": text},
    }


def answer_from(reply: bytes) -> str:
    """'yes', 'no' or 'no answer' from the socket's reply (empty when unanswered)."""
    try:
        behavior = json.loads(reply)["hookSpecificOutput"]["decision"]["behavior"]
    except (ValueError, KeyError, TypeError):
        return "no answer"
    return {"allow": "yes", "deny": "no"}.get(behavior, "no answer")


def ask_socket(path: Path, request: dict[str, Any], wait: float = WAIT) -> bytes:
    """Sends one request and reads the reply. Our side stays open while waiting: closing it tells
    the app the question was withdrawn."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(wait)
        conn.connect(str(path))
        conn.sendall(json.dumps(request).encode() + b"\n")
        reply = b""
        try:
            while chunk := conn.recv(65536):
                reply += chunk
        except TimeoutError:
            pass
        return reply


def client_name(ctx: Context | None) -> str:
    """The asking app's name from the MCP handshake ("claude-code", "cursor"), made readable."""
    info = None
    try:
        info = ctx.session.client_params.client_info  # type: ignore[union-attr]
    except AttributeError:
        try:
            info = ctx.session.client_params.clientInfo  # type: ignore[union-attr]
        except AttributeError:
            info = None
    name = getattr(info, "title", None) or getattr(info, "name", None) or "An agent"
    pretty = {"claude-code": "Claude Code", "codex-mcp-client": "Codex", "cursor-vscode": "Cursor",
              "gemini-cli-mcp-client": "Gemini CLI", "visual-studio-code": "VS Code", "claude-ai": "Claude"}
    return pretty.get(name, name)


def build(notch: Notch | None = None, sock: Path | None | bool = None) -> MCPServer:
    """The server; `notch` and `sock` are seams for tests (`sock=False`: no app running)."""
    server = MCPServer(
        "starnotch",
        instructions=("Reach the user in their MacBook notch. Use notify for short updates they should see "
                      "without being interrupted (a long task finished, a deploy failed). Use confirm when you "
                      "need a yes or no before a consequential step; it waits up to a minute for their click."),
    )
    poster = notch

    @server.tool()
    def notify(title: str, detail: str = "", tint: str = "accent", url: str = "") -> str:
        """Show one short line in the user's notch. title: up to 80 characters. detail: a second line.
        tint: accent, ok, waiting, critical or neutral. url: an http(s) link the line opens when clicked."""
        nonlocal poster
        poster = poster or Notch()
        status: dict[str, Any] = {"title": title.strip()[:80] or "Update", "tint": tint if tint in TINTS else "accent",
                                  "seconds": 6, "icon": "sparkles"}
        if detail.strip():
            status["detail"] = detail.strip()[:200]
        if url.startswith(("http://", "https://")):
            status["url"] = url
        return f"shown in the notch ({poster.post(status)})"

    @server.tool()
    async def confirm(question: str, ctx: Context, details: str = "") -> str:
        """Ask the user a yes/no question in their notch and wait for the click (up to a minute).
        Returns "yes", "no", or "no answer" (treat that as no). Keep the question to one line;
        put context in details."""
        path = socket_path() if sock is None else (sock or None)
        if path is None:
            return "no answer (Starnotch isn't running)"
        request = request_for(question, details, client_name(ctx), os.getcwd())
        try:
            reply = await asyncio.to_thread(ask_socket, path, request)
        except OSError as error:
            return f"no answer (Starnotch: {error.strerror or error})"
        return answer_from(reply)

    return server


if __name__ == "__main__":
    build().run()
