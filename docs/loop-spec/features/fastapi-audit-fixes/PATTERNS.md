# PATTERNS.md - fastapi-audit-fixes

> Produced by `pattern-mapper`. Read by `planner` before drafting tasks.
> One section per **concept** the upcoming feature will need. Concepts are system-design nouns/verbs, not file paths.

## Codebase context consulted

No generated codebase context documents were used. Direct sources: `.claude-plugin/plugin.json`, the feature SPEC, the graph and runtime helpers, their tests, and the SPEC/VERIFY/autonomous guidance. The shipped runtime is Bash/jq with stdlib Python helpers.

## Concept: Route recorded recovery before advancing

**Closest analog:** `lib/graph/probes/review-route.sh:4-15`

**Why this analog (one line):** The existing VERIFY bad-spec edge selects a return phase from durable feature state.

**Imports**

```bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

**Core pattern**

```bash
if [[ "${1:-}" == --answers ]]; then
  printf 'review=bad-spec\nreview=continue\n'
  exit 0
fi
[[ $# -eq 2 && "$1" == --feature-dir ]] || { echo "usage: review-route.sh --feature-dir DIR | --answers" >&2; exit 2; }
pending="$(bash "$script_dir/../../feature-read.sh" "$2" -r --filter '(.reviewRouting.route == "bad-spec") and (.reviewRouting.pending == true)')"
if [[ "$pending" == true ]]; then
  echo 'review=bad-spec reason=implementation reverted and spec amendment recorded'
else
  echo 'review=continue reason=no pending spec recovery'
fi
```

**Error handling**

The argument guard exits 2. `set -euo pipefail` propagates an unreadable feature; unknown route probes must not silently satisfy a route.

**Test analog** (if any)

```bash
    "$([[ "$(wc -l <<<"$short_path")" -lt "$(wc -l <<<"$full_path")" ]] && echo 1 || echo 0)"
  check "cycle graph declares no skippable field" "0" \
    "$(jq '[.nodes[] | select(has("skippable"))] | length' "$ROOT/graph/cycle.graph.json")"

  # Each plan gets a fresh feature directory. A graph resume ledger is durable
  # state, so sharing one fixture would make a later dry run test the prior
  # plan's successor rather than the plan it just wrote.
  compact_path_with() {
    local name="$1" plan="$2" dir
    dir="$WORK/cyclerepo/.loop-spec/features/$name"
    mkdir -p "$dir"
    jq -n --arg base "$base_sha" --arg slug "$name" --argjson plan "$plan" \
      '{slug:$slug,schemaVersion:7,execStyle:"auto",baseSha:$base,
        executionProfile:"compact",gatePlan:$plan,iterate:{used:0,feedback:null},
```
From `tests/lib/graph-run.test.sh:1017-1030`.

**Application gotchas**

- `graph/cycle.graph.json:971-982` routes VERIFY to DISCUSS for bad-spec; preserve this recovery priority. The queued-remediation edge is missing.
- `graph/cycle.graph.json:1489-1493` chains code review toward ITERATE. Exercise the real VERIFY resume boundary, not only a synthetic graph.
- `skills/verify/SKILL.md:118-126` claims a remediation graph route exists; that prose is currently ahead of the code.

---

## Concept: Durable task registration and retry

**Closest analog:** `lib/feature_write.py:24-42`

**Why this analog (one line):** The shared publisher preserves the previous file until an atomic durable replacement succeeds.

**Imports**

```python
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
```

**Core pattern**

```python
def publish(path, content):
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "wb") as stream:
            if path.exists():
                os.fchmod(stream.fileno(), stat.S_IMODE(path.stat().st_mode))
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
```

**Error handling**

```python
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
```

**Test analog** (if any)

```bash
# --- remediation intake ------------------------------------------------------------
bash "$REPO_ROOT/lib/feature-write.sh" append "$FD" pendingRemediationTasks '{"id":"task-001+remediate-1","subject":"Fix: a"}' >/dev/null
out="$(bash "$SCRIPT" run --feature-dir "$FD" 2>/dev/null)"
check "remediation: the task is registered in the sidecar" "1" "$(jq '[.[] | select(.id == "task-001+remediate-1")] | length' "$FD/tasks.json")"
check "remediation: it takes the project test command" "true" "$(jq -r '.[] | select(.id == "task-001+remediate-1") | .verifyCommand' "$FD/tasks.json")"
check "remediation: the pending array is cleared" "0" "$(jq '.pendingRemediationTasks | length' "$FD/feature.json")"
check "remediation: the count is reported" "1" "$(jq -r '.remediationRegistered' <<<"$out")"
```
From `tests/lib/execute-prepare.test.sh:60-66`.

**Application gotchas**

- `lib/execute-prepare.sh:73-100` reads and mutates tasks, then clears the entire queue even when registration fails; this is the defective call site, not a pattern to copy.
- `lib/feature_write.py:69-71` locks before reading; `lib/task-progress.sh:84-98` also replaces atomically but uses a fixed temporary name and no lock. Prefer the shared publisher for durability.
- `lib/verify-gate.sh:88-92,108` normalizes and appends full-shape tasks. Existing intake accepts partial tasks with the project test default. Retry must distinguish the same task from an ID collision and preserve unacknowledged work.

---

## Concept: Block exit until work is published

**Closest analog:** `lib/execute-exit-gate.sh:25-36`

**Why this analog (one line):** EXECUTE already emits FLAG lines and a failing exit when published task evidence is incomplete.

**Imports**

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cmd="${1:-}"
gate_usage="check|finish <feature-dir>"
. "$SCRIPT_DIR/exit-gate-prelude.sh" "${2:-}"
```

**Core pattern**

```bash
  check)
    tasks="$(fget '.artifacts.tasks // ""')"
    if [[ -n "$tasks" && -f "$tasks" ]]; then
      remaining="$(lib task-progress remaining "$tasks" | paste -sd, -)"
      [[ -z "$remaining" ]] || flag "[plan-adherence] tasks not published: $remaining (dispatch them again, or for a task whose commit is already on the feature branch run: bash lib/cycle-driver.sh task integrate --feature-dir $feature_dir --task <id>, or bash lib/task-progress.sh mark-done $(fget '.artifacts.tasks // "tasks.json"') <id>)"
    else
      flag "[plan-adherence] artifacts.tasks sidecar missing; cannot prove every PLAN task landed"
    fi
    rc=0; lib greenfield-bootstrap backfill-check "$feature_dir" >/dev/null 2>&1 || rc=$?
    (( rc == 3 )) && flag "[greenfield] commands.test is empty after the scaffold task; re-run detection"
    (( flags == 0 )) || exit 1
    ;;
```

**Error handling**

The missing-sidecar branch emits a plan-adherence FLAG; `flags != 0` exits 1. `lib/task-progress.sh:43-58` rejects unreadable JSON and non-array task data.

**Test analog** (if any)

```bash
# --- progress ----------------------------------------------------------------------
bash "$REPO_ROOT/lib/task-progress.sh" mark-done "$FD/tasks.json" task-001 >/dev/null
out="$(bash "$SCRIPT" run --feature-dir "$FD" 2>/dev/null)"
check "progress: done ids are reported" "task-001" "$(jq -r '.done[0]' <<<"$out")"
check "progress: a done task leaves the dispatch list" "0" "$(jq '[.tasks[] | select(.id == "task-001")] | length' <<<"$out")"
check "progress: a done blocker is pruned from blockedBy" "0" "$(jq '.tasks[] | select(.id == "task-002") | .blockedBy | length' <<<"$out")"
```
From `tests/lib/execute-prepare.test.sh:68-73`; this tests dispatch progress, not the exit gate.

**Application gotchas**

- The existing sidecar check alone cannot see queued work that intake never registered.
- The `remaining | paste` command substitution must not hide a reader error. Empty output is not evidence that invalid input has no remaining tasks.

---

## Concept: Preserve autonomous mode before feature creation

**Closest analog:** `lib/cycle-result.sh:299-326`

**Why this analog (one line):** The result interface already accepts an explicit true/false flag and arms a durable active-run record.

**Imports**

Standalone Bash helper; JSON is built with `jq --argjson` (`lib/cycle-result.sh:347-354,569-587`).

**Core pattern**

```bash
    feature_dir="" phase="startup" autonomous="false" classification_raw=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --result-root) result_root="${2:-}"; shift 2 || true ;;
        --cycle-type) cycle_type="${2:-}"; shift 2 || true ;;
        --title) title="${2:-}"; shift 2 || true ;;
        --slug) slug="${2:-}"; shift 2 || true ;;
        --branch) branch="${2:-}"; shift 2 || true ;;
        --base-branch) base_branch="${2:-}"; shift 2 || true ;;
        --feature-dir) feature_dir="${2:-}"; shift 2 || true ;;
        --phase) phase="${2:-}"; shift 2 || true ;;
        --autonomous) autonomous="${2:-}"; shift 2 || true ;;
        --classification) classification_raw="${2:-}"; shift 2 || true ;;
        *) shift || true ;;
      esac
    done
    # Reduced routes arm the same record: the contract is per ROUTE, not per cycle type.
    case "$cycle_type" in full|micro|debug) ;; *) cycle_type="" ;; esac
    [[ -n "$result_root" && -n "$cycle_type" ]] || {
```

**Error handling**

```bash
    [[ "$autonomous" == "true" || "$autonomous" == "false" ]] || autonomous="false"
    jq -e 'type == "array"' <<<"$warnings_json" >/dev/null 2>&1 || warnings_json="[]"
    # Publication path: from here on, failure exits 3 (see header). Exiting 0 with
    # no pointer written is how an unattended run gets lost -- the supervisor reads
    # "success, no result", which looks identical to a dozen other causes.
    result_root_abs="$(_resolve_result_root "$result_root")" || {
      echo "cycle-result.sh: TERMINAL RESULT NOT PUBLISHED - cannot resolve result root: $result_root" >&2; exit 3; }
    _prepare_result_root "$result_root_abs" || {
      echo "cycle-result.sh: TERMINAL RESULT NOT PUBLISHED - cannot prepare result root: $result_root_abs" >&2; exit 3; }
```

**Test analog** (if any)

```bash
# Case W: a full cycle publishes an active pointer before feature state exists,
# and an out-of-band reconciler can turn it into a terminal result.
ACTIVE_RESULT="$GENERIC_ROOT/.loop-spec/active-run.json"
bash "$LIB" begin --result-root "$GENERIC_ROOT" --cycle-type full \
  --title "Cloud task" --slug cloud-task --branch feat/cloud-task --base-branch main \
  --phase startup --autonomous true
check "W: active pointer created" "1" "$([[ -f "$ACTIVE_RESULT" ]] && echo 1 || echo 0)"
check "W: active pointer names phase" "startup:true" \
  "$(jq -r '.phase + ":" + (.autonomous | tostring)' "$ACTIVE_RESULT")"
bash "$REPO_ROOT/lib/cycle-reconcile.sh" --result-root "$GENERIC_ROOT" \
  --reason "container terminated" >/dev/null
check "W2: reconciler writes full result" "full:failed:interrupted" \
  "$(jq -r '.cycleType + ":" + .status + ":" + .outcome' "$GENERIC_RESULT")"
check "W2: reconciler keeps phase" "startup" "$(jq -r '.phaseReached' "$GENERIC_RESULT")"
check "W2: terminal write clears active pointer" "0" \
```
From `tests/lib/cycle-result.test.sh:495-509`.

**Application gotchas**

- `write-terminal` initializes autonomous=false at `lib/cycle-result.sh:365`, accepts `--autonomous` at line 386, and projects active-run context without mode at lines 560-561. Track explicit argument presence so explicit false wins over ambient true.
- `lib/cycle-result.sh:916` uses feature mode with a false fallback; jq `//` treats false as missing, so do not use it to implement boolean precedence.
- The active-run test proves pre-feature state exists but does not assert final autonomous mode. Extend terminal-writer coverage for environment fallback and explicit false. The lead reproduced the missing-feature environment failure; inspect caller behavior before widening changes.

---

## Concept: Ignore machine-local launcher artifacts

**Closest analog:** `.gitignore:20-26`

**Why this analog (one line):** The repository lists runtime telemetry paths individually alongside the existing result pointer.

**Imports**

Not applicable: Git ignore patterns have no imports.

**Core pattern**

```gitignore
# generated by tooling; never committed
docs/superpowers/
.loop-spec/learnings.jsonl
# machine-readable result pointer (lib/cycle-result.sh); local telemetry
.loop-spec/last-result.json
.loop-spec/runtime.json
.loop-spec/decisions-staging/
```

**Error handling**

Not applicable: patterns are declarative; test with git check-ignore and a clean temporary repository.

**Test analog** (if any)

```bash
  .loop-spec/active-run.json \
  .loop-spec/last-result.json \
  .loop-spec/results/run.json \
  .loop-spec/decisions-staging/decisions.jsonl \
  graphify-out/cache/deadbeef.json \
  graphify-out/cost.json \
  graphify-out/graph.json; do
  check "$path ignored" "ignored" \
    "$(git -C "$WORK" check-ignore -q "$path" && echo ignored || echo not-ignored)"
done
```
From `tests/lib/runtime-ignore.test.sh:61-70`.

**Application gotchas**

- This test currently exercises `lib/runtime-ignore.sh` and local info/exclude, not the root .gitignore. A regression for this finding must load the repository .gitignore itself.
- Ignore sessions and the two launcher files explicitly; a blanket `.loop-spec/` rule would also conceal source/configuration paths. Preserve positive visibility checks.

---

## Concept: Keep implementation choices outside frozen intent

**Closest analog:** `lib/spec_intent.py:37-42`

**Why this analog (one line):** The approved digest deliberately freezes Goal and Boundary while allowing other sections to evolve.

**Imports**

```python
import hashlib
import json
import re
```

**Core pattern**

```python
def verify_intent(text, approval):
    if (not isinstance(approval, dict) or not isinstance(approval.get("sha256"), str)
            or not re.fullmatch(r"[a-f0-9]{64}", approval["sha256"])):
        raise ValueError("SPEC.md Goal and Boundary have no recorded approval")
    if intent_digest(text) != approval["sha256"]:
        raise ValueError("SPEC.md Goal or Boundary changed after approval; restore the approved intent and route the intent gap to the human")
```

**Error handling**

```python
    for key in ("goal", "boundary"):
        if key not in sections or not "".join(sections[key][1:]).strip():
            raise ValueError("SPEC.md needs a non-empty " + key + " section before approval")
    content = json.dumps(sections, sort_keys=True, ensure_ascii=False).encode("utf-8")
```

**Test analog** (if any)

```python
    approval = json.loads((feature / "feature.json").read_text())["specApproval"]
    assert approval["source"] == "autonomous"
    assert approval["sha256"] == intent_digest(original)
    call("artifact-lint.sh", "spec", str(spec), "--feature-dir", str(feature))
    spec.write_text(original.replace("Use existing helpers.", "Reuse the parser."))
    call("artifact-lint.sh", "spec", str(spec), "--feature-dir", str(feature))
    spec.write_text(original.replace("Return the requested output.", "Return different output."))
    subprocess.run(["git", "add", "docs"], cwd=temp, check=True)
    subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.com",
                    "commit", "-qm", "Changed spec"], cwd=temp, check=True)
    assert "changed after approval" in call("artifact-lint.sh", "spec", str(spec),
                                            "--feature-dir", str(feature), expected=1)
```
From `tests/lib/spec-intent.test.sh:57-68`.

**Application gotchas**

- `lib/spec_intent.py:21-22` recognizes both Goal/Goals and Boundary/Boundaries spellings. Do not narrow or bypass this hash.
- `skills/shared/autonomous-mode.md:111-116` keeps tamper scans hard while self-answering certain intent questions. Clarify that self-answering cannot approve changing already frozen intent.
- Explain outcome wording before approval and use an implementation section for the path-versus-query choice; do not repair this audit by rewriting approval records.

---

## Open questions for the planner

- None. The SPEC explicitly preserves the safety boundary and excludes a paid live run.

## Concepts with no clear analog

- `Atomic acknowledgment across feature state and task sidecar` -- Existing writers publish one file at a time. No observed helper provides a two-file transaction; the planner must specify safe ordering, retry identity, and failure evidence rather than assume atomicity across both files.
