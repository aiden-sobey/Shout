"""American → British spelling for transcripts.

The Whisper `.en` models write American spelling ("recognize", "color"). This swaps words
using breame's American→British dictionary, keeping each word's capitalisation.

Words whose British spelling depends on meaning are left alone, because swapping them
blindly is wrong as often as it's right:

- meter: "metre" is the unit, but a measuring device is still a "meter" (smart meter).
- program: "programme" is TV/events, but software is a "program" (and Australian usage
  mostly keeps "program").
- license, practice: British uses "licence"/"practice" for the noun and
  "license"/"practise" for the verb ("licensed", never "licenced").
- draft (documents stay "draft"), disk (computer disks), dialog (dialog boxes),
  ton (a ton is not a tonne), tire ("to tire"), install ("instal" is rare in British use).
"""

from __future__ import annotations

import re

from breame.spelling import american_spelling_exists, get_british_spelling

SPELLINGS = ("en-US", "en-GB")

CONTEXT_DEPENDENT = frozenset(
    {
        "meter", "meters",
        "program", "programs",
        "license", "licensed", "licenses", "licensing",
        "practice", "practiced", "practices", "practicing",
        "draft", "drafts",
        "disk", "disks",
        "dialog", "dialogs",
        "ton", "tons",
        "tire", "tires",
        "install", "installs",
    }
)

_WORD = re.compile(r"[A-Za-z]+")


def to_british(text: str) -> str:
    return _WORD.sub(_convert, text)


def apply(text: str, spelling: str) -> str:
    return to_british(text) if spelling == "en-GB" else text


def _convert(match: re.Match[str]) -> str:
    word = match.group(0)
    lower = word.lower()
    if lower in CONTEXT_DEPENDENT or not american_spelling_exists(lower):
        return word
    return _match_case(word, get_british_spelling(lower))


def _match_case(original: str, replacement: str) -> str:
    if original.isupper() and len(original) > 1:
        return replacement.upper()
    if original[0].isupper():
        return replacement[0].upper() + replacement[1:]
    return replacement
