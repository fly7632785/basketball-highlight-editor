#!/usr/bin/env python3
"""Check whether the tracked tree is suitable for a source-only public release."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


BLOCKED_SUFFIXES = {
    ".7z",
    ".a",
    ".avi",
    ".bin",
    ".dll",
    ".dylib",
    ".gz",
    ".mkv",
    ".mov",
    ".mp4",
    ".onnx",
    ".pt",
    ".pth",
    ".so",
    ".tar",
    ".tgz",
    ".weights",
    ".zip",
}
# The desktop release intentionally bundles the project model so a fresh clone
# and the generated packages work without a silent download from an unknown
# address. Other model/native artifacts remain blocked by the audit.
ALLOWED_RELEASE_ARTIFACTS = {"models/bball_model.pt"}
BLOCKED_PATH_PARTS = (
    ".research/opensource-refs-",
    ".venv/",
    ".tooling/",
    "build/",
    "dist/",
    "data/videos/",
    "data/artifacts/",
)
SECRET_PATTERNS = (
    re.compile(r"(?:AIzaSy|ghp_|github_pat_|sk-)[A-Za-z0-9_-]{12,}"),
    re.compile(r"-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----"),
)
_MACOS_USER_DIR = "/" + "Users" + "/"
_LINUX_USER_DIR = "/" + "home" + "/"
ABSOLUTE_PATH_PATTERNS = (
    re.compile(re.escape(_MACOS_USER_DIR) + r"(?!\.\.\.)[^/\s]+/"),
    re.compile(re.escape(_LINUX_USER_DIR) + r"(?!\.\.\.)[^/\s]+/"),
    re.compile(r"[A-Za-z]:[\\/]Users[\\/](?!\.\.\.)[^\\/\s]+[\\/]"),
)
VALID_FONT_HEADERS = (b"\x00\x01\x00\x00", b"OTTO", b"true", b"typ1")


def _tracked_files(root: Path) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        check=True,
        capture_output=True,
    )
    return [item.decode("utf-8") for item in result.stdout.split(b"\0") if item]


def _gitlinks(root: Path) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--stage", "-z"],
        check=True,
        capture_output=True,
    )
    links: list[str] = []
    for record in result.stdout.split(b"\0"):
        if not record:
            continue
        header, path = record.rsplit(b"\t", 1)
        if header.startswith(b"160000 "):
            links.append(path.decode("utf-8"))
    return links


def _read_text(path: Path) -> str | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if b"\0" in data[:4096]:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def _font_is_valid(path: Path) -> bool:
    try:
        header = path.read_bytes()[:4]
    except OSError:
        return False
    return header in VALID_FONT_HEADERS


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    root = args.root.expanduser().resolve()
    errors: list[str] = []
    warnings: list[str] = []

    try:
        files = _tracked_files(root)
        gitlinks = _gitlinks(root)
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"open-source-check: FAILED to inspect Git: {exc}", file=sys.stderr)
        return 2

    if gitlinks:
        errors.extend(f"tracked gitlink: {path}" for path in gitlinks)

    for relative in files:
        path = Path(relative)
        normalized = f"{relative}/" if path.is_dir() else relative
        if path.name == ".DS_Store":
            errors.append(f"tracked OS metadata: {relative}")
        if any(part in normalized for part in BLOCKED_PATH_PARTS):
            errors.append(f"private/generated/reference path: {relative}")
        if (
            path.suffix.lower() in BLOCKED_SUFFIXES
            and relative not in ALLOWED_RELEASE_ARTIFACTS
        ):
            errors.append(f"binary/video/model artifact: {relative}")
        if path.suffix.lower() in {".ttf", ".otf"} and not _font_is_valid(root / path):
            errors.append(f"font file is not a valid font binary: {relative}")
        if (
            relative.startswith("capture/")
            and path.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp"}
        ) or path.name.lower().startswith("screenshot"):
            warnings.append(f"review screenshot for public rights and personal data: {relative}")

        text = _read_text(root / path)
        if text is None:
            continue
        for pattern in SECRET_PATTERNS:
            if pattern.search(text):
                errors.append(f"secret-like value: {relative}")
                break
        for pattern in ABSOLUTE_PATH_PATTERNS:
            if pattern.search(text):
                errors.append(f"machine-specific absolute path: {relative}")
                break
        if relative.startswith("data/") and path.name not in {"README.md"}:
            errors.append(f"tracked local data: {relative}")

    if not (root / "models" / "README.md").is_file():
        warnings.append("models/README.md is missing; explain how users provide model weights")
    warnings.append("verify dependency and FFmpeg notices before publishing a binary release")
    warnings.append("verify model-weight and training-data rights before publishing any model artifact")

    print(f"open-source-check: {'FAILED' if errors else 'PASS'}")
    print(f"tracked files: {len(files)}")
    for item in errors:
        print(f"ERROR: {item}")
    for item in warnings:
        print(f"WARNING: {item}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
