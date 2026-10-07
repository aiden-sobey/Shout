"""Command-line tools: downloading models and benchmarking.

    shout-engine download small.en          # a Whisper model
    shout-engine download silero-vad        # the optional silero voice detector
    shout-engine bench clip.wav [clip2.wav ...] --models small.en base.en --threads 4 6 --beams 5 1
"""

from __future__ import annotations

import argparse
import itertools
import resource
import statistics
import sys
import time
import wave
from pathlib import Path

import numpy as np


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="shout-engine")
    commands = parser.add_subparsers(dest="command", required=True)

    download = commands.add_parser("download", help="download a model (needs network)")
    download.add_argument("names", nargs="+", help="model names (e.g. small.en) or silero-vad")

    bench = commands.add_parser("bench", help="time transcription of WAV files (16 kHz mono 16-bit)")
    bench.add_argument("wavs", nargs="+", type=Path)
    bench.add_argument("--models", nargs="+", default=["small.en"])
    bench.add_argument("--compute-types", nargs="+", default=["int8"])
    bench.add_argument("--threads", nargs="+", type=int, default=[4])
    bench.add_argument("--beams", nargs="+", type=int, default=[5])
    bench.add_argument("--vad", default="pyannote", choices=["pyannote", "silero"])
    bench.add_argument("--runs", type=int, default=5)

    args = parser.parse_args(argv)
    if args.command == "download":
        return _download(args.names)
    return _bench(args)


def _download(names: list[str]) -> int:
    from faster_whisper.utils import download_model

    from .engine import SILERO_REPO, models_dir

    for name in names:
        print(f"Downloading {name}…", file=sys.stderr, flush=True)
        started = time.perf_counter()
        if name == "silero-vad":
            import torch

            torch.hub.load(repo_or_dir=SILERO_REPO, model="silero_vad", trust_repo=True, onnx=False)
        else:
            download_model(name, cache_dir=str(models_dir()))
        print(f"  done in {time.perf_counter() - started:.0f} s", file=sys.stderr, flush=True)
    return 0


def _read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path)) as wav:
        if wav.getframerate() != 16_000 or wav.getnchannels() != 1 or wav.getsampwidth() != 2:
            raise SystemExit(f"{path}: needs 16 kHz mono 16-bit (try: afconvert -f WAVE -d LEI16@16000 -c 1 in out)")
        frames = wav.readframes(wav.getnframes())
    return np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0


def _peak_rss_mb() -> float:
    # ru_maxrss is in bytes on macOS (kilobytes on Linux).
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return peak / (1024 * 1024) if sys.platform == "darwin" else peak / 1024


def _bench(args: argparse.Namespace) -> int:
    from .engine import Engine, LoadedConfig

    clips = [(path.name, _read_wav(path)) for path in args.wavs]
    print("model\tcompute\tthreads\tbeam\tclip\taudio_s\tmedian_ms\tmin_ms\trtf\tpeak_rss_mb\ttext")
    for model, compute_type, threads, beam in itertools.product(
        args.models, args.compute_types, args.threads, args.beams
    ):
        engine = Engine()
        engine.load(LoadedConfig(model, compute_type, threads, args.vad, beam))
        for name, audio in clips:
            times = []
            text = ""
            for _ in range(args.runs):
                result = engine.transcribe(audio)
                times.append(result["transcribe_ms"])
                text = result["text"]
            median = statistics.median(times)
            seconds = audio.size / 16_000
            print(
                f"{model}\t{compute_type}\t{threads}\t{beam}\t{name}\t{seconds:.1f}\t{median:.0f}\t{min(times)}"
                f"\t{median / 1000 / seconds:.3f}\t{_peak_rss_mb():.0f}\t{text[:60]}",
                flush=True,
            )
    return 0


def run() -> None:
    """Console-script entry point (`shout-engine ...`)."""
    from .stdio import hard_exit

    hard_exit(main())


if __name__ == "__main__":
    run()
