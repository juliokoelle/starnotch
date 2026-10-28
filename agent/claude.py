"""The one place that talks to Claude: a JSON-in, JSON-out call with a schema.

Two backends, chosen by STARNOTCH_BRAIN (see `make_brain`):
- ClaudeCode runs the user's own Claude Code CLI headless, so Tara thinks on their Claude plan.
- Claude calls the Anthropic API; the key comes from the environment (ANTHROPIC_API_KEY or an `ant auth login`
  profile), never from a file here.
"""

from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Protocol

import anthropic

MODEL = os.environ.get("STARNOTCH_MODEL", "claude-sonnet-5-5")
EFFORT = os.environ.get("STARNOTCH_EFFORT", "low")
FALLBACK_BETA = "server-side-fallback-2026-07-01"
TIMEOUT = 30  # live: better a rule now than Claude late

BRAINS = ("auto", "claude-code", "api", "rules")
CODE_MODEL = "sonnet"  # Claude Code's alias for the newest Sonnet
CLAUDE_BINARIES = ("~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude")
BRAIN_FOLDER = Path.home() / "Library" / "Application Support" / "Starnotch" / "brain"
# With any of these set, Claude Code bills an API key or a cloud account instead of the user's plan.
BILLING_ENV = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
               "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY")
PLAN_LOGINS = ("claude.ai", "oauth_token")  # `claude auth status`: a Pro/Max/Team login, or `claude setup-token`
# Claude Code retries an overloaded (529) or throttled (429) API for a minute and more; one retry, as the API backend
# does, fails within seconds, so a live batch falls to the rules instead of waiting out TIMEOUT.
CODE_RETRIES = "1"
SYSTEM_FILES = "starnotch-system-*"  # system prompts handed to claude -p; they carry the meeting memory


IMAGE_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp"}
IMAGE_FILES = "starnotch-image-*"  # screenshots handed to claude -p, next to the system prompts


class JSONModel(Protocol):
    def json(self, system: str, user: str, schema: dict[str, Any], max_tokens: int = 4000,
             images: list[Path] | None = None) -> dict[str, Any] | None: ...


class Claude:
    """Structured-output calls to Claude. Returns None on a refusal or an unreadable answer."""

    def __init__(self, model: str = MODEL, effort: str = EFFORT, client: anthropic.Anthropic | None = None):
        self.model = model
        self.effort = effort
        self.client = client or anthropic.Anthropic(max_retries=1, timeout=TIMEOUT)
        # Server-side fallback re-runs a declined request on another model. Switched off if the API rejects it.
        self.fallbacks = os.environ.get("STARNOTCH_NO_FALLBACK") is None

    def json(self, system: str, user: str, schema: dict[str, Any], max_tokens: int = 4000,
             images: list[Path] | None = None) -> dict[str, Any] | None:
        content: str | list[dict[str, Any]] = user
        if images:  # a screenshot the user asks about, before the question
            content = [{"type": "image", "source": {"type": "base64", "media_type": _media_type(path),
                                                    "data": base64.b64encode(Path(path).read_bytes()).decode()}}
                       for path in images] + [{"type": "text", "text": user}]
        request: dict[str, Any] = dict(
            model=self.model,
            max_tokens=max_tokens,
            system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
            messages=[{"role": "user", "content": content}],
            output_config={"effort": self.effort, "format": {"type": "json_schema", "schema": schema}},
        )
        try:
            response = self._create(request)
        except anthropic.BadRequestError as error:
            if not self.fallbacks or "fallback" not in str(error).lower():
                raise
            print(f"claude: fallbacks rejected, continuing without: {error}", file=sys.stderr)
            self.fallbacks = False
            response = self._create(request)
        if response.stop_reason in ("refusal", "max_tokens"):
            return None
        text = next((b.text for b in response.content if b.type == "text"), "")
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return None
        return data if isinstance(data, dict) else None

    def _create(self, request: dict[str, Any]):
        if self.fallbacks:
            return self.client.beta.messages.create(**request, betas=[FALLBACK_BETA], fallbacks="default")
        return self.client.beta.messages.create(**request)


class ClaudeCodeError(RuntimeError):
    """One Claude Code call failed; the next one may work."""


class ClaudeCodeUnavailable(ClaudeCodeError):
    """Claude Code can't think for Tara on the user's plan: not installed, not signed in, or it would bill an API."""


def find_claude() -> str | None:
    """The claude binary: on PATH, else where its installers put it (an app's PATH often lacks those)."""
    found = shutil.which("claude")
    if found:
        return found
    for candidate in CLAUDE_BINARIES:
        path = Path(candidate).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return None


def plan_env(environ: dict[str, str] | None = None) -> dict[str, str]:
    """The environment for Claude Code without anything that would bill outside the user's plan, retries capped."""
    env = {k: v for k, v in (os.environ if environ is None else environ).items() if k not in BILLING_ENV}
    return {**env, "CLAUDE_CODE_MAX_RETRIES": CODE_RETRIES}


class ClaudeCode:
    """Structured-output calls through the user's Claude Code CLI (`claude -p`), counted against their Claude plan.

    Each call starts a bare session: no tools, no MCP servers, no hooks, plugins, settings or CLAUDE.md, no saved
    transcript, in an empty folder of its own. That keeps the context at our prompt plus about a thousand tokens.
    Returns None on a refusal or an unreadable answer, like Claude.
    """

    def __init__(self, binary: str | None = None, model: str = CODE_MODEL, effort: str = EFFORT,
                 folder: Path | None = None, timeout: float = TIMEOUT):
        self.binary = binary or find_claude()
        if not self.binary:
            raise ClaudeCodeUnavailable("Claude Code isn't installed (no claude binary found)")
        self.model = model
        self.effort = effort
        self.folder = Path(folder or BRAIN_FOLDER)
        self.timeout = timeout
        self.folder.mkdir(parents=True, exist_ok=True)
        self.sweep()
        self.check_login()

    def sweep(self, older_than: float = 300) -> None:
        """Removes prompt and image files a killed agent left behind (a running call's file is minutes younger)."""
        for path in [*self.folder.glob(SYSTEM_FILES), *self.folder.glob(IMAGE_FILES)]:
            try:
                if path.stat().st_mtime < time.time() - older_than:
                    path.unlink()
            except OSError:
                pass

    def check_login(self) -> None:
        """Raises ClaudeCodeUnavailable unless Claude Code is signed in to a Claude plan (no tokens spent)."""
        try:
            proc = subprocess.run([self.binary, "auth", "status", "--json"], capture_output=True, text=True,
                                  encoding="utf-8", timeout=15, cwd=self.folder, env=plan_env(), stdin=subprocess.DEVNULL)
            status = json.loads(proc.stdout)
        except (OSError, subprocess.TimeoutExpired, ValueError) as error:
            raise ClaudeCodeUnavailable(f"Claude Code couldn't confirm a login (claude auth status): {error}") from error
        if not isinstance(status, dict) or not status.get("loggedIn"):
            raise ClaudeCodeUnavailable("Claude Code isn't signed in (run: claude auth login)")
        if status.get("authMethod") not in PLAN_LOGINS or status.get("apiProvider", "firstParty") != "firstParty":
            raise ClaudeCodeUnavailable(f"Claude Code is signed in with {status.get('authMethod')}, not a Claude plan; "
                                        "Starnotch won't bill it")

    def args(self, system_file: str, schema: dict[str, Any], images: list[str] | None = None) -> list[str]:
        # A screenshot is a file in the brain folder (the session's working folder): Read is the one tool, allowed
        # for that file only (headless, any other read outside the folder is denied).
        tools = ["--tools", "Read", "--allowedTools", ",".join(f"Read(./{Path(i).name})" for i in images)] if images \
            else ["--tools", ""]
        return [
            self.binary, "-p",
            "--output-format", "json",
            "--json-schema", json.dumps(schema, ensure_ascii=False),
            "--system-prompt-file", system_file,
            "--model", self.model,
            "--effort", self.effort,
            *tools,
            "--strict-mcp-config", "--mcp-config", '{"mcpServers": {}}',
            "--setting-sources", "",  # no user/project settings: no hooks, plugins, apiKeyHelper or memory
            "--disable-slash-commands",
            "--no-session-persistence",
        ]

    def json(self, system: str, user: str, schema: dict[str, Any], max_tokens: int = 4000,
             images: list[Path] | None = None) -> dict[str, Any] | None:
        # max_tokens has no CLI flag; the answers here are short. The prompt goes in on stdin and the system prompt
        # (it carries the whole meeting memory) through a file, so neither hits the argument length limit. The file
        # lives in the brain folder, not $TMPDIR, so one a killed agent leaves behind is swept on the next start.
        # A screenshot is copied there too: the session may read its own folder and nothing else.
        copies: list[Path] = []
        try:
            for image in images or []:
                fd, name = tempfile.mkstemp(suffix=Path(image).suffix.lower() or ".png", prefix=IMAGE_FILES[:-1],
                                            dir=self.folder)
                with os.fdopen(fd, "wb") as handle:
                    handle.write(Path(image).read_bytes())
                copies.append(Path(name))
            if copies:
                user = "\n".join(f"Screenshot of the window the user asks about: ./{c.name} (read it first)"
                                 for c in copies) + "\n\n" + user
            with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".md", prefix=SYSTEM_FILES[:-1],
                                             dir=self.folder) as file:
                file.write(system)
                file.flush()
                # A screenshot costs a Read turn: twice the time.
                timeout = self.timeout * (2 if copies else 1)
                try:
                    proc = subprocess.run(self.args(file.name, schema, [str(c) for c in copies]), input=user,
                                          capture_output=True, text=True, encoding="utf-8", timeout=timeout,
                                          cwd=self.folder, env=plan_env())
                except subprocess.TimeoutExpired:  # its text lists the whole command line: not for the notch
                    raise ClaudeCodeError(f"Claude Code took longer than {timeout:g} s") from None
        finally:
            for copy in copies:
                copy.unlink(missing_ok=True)
        try:
            result = json.loads(proc.stdout)
        except ValueError:
            detail = (proc.stderr or proc.stdout).strip()[:200]
            raise ClaudeCodeError(f"claude exited {proc.returncode}: {detail}") from None
        if not isinstance(result, dict):
            raise ClaudeCodeError(f"claude exited {proc.returncode}: unexpected output")
        usage = result.get("usage") or {}
        read = sum(usage.get(k) or 0 for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
        print(f"claude-code: {read} tokens in, {usage.get('output_tokens', 0)} out, {result.get('duration_ms')} ms",
              file=sys.stderr)
        if result.get("is_error"):
            message = str(result.get("result") or result.get("subtype") or "error")
            if result.get("api_error_status") in (401, 403) or "log in" in message.lower() or "login" in message.lower():
                raise ClaudeCodeUnavailable(f"Claude Code isn't signed in: {message}")
            raise ClaudeCodeError(f"claude: {message}")
        if result.get("stop_reason") == "refusal":
            return None
        data = result.get("structured_output")
        if data is None:
            try:
                data = json.loads(result.get("result") or "")
            except ValueError:
                return None
        return data if isinstance(data, dict) else None


def _media_type(path: Path | str) -> str:
    return IMAGE_TYPES.get(Path(path).suffix.lower(), "image/png")


def make_brain(choice: str | None = None) -> tuple[str, JSONModel | None, str | None]:
    """(brain, model, why it fell back to rules) from STARNOTCH_BRAIN: auto (default) | claude-code | api | rules.

    auto: Claude Code when a claude binary is found, else the API when ANTHROPIC_API_KEY is set, else rules.
    A Claude Code that can't think on the user's plan falls back to rules, never to the API.
    """
    choice = (choice if choice is not None else os.environ.get("STARNOTCH_BRAIN", "")).strip().lower() or "auto"
    if choice not in BRAINS:
        return "rules", None, f"unknown STARNOTCH_BRAIN {choice!r}, using rules"
    if choice == "claude-code" or (choice == "auto" and find_claude()):
        try:
            return "claude-code", ClaudeCode(), None
        except ClaudeCodeUnavailable as error:
            return "rules", None, f"{error}; using rules"
    if choice == "api" or (choice == "auto" and os.environ.get("ANTHROPIC_API_KEY")):
        try:
            return "api", Claude(), None
        except Exception as error:  # no credentials
            return "rules", None, f"Claude unavailable, using rules: {error}"
    return "rules", None, None
