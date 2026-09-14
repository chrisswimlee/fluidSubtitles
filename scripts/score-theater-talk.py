#!/usr/bin/env python3
"""Score a Theater talk against a reference JSONL. Same 15% bar as TheaterQualityScore.

Each line is one JSON object: languageID, reference, hypothesis.
See docs/STAGE_SCORE.md for a three-line English plus Korean layout example.
Do not check in a real talk or invented WER.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


STAGE_ACCEPTABLE = 0.15
COMPACT = {"ko", "th", "ja", "zh"}


def language_code(language_id: str) -> str:
    return (language_id or "en").split("-")[0].lower()


def tokens(text: str) -> list[str]:
    return [part for part in re.split(r"[\s\W]+", text.lower()) if part]


def folded_letters(text: str) -> list[str]:
    return [character for character in text.lower() if character.isalnum()]


def edit_distance(left: list[str], right: list[str]) -> int:
    if not left:
        return len(right)
    if not right:
        return len(left)
    previous = list(range(len(right) + 1))
    current = [0] * (len(right) + 1)
    for i, left_item in enumerate(left):
        current[0] = i + 1
        for j, right_item in enumerate(right):
            cost = 0 if left_item == right_item else 1
            current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + cost)
        previous, current = current, previous
    return previous[len(right)]


def error_rate(reference: str, hypothesis: str, language_id: str) -> float:
    if language_code(language_id) in COMPACT:
        left = folded_letters(reference)
        right = folded_letters(hypothesis)
    else:
        left = tokens(reference)
        right = tokens(hypothesis)
    if not left:
        return 0.0 if not right else 1.0
    return edit_distance(left, right) / len(left)


def load_lines(path: Path) -> list[dict]:
    rows = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        rows.append(json.loads(line))
    return rows


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: score-theater-talk.py reference.jsonl [LastListenLatency.json]", file=sys.stderr)
        return 2
    rows = load_lines(Path(sys.argv[1]))
    if not rows:
        print("no lines", file=sys.stderr)
        return 1
    errors = []
    shown = True
    for row in rows:
        language_id = row.get("languageID") or row.get("language_id") or "en"
        rate = error_rate(row["reference"], row["hypothesis"], language_id)
        errors.append(rate)
        if rate > STAGE_ACCEPTABLE:
            shown = False
        print(f"{rate:.3f}  {language_id}  {row['reference'][:48]}")
    mean = sum(errors) / len(errors)
    print(f"mean={mean:.3f} would_show={str(shown).lower()} lines={len(errors)}")
    if len(sys.argv) > 2:
        latency = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
        print(
            "latency "
            f"e2e={latency.get('endToEndMilliseconds')} "
            f"mt={latency.get('machineTranslationMilliseconds')}"
        )
    return 0 if shown else 1


if __name__ == "__main__":
    raise SystemExit(main())
