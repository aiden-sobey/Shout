"""WhisperX wrapper: load a model once, keep it in memory, transcribe numpy audio.

WhisperX, torch and friends are imported lazily so that `stdio.reserve_stdout()` runs
before any of them can print, and so `status` answers quickly.
"""

from __future__ import annotations

import logging
import os
import platform
import time
import warnings
import wave
from dataclasses import asdict, dataclass, replace
from importlib import metadata, resources
from pathlib import Path
from typing import Any

import numpy as np

from . import __version__, spelling as spelling_rules
from .formatting import format_numbered_list

# pyannote imports torchcodec, which warns at length when FFmpeg isn't installed. The engine
# only ever passes numpy arrays, so it never decodes files and doesn't need FFmpeg.
warnings.filterwarnings("ignore", message=r"(?s).*torchcodec.*")
from .audio import SAMPLE_RATE, duration_ms
from .protocol import ProtocolError

log = logging.getLogger("shout_engine")

# Models offered in the app. Anything faster-whisper knows also works from the CLI.
KNOWN_MODELS = ("tiny.en", "base.en", "small.en", "medium.en", "distil-large-v3", "large-v3-turbo")

# Clips shorter than this are treated as accidental taps: no speech.
MIN_AUDIO_SECONDS = 0.3

SILERO_REPO = "snakers4/silero-vad"


def models_dir() -> Path:
    override = os.environ.get("SHOUT_MODELS_DIR")
    path = Path(override) if override else Path.home() / "Library/Application Support/Shout/models"
    path.mkdir(parents=True, exist_ok=True)
    return path


def is_downloaded(model: str) -> bool:
    from faster_whisper.utils import download_model

    try:
        path = download_model(model, local_files_only=True, cache_dir=str(models_dir()))
    except Exception:  # noqa: BLE001 - huggingface_hub raises several different errors here
        return False
    # The snapshot folder appears as soon as a download starts; the weights file only once
    # it has fully arrived.
    return (Path(path) / "model.bin").exists()


def silero_cached() -> bool:
    import torch

    # torch.hub caches GitHub repos as <hub dir>/<owner>_<repo>_<branch>.
    return (Path(torch.hub.get_dir()) / "snakers4_silero-vad_master").exists()


@dataclass(frozen=True)
class LoadedConfig:
    model: str
    compute_type: str
    threads: int
    vad_method: str
    beam_size: int


class Engine:
    def __init__(self) -> None:
        self._pipeline: Any = None
        self._config: LoadedConfig | None = None

    @property
    def loaded(self) -> LoadedConfig | None:
        return self._config

    def status(self) -> dict[str, Any]:
        import ctranslate2

        return {
            "engine_version": __version__,
            "whisperx_version": metadata.version("whisperx"),
            "python_version": platform.python_version(),
            "models_dir": str(models_dir()),
            "downloaded_models": [m for m in KNOWN_MODELS if is_downloaded(m)],
            "supported_compute_types": sorted(ctranslate2.get_supported_compute_types("cpu")),
            "silero_vad_downloaded": silero_cached(),
            "loaded": asdict(self._config) if self._config else None,
        }

    def load(self, config: LoadedConfig, *, on_loading: Any = None) -> dict[str, Any]:
        """Load (or replace) the model. On failure the previous model stays loaded."""
        import ctranslate2

        supported = ctranslate2.get_supported_compute_types("cpu")
        if config.compute_type not in supported:
            raise ProtocolError(
                "unsupported_compute_type",
                f"`{config.compute_type}` isn't supported on this CPU. Use one of: {', '.join(sorted(supported))}",
            )
        if not is_downloaded(config.model):
            raise ProtocolError(
                "model_not_found",
                f"Model `{config.model}` isn't downloaded. Run: shout-engine download {config.model}",
            )
        if config.vad_method == "silero" and not silero_cached():
            raise ProtocolError(
                "model_not_found",
                "The silero voice detector isn't downloaded. Run: shout-engine download silero-vad",
            )

        if on_loading:
            on_loading()
        import torch
        import whisperx

        torch.set_num_threads(config.threads)
        started = time.perf_counter()
        pipeline = whisperx.load_model(
            config.model,
            "cpu",
            compute_type=config.compute_type,
            language="en",
            asr_options={"beam_size": config.beam_size},
            vad_method=config.vad_method,
            download_root=str(models_dir()),
            local_files_only=True,
            threads=config.threads,
        )
        load_ms = _ms_since(started)

        started = time.perf_counter()
        self._run(pipeline, _warmup_audio(), batch_size=1)
        warmup_ms = _ms_since(started)

        self._pipeline = pipeline
        self._config = config
        log.info("Loaded %s (%s) in %d ms, warm-up %d ms", config.model, config.compute_type, load_ms, warmup_ms)
        return {"model": config.model, "compute_type": config.compute_type, "load_ms": load_ms, "warmup_ms": warmup_ms}

    def transcribe(
        self,
        audio: np.ndarray,
        *,
        initial_prompt: str | None = None,
        hotwords: str | None = None,
        spelling: str = "en-US",
        format_lists: bool = False,
        batch_size: int = 8,
    ) -> dict[str, Any]:
        if self._pipeline is None:
            raise ProtocolError("model_not_loaded", "No model is loaded. Send `load_model` first.")

        started = time.perf_counter()
        if audio.size < MIN_AUDIO_SECONDS * SAMPLE_RATE:
            segments: list[dict[str, Any]] = []
        else:
            # Vocabulary is read from the options on every batch, so swapping it per request
            # is cheap and needs no reload.
            self._pipeline.options = replace(
                self._pipeline.options, initial_prompt=initial_prompt, hotwords=hotwords
            )
            segments = self._run(self._pipeline, audio, batch_size=batch_size)

        cleaned = [
            {
                "start": round(float(s["start"]), 3),
                "end": round(float(s["end"]), 3),
                "text": spelling_rules.apply(s["text"].strip(), spelling),
            }
            for s in segments
            if s.get("text", "").strip()
        ]
        text = " ".join(s["text"] for s in cleaned)
        if format_lists:
            # On the joined text: a spoken list can span several segments.
            text = format_numbered_list(text)
        return {
            "text": text,
            "segments": cleaned,
            "audio_ms": duration_ms(audio),
            "transcribe_ms": _ms_since(started),
        }

    @staticmethod
    def _run(pipeline: Any, audio: np.ndarray, *, batch_size: int) -> list[dict[str, Any]]:
        result = pipeline.transcribe(audio, batch_size=batch_size, language="en", print_progress=False)
        return list(result.get("segments", []))


def _ms_since(started: float) -> int:
    return round((time.perf_counter() - started) * 1000)


def _warmup_audio() -> np.ndarray:
    """A short spoken phrase shipped with the package, so warm-up exercises the ASR model
    (silence would be dropped by voice detection before the model ever ran)."""
    with resources.files("shout_engine").joinpath("assets/warmup.wav").open("rb") as handle:
        with wave.open(handle) as wav:
            frames = wav.readframes(wav.getnframes())
    return np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
