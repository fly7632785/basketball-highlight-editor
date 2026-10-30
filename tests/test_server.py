import io
import json
import threading

import pytest

from engine.python.basketball_engine import server
from engine.python.basketball_engine.protocol import ProtocolError
from engine.python.basketball_engine.service import EngineService


def _request(request_id, command, payload=None):
    return json.dumps({
        "protocol_version": "1.0", "type": "request",
        "request_id": request_id, "command": command, "payload": payload or {},
    }) + "\n"


def test_slow_preview_does_not_block_player_creation(tmp_path, monkeypatch):
    service = EngineService()
    service.create_project({"root_path": str(tmp_path), "name": "标签测试"})
    preview_started = threading.Event()
    player_returned = threading.Event()
    preview_returned = threading.Event()

    def slow_preview(payload):
        preview_started.set()
        # The response writer releases this wait, so response order (not a
        # fragile timing threshold) proves interactive work can overtake it.
        player_returned.wait(2)
        return {"path": "preview.jpg"}

    class Output(io.StringIO):
        def write(self, value):
            result = super().write(value)
            if json.loads(value)["request_id"] == "create":
                player_returned.set()
            if json.loads(value)["request_id"] == "preview":
                preview_returned.set()
            return result

    def requests():
        yield _request("preview", "extract_preview")
        assert preview_started.wait(2)
        yield _request("create", "create_player", {
            "project_root": str(tmp_path), "name": "第三位",
        })
        assert preview_returned.wait(2)

    output = Output()
    monkeypatch.setattr(service, "extract_preview", slow_preview)
    monkeypatch.setattr(server, "EngineService", lambda: service)
    monkeypatch.setattr(server.sys, "stdin", requests())
    monkeypatch.setattr(server.sys, "stdout", output)

    assert server.main() == 0
    responses = [json.loads(line) for line in output.getvalue().splitlines()]
    assert [item["request_id"] for item in responses] == ["create", "preview"]
    assert all(item["ok"] for item in responses)
    assert responses[0]["payload"]["player"]["name"] == "第三位"


@pytest.mark.parametrize("error,code", [
    (ProtocolError("VIDEO_OPEN_FAILED", "预览失败"), "VIDEO_OPEN_FAILED"),
    (RuntimeError("preview failed"), "ENGINE_ERROR"),
])
def test_preview_errors_keep_request_ids_and_do_not_break_other_requests(monkeypatch, error, code):
    service = EngineService()

    def failed_preview(payload):
        raise error

    finished = threading.Event()
    class Output(io.StringIO):
        def write(self, value):
            result = super().write(value)
            if json.loads(value)["request_id"] == "preview":
                finished.set()
            return result
    output = Output()
    def requests():
        yield _request("preview", "extract_preview")
        yield "not json\n"
        yield _request("hello", "hello")
        assert finished.wait(2)
    monkeypatch.setattr(service, "extract_preview", failed_preview)
    monkeypatch.setattr(server, "EngineService", lambda: service)
    monkeypatch.setattr(server.sys, "stdin", requests())
    monkeypatch.setattr(server.sys, "stdout", output)

    assert server.main() == 0
    responses = [json.loads(line) for line in output.getvalue().splitlines()]
    by_id = {item["request_id"]: item for item in responses}
    assert len(responses) == 3
    assert by_id["preview"]["error"]["code"] == code
    assert by_id["hello"]["ok"] is True
    assert by_id[None]["ok"] is False
