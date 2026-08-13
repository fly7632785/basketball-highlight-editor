from __future__ import annotations

import json
from typing import Any, Dict


PROTOCOL_VERSION = "1.0"


class ProtocolError(Exception):
    def __init__(self, code: str, message: str, details: Dict[str, Any] | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}


def response(request_id: str | None, payload: Dict[str, Any] | None = None) -> Dict[str, Any]:
    return {
        "protocol_version": PROTOCOL_VERSION,
        "type": "response",
        "request_id": request_id,
        "ok": True,
        "payload": payload or {},
    }


def error_response(
    request_id: str | None,
    code: str,
    message: str,
    details: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    return {
        "protocol_version": PROTOCOL_VERSION,
        "type": "response",
        "request_id": request_id,
        "ok": False,
        "error": {"code": code, "message": message, "details": details or {}},
    }


def parse_request(raw: str) -> Dict[str, Any]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ProtocolError("INVALID_REQUEST", "请求不是有效 JSON", {"error": str(exc)}) from exc

    if not isinstance(value, dict):
        raise ProtocolError("INVALID_REQUEST", "请求必须是 JSON object")
    if value.get("type") != "request":
        raise ProtocolError("INVALID_REQUEST", "请求 type 必须为 request")
    if value.get("protocol_version") != PROTOCOL_VERSION:
        raise ProtocolError("UNSUPPORTED_PROTOCOL", "不支持的协议版本")
    request_id = value.get("request_id")
    if request_id is not None and (not isinstance(request_id, str) or not request_id):
        raise ProtocolError("INVALID_REQUEST", "request_id 必须是非空字符串或 null")
    if not isinstance(value.get("command"), str) or not value["command"]:
        raise ProtocolError("INVALID_REQUEST", "缺少 command")
    payload = value.get("payload", {})
    if not isinstance(payload, dict):
        raise ProtocolError("INVALID_REQUEST", "payload 必须是 JSON object")
    return value
