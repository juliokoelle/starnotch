"""Placeholder: this repository has no wiki of people and projects; the functions return nothing."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from memory import DEFAULT_DIR

WIKI_DIR = DEFAULT_DIR / "wiki"


def age(folder: Path) -> float | None:
    return None


def build(*args: Any, **kwargs: Any) -> list[dict[str, Any]]:
    return []


def load(folder: Path) -> list[dict[str, Any]]:
    return []


def lookup(pages: list[dict[str, Any]], question: str) -> list[dict[str, Any]]:
    return []


def without_screen(pages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return pages


def as_context(pages: list[dict[str, Any]]) -> str:
    return ""


def profile(*args: Any, **kwargs: Any) -> int:
    return 0
