#!/usr/bin/env python3
"""Check relative links and images in Markdown files."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


LINK_PATTERN = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
EXCLUDED_PARTS = {
    ".git",
    ".venv",
    ".tooling",
    ".research",
    ".social-publish",
    ".claude",
    "build",
    "dist",
    "target",
    "third_party",
    "node_modules",
}


def markdown_files(root: Path) -> list[Path]:
    return [
        path
        for path in root.rglob("*.md")
        if not any(part in EXCLUDED_PARTS for part in path.relative_to(root).parts)
    ]


def is_external(target: str) -> bool:
    return (
        not target
        or target.startswith("#")
        or target.startswith("mailto:")
        or "://" in target
    )


def check(root: Path) -> list[str]:
    missing: list[str] = []
    for markdown in markdown_files(root):
        text = markdown.read_text(encoding="utf-8")
        for raw_target in LINK_PATTERN.findall(text):
            target = raw_target.split("#", 1)[0].strip().strip("<>")
            if is_external(target):
                continue
            resolved = (markdown.parent / target).resolve()
            if not resolved.exists():
                missing.append(
                    f"{markdown.relative_to(root)} -> {target}"
                )
    return missing


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.expanduser().resolve()
    missing = check(root)
    if missing:
        print("docs-links: FAILED")
        for item in missing:
            print(f"ERROR: missing relative target: {item}")
        return 1
    print(f"docs-links: PASS ({len(markdown_files(root))} Markdown files checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
