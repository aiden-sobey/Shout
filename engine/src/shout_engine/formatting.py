"""Light formatting for dictated text: put spoken numbered lists on separate lines.

    "Okay let's 1, enable it for no one but ship it. 2, test it out. 3, enable the flag."
    →
    "Okay let's:
    1. Enable it for no one but ship it.
    2. Test it out.
    3. Enable the flag."

A list is only recognised when the numbers count up from 1 in order (at least 1 and 2),
each written as a digit or number word followed by `,` `.` `:` or `)` and a space, and every
item has at least two words. That keeps ordinary sentences ("one, maybe two options",
"meet at 1. Then 2.") untouched. Only the first list in the text is formatted.

Any lead-in text gets its own line ending in a colon, so it introduces the list.
"""

from __future__ import annotations

import re

_WORDS = ("one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten")
_VALUES = {word: index + 1 for index, word in enumerate(_WORDS)}

# A number at the start of the text or after whitespace, then list punctuation, then a space.
_MARKER = re.compile(
    r"(?:(?<=\s)|^)(?P<number>\d{1,2}|" + "|".join(_WORDS) + r")[,.:)]\s+",
    re.IGNORECASE,
)

MIN_ITEM_WORDS = 2

# Lead-in punctuation that gives way to the colon ("Here's the plan." → "Here's the plan:").
# Question and exclamation marks are kept: they already end the lead-in naturally.
_REPLACEABLE_ENDINGS = ",.;…-–—"
_KEPT_ENDINGS = ":?!"


def format_numbered_list(text: str) -> str:
    markers = [(m, _value(m.group("number"))) for m in _MARKER.finditer(text)]
    for start_index, (first, value) in enumerate(markers):
        if value != 1:
            continue
        chain = [first]
        for marker, number in markers[start_index + 1 :]:
            if number == len(chain) + 1:
                chain.append(marker)
        if len(chain) < 2:
            continue
        items = _items(text, chain)
        if all(len(item.split()) >= MIN_ITEM_WORDS for item in items):
            lead = _introduce(text[: first.start()])
            lines = [f"{index}. {_capitalise(item)}" for index, item in enumerate(items, start=1)]
            return "\n".join([lead, *lines] if lead else lines)
    return text


def _introduce(lead: str) -> str:
    """The text before the list, ending in a colon (empty if there's no lead-in)."""
    lead = lead.rstrip().rstrip(_REPLACEABLE_ENDINGS).rstrip()
    if not lead or lead.endswith(tuple(_KEPT_ENDINGS)):
        return lead
    return lead + ":"


def _value(token: str) -> int:
    return int(token) if token.isdigit() else _VALUES[token.lower()]


def _items(text: str, chain: list[re.Match[str]]) -> list[str]:
    ends = [marker.start() for marker in chain[1:]] + [len(text)]
    return [text[marker.end() : end].strip() for marker, end in zip(chain, ends)]


def _capitalise(item: str) -> str:
    return item[0].upper() + item[1:] if item and item[0].islower() else item
