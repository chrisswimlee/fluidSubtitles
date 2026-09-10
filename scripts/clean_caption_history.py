#!/usr/bin/env python3
"""Clean Theater caption history for Korean, English, and Thai via a local MLX model.

Default model is Gemma 3 12B (text, 4-bit). That family is trained for 140+
languages and is the best small MLX fit for all three of fluidSubtitles'
languages. Qwen is stronger on Korean than Thai; do not use it here.

  python3 scripts/clean_caption_history.py --dry-run
  python3 scripts/clean_caption_history.py --limit 8 --out /tmp/cleaned.jsonl
  python3 scripts/clean_caption_history.py --fast
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
from pathlib import Path

DEFAULT_DB = (
    Path.home()
    / "Library/Application Support/fluidSubtitles/TranscriptionHistory.sqlite3"
)
CATALOG_PATH = (
    Path(__file__).resolve().parents[1]
    / "Sources/FluidSubtitles/Resources/mlx_runner/catalog.json"
)


def load_catalog() -> dict:
    return json.loads(CATALOG_PATH.read_text(encoding="utf-8"))


def resolve_model_repo(value: str) -> str:
    if CATALOG_PATH.is_file():
        for model in load_catalog()["models"]:
            if model["id"] == value or model["repo"] == value:
                return model["repo"]
    return value


HANGUL = re.compile(r"[\uac00-\ud7a3]")
THAI = re.compile(r"[\u0e00-\u0e7f]")
LATIN = re.compile(r"[A-Za-z]")
SENTENCE_SPLIT = re.compile(r"(?<=[.!?。？！])\s+|(?<=\n)")
FILLER = re.compile(
    r"^\s*(stop|스탑|หยุด)\s*[.!]?\s*$",
    re.IGNORECASE,
)
SPACE = re.compile(r"\s+")

SYSTEM_PROMPT = """You clean live captions among Korean, English, and Thai only.

The input is a spoken source line and its machine translation. Both may contain
ASR restarts, duplicate drafts, leftover "Stop", and broken endings.

Return JSON only, no markdown:
{"source_lang":"ko|en|th","target_lang":"ko|en|th","source":"...","target":"...","ok":true}

Rules:
- Use Korean, English, or Thai only. Never introduce another language.
- Keep the speaker's last intended wording. Drop restarts and "Stop".
- Do not answer questions. Do not add facts, names, or a nicer translation.
- Korean: keep 반말 vs 존댓말 from the source. Complete a broken ending only when a later restart already said the full form (지내십니 → 지내십니까).
- Thai: keep ครับ/ค่ะ/คะ if present; do not invent polite particles. Keep tone marks.
- English: normal caption punctuation and capitalization.
- If the source is unrecoverable, set ok=false and copy the pre-cleaned text unchanged.
"""


def detect_lang(text: str) -> str:
    hangul = len(HANGUL.findall(text))
    thai = len(THAI.findall(text))
    latin = len(LATIN.findall(text))
    total = hangul + thai + latin
    if total == 0:
        return "und"
    scores = {"ko": hangul, "th": thai, "en": latin}
    lang, count = max(scores.items(), key=lambda item: item[1])
    if count / total < 0.45:
        return "und"
    return lang


def _norm(text: str) -> str:
    text = SPACE.sub(" ", text).strip().lower()
    return re.sub(r"[.!?。？！,，、]", "", text)


def collapse_restarts(text: str) -> str:
    raw = SPACE.sub(" ", text).strip()
    if not raw:
        return ""
    parts = [part.strip() for part in SENTENCE_SPLIT.split(raw) if part.strip()]
    if len(parts) <= 1:
        parts = [raw]
    kept: list[str] = []
    for part in parts:
        if FILLER.match(part):
            continue
        normalized = _norm(part)
        if not normalized:
            continue
        replaced = False
        for index, previous in enumerate(kept):
            previous_norm = _norm(previous)
            if normalized == previous_norm or normalized.startswith(previous_norm) or previous_norm.startswith(normalized):
                kept[index] = part if len(normalized) >= len(previous_norm) else previous
                replaced = True
                break
        if not replaced:
            kept.append(part)
    return SPACE.sub(" ", " ".join(kept)).strip()


def load_history(db_path: Path) -> list[dict]:
    connection = sqlite3.connect(db_path)
    connection.row_factory = sqlite3.Row
    rows = []
    for row in connection.execute(
        "SELECT id, timestamp, app_name, payload FROM history ORDER BY timestamp"
    ):
        payload = json.loads(row["payload"])
        source = (payload.get("rawText") or "").strip()
        target = (payload.get("processedText") or "").strip()
        if not source and not target:
            continue
        rows.append(
            {
                "id": row["id"],
                "timestamp": row["timestamp"],
                "app": row["app_name"] or payload.get("appName") or "",
                "window": payload.get("windowTitle") or "",
                "source": source,
                "target": target,
            }
        )
    return rows


def preclean(row: dict) -> dict:
    source = collapse_restarts(row["source"])
    target = collapse_restarts(row["target"])
    return {
        **row,
        "source": source,
        "target": target,
        "source_lang": detect_lang(source),
        "target_lang": detect_lang(target),
    }


def user_prompt(row: dict) -> str:
    return (
        f"source_lang_guess: {row['source_lang']}\n"
        f"target_lang_guess: {row['target_lang']}\n"
        f"source: {row['source']}\n"
        f"target: {row['target']}"
    )


def extract_json(text: str) -> dict:
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("model did not return JSON")
    return json.loads(text[start : end + 1])


def generate_clean(model, tokenizer, row: dict) -> dict:
    from mlx_lm import generate

    messages = [
        {"role": "user", "content": f"{SYSTEM_PROMPT}\n\n{user_prompt(row)}"},
    ]
    prompt = tokenizer.apply_chat_template(
        messages, add_generation_prompt=True, tokenize=False
    )
    try:
        from mlx_lm.sample_utils import make_sampler

        raw = generate(
            model,
            tokenizer,
            prompt=prompt,
            max_tokens=256,
            sampler=make_sampler(temp=0.0),
        )
    except TypeError:
        raw = generate(model, tokenizer, prompt=prompt, max_tokens=256, temp=0.0)
    cleaned = extract_json(raw)
    source_lang = cleaned.get("source_lang")
    target_lang = cleaned.get("target_lang")
    if source_lang not in {"ko", "en", "th"} or target_lang not in {"ko", "en", "th"}:
        raise ValueError(f"unsupported language pair {source_lang}->{target_lang}")
    return cleaned


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--out", type=Path)
    parser.add_argument(
        "--model",
        default="gemma3-12b",
        help="catalog id (gemma4-e2b, gemma4-26b-a4b, gemma3-12b, ...) or an mlx-community repo",
    )
    parser.add_argument(
        "--fast",
        action="store_true",
        help="use gemma3-4b instead of the selected model",
    )
    parser.add_argument("--limit", type=int)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="collapse restarts only; do not load a model",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if not args.db.exists():
        print(f"history not found: {args.db}", file=sys.stderr)
        return 1
    rows = [preclean(row) for row in load_history(args.db)]
    if args.limit:
        rows = rows[: args.limit]
    if args.dry_run:
        for row in rows:
            print(json.dumps(row, ensure_ascii=False))
        return 0

    from mlx_lm import load

    model_id = resolve_model_repo("gemma3-4b" if args.fast else args.model)
    print(f"loading {model_id}", file=sys.stderr)
    model, tokenizer = load(model_id)

    handle = args.out.open("w", encoding="utf-8") if args.out else sys.stdout
    try:
        for row in rows:
            try:
                cleaned = generate_clean(model, tokenizer, row)
            except Exception as error:
                cleaned = {
                    "source_lang": row["source_lang"],
                    "target_lang": row["target_lang"],
                    "source": row["source"],
                    "target": row["target"],
                    "ok": False,
                    "error": str(error),
                }
            record = {**row, **cleaned}
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
            handle.flush()
    finally:
        if args.out:
            handle.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
