#!/usr/bin/env python3
"""Validate the local runtime needed by the basketball highlight engine."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path


REQUIRED_SCRIPTS = (
    "create_proxy.py",
    "scan_video.py",
    "generate_candidates.py",
    "refine_dynamic_candidates.py",
    "refine_candidates.py",
)
REQUIRED_IMPORTS = ("cv2", "numpy", "ultralytics", "torch")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--python", dest="python_path", default=sys.executable)
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    parser.add_argument("--ffprobe", default=shutil.which("ffprobe"))
    parser.add_argument("--model", type=Path)
    parser.add_argument("--json", action="store_true")
    return parser.parse_args()


def _check_imports(python_path: str) -> tuple[bool, str]:
    command = [
        python_path,
        "-c",
        "import " + ", ".join(REQUIRED_IMPORTS),
    ]
    try:
        subprocess.run(command, check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        return False, str(exc)
    return True, "ok"


def _check_binary(path: str | None) -> tuple[bool, str]:
    if not path:
        return False, "not found"
    try:
        subprocess.run(
            [path, "-version"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        return False, str(exc)
    return True, str(Path(path).resolve())


def main() -> int:
    args = _parse_args()
    root = args.root.expanduser().resolve()
    model_default = root / "models" / "bball_model.pt"
    if not model_default.is_file():
        model_default = root / "third_party" / "basketball-shot-detection" / "bball_model.pt"
    model = (args.model or model_default).resolve()
    checks: dict[str, dict[str, object]] = {}

    engine = root / "engine" / "python" / "basketball_engine"
    checks["engine"] = {"ok": engine.is_dir(), "path": str(engine)}
    checks["src"] = {
        "ok": (root / "src" / "basketball_highlight").is_dir(),
        "path": str(root / "src"),
    }
    schema = root / "docs" / "architecture" / "SQLITE_SCHEMA_V1.sql"
    checks["sqlite_schema"] = {"ok": schema.is_file(), "path": str(schema)}
    missing_scripts = [name for name in REQUIRED_SCRIPTS if not (root / "scripts" / name).is_file()]
    checks["scripts"] = {"ok": not missing_scripts, "missing": missing_scripts}
    checks["model"] = {"ok": model.is_file(), "path": str(model)}

    imports_ok, imports_detail = _check_imports(args.python_path)
    checks["python_imports"] = {
        "ok": imports_ok,
        "python": args.python_path,
        "detail": imports_detail,
    }
    ffmpeg_ok, ffmpeg_detail = _check_binary(args.ffmpeg)
    ffprobe_ok, ffprobe_detail = _check_binary(args.ffprobe)
    checks["ffmpeg"] = {"ok": ffmpeg_ok, "detail": ffmpeg_detail}
    checks["ffprobe"] = {"ok": ffprobe_ok, "detail": ffprobe_detail}

    ok = all(bool(item["ok"]) for item in checks.values())
    result = {"ok": ok, "root": str(root), "checks": checks}
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"runtime: {'OK' if ok else 'FAILED'}")
        for name, item in checks.items():
            print(f"- {name}: {'OK' if item['ok'] else 'FAILED'}")
            if not item["ok"]:
                print(f"  {item}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
