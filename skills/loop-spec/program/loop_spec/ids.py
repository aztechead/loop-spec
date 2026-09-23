"""Ids, content digests, and timestamps shared by every module that writes state.

Use `new_id` for a fresh identifier, `digest`/`digest_bytes` for content-addressed
comparisons (the state digest guard, `inputsDigest` fields), and `now_iso` for every
timestamp field so they sort and compare consistently.
"""
import hashlib
import json
import secrets
from datetime import datetime, timezone

_KINDS = {"run", "attempt", "step", "question", "range", "finding"}


def new_id(kind: str) -> str:
    if kind not in _KINDS:
        # A kind outside this set is a programming error in the caller, not an
        # operator input, so this is a plain ValueError rather than LoopSpecError.
        raise ValueError(f"unknown id kind: {kind!r} (expected one of {sorted(_KINDS)})")
    return f"{kind}-{secrets.token_hex(6)}"


def digest_bytes(data: bytes) -> str:
    return f"sha256:{hashlib.sha256(data).hexdigest()}"


def digest(obj) -> str:
    # sort_keys makes the digest independent of dict insertion order; compact
    # separators keep it independent of formatting.
    canonical = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return digest_bytes(canonical.encode())


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")
