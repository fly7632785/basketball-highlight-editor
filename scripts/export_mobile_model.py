#!/usr/bin/env python3
"""Export the validated YOLO checkpoint for the mobile runtime.

This intentionally fails with an actionable message when the optional ONNX
export dependency is not installed; it never claims that a mobile model was
created when the export did not happen.

``--dynamic`` 导出动态 batch,供桌面端 ONNX Runtime / DirectML 使用;
不带该参数时行为和以前完全一致(固定 batch=1,移动端)。
"""

from __future__ import annotations

import argparse
import json
import shutil
import tempfile
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, default=Path("models/bball_model.pt"))
    parser.add_argument("--output", type=Path, default=Path("models/bball_model.onnx"))
    parser.add_argument("--imgsz", type=int, default=640)
    # 移动端继续用固定 batch=1;桌面端 DirectML 走动态 batch,见
    # docs/implementation/DESKTOP_DML_ACCELERATION_PLAN.md。
    parser.add_argument("--dynamic", action="store_true",
                        help="导出动态 batch(桌面 ORT/DirectML 需要)")
    parser.add_argument("--batch", type=int, default=1,
                        help="静态导出时的固定 batch;动态导出时作为参考 batch")
    args = parser.parse_args()

    if not args.model.is_file():
        parser.error(f"model not found: {args.model}")
    try:
        from ultralytics import YOLO
    except ImportError as error:
        raise SystemExit("ultralytics is required: pip install ultralytics") from error

    args.output.parent.mkdir(parents=True, exist_ok=True)
    # ultralytics 总是把 .onnx 写在 .pt 旁边；先复制到临时目录再导出，
    # 免得 --output 指向别处时也覆盖掉 models/ 里原有的移动端模型。
    with tempfile.TemporaryDirectory() as workdir:
        staged = Path(workdir) / args.model.name
        shutil.copy2(args.model, staged)
        model = YOLO(str(staged))
        exported = model.export(
            format="onnx", imgsz=args.imgsz, simplify=False,
            dynamic=bool(args.dynamic), batch=max(1, int(args.batch)),
        )
        exported_path = Path(str(exported))
        if not exported_path.is_file():
            raise SystemExit(f"export reported success but output is missing: {exported_path}")
        args.output.write_bytes(exported_path.read_bytes())
    if args.dynamic:
        # 类别名随模型一起走:ORT 侧没有 torch,读不到 names。
        names = {int(key): str(value) for key, value in (model.names or {}).items()}
        sidecar = args.output.with_suffix(args.output.suffix + ".names.json")
        sidecar.write_text(
            json.dumps({"names": names, "dynamic": True, "imgsz": args.imgsz},
                       ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        print(sidecar)
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
