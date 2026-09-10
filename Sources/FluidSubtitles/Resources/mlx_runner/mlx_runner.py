#!/usr/bin/env python3
"""Local MLX runner for fluidSubtitles Korean / English / Thai caption cleanup.

Accepts a catalog id, a Hugging Face repo, an LM Studio folder, or any built
MLX directory that contains config.json.

  python3.12 mlx_runner.py setup
  python3.12 mlx_runner.py list
  python3.12 mlx_runner.py status
  python3.12 mlx_runner.py resolve ~/.lmstudio/models/lmstudio-community/gemma-4-31B-it-MLX-4bit
  python3.12 mlx_runner.py use /path/to/mlx-model
  python3.12 mlx_runner.py download gemma4-e4b
  python3.12 mlx_runner.py serve --model gemma4-e4b
  python3.12 mlx_runner.py stop
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
CATALOG_PATH = Path(os.environ.get("FLUID_MLX_CATALOG", SCRIPT_DIR / "catalog.json"))
STATE_DIR = Path.home() / "Library/Application Support/fluidSubtitles/MLXRunner"
MODELS_DIR = STATE_DIR / "Models"
STATE_PATH = STATE_DIR / "state.json"
PID_PATH = STATE_DIR / "server.pid"
VENV = STATE_DIR / "venv"
PYTHON312 = Path("/opt/homebrew/bin/python3.12")
LM_STUDIO_MODELS = Path.home() / ".lmstudio/models"
HF_REPO_RE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
SERVER_MARKERS = ("mlx_lm.server", "mlx_vlm.server", "mlx_runner.py serve")


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def venv_python() -> Path:
    return VENV / "bin" / "python3"


def load_catalog() -> dict:
    return json.loads(CATALOG_PATH.read_text(encoding="utf-8"))


def expand_path(raw: str) -> Path:
    return Path(raw).expanduser().resolve()


def looks_like_mlx(folder: Path) -> bool:
    if not (folder / "config.json").is_file():
        return False
    names = []
    try:
        names = [item.name.lower() for item in folder.iterdir() if item.is_file()]
    except OSError:
        return False
    has_weights = any(
        name.endswith((".safetensors", ".npz"))
        or name.endswith(".safetensors.index.json")
        or name in {"weights.npz", "model.safetensors"}
        for name in names
    )
    has_gguf = any(name.endswith(".gguf") for name in names)
    if has_weights:
        return True
    try:
        config = json.loads((folder / "config.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    if isinstance(config.get("quantization"), dict):
        return True
    return not has_gguf


def mlx_folder(raw: str | Path) -> Path | None:
    path = expand_path(str(raw))
    if path.is_file():
        path = path.parent
    if looks_like_mlx(path):
        return path
    return None


def hugging_face_repo(raw: str) -> str | None:
    value = raw.strip().strip("\"'")
    if value.startswith("hf:"):
        value = value[3:]
    parsed = urlparse(value)
    if parsed.scheme in {"http", "https"} and parsed.netloc in {
        "huggingface.co",
        "www.huggingface.co",
        "hf.co",
        "www.hf.co",
    }:
        parts = [part for part in parsed.path.split("/") if part and part not in {"tree", "blob", "resolve"}]
        if len(parts) >= 2:
            value = f"{parts[0]}/{parts[1]}"
    if HF_REPO_RE.fullmatch(value):
        return value
    return None


def catalog_by_id() -> dict[str, dict]:
    return {model["id"]: model for model in load_catalog()["models"]}


def catalog_match(*, model_id: str | None = None, repo: str | None = None, path: Path | None = None) -> dict | None:
    for model in load_catalog()["models"]:
        if model_id and model["id"] == model_id:
            return model
        if repo and model.get("repo") == repo:
            return model
        if path is None:
            continue
        candidates = [MODELS_DIR / model["id"], *[Path(hint).expanduser() for hint in model.get("local_hints") or []]]
        for candidate in candidates:
            try:
                if candidate.exists() and candidate.resolve() == path.resolve():
                    return model
            except OSError:
                continue
    return None


def make_local_model(folder: Path, source: str) -> dict:
    relative = None
    try:
        if LM_STUDIO_MODELS in folder.parents or folder == LM_STUDIO_MODELS:
            relative = str(folder.relative_to(LM_STUDIO_MODELS))
    except ValueError:
        relative = None
    name = relative or folder.name
    return {
        "id": f"local:{folder}",
        "name": name,
        "repo": str(folder),
        "size": "On disk",
        "ram_gb": 0,
        "quality": "lmstudio" if source == "lmstudio" else "local",
        "languages": ["ko", "en", "th"],
        "recommended": False,
        "detail": (
            "Already downloaded in LM Studio. The runner uses this folder as-is."
            if source == "lmstudio"
            else "Built MLX folder on this Mac. The runner uses this folder as-is."
        ),
        "local_hints": [str(folder)],
        "source": source,
    }


def discover_lmstudio() -> list[dict]:
    if not LM_STUDIO_MODELS.is_dir():
        return []
    found: list[dict] = []
    seen: set[str] = set()
    for dirpath, dirnames, filenames in os.walk(LM_STUDIO_MODELS):
        rel = Path(dirpath).relative_to(LM_STUDIO_MODELS)
        if len(rel.parts) > 4:
            dirnames.clear()
            continue
        if "config.json" not in filenames:
            continue
        folder = Path(dirpath)
        if not looks_like_mlx(folder):
            continue
        if catalog_match(path=folder):
            continue
        key = str(folder)
        if key in seen:
            continue
        seen.add(key)
        found.append(make_local_model(folder, "lmstudio"))
        dirnames.clear()
    found.sort(key=lambda item: item["name"].lower())
    return found


def read_state() -> dict:
    catalog = load_catalog()
    if not STATE_PATH.is_file():
        return {
            "selected": catalog["default_model_id"],
            "port": catalog["default_port"],
            "custom_models": [],
        }
    state = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    state.setdefault("selected", catalog["default_model_id"])
    state.setdefault("port", catalog["default_port"])
    state.setdefault("custom_models", [])
    return state


def write_state(state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")


def remember_custom(model: dict) -> None:
    if model.get("source") == "catalog":
        return
    state = read_state()
    models = [item for item in state.get("custom_models") or [] if item.get("id") != model["id"]]
    models.append({key: model[key] for key in (
        "id", "name", "repo", "size", "ram_gb", "quality", "languages",
        "recommended", "detail", "local_hints", "source",
    ) if key in model})
    state["custom_models"] = models
    write_state(state)


def resolve_model_path(model: dict) -> Path | None:
    managed = MODELS_DIR / model["id"]
    if looks_like_mlx(managed):
        return managed
    safe = re.sub(r"[^A-Za-z0-9._-]+", "--", model["id"]).strip("-")
    managed_safe = MODELS_DIR / safe
    if looks_like_mlx(managed_safe):
        return managed_safe
    for hint in model.get("local_hints") or []:
        folder = mlx_folder(hint)
        if folder is not None:
            return folder
    if model.get("source") in {"local", "lmstudio"}:
        folder = mlx_folder(model.get("repo") or "")
        if folder is not None:
            return folder
    return None


def spec_from_catalog(model: dict) -> dict:
    path = resolve_model_path(model)
    return {
        **model,
        "source": model.get("source") or "catalog",
        "kind": "catalog",
        "installed": path is not None,
        "path": str(path) if path else None,
    }


def resolve_spec(raw: str | None) -> dict:
    catalog = load_catalog()
    value = (raw or "").strip().strip("\"'")
    if not value:
        return spec_from_catalog(catalog_by_id()[catalog["default_model_id"]])

    by_id = catalog_match(model_id=value)
    if by_id:
        return spec_from_catalog(by_id)

    if value.startswith("local:"):
        folder = mlx_folder(value[6:]) or expand_path(value[6:])
        matched = catalog_match(path=folder) if folder.exists() else None
        if matched:
            return spec_from_catalog(matched)
        source = "lmstudio" if LM_STUDIO_MODELS in folder.parents or folder == LM_STUDIO_MODELS else "local"
        model = make_local_model(folder, source)
        path = folder if looks_like_mlx(folder) else None
        return {**model, "kind": source, "installed": path is not None, "path": str(path) if path else None}

    repo = hugging_face_repo(value)
    if repo:
        matched = catalog_match(repo=repo)
        if matched:
            return spec_from_catalog(matched)
        model = {
            "id": f"hf:{repo}",
            "name": repo,
            "repo": repo,
            "size": "Hugging Face",
            "ram_gb": 0,
            "quality": "custom",
            "languages": ["ko", "en", "th"],
            "recommended": False,
            "detail": "Pasted Hugging Face MLX repo. Download it, then Start.",
            "local_hints": [],
            "source": "huggingface",
        }
        path = resolve_model_path(model)
        return {**model, "kind": "huggingface", "installed": path is not None, "path": str(path) if path else None}

    maybe_path = expand_path(value)
    if value.startswith(("/", "~")) or maybe_path.exists():
        folder = mlx_folder(maybe_path) or maybe_path
        matched = catalog_match(path=folder) if folder.exists() else None
        if matched:
            return spec_from_catalog(matched)
        source = "lmstudio" if LM_STUDIO_MODELS in folder.parents or folder == LM_STUDIO_MODELS else "local"
        model = make_local_model(folder, source)
        path = folder if looks_like_mlx(folder) else None
        return {**model, "kind": source, "installed": path is not None, "path": str(path) if path else None}

    emit({"ok": False, "error": f"unknown model: {value}"})
    raise SystemExit(1)


def known_models(selected: str) -> list[dict]:
    rows: list[dict] = []
    seen: set[str] = set()

    def add(model: dict) -> None:
        spec = resolve_spec(model["id"]) if "id" in model else model
        if spec["id"] in seen:
            return
        seen.add(spec["id"])
        rows.append(
            {
                **{key: spec[key] for key in spec if key not in {"kind"}},
                "selected": spec["id"] == selected,
            }
        )

    for model in load_catalog()["models"]:
        add(model)
    for model in read_state().get("custom_models") or []:
        add(model)
    for model in discover_lmstudio():
        add(model)
    return rows


def read_pid_info() -> dict | None:
    if not PID_PATH.is_file():
        return None
    text = PID_PATH.read_text(encoding="utf-8").strip()
    if not text:
        return None
    try:
        payload = json.loads(text)
        if isinstance(payload, dict) and payload.get("pid"):
            return payload
    except json.JSONDecodeError:
        pass
    try:
        return {"pid": int(text)}
    except ValueError:
        return None


def write_pid_info(info: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    PID_PATH.write_text(json.dumps(info) + "\n", encoding="utf-8")


def process_command(pid: int) -> str:
    try:
        return subprocess.check_output(["ps", "-p", str(pid), "-o", "command="], text=True).strip()
    except subprocess.CalledProcessError:
        return ""


def is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def is_our_server(pid: int) -> bool:
    command = process_command(pid)
    return any(marker in command for marker in SERVER_MARKERS)


def running_info() -> dict | None:
    info = read_pid_info()
    if info is None:
        return None
    pid = int(info["pid"])
    if not is_alive(pid) or not is_our_server(pid):
        PID_PATH.unlink(missing_ok=True)
        return None
    return info


def port_in_use(port: int) -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(0.2)
    try:
        return sock.connect_ex(("127.0.0.1", port)) == 0
    finally:
        sock.close()


def send_signal(pid: int, pgid: int | None, sig: int) -> None:
    try:
        if pgid:
            os.killpg(pgid, sig)
            return
    except OSError:
        pass
    try:
        os.kill(pid, sig)
    except OSError:
        pass


def stop_server(timeout: float = 8.0) -> dict:
    info = read_pid_info()
    if info is None:
        return {"ok": True, "stopped": False}
    pid = int(info["pid"])
    pgid = int(info["pgid"]) if info.get("pgid") else None
    if not is_alive(pid):
        PID_PATH.unlink(missing_ok=True)
        return {"ok": True, "stopped": False, "stale": True}
    if not is_our_server(pid):
        PID_PATH.unlink(missing_ok=True)
        return {"ok": True, "stopped": False, "stale": True, "foreign": True}

    send_signal(pid, pgid, signal.SIGTERM)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not is_alive(pid):
            PID_PATH.unlink(missing_ok=True)
            return {"ok": True, "stopped": True, "pid": pid}
        time.sleep(0.1)
    send_signal(pid, pgid, signal.SIGKILL)
    time.sleep(0.2)
    PID_PATH.unlink(missing_ok=True)
    return {"ok": True, "stopped": True, "pid": pid, "killed": True}


def ensure_venv_runtime() -> None:
    current = Path(sys.executable).resolve()
    target = venv_python()
    if target.is_file() and current == target.resolve():
        return
    if target.is_file():
        os.execv(str(target), [str(target), *sys.argv])
    emit(
        {
            "ok": False,
            "error": (
                "MLX is not installed yet. Use Install MLX runtime in the app, or:\n"
                f"  /opt/homebrew/bin/python3.12 {SCRIPT_DIR / 'mlx_runner.py'} setup"
            ),
        }
    )
    raise SystemExit(1)


def dependency_error(need_vlm: bool = False) -> str | None:
    try:
        import huggingface_hub  # noqa: F401
        import mlx_lm  # noqa: F401
    except ImportError:
        return f"/opt/homebrew/bin/python3.12 {SCRIPT_DIR / 'mlx_runner.py'} setup"
    if need_vlm:
        try:
            import mlx_vlm  # noqa: F401
        except ImportError:
            return "This model needs mlx-vlm. Run Install MLX runtime again."
    return None


def is_multimodal(folder: Path) -> bool:
    try:
        config = json.loads((folder / "config.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    model_type = str(config.get("model_type", "")).lower()
    architectures = [str(item) for item in (config.get("architectures") or [])]
    if any("ConditionalGeneration" in item for item in architectures):
        return True
    return model_type == "gemma4"


def server_module(folder: Path) -> str:
    return "mlx_vlm.server" if is_multimodal(folder) else "mlx_lm.server"


def cmd_setup(_: argparse.Namespace) -> int:
    if not PYTHON312.is_file():
        emit({"ok": False, "error": "Need Homebrew Python 3.12: brew install python@3.12"})
        return 1
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if not venv_python().is_file():
        subprocess.check_call([str(PYTHON312), "-m", "venv", str(VENV)])
    subprocess.check_call(
        [str(venv_python()), "-m", "pip", "install", "-U", "pip", "mlx-lm", "mlx-vlm", "huggingface_hub"]
    )
    emit({"ok": True, "python": str(venv_python()), "venv": str(VENV)})
    return 0


def cmd_list(_: argparse.Namespace) -> int:
    catalog = load_catalog()
    state = read_state()
    selected = state.get("selected", catalog["default_model_id"])
    emit(
        {
            "ok": True,
            "default_model_id": catalog["default_model_id"],
            "selected": selected,
            "models": known_models(selected),
        }
    )
    return 0


def cmd_status(_: argparse.Namespace) -> int:
    catalog = load_catalog()
    state = read_state()
    selected = state.get("selected", catalog["default_model_id"])
    info = running_info()
    emit(
        {
            "ok": True,
            "selected": selected,
            "port": int(state.get("port", catalog["default_port"])),
            "running": info is not None,
            "pid": None if info is None else int(info["pid"]),
            "running_model": None if info is None else info.get("model"),
            "missing_dependency": dependency_error() if venv_python().is_file() else (
                f"/opt/homebrew/bin/python3.12 {SCRIPT_DIR / 'mlx_runner.py'} setup"
            ),
            "runtime_ready": venv_python().is_file() and dependency_error() is None,
            "models_dir": str(MODELS_DIR),
            "lmstudio_dir": str(LM_STUDIO_MODELS),
            "models": known_models(selected),
        }
    )
    return 0


def cmd_resolve(args: argparse.Namespace) -> int:
    spec = resolve_spec(args.model)
    emit({"ok": True, **spec})
    return 0


def cmd_select(args: argparse.Namespace) -> int:
    spec = resolve_spec(args.model)
    remember_custom(spec)
    state = read_state()
    state["selected"] = spec["id"]
    write_state(state)
    emit({"ok": True, "selected": spec["id"], "installed": spec["installed"], "path": spec["path"]})
    return 0


def cmd_use(args: argparse.Namespace) -> int:
    spec = resolve_spec(args.model)
    if spec["kind"] in {"local", "lmstudio"} and not spec["installed"]:
        emit({"ok": False, "error": f"That folder is not a built MLX model (missing config.json): {spec['repo']}"})
        return 1
    remember_custom(spec)
    state = read_state()
    state["selected"] = spec["id"]
    write_state(state)
    emit(
        {
            "ok": True,
            "id": spec["id"],
            "selected": spec["id"],
            "installed": spec["installed"],
            "path": spec["path"],
            "source": spec.get("source"),
        }
    )
    return 0


def cmd_download(args: argparse.Namespace) -> int:
    ensure_venv_runtime()
    missing = dependency_error()
    if missing:
        emit({"ok": False, "error": f"Install MLX first: {missing}"})
        return 1

    spec = resolve_spec(args.model)
    if spec["kind"] in {"local", "lmstudio"}:
        return cmd_use(args)

    existing = Path(spec["path"]) if spec.get("path") else None
    if existing is not None and not args.force:
        remember_custom(spec)
        state = read_state()
        state["selected"] = spec["id"]
        write_state(state)
        emit({"ok": True, "id": spec["id"], "path": str(existing), "installed": True, "reused": True})
        return 0

    from huggingface_hub import snapshot_download
    from tqdm.auto import tqdm

    dest = MODELS_DIR / re.sub(r"[^A-Za-z0-9._-]+", "--", spec["id"]).strip("-")
    dest.mkdir(parents=True, exist_ok=True)

    class Progress(tqdm):
        def update(self, n=1):
            super().update(n)
            total = self.total or 0
            fraction = (self.n / total) if total else None
            emit(
                {
                    "event": "progress",
                    "id": spec["id"],
                    "fraction": fraction,
                    "message": self.desc or "Downloading",
                }
            )

    emit({"event": "progress", "id": spec["id"], "fraction": 0.0, "message": f"Fetching {spec['repo']}"})
    try:
        snapshot_download(repo_id=spec["repo"], local_dir=str(dest), tqdm_class=Progress)
    except TypeError:
        snapshot_download(repo_id=spec["repo"], local_dir=str(dest))
    if not looks_like_mlx(dest):
        emit({"ok": False, "error": f"download finished but {dest / 'config.json'} is missing"})
        return 1
    spec["local_hints"] = spec.get("local_hints") or []
    remember_custom(spec)
    state = read_state()
    state["selected"] = spec["id"]
    write_state(state)
    emit({"ok": True, "id": spec["id"], "path": str(dest), "installed": True})
    return 0


def cmd_serve(args: argparse.Namespace) -> int:
    ensure_venv_runtime()
    catalog = load_catalog()
    state = read_state()
    spec = resolve_spec(args.model or state.get("selected") or catalog["default_model_id"])
    model_path = Path(spec["path"]) if spec.get("path") else None
    if model_path is None or not looks_like_mlx(model_path):
        emit({"ok": False, "error": f"{spec['id']} is not on disk yet"})
        return 1

    missing = dependency_error(need_vlm=is_multimodal(model_path))
    if missing:
        emit({"ok": False, "error": f"Install MLX first: {missing}"})
        return 1

    port = int(args.port or state.get("port") or catalog["default_port"])
    existing = running_info()
    if existing:
        same = existing.get("model") == spec["id"] and int(existing.get("port") or port) == port
        if same:
            emit(
                {
                    "ok": True,
                    "already_running": True,
                    "pid": int(existing["pid"]),
                    "port": port,
                    "model": spec["id"],
                }
            )
            return 0
        stop_server()
        wait_until = time.monotonic() + 3
        while port_in_use(port) and time.monotonic() < wait_until:
            time.sleep(0.1)

    if port_in_use(port):
        emit({"ok": False, "error": f"Port {port} is already in use."})
        return 1

    module = server_module(model_path)
    command = [
        sys.executable,
        "-m",
        module,
        "--model",
        str(model_path),
        "--host",
        "127.0.0.1",
        "--port",
        str(port),
    ]
    try:
        os.setsid()
    except OSError:
        pass
    write_pid_info(
        {
            "pid": os.getpid(),
            "pgid": os.getpgid(0),
            "port": port,
            "model": spec["id"],
            "path": str(model_path),
        }
    )
    state["selected"] = spec["id"]
    state["port"] = port
    write_state(state)
    remember_custom(spec)
    emit(
        {
            "ok": True,
            "pid": os.getpid(),
            "port": port,
            "model": spec["id"],
            "module": module,
            "base_url": f"http://127.0.0.1:{port}/v1",
        }
    )
    os.chdir(STATE_DIR)
    os.execv(sys.executable, command)


def cmd_stop(_: argparse.Namespace) -> int:
    emit(stop_server())
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("setup")
    sub.add_parser("list")
    sub.add_parser("status")
    sub.add_parser("stop")

    for name in ("select", "use", "resolve"):
        command = sub.add_parser(name)
        command.add_argument("model")

    download = sub.add_parser("download")
    download.add_argument("model")
    download.add_argument("--force", action="store_true")

    serve = sub.add_parser("serve")
    serve.add_argument("--model")
    serve.add_argument("--port", type=int)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    commands = {
        "setup": cmd_setup,
        "list": cmd_list,
        "status": cmd_status,
        "resolve": cmd_resolve,
        "select": cmd_select,
        "use": cmd_use,
        "download": cmd_download,
        "serve": cmd_serve,
        "stop": cmd_stop,
    }
    return commands[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
