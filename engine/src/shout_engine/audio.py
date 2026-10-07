"""Audio decoding for the `transcribe` request."""

from __future__ import annotations

import base64
import binascii

import numpy as np

SAMPLE_RATE = 16_000
MAX_AUDIO_SECONDS = 10 * 60


class AudioError(ValueError):
    pass


def decode_pcm_s16le_b64(data: str, sample_rate: int) -> np.ndarray:
    """Turn base64 mono 16-bit little-endian PCM into float32 samples in [-1, 1)."""
    if sample_rate != SAMPLE_RATE:
        raise AudioError(f"sample_rate must be {SAMPLE_RATE}, got {sample_rate}")
    try:
        raw = base64.b64decode(data, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise AudioError(f"pcm_s16le_b64 is not valid base64: {exc}") from exc
    if len(raw) % 2:
        raise AudioError("PCM data has an odd number of bytes")
    samples = np.frombuffer(raw, dtype="<i2")
    if samples.size > MAX_AUDIO_SECONDS * SAMPLE_RATE:
        raise AudioError(f"audio is longer than {MAX_AUDIO_SECONDS // 60} minutes")
    return samples.astype(np.float32) / 32768.0


def encode_pcm_s16le_b64(audio: np.ndarray) -> str:
    """Inverse of `decode_pcm_s16le_b64`. Used by tests and the bench command."""
    clipped = np.clip(audio, -1.0, 1.0 - 1.0 / 32768.0)
    return base64.b64encode((clipped * 32768.0).astype("<i2").tobytes()).decode("ascii")


def duration_ms(audio: np.ndarray) -> int:
    return round(audio.size * 1000 / SAMPLE_RATE)
