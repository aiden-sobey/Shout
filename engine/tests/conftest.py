"""Exit the test process without interpreter teardown once the slow tests have loaded
WhisperX in-process: torch/CTranslate2 can abort in a native destructor on macOS, which
would turn a passing run into exit status 134. See shout_engine.__main__.hard_exit."""

import os
import sys

_exit_status = 0


def pytest_sessionfinish(session, exitstatus):
    global _exit_status
    _exit_status = int(exitstatus)


def pytest_unconfigure(config):
    if "whisperx" in sys.modules:
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(_exit_status)
