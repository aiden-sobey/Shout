"""Request parsing and response shapes. See docs/protocol.md."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Literal

VAD_METHODS = ("pyannote", "silero")
SPELLINGS = ("en-US", "en-GB")


class ProtocolError(Exception):
    """A request the engine refuses. Becomes an `ok: false` response."""

    def __init__(self, code: str, message: str, request_id: str | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.request_id = request_id


@dataclass(frozen=True)
class StatusRequest:
    id: str


@dataclass(frozen=True)
class LoadModelRequest:
    id: str
    model: str
    compute_type: str
    threads: int
    vad_method: Literal["pyannote", "silero"]
    beam_size: int


@dataclass(frozen=True)
class TranscribeOptions:
    initial_prompt: str | None = None
    hotwords: str | None = None
    align: bool = False
    spelling: Literal["en-US", "en-GB"] = "en-US"
    format_lists: bool = False


@dataclass(frozen=True)
class TranscribeRequest:
    id: str
    sample_rate: int
    pcm_s16le_b64: str
    options: TranscribeOptions


@dataclass(frozen=True)
class ShutdownRequest:
    id: str


Request = StatusRequest | LoadModelRequest | TranscribeRequest | ShutdownRequest


def parse_request(line: str) -> Request:
    try:
        payload = json.loads(line)
    except json.JSONDecodeError as exc:
        raise ProtocolError("bad_request", f"invalid JSON: {exc.msg}") from exc
    if not isinstance(payload, dict):
        raise ProtocolError("bad_request", "request must be a JSON object")

    request_id = payload.get("id")
    if not isinstance(request_id, str) or not request_id:
        raise ProtocolError("bad_request", "request needs a non-empty string `id`")
    fields = _Fields(payload, request_id)

    op = payload.get("op")
    if op == "status":
        return StatusRequest(id=request_id)
    if op == "shutdown":
        return ShutdownRequest(id=request_id)
    if op == "load_model":
        vad_method = fields.string("vad_method")
        if vad_method not in VAD_METHODS:
            raise ProtocolError(
                "bad_request", f"`vad_method` must be one of {', '.join(VAD_METHODS)}", request_id
            )
        return LoadModelRequest(
            id=request_id,
            model=fields.string("model"),
            compute_type=fields.string("compute_type"),
            threads=fields.integer("threads", minimum=1, maximum=64),
            vad_method=vad_method,  # type: ignore[arg-type]
            beam_size=fields.integer("beam_size", minimum=1, maximum=10),
        )
    if op == "transcribe":
        raw_options = payload.get("options") or {}
        if not isinstance(raw_options, dict):
            raise ProtocolError("bad_request", "`options` must be an object", request_id)
        option_fields = _Fields(raw_options, request_id)
        spelling = raw_options.get("spelling", "en-US")
        if spelling not in SPELLINGS:
            raise ProtocolError("bad_request", f"`spelling` must be one of {', '.join(SPELLINGS)}", request_id)
        return TranscribeRequest(
            id=request_id,
            sample_rate=fields.integer("sample_rate", minimum=1, maximum=192_000),
            pcm_s16le_b64=fields.string("pcm_s16le_b64", allow_empty=True),
            options=TranscribeOptions(
                initial_prompt=option_fields.optional_string("initial_prompt"),
                hotwords=option_fields.optional_string("hotwords"),
                align=option_fields.boolean("align", default=False),
                spelling=spelling,
                format_lists=option_fields.boolean("format_lists", default=False),
            ),
        )
    if not isinstance(op, str):
        raise ProtocolError("bad_request", "request needs a string `op`", request_id)
    raise ProtocolError("unknown_op", f"unknown op `{op}`", request_id)


def success(request_id: str, result: dict[str, Any]) -> dict[str, Any]:
    return {"id": request_id, "ok": True, "result": result}


def failure(request_id: str | None, code: str, message: str) -> dict[str, Any]:
    return {"id": request_id, "ok": False, "error": {"code": code, "message": message}}


def event(name: str, **fields: Any) -> dict[str, Any]:
    return {"event": name, **fields}


class _Fields:
    def __init__(self, payload: dict[str, Any], request_id: str) -> None:
        self._payload = payload
        self._id = request_id

    def _fail(self, message: str) -> ProtocolError:
        return ProtocolError("bad_request", message, self._id)

    def string(self, name: str, *, allow_empty: bool = False) -> str:
        value = self._payload.get(name)
        if not isinstance(value, str) or (not allow_empty and not value):
            raise self._fail(f"`{name}` must be a non-empty string")
        return value

    def optional_string(self, name: str) -> str | None:
        value = self._payload.get(name)
        if value is None:
            return None
        if not isinstance(value, str):
            raise self._fail(f"`{name}` must be a string or null")
        return value.strip() or None

    def integer(self, name: str, *, minimum: int, maximum: int) -> int:
        value = self._payload.get(name)
        # bool is a subclass of int; reject it explicitly.
        if not isinstance(value, int) or isinstance(value, bool):
            raise self._fail(f"`{name}` must be an integer")
        if not minimum <= value <= maximum:
            raise self._fail(f"`{name}` must be between {minimum} and {maximum}")
        return value

    def boolean(self, name: str, *, default: bool) -> bool:
        value = self._payload.get(name, default)
        if not isinstance(value, bool):
            raise self._fail(f"`{name}` must be true or false")
        return value
