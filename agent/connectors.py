"""Snapshots other tools leave for Tara: one JSON file per source in `connectors/` next to the memory.

Any tool may write `<support>/connectors/<name>.json` (a vault, a task list, a CRM). The agent reads no schema of its
own: every object in the file that has a `title`, `name` or `text` becomes an item, with the body text it carries
(`text`, `content`, `body`, `summary`, `notes`), a date (`date`, `due`, `updated`) and where it lives (`url`, `link`,
or a `path` on disk). The key it sits under (`tasks`, `today`) is its group. A file may name itself with a top-level
`name` or `title`; otherwise the file name is used. Files that are missing, unreadable or not JSON are skipped, so
the agent never depends on a connector being there.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable
from urllib.parse import quote

from memory import DEFAULT_DIR

FOLDER = DEFAULT_DIR.parent / "connectors"
TITLE_KEYS = ("title", "name", "text")
BODY_KEYS = ("text", "content", "body", "summary", "notes", "description")
DATE_KEYS = ("date", "due", "updated", "modified", "created")
MAX_ITEMS = 80  # per file
MAX_BODY = 1_500  # characters of one item's body in the prompt
MAX_CHARS = 24_000  # all connectors together in the prompt


@dataclass
class Item:
    id: str  # "<source>:<n>", what the model cites
    source: str  # the file's name, e.g. "vault"
    group: str  # the key it sat under, e.g. "tasks"
    title: str
    body: str = ""
    date: str = ""
    url: str = ""


def read(folder: Path | None = FOLDER, allow: Callable[[str], bool] | None = None) -> list[Item]:
    """Every item of every snapshot in the folder, file by file in name order. `allow` gets each file's stem
    ("vault", "calendar") and leaves out the files it refuses (the privacy switches)."""
    if not folder or not folder.is_dir():
        return []
    items: list[Item] = []
    for path in sorted(folder.glob("*.json")):
        if allow is not None and not allow(path.stem):
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        source = path.stem
        if isinstance(data, dict) and isinstance(data.get("name"), str) and data["name"].strip():
            source = data["name"].strip()
        found: list[Item] = []
        _walk(data, source, "", found, top=True)
        for n, item in enumerate(found[:MAX_ITEMS]):
            item.id = f"{path.stem}:{n}"
            items.append(item)
    return items


def _walk(value: Any, source: str, group: str, out: list[Item], top: bool = False) -> None:
    if len(out) >= MAX_ITEMS:
        return
    if isinstance(value, list):
        for child in value:
            _walk(child, source, group, out)
        return
    if not isinstance(value, dict):
        return
    title = _first(value, TITLE_KEYS)
    if title and not top:
        body = "\n".join(_text(value[k]) for k in BODY_KEYS if k in value and _text(value[k]) != title)
        out.append(Item(id="", source=source, group=group, title=_one_line(title)[:160], body=body.strip()[:MAX_BODY],
                        date=str(_first(value, DATE_KEYS) or "")[:16], url=_where(value)))
    for key, child in value.items():
        if isinstance(child, (dict, list)):
            _walk(child, source, key if top or not group else group, out)


def _first(value: dict[str, Any], keys: tuple[str, ...]) -> str:
    for key in keys:
        text = value.get(key)
        if isinstance(text, (str, int, float)) and str(text).strip():
            return str(text).strip()
    return ""


def _text(value: Any) -> str:
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, list):
        return "\n".join(_text(v) for v in value if isinstance(v, str))
    return ""


def _one_line(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def _where(value: dict[str, Any]) -> str:
    for key in ("url", "link", "uri"):
        if isinstance(value.get(key), str) and value[key].strip():
            return value[key].strip()
    path = value.get("path")
    if isinstance(path, str) and path.startswith("/"):
        return "file://" + quote(path)
    return ""


def as_context(items: list[Item], max_chars: int = MAX_CHARS) -> str:
    """Prompt text: per source, one block per item with its id, group, date and body."""
    blocks, used, current = [], 0, None
    for item in items:
        lines = []
        if item.source != current:
            current = item.source
            lines.append(f"## Source: {item.source}")
        head = f"- [{item.id}] {item.group + ': ' if item.group else ''}{item.title}" + (f" ({item.date})" if item.date else "")
        lines.append(head)
        lines += [f"  {line}" for line in item.body.splitlines() if line.strip()]
        block = "\n".join(lines)
        if used + len(block) > max_chars:
            break
        blocks.append(block)
        used += len(block) + 1
    return "\n".join(blocks)


def get(items: list[Item], item_id: str) -> Item | None:
    return next((i for i in items if i.id == item_id), None)
