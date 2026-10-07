import json

import pytest

from shout_engine.protocol import ProtocolError, parse_request
from shout_engine.spelling import apply, to_british


@pytest.mark.parametrize(
    ("american", "british"),
    [
        ("I recognize the color of the organization.", "I recognise the colour of the organisation."),
        ("We should analyze their behavior.", "We should analyse their behaviour."),
        ("It's my favorite center for traveling.", "It's my favourite centre for travelling."),
        ("Twelve kilometers away.", "Twelve kilometres away."),
    ],
)
def test_converts_common_american_spellings(american, british):
    assert to_british(american) == british


def test_keeps_capitalisation():
    assert to_british("Recognize RECOGNIZE recognize") == "Recognise RECOGNISE recognise"


def test_handles_punctuation_and_possessives():
    assert to_british("the organization's (color)!") == "the organisation's (colour)!"
    assert to_british("re-organize") == "re-organise"


@pytest.mark.parametrize(
    "unchanged",
    [
        "Install the smart meter program.",
        "She is licensed to practice law.",
        "Send me the draft by Friday.",
        "Save it to disk, then close the dialog.",
        "It weighs a ton and the tires are flat.",
    ],
)
def test_leaves_meaning_dependent_words_alone(unchanged):
    assert to_british(unchanged) == unchanged


def test_british_and_unrelated_text_is_untouched():
    text = "The colour of the programme was grey. Gridsight DNSP 2026."
    assert to_british(text) == text


def test_apply_respects_setting():
    assert apply("color", "en-US") == "color"
    assert apply("color", "en-GB") == "colour"


def test_protocol_defaults_to_us_and_validates():
    base = {"id": "1", "op": "transcribe", "sample_rate": 16000, "pcm_s16le_b64": ""}
    assert parse_request(json.dumps(base)).options.spelling == "en-US"
    gb = parse_request(json.dumps({**base, "options": {"spelling": "en-GB"}}))
    assert gb.options.spelling == "en-GB"
    with pytest.raises(ProtocolError) as caught:
        parse_request(json.dumps({**base, "options": {"spelling": "en-AU"}}))
    assert caught.value.code == "bad_request"
