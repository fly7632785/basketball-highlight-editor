import errno
import json
import queue
import sys
import threading
import traceback

from .diagnostics import environment_summary, log_diagnostic
from .protocol import ProtocolError, error_response, parse_request, response
from .service import EngineService
from .request_control import set_cancel_event, set_commit_callback, check_cancelled


def describe_unexpected_error(exc: Exception) -> tuple[str, str]:
    """把常见的系统错误转成界面能给出明确提示的错误码，其它的仍按 ENGINE_ERROR 返回。"""
    if isinstance(exc, FileNotFoundError):
        return "FILE_NOT_FOUND", str(exc.filename or exc)
    if isinstance(exc, PermissionError):
        return "FILE_ACCESS_DENIED", str(exc.filename or exc)
    if isinstance(exc, OSError) and exc.errno == errno.ENOSPC:
        return "DISK_FULL", str(exc)
    return "ENGINE_ERROR", str(exc)


class _RequestWorker:
    """One daemon worker; a blocked OS read must not prevent process exit."""
    def __init__(self):
        self._queue = queue.Queue()
        self._thread = threading.Thread(target=self._run, name="heavy-request", daemon=True)
        self._thread.start()

    def _run(self):
        while True:
            item = self._queue.get()
            if item is None:
                return
            function, args = item
            try:
                function(*args)
            except Exception:
                log_diagnostic(f"heavy request worker failed:\n{traceback.format_exc()}")

    def submit(self, function, *args):
        self._queue.put((function, args))

    def shutdown(self, timeout: float) -> None:
        self._queue.put(None)
        self._thread.join(timeout)
        if self._thread.is_alive():
            log_diagnostic("heavy request still running after shutdown deadline")


def main() -> int:
    service = EngineService()
    output_stream = sys.stdout
    output_lock = threading.Lock()
    # Full-source validation and preview extraction must not block the reader.
    heavy = _RequestWorker()
    slots = threading.BoundedSemaphore(2)  # one running, one queued
    registry_lock = threading.Lock()
    projects = set()
    requests = {}
    tickets = {}
    closing = False
    slow_commands = {"link_video", "relink_video", "suggest_roi", "open_project", "extract_preview"}
    protected_commands = slow_commands | {
        "create_project", "delete_project", "start_analysis", "start_export",
        "reorder_videos", "set_analysis_queue", "set_analysis_range",
        "save_roi", "start_review", "review_candidate", "set_candidates_player",
        "set_candidate_player", "delete_player",
        "update_clip_range", "update_clip_ranges", "create_manual_candidate",
        "retry_analysis", "retry_export", "update_project_settings",
        "set_analysis_mode", "save_workflow_draft", "clear_workflow_draft",
        "set_telemetry_consent", "cleanup_artifacts",
    }

    def project_key(payload):
        from pathlib import Path
        root = payload.get("project_root") or payload.get("root_path")
        return str(Path(root).expanduser().resolve()) if isinstance(root, str) and root.strip() else None

    def admit(request, slow):
        key = project_key(request.get("payload", {}))
        request_id = request.get("request_id")
        if key is not None and request["command"] in {"open_project", "link_video", "relink_video", "extract_preview", "suggest_roi", "delete_project", "create_project", "start_analysis"}:
            with service._job_lock:
                if key in service._export_projects:
                    raise ProtocolError("PROJECT_BUSY", "项目正在导出，请等待完成或取消")
        if slow and not slots.acquire(blocking=False):
            raise ProtocolError("PROJECT_BUSY", "请求队列已满，请稍后重试")
        with registry_lock:
            if closing:
                if slow:
                    slots.release()
                raise ProtocolError("PROJECT_BUSY", "引擎正在关闭")
            if (key is not None and key in projects) or (slow and request_id is not None and request_id in requests):
                if slow:
                    slots.release()
                raise ProtocolError("PROJECT_BUSY", "项目正在读取，请稍后重试")
            if key is not None:
                projects.add(key)
            ticket = {"event": threading.Event(), "committed": False} if slow else None
            if slow:
                tickets[id(ticket)] = ticket
                if request_id is not None:
                    requests[request_id] = ticket
        return key, request_id, ticket

    def release(token, slow):
        key, request_id, ticket = token
        with registry_lock:
            if key is not None:
                projects.discard(key)
            if slow:
                tickets.pop(id(ticket), None)
                if request_id is not None and requests.get(request_id) is ticket:
                    requests.pop(request_id)
        if slow:
            slots.release()

    def run_admitted(request, token, slow):
        ticket = token[2]
        set_cancel_event(ticket["event"] if ticket else None)
        def begin_commit():
            with registry_lock:
                if ticket["event"].is_set():
                    raise ProtocolError("REQUEST_CANCELLED", "请求已取消")
                ticket["committed"] = True
        set_commit_callback(begin_commit if ticket else None)
        try:
            handle_request(request)
        finally:
            set_commit_callback(None)
            set_cancel_event(None)
            release(token, slow)
    threading.Thread(
        target=lambda: log_diagnostic(environment_summary()),
        name="environment-log",
        daemon=True,
    ).start()

    def write_output(output):
        line = json.dumps(output, ensure_ascii=False, separators=(",", ":")) + "\n"
        with output_lock:
            output_stream.write(line)
            output_stream.flush()

    def handle_request(request):
        request_id = request.get("request_id")
        try:
            check_cancelled()
            result = service.handle(request["command"], request.get("payload", {}))
            check_cancelled()
            output = response(request_id, result)
        except ProtocolError as exc:
            try:
                check_cancelled()
            except ProtocolError as cancelled:
                exc = cancelled
            output = error_response(request_id, exc.code, exc.message, exc.details)
        except Exception as exc:
            log_diagnostic(f"request {request.get('command')} failed:\n{traceback.format_exc()}")
            try:
                check_cancelled()
            except ProtocolError as cancelled:
                output = error_response(request_id, cancelled.code, cancelled.message, cancelled.details)
            else:
                output = error_response(request_id, *describe_unexpected_error(exc))
        write_output(output)

    try:
        for raw_line in sys.stdin:
            line = raw_line.strip()
            if not line:
                continue
            request_id = None
            try:
                request = parse_request(line)
                request_id = request.get("request_id")
                command = request["command"]
                if command == "cancel_request":
                    target = request.get("payload", {}).get("request_id")
                    with registry_lock:
                        ticket = requests.get(target) if isinstance(target, str) else None
                        accepted = ticket is not None and not ticket["committed"]
                        if accepted:
                            ticket["event"].set()
                    write_output(response(request_id, {"cancel_requested": accepted}))
                elif command in slow_commands:
                    token = admit(request, True)
                    try:
                        heavy.submit(run_admitted, request, token, True)
                    except Exception:
                        release(token, True)
                        raise
                elif command in protected_commands:
                    token = admit(request, False)
                    run_admitted(request, token, False)
                else:
                    handle_request(request)
            except ProtocolError as exc:
                write_output(error_response(request_id, exc.code, exc.message, exc.details))
            except Exception as exc:
                log_diagnostic(f"request could not be read:\n{traceback.format_exc()}")
                write_output(error_response(request_id, "ENGINE_ERROR", str(exc)))
    finally:
        with registry_lock:
            closing = True
            for ticket in tickets.values():
                if not ticket["committed"]:
                    ticket["event"].set()
        try:
            service.shutdown()
        finally:
            heavy.shutdown(timeout=0.5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
