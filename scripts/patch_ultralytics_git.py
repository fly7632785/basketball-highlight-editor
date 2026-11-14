#!/usr/bin/env python3
"""Make Ultralytics' optional Git metadata lookup tolerate sandbox denial."""

from __future__ import annotations

import os
import sys
from pathlib import Path


_ORIGINAL = '''        if g.is_file():
            t = g.read_text(errors="ignore").strip()
'''
_PATCHED = '''        if g.is_file():
            try:
                t = g.read_text(errors="ignore").strip()
            except OSError:
                # Git metadata is optional; sandbox denial must not block model loading.
                return None
'''


def patch_git_module(path: Path) -> bool:
    """Patch one installed ultralytics/utils/git.py; return whether it changed."""
    source = path.read_text(encoding="utf-8")
    if _PATCHED in source:
        return False
    if _ORIGINAL not in source:
        raise RuntimeError(f"unsupported Ultralytics GitRepo source: {path}")
    temporary = path.with_name(f"{path.name}.tmp")
    temporary.write_text(source.replace(_ORIGINAL, _PATCHED, 1), encoding="utf-8")
    os.replace(temporary, path)
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <python-runtime>", file=sys.stderr)
        return 2
    runtime = Path(sys.argv[1])
    matches = list(runtime.glob("lib/python*/site-packages/ultralytics/utils/git.py"))
    if len(matches) != 1:
        print(f"expected one Ultralytics GitRepo module under {runtime}, found {len(matches)}", file=sys.stderr)
        return 1
    changed = patch_git_module(matches[0])
    print(f"Ultralytics sandbox Git metadata fallback: {'patched' if changed else 'already patched'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
