import json

import pytest

from shout_engine.formatting import format_numbered_list
from shout_engine.protocol import parse_request


def test_the_example_from_shout():
    text = "Okay let's 1, enable it for no one but ship it. 2, test it out. 3, enable the feature flag for all."
    assert format_numbered_list(text) == (
        "Okay let's:\n"
        "1. Enable it for no one but ship it.\n"
        "2. Test it out.\n"
        "3. Enable the feature flag for all."
    )


def test_number_words_and_other_punctuation():
    text = "Agenda: One. Review the numbers. Two: agree the plan. Three) book the room."
    assert format_numbered_list(text) == (
        "Agenda:\n1. Review the numbers.\n2. Agree the plan.\n3. Book the room."
    )


@pytest.mark.parametrize(
    ("lead", "expected"),
    [
        ("Here's the plan.", "Here's the plan:"),
        ("Okay, so,", "Okay, so:"),
        ("The steps are…", "The steps are:"),
        ("What should we do?", "What should we do?"),
        ("Do this now!", "Do this now!"),
        ("Agenda:", "Agenda:"),
    ],
)
def test_lead_in_ends_with_a_colon(lead, expected):
    formatted = format_numbered_list(f"{lead} 1, write the code. 2, ship the code.")
    assert formatted.split("\n")[0] == expected


def test_list_without_lead_in():
    assert format_numbered_list("1, buy milk please. 2, call mum back.") == "1. Buy milk please.\n2. Call mum back."


@pytest.mark.parametrize(
    "text",
    [
        "I have one, maybe two options.",  # items too short
        "Meet at 1. Then at 2. Done.",  # last item is one word
        "We shipped version 2, which fixed it, then 3, which broke it again.",  # doesn't start at 1
        "The ratio is 1.5 to 2.5 overall.",  # decimals aren't markers
        "Just a normal sentence with no list at all.",
        "1, only one item here and nothing else.",  # needs at least two items
        "Step 1 is ready and step 2 is not.",  # no list punctuation
    ],
)
def test_leaves_ordinary_text_alone(text):
    assert format_numbered_list(text) == text


def test_out_of_order_numbers_skip_to_the_next_in_sequence():
    text = "Plan: 1, write the code. 3, oops wrong. 2, review the change."
    # 1 and 2 form the list; the stray 3 stays inside item 1.
    assert format_numbered_list(text) == "Plan:\n1. Write the code. 3, oops wrong.\n2. Review the change."


def test_protocol_option_defaults_off():
    base = {"id": "1", "op": "transcribe", "sample_rate": 16000, "pcm_s16le_b64": ""}
    assert parse_request(json.dumps(base)).options.format_lists is False
    on = parse_request(json.dumps({**base, "options": {"format_lists": True}}))
    assert on.options.format_lists is True
