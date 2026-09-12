#!/usr/bin/env python3
"""Print the CHANGELOG section for a git tag, or [Unreleased] as a fallback."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def section(text: str, heading: str) -> str:
    pattern = re.compile(rf"^## {re.escape(heading)}(?:\s|$).*", re.MULTILINE)
    match = pattern.search(text)
    if match is None:
        return ""
    start = match.end()
    next_heading = re.search(r"^## ", text[start:], re.MULTILINE)
    end = start + next_heading.start() if next_heading else len(text)
    return text[start:end].strip()


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: extract-changelog.py vX.Y.Z", file=sys.stderr)
        return 2
    tag = sys.argv[1].strip()
    version = tag[1:] if tag.startswith("v") else tag
    text = Path("CHANGELOG.md").read_text(encoding="utf-8")
    notes = section(text, f"[{version}]") or section(text, "[Unreleased]")
    if not notes:
        return 1
    print(notes)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
