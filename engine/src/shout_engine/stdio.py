"""Keep stdout for protocol messages only.

CTranslate2, pyannote, torch and plain `print` calls all write to stdout, which
would corrupt the JSON Lines stream. `reserve_stdout` must run before any of
those libraries are imported: it keeps a private handle on the real stdout and
points file descriptor 1 (and `sys.stdout`) at stderr.
"""

from __future__ import annotations

import json
import os
import sys
import threading
from typing import Any, TextIO


def reserve_stdout() -> TextIO:
    sys.stdout.flush()
    protocol_fd = os.dup(1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    return os.fdopen(protocol_fd, "w", buffering=1, encoding="utf-8")


class ProtocolWriter:
    """Writes one JSON object per line. Safe to call from several threads."""

    def __init__(self, stream: TextIO) -> None:
        self._stream = stream
        self._lock = threading.Lock()

    def send(self, message: dict[str, Any]) -> None:
        line = json.dumps(message, separators=(",", ":"), ensure_ascii=False)
        with self._lock:
            self._stream.write(line + "\n")
            self._stream.flush()


def hard_exit(code: int) -> None:
    """Exit without interpreter teardown.

    With torch, pyannote and CTranslate2 loaded, normal shutdown on macOS can abort in a
    native destructor ("recursive_mutex lock failed"), turning a clean exit into a crash.
    Everything worth keeping has been written by now, so flush and leave.
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except Exception:  # noqa: BLE001
            pass
    os._exit(code)
