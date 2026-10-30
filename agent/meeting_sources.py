"""Where meetings come from: the meeting module's own recordings and Jamie. Every meeting is saved as it comes."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import privacy

OWN = "starnotch"  # the meeting module's recordings


def enabled(file: Path | None = None) -> list[str]:
    """The sources that feed the memory here: the recordings and Jamie."""
    return [OWN, "jamie"]


def why_not(source: str, file: Path | None = None) -> tuple[str, str]:
    """(state, message) when `source` may not bring meetings in now, ("", "") when it may."""
    refused = privacy.load().why_not("meetings")
    return ("paused", refused) if refused else ("", "")


def place(memory: Any, meeting: Any) -> tuple[Path | None, Any]:
    """Writes `meeting` into the memory: (path, None)."""
    return memory.save(meeting), None
