"""Short-lived request admission and cooperative cancellation for slow I/O."""
from __future__ import annotations

import hashlib
import os
import threading
from pathlib import Path

from .protocol import ProtocolError

_local = threading.local()


def set_cancel_event(event: threading.Event | None) -> None:
    _local.cancel_event = event


def set_commit_callback(callback) -> None:
    _local.commit_callback = callback


def begin_commit() -> None:
    callback = getattr(_local, 'commit_callback', None)
    if callback is not None:
        callback()
    else:
        check_cancelled()


def check_cancelled() -> None:
    event = getattr(_local, 'cancel_event', None)
    if event is not None and event.is_set():
        raise ProtocolError('REQUEST_CANCELLED', '请求已取消')


def fingerprint(path: str | Path) -> str:
    source = Path(path)
    digest = hashlib.sha256()
    with source.open('rb') as stream:
        before = os.fstat(stream.fileno())
        while True:
            check_cancelled()
            chunk = stream.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        check_cancelled()
        after = os.fstat(stream.fileno())
    current = source.stat()
    fields = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns)
    if fields(before) != fields(after) or fields(after) != fields(current):
        raise ProtocolError('VIDEO_SOURCE_CHANGED', '读取期间原视频发生变化，请重试')
    return f'{after.st_size}:{digest.hexdigest()}'
