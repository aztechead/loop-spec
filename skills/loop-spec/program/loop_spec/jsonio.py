"""Atomic JSON file I/O and append-only JSONL logs.

Use `atomic_write_json` for anything only one writer should produce at a time
(state.json, product files); use `append_jsonl` for logs that accumulate one record
per event (events.jsonl). `read_json` is a thin wrapper kept here so every module
loads JSON the same way.
"""
import json
import os
from pathlib import Path


def render_json(value) -> str:
    """JSON as a step prompt shows it. Non-ASCII stays itself, never a \\u escape: a
    lead that re-types the prompt writes the character, so an escape could never
    match the transcript (LF-57). A literal backslash-u in a string stays escaped."""
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False)


def read_json(path: Path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def atomic_write_json(path: Path, obj) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(obj, sort_keys=True, indent=2, ensure_ascii=False) + "\n"
    tmp = path.parent / f".{path.name}.tmp-{os.getpid()}"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(payload)
        os.replace(tmp, path)  # same-directory rename: atomic, no partial file ever visible
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


def append_jsonl(path: Path, obj) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(obj, sort_keys=True, ensure_ascii=False)
    with open(path, "a", encoding="utf-8") as f:
        f.write(line + "\n")
