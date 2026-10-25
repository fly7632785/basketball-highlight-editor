#!/usr/bin/env python3
"""生成 App 检查更新用的 latest.json。

更新说明取 README「最近更新」表里这个版本的那一行，没有这一行就报错，
发版前必须先写好。签名在发版流程里用 openssl 对生成的文件做。

用法：
  scripts/build_update_manifest.py --tag v0.1.11 --assets-dir DIR \
    --base-url https://.../releases --out latest.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = {
    "macos-arm64": ".dmg",
    "macos-x86_64": ".dmg",
    "windows-x64": ".zip",
    "android-arm64-v8a": ".apk",
}


def release_notes(readme: Path, version: str) -> str:
    prefix = f"| v{version} |"
    for line in readme.read_text(encoding="utf-8").splitlines():
        if line.startswith(prefix):
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            if len(cells) >= 3 and cells[2]:
                return cells[2]
    raise SystemExit(f"{readme} 的「最近更新」表里没有 v{version} 这一行")


def package_entries(assets_dir: Path, version: str, base_url: str, android_base_url: str) -> dict:
    packages = {}
    for platform, suffix in PLATFORMS.items():
        matches = sorted(
            path for path in assets_dir.iterdir()
            if path.name.startswith(f"BHE-{platform}-v{version}") and path.name.endswith(suffix)
        )
        if len(matches) > 1:
            raise SystemExit(f"{platform} 有多个安装包：{[path.name for path in matches]}")
        if not matches:
            continue
        path = matches[0]
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
        url_base = android_base_url if platform.startswith("android") else base_url
        packages[platform] = {
            "url": f"{url_base.rstrip('/')}/{path.name}",
            "sha256": digest.hexdigest(),
            "size": path.stat().st_size,
        }
    if not packages:
        raise SystemExit(f"{assets_dir} 里没有 v{version} 的安装包")
    return packages


def build_manifest(
    tag: str,
    assets_dir: Path,
    base_url: str,
    readme_zh: Path,
    readme_en: Path,
    android_base_url: str | None = None,
) -> dict:
    version = tag.removeprefix("v")
    return {
        "version": version,
        "published_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "notes": {
            "zh": release_notes(readme_zh, version),
            "en": release_notes(readme_en, version),
        },
        "packages": package_entries(assets_dir, version, base_url, android_base_url or base_url),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--assets-dir", type=Path, required=True)
    parser.add_argument("--base-url", required=True)
    # 安卓 APK 只能通过自定义域名下载，OSS 默认域名会被拒绝。
    parser.add_argument("--android-base-url")
    parser.add_argument("--readme-zh", type=Path, default=ROOT / "README.md")
    parser.add_argument("--readme-en", type=Path, default=ROOT / "README.en.md")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    manifest = build_manifest(
        args.tag, args.assets_dir, args.base_url, args.readme_zh, args.readme_en, args.android_base_url
    )
    args.out.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{args.out}: v{manifest['version']} {sorted(manifest['packages'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
