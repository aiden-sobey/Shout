"""Real transcription with WhisperX. Slow; run with `uv run pytest -m slow`."""

from pathlib import Path

import numpy as np
import pytest

from shout_engine.cli import _read_wav
from shout_engine.engine import Engine, LoadedConfig, is_downloaded

FIXTURES = Path(__file__).parent / "fixtures"
MODEL = "small.en"

pytestmark = [
    pytest.mark.slow,
    pytest.mark.skipif(not is_downloaded(MODEL), reason=f"{MODEL} not downloaded"),
]


@pytest.fixture(scope="module")
def engine() -> Engine:
    engine = Engine()
    engine.load(LoadedConfig(MODEL, "int8", threads=4, vad_method="pyannote", beam_size=5))
    return engine


@pytest.mark.parametrize(
    ("fixture", "keywords"),
    [
        ("short.wav", ["report", "friday"]),
        ("ten.wav", ["pull request", "topology", "release"]),
        ("long.wav", ["bicycle", "solar", "batteries", "dentist"]),
    ],
)
def test_transcribes_tts_fixtures(engine, fixture, keywords):
    result = engine.transcribe(_read_wav(FIXTURES / fixture))
    text = result["text"].lower()
    for keyword in keywords:
        assert keyword in text, f"{keyword!r} missing from {text!r}"
    assert result["segments"]


def test_silence_returns_empty_text(engine):
    result = engine.transcribe(np.zeros(16000 * 2, dtype=np.float32))
    assert result["text"] == ""
    assert result["segments"] == []


def test_quiet_noise_returns_empty_text(engine):
    rng = np.random.default_rng(0)
    result = engine.transcribe((rng.standard_normal(16000 * 3) * 0.001).astype(np.float32))
    assert result["text"] == ""


def test_tiny_clip_is_ignored(engine):
    assert engine.transcribe(np.zeros(1600, dtype=np.float32))["text"] == ""


def test_hotwords_are_accepted_per_request(engine):
    audio = _read_wav(FIXTURES / "short.wav")
    with_vocab = engine.transcribe(audio, hotwords="Gridsight, DNSP")
    without = engine.transcribe(audio)
    assert "report" in with_vocab["text"].lower()
    assert "report" in without["text"].lower()


def test_british_spelling(engine):
    audio = _read_wav(FIXTURES / "spelling.wav")
    american = engine.transcribe(audio)["text"].lower()
    british = engine.transcribe(audio, spelling="en-GB")
    text = british["text"].lower()
    assert "recognize" in american and "color" in american
    for word in ["recognise", "colour", "organisation", "realise"]:
        assert word in text, f"{word!r} missing from {text!r}"
    # Meaning-dependent words stay as they are.
    for word in ["meter", "program", "license"]:
        assert word in text, f"{word!r} missing from {text!r}"
    # Segment texts are converted too, not just the joined text.
    assert "color" not in " ".join(s["text"] for s in british["segments"]).lower()


def test_spoken_numbered_list_is_formatted(engine):
    audio = _read_wav(FIXTURES / "list.wav")
    lines = engine.transcribe(audio, format_lists=True)["text"].split("\n")
    assert len(lines) == 4, lines
    assert lines[0].endswith(":")
    assert [line[:3] for line in lines[1:]] == ["1. ", "2. ", "3. "]
    assert "test it out" in lines[2].lower()
    # Off by default.
    assert "\n" not in engine.transcribe(audio)["text"]
