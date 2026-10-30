"""Placeholder: this repository has no full-text index of the notes vault; the vault is read through its connector
snapshot. The functions return nothing."""

from __future__ import annotations

from typing import Any

from memory import DEFAULT_DIR

INDEX_FILE = DEFAULT_DIR / "vault-index.sqlite"


class VaultIndex:
    """Not in this build; nothing makes one."""

    file = INDEX_FILE


def from_config(*args: Any, **kwargs: Any) -> VaultIndex | None:
    return None


def own(*args: Any, **kwargs: Any) -> VaultIndex | None:
    return None


def as_items(hits: list[Any]) -> list[Any]:
    return []
