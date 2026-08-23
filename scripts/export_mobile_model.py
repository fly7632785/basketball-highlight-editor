#!/usr/bin/env python3
"""Export the validated YOLO checkpoint for the mobile runtime.

This intentionally fails with an actionable message when the optional ONNX
export dependency is not installed; it never claims that a mobile model was
created when the export did not happen.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, default=Path("models/bball_model.pt"))
    parser.add_argument("--output", type=Path, default=Path("models/bball_model.onnx"))
    parser.add_argument("--imgsz", type=int, default=640)
    args = parser.parse_args()

    if not args.model.is_file():
        parser.error(f"model not found: {args.model}")
    try:
        from ultralytics import YOLO
    except ImportError as error:
        raise SystemExit("ultralytics is required: pip install ultralytics") from error

    args.output.parent.mkdir(parents=True, exist_ok=True)
    model = YOLO(str(args.model))
    exported = model.export(format="onnx", imgsz=args.imgsz, simplify=False, dynamic=False)
    exported_path = Path(str(exported))
    if not exported_path.is_file():
        raise SystemExit(f"export reported success but output is missing: {exported_path}")
    if exported_path.resolve() != args.output.resolve():
        args.output.write_bytes(exported_path.read_bytes())
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
