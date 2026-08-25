"""Resolve media tools from the bundled runtime before using the host PATH."""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path


_MEDIA_TOOLS = {"ffmpeg", "ffprobe"}


def _runtime_roots() -> list[Path]:
    roots: list[Path] = []
    configured = os.environ.get("BHE_RUNTIME_ROOT")
    if configured:
        roots.append(Path(configured).expanduser())

    # Packaged layout: <runtime>/engine/python/basketball_engine/*.py.
    module_path = Path(__file__).resolve()
    if len(module_path.parents) > 3:
        roots.append(module_path.parents[3])

    # Fallback for layouts where the module is loaded from a copied location.
    executable = Path(sys.executable).resolve()
    if len(executable.parents) > 2 and executable.parent.name == "bin":
        roots.append(executable.parents[2])
    return roots


def resolve_media_tool(name: str) -> str:
    """Return the bundled executable path, falling back to the host PATH."""
    if name not in _MEDIA_TOOLS:
        raise ValueError(f"unsupported media tool: {name}")
    seen: set[Path] = set()
    for root in _runtime_roots():
        candidate = (root / "bin" / name).resolve()
        if candidate in seen:
            continue
        seen.add(candidate)
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return shutil.which(name) or name
