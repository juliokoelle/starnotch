import shutil
from pathlib import Path

import pytest

DEMO = Path(__file__).resolve().parent.parent / "demo" / "meetings"


@pytest.fixture
def memory_dir(tmp_path: Path) -> Path:
    """A copy of the demo meetings in a temp folder."""
    target = tmp_path / "memory"
    shutil.copytree(DEMO, target)
    return target
