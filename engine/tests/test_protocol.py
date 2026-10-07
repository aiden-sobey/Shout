import json

import numpy as np
import pytest

from shout_engine.audio import AudioError, decode_pcm_s16le_b64, duration_ms, encode_pcm_s16le_b64
from shout_engine.protocol import (
    LoadModelRequest,
    ProtocolError,
    ShutdownRequest,
    StatusRequest,
    TranscribeRequest,
    failure,
    parse_request,
    success,
)


def line(**fields) -> str:
    return json.dumps(fields)


class TestParseRequest:
    def test_status_and_shutdown(self):
        assert parse_request(line(id="1", op="status")) == StatusRequest(id="1")
        assert parse_request(line(id="2", op="shutdown")) == ShutdownRequest(id="2")

    def test_load_model(self):
        request = parse_request(
            line(id="3", op="load_model", model="small.en", compute_type="int8", threads=4, vad_method="pyannote", beam_size=5)
        )
        assert request == LoadModelRequest("3", "small.en", "int8", 4, "pyannote", 5)

    def test_transcribe_with_defaults(self):
        request = parse_request(line(id="4", op="transcribe", sample_rate=16000, pcm_s16le_b64="AAA="))
        assert isinstance(request, TranscribeRequest)
        assert request.options.align is False
        assert request.options.hotwords is None

    def test_blank_vocabulary_becomes_none(self):
        request = parse_request(
            line(id="5", op="transcribe", sample_rate=16000, pcm_s16le_b64="", options={"hotwords": "  ", "align": False})
        )
        assert request.options.hotwords is None

    @pytest.mark.parametrize(
        ("raw", "code"),
        [
            ("not json", "bad_request"),
            ("[1, 2]", "bad_request"),
            (line(op="status"), "bad_request"),  # no id
            (line(id="", op="status"), "bad_request"),
            (line(id="6", op="dance"), "unknown_op"),
            (line(id="7"), "bad_request"),  # no op
            (line(id="8", op="load_model", model="x", compute_type="int8", threads=0, vad_method="pyannote", beam_size=5), "bad_request"),
            (line(id="9", op="load_model", model="x", compute_type="int8", threads=True, vad_method="pyannote", beam_size=5), "bad_request"),
            (line(id="10", op="load_model", model="x", compute_type="int8", threads=4, vad_method="webrtc", beam_size=5), "bad_request"),
            (line(id="11", op="transcribe", sample_rate=16000, pcm_s16le_b64="", options={"align": "yes"}), "bad_request"),
        ],
    )
    def test_rejects(self, raw, code):
        with pytest.raises(ProtocolError) as caught:
            parse_request(raw)
        assert caught.value.code == code

    def test_error_keeps_the_request_id_when_known(self):
        with pytest.raises(ProtocolError) as caught:
            parse_request(line(id="12", op="dance"))
        assert caught.value.request_id == "12"


def test_response_shapes():
    assert success("1", {"a": 1}) == {"id": "1", "ok": True, "result": {"a": 1}}
    assert failure(None, "bad_request", "nope") == {
        "id": None,
        "ok": False,
        "error": {"code": "bad_request", "message": "nope"},
    }


class TestAudio:
    def test_round_trip(self):
        audio = np.array([0.0, 0.5, -0.5, 0.25], dtype=np.float32)
        decoded = decode_pcm_s16le_b64(encode_pcm_s16le_b64(audio), 16000)
        assert decoded.dtype == np.float32
        np.testing.assert_allclose(decoded, audio, atol=1 / 32768)

    def test_full_scale_values(self):
        decoded = decode_pcm_s16le_b64(encode_pcm_s16le_b64(np.array([1.0, -1.0], dtype=np.float32)), 16000)
        assert decoded.min() >= -1.0 and decoded.max() < 1.0

    def test_wrong_sample_rate(self):
        with pytest.raises(AudioError):
            decode_pcm_s16le_b64("AAA=", 44100)

    def test_bad_base64(self):
        with pytest.raises(AudioError):
            decode_pcm_s16le_b64("not base64!!", 16000)

    def test_odd_byte_count(self):
        with pytest.raises(AudioError):
            decode_pcm_s16le_b64("AAAA", 16000)  # 3 bytes

    def test_duration(self):
        assert duration_ms(np.zeros(16000, dtype=np.float32)) == 1000
