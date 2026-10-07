"""Runs the real `python -m shout_engine` process and checks the stdio contract."""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from shout_engine.audio import encode_pcm_s16le_b64
from shout_engine.cli import _read_wav
from shout_engine.engine import is_downloaded

FIXTURES = Path(__file__).parent / "fixtures"


class EngineProcess:
    def __init__(self) -> None:
        env = {**os.environ, "HF_HUB_OFFLINE": "1"}
        self.proc = subprocess.Popen(
            [sys.executable, "-m", "shout_engine"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        self.lines: list[str] = []

    def read(self) -> dict:
        raw = self.proc.stdout.readline()
        assert raw, "engine closed stdout"
        self.lines.append(raw)
        return json.loads(raw)  # every stdout line must be valid JSON

    def request(self, **fields) -> dict:
        self.proc.stdin.write(json.dumps(fields) + "\n")
        self.proc.stdin.flush()
        while True:
            message = self.read()
            if "event" not in message:
                return message

    def close(self) -> int:
        self.proc.stdin.close()
        return self.proc.wait(timeout=30)


@pytest.fixture
def engine():
    process = EngineProcess()
    yield process
    if process.proc.poll() is None:
        process.proc.kill()


def test_ready_status_errors_and_shutdown(engine):
    ready = engine.read()
    assert ready["event"] == "ready"

    status = engine.request(id="1", op="status")
    assert status["ok"] is True
    assert "int8" in status["result"]["supported_compute_types"]
    assert status["result"]["loaded"] is None
    assert isinstance(status["result"]["silero_vad_downloaded"], bool)

    bad = engine.request(id="2", op="transcribe", sample_rate=16000, pcm_s16le_b64="AAAAAA==")
    assert bad == {"id": "2", "ok": False, "error": bad["error"]}
    assert bad["error"]["code"] == "model_not_loaded"

    garbage = engine.request(id="3", op="nope")
    assert garbage["error"]["code"] == "unknown_op"

    missing = engine.request(
        id="4", op="load_model", model="medium.en", compute_type="int8", threads=2, vad_method="pyannote", beam_size=1
    )
    if not is_downloaded("medium.en"):
        assert missing["error"]["code"] == "model_not_found"

    unsupported = engine.request(
        id="5", op="load_model", model="tiny.en", compute_type="float16", threads=2, vad_method="pyannote", beam_size=1
    )
    assert unsupported["error"]["code"] == "unsupported_compute_type"

    assert engine.request(id="6", op="shutdown") == {"id": "6", "ok": True, "result": {}}
    assert engine.proc.wait(timeout=30) == 0


def test_exits_when_stdin_closes(engine):
    assert engine.read()["event"] == "ready"
    assert engine.close() == 0


@pytest.mark.slow
@pytest.mark.skipif(not is_downloaded("tiny.en"), reason="tiny.en not downloaded")
def test_transcribes_over_stdio_with_clean_stdout(engine):
    """Loading a model makes torch/pyannote/ctranslate2 chatty; none of it may reach stdout."""
    assert engine.read()["event"] == "ready"
    loaded = engine.request(
        id="1", op="load_model", model="tiny.en", compute_type="int8", threads=4, vad_method="pyannote", beam_size=1
    )
    assert loaded["ok"] is True, loaded

    audio = _read_wav(FIXTURES / "short.wav")
    result = engine.request(id="2", op="transcribe", sample_rate=16000, pcm_s16le_b64=encode_pcm_s16le_b64(audio))
    assert result["ok"] is True, result
    assert "report" in result["result"]["text"].lower()

    align = engine.request(
        id="3", op="transcribe", sample_rate=16000, pcm_s16le_b64=encode_pcm_s16le_b64(audio), options={"align": True}
    )
    assert align["error"]["code"] == "not_implemented"

    assert engine.close() == 0
    for raw in engine.lines:
        json.loads(raw)
