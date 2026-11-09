from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

from patch_ultralytics_git import patch_git_module


def test_git_metadata_permission_error_is_ignored(tmp_path, monkeypatch):
    module_path = tmp_path / "git.py"
    module_path.write_text(
        "from pathlib import Path\n"
        "class GitRepo:\n"
        "    @staticmethod\n"
        "    def _gitdir(root):\n"
        "        g = root / '.git'\n"
        "        if g.is_dir():\n"
        "            return g\n"
        "        if g.is_file():\n"
        '            t = g.read_text(errors="ignore").strip()\n'
        "            if t.startswith('gitdir:'):\n"
        "                return (root / t.split(':', 1)[1].strip()).resolve()\n"
        "        return None\n",
        encoding="utf-8",
    )
    assert patch_git_module(module_path)
    assert not patch_git_module(module_path)

    spec = spec_from_file_location("patched_ultralytics_git", module_path)
    assert spec and spec.loader
    module = module_from_spec(spec)
    spec.loader.exec_module(module)

    root = tmp_path / "worktree"
    root.mkdir()
    marker = root / ".git"
    marker.write_text("gitdir: ../.git/worktrees/test\n", encoding="utf-8")
    original_read_text = Path.read_text

    def deny_git_pointer(path, *args, **kwargs):
        if path == marker:
            raise PermissionError("Operation not permitted")
        return original_read_text(path, *args, **kwargs)

    monkeypatch.setattr(Path, "read_text", deny_git_pointer)
    assert module.GitRepo._gitdir(root) is None


def test_patch_rejects_unrecognized_ultralytics_source(tmp_path):
    module_path = tmp_path / "git.py"
    module_path.write_text("class GitRepo: pass\n", encoding="utf-8")
    try:
        patch_git_module(module_path)
    except RuntimeError as error:
        assert "unsupported Ultralytics" in str(error)
    else:
        raise AssertionError("unexpected source layout should fail the build patch")
