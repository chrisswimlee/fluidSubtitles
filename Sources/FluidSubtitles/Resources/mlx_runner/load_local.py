#!/usr/bin/env python3
"""Load a catalog model, an LM Studio folder, or any built MLX directory.

Uses Python 3.12. Do not use Homebrew python3 (3.14) — MLX does not run there.

  python3.12 load_local.py --setup
  python3.12 load_local.py --download
  python3.12 load_local.py --model ~/.lmstudio/models/lmstudio-community/gemma-4-31B-it-MLX-4bit
  python3.12 load_local.py --serve --model /path/to/mlx-folder
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import mlx_runner as runner


def cmd_prompt(model_id: str, prompt: str, max_tokens: int) -> int:
    runner.ensure_venv_runtime()
    spec = runner.resolve_spec(model_id)
    if not spec.get("path"):
        raise SystemExit(f"{spec['id']} is not on disk yet")
    path = Path(spec["path"])
    print(f"loading {path}", file=sys.stderr)
    config = json.loads((path / "config.json").read_text(encoding="utf-8"))
    model_type = str(config.get("model_type", ""))
    architectures = config.get("architectures") or []
    multimodal = model_type == "gemma4" or any("ConditionalGeneration" in str(item) for item in architectures)
    if multimodal:
        from mlx_vlm import generate, load
        from mlx_vlm.prompt_utils import apply_chat_template
        from mlx_vlm.utils import load_config

        model, processor = load(str(path))
        formatted = apply_chat_template(processor, load_config(str(path)), prompt, num_images=0)
        text = generate(model, processor, formatted, max_tokens=max_tokens)
    else:
        from mlx_lm import generate, load

        model, tokenizer = load(str(path))
        messages = [{"role": "user", "content": prompt}]
        formatted = tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
        text = generate(model, tokenizer, prompt=formatted, max_tokens=max_tokens)
    print(text if isinstance(text, str) else getattr(text, "text", text))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--setup", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--model", default="gemma4-e4b")
    parser.add_argument("--prompt")
    parser.add_argument("--max-tokens", type=int, default=80)
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    if args.setup:
        return runner.cmd_setup(args)
    if args.list:
        return runner.cmd_list(args)
    if args.download:
        args.force = args.force
        return runner.cmd_download(args)
    if args.serve:
        return runner.cmd_serve(args)
    if args.prompt:
        return cmd_prompt(args.model, args.prompt, args.max_tokens)
    return runner.cmd_resolve(args)


if __name__ == "__main__":
    raise SystemExit(main())
