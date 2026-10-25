import errno
import io
import json

import pytest

from engine.python.basketball_engine import server
from engine.python.basketball_engine.server import describe_unexpected_error
from engine.python.basketball_engine.protocol import PROTOCOL_VERSION
from engine.python.basketball_engine.service import EngineService


def test_unexpected_engine_error_is_logged_with_traceback(monkeypatch, capsys):
    def explode(self, command, payload):
        raise RuntimeError("disk gone")

    monkeypatch.setattr(EngineService, "handle", explode)
    request = json.dumps({
        "type": "request",
        "protocol_version": PROTOCOL_VERSION,
        "request_id": "r1",
        "command": "list_candidates",
        "payload": {},
    })
    monkeypatch.setattr("sys.stdin", io.StringIO(request + "\n"))

    server.main()

    captured = capsys.readouterr()
    assert json.loads(captured.out.splitlines()[0])["error"]["code"] == "ENGINE_ERROR"
    assert "[bhe] request list_candidates failed: disk gone" in captured.err
    assert "Traceback" in captured.err


@pytest.mark.parametrize(
    ("error", "code", "message"),
    [
        (FileNotFoundError(errno.ENOENT, "missing", r"C:\\Videos\\BasketballProjects"), "FILE_NOT_FOUND", r"C:\\Videos\\BasketballProjects"),
        (PermissionError(errno.EACCES, "denied", "/data/project.db"), "FILE_ACCESS_DENIED", "/data/project.db"),
        (OSError(errno.ENOSPC, "No space left on device"), "DISK_FULL", "[Errno 28] No space left on device"),
        (RuntimeError("boom"), "ENGINE_ERROR", "boom"),
    ],
)
def test_common_system_errors_get_a_specific_code(error, code, message):
    assert describe_unexpected_error(error) == (code, message)
