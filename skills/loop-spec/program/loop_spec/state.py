"""Durable per-run state: single writer, digest-guarded against out-of-band edits.

Use `StateStore.create` to start a new run's state.json, `StateStore.open` to resume
one, mutate the loaded `state` dict, then call `save()`. No other code writes
state.json; the sidecar digest is how `open()` notices if something else did.
"""
from pathlib import Path

from loop_spec import VERSION
from loop_spec.errors import LoopSpecError
from loop_spec.ids import digest
from loop_spec.jsonio import atomic_write_json, read_json
from loop_spec.paths import FeaturePaths

# The shape of state.json. 2 (7.4.0): phase facts the core reads live in products and
# core records, not plug-in buckets (D4); controller.check_compatible refuses to resume
# a lower one.
STATE_FORMAT = 2


def _digest_path(paths: FeaturePaths) -> Path:
    return paths.state_json.parent / "state.digest"


class StateStore:
    """Owns state.json for one feature run; construct via create() or open()."""

    def __init__(self, paths: FeaturePaths, state: dict) -> None:
        self.paths = paths
        self.state = state

    @classmethod
    def create(cls, paths: FeaturePaths, run_fields: dict, request_text: str) -> "StateStore":
        if paths.state_json.exists():
            raise LoopSpecError(
                f"a run already exists at {paths.state_json}",
                repair="run `loop-spec status --slug <slug>` to resume it, or pick a new slug",
            )
        state = {
            "schema": 1,
            "loopSpecVersion": VERSION,
            "stateFormat": STATE_FORMAT,
            "run": run_fields,
            "request": {"text": request_text, "digest": digest(request_text)},
            "phase": {"current": None, "attemptId": None, "entry": "fresh", "entryPayload": None},
            "products": {k: None for k in
                         ("spec", "plan", "execute", "verify", "iterate", "deliver", "debug")},
            "revisions": {"requirements": None, "plan": None},
            "approval": None,
            "baseline": None,
            "ledger": {"findings": [], "reviewedRanges": [], "reviews": []},
            "budget": {"limit": 2, "spent": 0, "transitions": []},
            "repos": None,
            "questions": {"open": None, "answered": {}, "retired": [], "policy": None, "policyAnswered": []},
            "steps": {"open": [], "retired": [], "quarantined": [], "submissions": {}},
            "implementations": {"phases": {}, "roles": {}},
            "attempts": [],
            "result": None,
        }
        store = cls(paths, state)
        store.save()
        return store

    @classmethod
    def open(cls, paths: FeaturePaths) -> "StateStore":
        if not paths.state_json.exists():
            raise LoopSpecError(
                f"no run state at {paths.state_json}",
                repair="start a run first (e.g. `loop-spec cycle`), or check --slug",
            )
        state = read_json(paths.state_json)
        digest_path = _digest_path(paths)
        expected = digest_path.read_text(encoding="utf-8").strip() if digest_path.exists() else None
        if expected is None or digest(state) != expected:
            raise LoopSpecError(
                "state.json was edited outside the program",
                repair=f"inspect {paths.state_json}; run `loop-spec status`; remove the edit or start a new run",
            )
        return cls(paths, state)

    def save(self) -> None:
        atomic_write_json(self.paths.state_json, self.state)
        _digest_path(self.paths).write_text(digest(self.state) + "\n", encoding="utf-8")
