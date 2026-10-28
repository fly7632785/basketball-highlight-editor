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
    "verify_rim_crossing.py",
)
REQUIRED_IMPORTS = ("cv2", "numpy", "ultralytics", "torch", "dill")


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


def _check_binary(path: str | None, expected_name: str) -> tuple[bool, str]:
    if not path:
        return False, "not found"
    try:
        result = subprocess.run(
            [path, "-version"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        return False, str(exc)
    version = f"{result.stdout}\n{result.stderr}".lower()
    if f"{expected_name} version" not in version:
        return False, f"{path} is not {expected_name} ({version.splitlines()[0] if version else 'no version output'})"
    return True, str(Path(path).resolve())


def _acceleration_report(python_path: str, model: Path) -> dict[str, object]:
    """报告加速后端可用性。只是信息,不参与 OK/FAILED 判定。

    桌面端 DirectML 需要两件事同时成立:装了 onnxruntime-directml,且
    ``models/bball_model.onnx``(动态 batch)存在。缺任一项都会回落 CPU。

    CoreML 同理:需要 wheel 带 ``CoreMLExecutionProvider``,且
    ``models/bball_model.static.onnx``(静态 batch=1、640x640)存在。
    动态模型不能给 CoreML 用(实测慢 4 倍),所以两条产物必须分开。
    """
    onnx_model = model.with_suffix(".onnx")
    static_onnx = model.with_name(model.stem + ".static.onnx")
    probe = (
        "import json\n"
        "try:\n"
        "    import onnxruntime as ort\n"
        "    providers = ort.get_available_providers()\n"
        "    version = ort.__version__\n"
        "except Exception as exc:\n"
        "    providers, version = [], None\n"
        "print(json.dumps({'onnxruntime': version, 'providers': providers}))\n"
    )
    try:
        result = subprocess.run(
            [python_path, "-c", probe],
            check=True, capture_output=True, text=True, timeout=60,
        )
        payload = json.loads(result.stdout.strip().splitlines()[-1])
    except (OSError, subprocess.CalledProcessError, ValueError, IndexError):
        payload = {"onnxruntime": None, "providers": []}
    providers = list(payload.get("providers") or [])
    coreml_provider = "CoreMLExecutionProvider" in providers
    static_ready = static_onnx.is_file()
    return {
        "onnxruntime": payload.get("onnxruntime"),
        "providers": providers,
        "dml_provider": "DmlExecutionProvider" in providers,
        "onnx_model": str(onnx_model) if onnx_model.is_file() else None,
        "dml_ready": "DmlExecutionProvider" in providers and onnx_model.is_file(),
        "ort_coreml": coreml_provider,
        "static_onnx": str(static_onnx) if static_ready else None,
        "coreml_ready": coreml_provider and static_ready,
    }


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
    ffmpeg_ok, ffmpeg_detail = _check_binary(args.ffmpeg, "ffmpeg")
    ffprobe_ok, ffprobe_detail = _check_binary(args.ffprobe, "ffprobe")
    checks["ffmpeg"] = {"ok": ffmpeg_ok, "detail": ffmpeg_detail}
    checks["ffprobe"] = {"ok": ffprobe_ok, "detail": ffprobe_detail}
    # 可选能力:只报告,不参与判定(缺了就是 CPU 推理,不算运行时故障)。
    checks["acceleration"] = {
        "ok": True,
        "optional": True,
        **_acceleration_report(args.python_path, model),
    }

    ok = all(bool(item["ok"]) for item in checks.values() if not item.get("optional"))
    result = {"ok": ok, "root": str(root), "checks": checks}
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"runtime: {'OK' if ok else 'FAILED'}")
        for name, item in checks.items():
            if item.get("optional"):
                continue
            print(f"- {name}: {'OK' if item['ok'] else 'FAILED'}")
            if not item["ok"]:
                print(f"  {item}")
        accel = checks["acceleration"]
        ready = []
        if accel.get("dml_ready"):
            ready.append("DirectML")
        if accel.get("coreml_ready"):
            ready.append("CoreML")
        if ready:
            print(f"- acceleration: {' + '.join(ready)} ready")
        else:
            print(
                "- acceleration: CPU only "
                f"(onnxruntime={accel.get('onnxruntime')}, "
                f"dml_provider={accel.get('dml_provider')}, "
                f"onnx_model={'yes' if accel.get('onnx_model') else 'no'}, "
                f"coreml_provider={accel.get('ort_coreml')}, "
                f"static_onnx={'yes' if accel.get('static_onnx') else 'no'})"
            )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
