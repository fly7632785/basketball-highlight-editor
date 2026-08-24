import json
from pathlib import Path
from typing import Callable, TypeVar


T = TypeVar("T")


def read_json_cache(path: Path, validator: Callable[[object], bool]) -> T | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        path.unlink(missing_ok=True)
        return None
    if not validator(value):
        path.unlink(missing_ok=True)
        return None
    return value


def write_json_cache(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(f"{path.suffix}.tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    temporary.replace(path)
