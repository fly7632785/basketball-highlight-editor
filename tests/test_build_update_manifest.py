import hashlib
import importlib.util
import json
from pathlib import Path

import pytest

_spec = importlib.util.spec_from_file_location(
    "build_update_manifest",
    Path(__file__).resolve().parents[1] / "scripts" / "build_update_manifest.py",
)
manifest_script = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(manifest_script)


def _readmes(tmp_path: Path) -> tuple[Path, Path]:
    zh = tmp_path / "README.md"
    zh.write_text(
        "| 版本 | 日期 | 主要更新 |\n|---|---|---|\n"
        "| v0.1.11 | 2026-10-24 | 应用内检查更新 |\n"
        "| v0.1.10 | 2026-10-23 | 多段视频 |\n",
        encoding="utf-8",
    )
    en = tmp_path / "README.en.md"
    en.write_text("| v0.1.11 | 2026-10-24 | In-app updates |\n", encoding="utf-8")
    return zh, en


def test_manifest_lists_each_platform_package_with_its_checksum(tmp_path: Path):
    assets = tmp_path / "assets"
    assets.mkdir()
    for name in (
        "BHE-macos-arm64-v0.1.11-adhoc.dmg",
        "BHE-macos-arm64-v0.1.11-adhoc.dmg.sha256",
        "BHE-windows-x64-v0.1.11.zip",
        "BHE-android-arm64-v8a-v0.1.11.apk",
        "BHE-macos-x86_64-v0.1.10-adhoc.dmg",
    ):
        (assets / name).write_bytes(name.encode())
    zh, en = _readmes(tmp_path)
    out = tmp_path / "latest.json"

    manifest_script.main([
        "--tag", "v0.1.11",
        "--assets-dir", str(assets),
        "--base-url", "https://oss.example/releases/",
        "--readme-zh", str(zh),
        "--readme-en", str(en),
        "--out", str(out),
    ])

    manifest = json.loads(out.read_text(encoding="utf-8"))
    assert manifest["version"] == "0.1.11"
    assert manifest["notes"] == {"zh": "应用内检查更新", "en": "In-app updates"}
    assert sorted(manifest["packages"]) == ["android-arm64-v8a", "macos-arm64", "windows-x64"]
    mac = manifest["packages"]["macos-arm64"]
    assert mac["url"] == "https://oss.example/releases/BHE-macos-arm64-v0.1.11-adhoc.dmg"
    assert mac["sha256"] == hashlib.sha256(b"BHE-macos-arm64-v0.1.11-adhoc.dmg").hexdigest()
    assert mac["size"] == len("BHE-macos-arm64-v0.1.11-adhoc.dmg")


def test_manifest_requires_release_notes_for_the_version(tmp_path: Path):
    assets = tmp_path / "assets"
    assets.mkdir()
    (assets / "BHE-windows-x64-v0.1.12.zip").write_bytes(b"zip")
    zh, en = _readmes(tmp_path)
    with pytest.raises(SystemExit, match="v0.1.12"):
        manifest_script.build_manifest("v0.1.12", assets, "https://oss.example", zh, en)


def test_android_package_uses_the_custom_domain(tmp_path: Path):
    assets = tmp_path / "assets"
    assets.mkdir()
    (assets / "BHE-android-arm64-v8a-v0.1.11-debug-signed.apk").write_bytes(b"apk")
    (assets / "BHE-windows-x64-v0.1.11.zip").write_bytes(b"zip")
    zh, en = _readmes(tmp_path)

    manifest = manifest_script.build_manifest(
        "v0.1.11",
        assets,
        "https://oss.example/releases",
        zh,
        en,
        android_base_url="https://custom.example/releases",
    )

    assert manifest["packages"]["android-arm64-v8a"]["url"] == (
        "https://custom.example/releases/BHE-android-arm64-v8a-v0.1.11-debug-signed.apk"
    )
    assert manifest["packages"]["windows-x64"]["url"] == "https://oss.example/releases/BHE-windows-x64-v0.1.11.zip"
