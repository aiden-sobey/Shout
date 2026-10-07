"""`python -m shout_engine` — the stdio engine the app talks to (see docs/protocol.md).

`python -m shout_engine <command>` runs the CLI instead (download, bench).
"""

from __future__ import annotations

import sys


def serve() -> int:
    # Must happen before anything that might print to stdout is imported.
    from .stdio import ProtocolWriter, reserve_stdout

    writer = ProtocolWriter(reserve_stdout())

    import logging
    import traceback
    from importlib import metadata

    from . import __version__
    from .audio import AudioError, decode_pcm_s16le_b64
    from .engine import Engine, LoadedConfig
    from .protocol import (
        LoadModelRequest,
        ProtocolError,
        ShutdownRequest,
        StatusRequest,
        TranscribeRequest,
        event,
        failure,
        parse_request,
        success,
    )

    logging.basicConfig(
        stream=sys.stderr, level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )
    log = logging.getLogger("shout_engine")
    engine = Engine()

    writer.send(event("ready", engine_version=__version__, whisperx_version=metadata.version("whisperx")))
    log.info("Engine %s ready", __version__)

    for line in sys.stdin:
        if not line.strip():
            continue
        request_id = None
        try:
            request = parse_request(line)
            request_id = request.id
            if isinstance(request, StatusRequest):
                writer.send(success(request.id, engine.status()))
            elif isinstance(request, LoadModelRequest):
                config = LoadedConfig(
                    model=request.model,
                    compute_type=request.compute_type,
                    threads=request.threads,
                    vad_method=request.vad_method,
                    beam_size=request.beam_size,
                )
                result = engine.load(
                    config,
                    on_loading=lambda: writer.send(
                        event("model_loading", model=config.model, compute_type=config.compute_type)
                    ),
                )
                writer.send(success(request.id, result))
            elif isinstance(request, TranscribeRequest):
                if request.options.align:
                    raise ProtocolError("not_implemented", "Alignment isn't implemented yet (meeting mode).")
                try:
                    audio = decode_pcm_s16le_b64(request.pcm_s16le_b64, request.sample_rate)
                except AudioError as exc:
                    raise ProtocolError("bad_request", str(exc)) from exc
                result = engine.transcribe(
                    audio,
                    initial_prompt=request.options.initial_prompt,
                    hotwords=request.options.hotwords,
                    spelling=request.options.spelling,
                    format_lists=request.options.format_lists,
                )
                log.info("Transcribed %d ms of audio in %d ms", result["audio_ms"], result["transcribe_ms"])
                writer.send(success(request.id, result))
            elif isinstance(request, ShutdownRequest):
                writer.send(success(request.id, {}))
                log.info("Shutting down on request")
                return 0
        except ProtocolError as exc:
            writer.send(failure(exc.request_id or request_id, exc.code, exc.message))
        except Exception as exc:  # noqa: BLE001 - one bad request must not kill the engine
            log.error("Unhandled error:\n%s", traceback.format_exc())
            writer.send(failure(request_id, "internal", f"{type(exc).__name__}: {exc}"))

    log.info("stdin closed; exiting")
    return 0


def main() -> int:
    if len(sys.argv) > 1:
        from .cli import main as cli_main

        return cli_main(sys.argv[1:])
    return serve()


if __name__ == "__main__":
    from .stdio import hard_exit

    hard_exit(main())
