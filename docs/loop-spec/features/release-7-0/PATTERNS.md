# PATTERNS.md - release-7-0

For maintainers and the planner choosing implementation seams for stable requirements and verifiable coverage.

## Codebase context consulted

Read CLAUDE.md, the approved SPEC, the pattern-mapper charter, the human-docs contract, and the source and test locations cited below. No generated codebase map was consulted. The existing shape is Bash launchers around stdlib Python modules, with the graph driver importing the same modules used by shell entry points.

## Concept: Shared parsing and typed readers

**Closest analog:** `lib/feature_read.py:60-93`; shell entry at `lib/feature-read.sh:10`, direct Python caller at `lib/graph/driver.py:224-230`.

**Why this analog:** One named module owns interpretation and errors for shell and Python consumers.

**Imports:** stdlib json, os, re, subprocess, sys (`lib/feature_read.py:46-50`).

**Core pattern**

```python
def load_state(target):
    file_path = target if os.path.basename(target) == "feature.json" else os.path.join(target, "feature.json")
    try:
        with open(file_path, "r", encoding="utf-8") as fh:
            state = json.load(fh)
    except (IOError, OSError) as exc:
        raise IOError("cannot read {}: {}".format(file_path, exc.strerror or exc))
    except ValueError as exc:
        raise IOError("{} is not JSON: {}".format(file_path, exc))
    if not isinstance(state, dict):
        raise IOError("{} is not a JSON object".format(file_path))
    return state
```

**Error handling:** The module rejects undeclared keys and distinguishes invalid input from unreadable state (`lib/feature_read.py:189-193`, `lib/feature_read.py:225-233`). The existing Markdown task parser derives dispatch JSON from PLAN instead of a completion message (`lib/plan-tasks.sh:1-26`), and PLAN egress names that extractor (`lib/plan-exit-gate.sh:21`).

**Application gotchas**

- The state reader is an interface analog, not a requirement grammar. It does not solve multiline Markdown, retired IDs, scenarios, or semantic revisions.
- Do not carry the embedded Python shape of plan-tasks into another substantial parser; CLAUDE.md calls for named modules.

## Concept: Atomic state publication

**Closest analog:** `lib/feature_write.py:24-43`; launcher `lib/feature-write.sh:9`.

**Why this analog:** A temporary sibling is flushed before replacement; the writer locks before reading current state.

**Imports:** fcntl, json, os, pathlib.Path, re, stat, subprocess, sys, tempfile (`lib/feature_write.py:3-11`).

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

**Error handling:** Temporary cleanup is in finally (`lib/feature_write.py:39-43`); the lock spans reading through publication and store persistence (`lib/feature_write.py:71-129`). Store failure explicitly says local state was written.

**Test analog:** Previous state survives a second write (`tests/lib/feature-write.test.sh:31-36`).

```bash
# Case B: second write rotates current to .bak
bash "$LIB" "$WORK/feat" '{"slug":"bar","schemaVersion":1}' >/dev/null
got_curr=$(jq -r '.slug' "$WORK/feat/feature.json")
got_bak=$(jq -r '.slug' "$WORK/feat/feature.json.bak")
check "B: second write rotates current to .bak (current=bar)" "bar" "$got_curr"
check "B: second write rotates current to .bak (bak=foo)" "foo" "$got_bak"
```

**Application gotchas**

- Atomic replacement of one file is not an atomic multi-artifact migration. Recovery, source validation, and publication generations remain separate work.
- The rotating feature.json backup is not an immutable archive of original legacy artifacts.

## Concept: Observed verification

**Closest analog:** `lib/graph/driver.py:2407-2497`.

**Why this analog:** The command executor returns actual exit and output; the writer derives PASS from the exit.

**Imports:** subprocess and os, already imported by the driver (`lib/graph/driver.py:213-219`).

**Core pattern**

```python
def observe(command, root):
    """Run one command in the feature root and return (exit, output block): the block is
    the output capped at 200 lines, or the exit when there was none."""
    try:
        proc = subprocess.run(["bash", "-c", command], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              universal_newlines=True, timeout=int(os.environ.get("LOOP_SPEC_PHASE_TIMEOUT_MINS") or 60) * 60)
        code, output = proc.returncode, proc.stdout
    except subprocess.TimeoutExpired:
        code, output = 124, "(timed out)"
    lines = output.rstrip("\n").splitlines()
    if len(lines) > 200:
        lines = lines[:200] + ["... (%d more lines)" % (len(lines) - 200)]
    return code, ("\n".join(lines) or "(no output, exit %d)" % code)
```

**Error handling:** Timeout becomes exit 124. Missing commands become explicit FAIL rows (`lib/graph/driver.py:2447-2452`).

**Test analog:** `tests/lib/cycle-driver.test.sh:458-469` rejects supplied evidence and checks observed PASS/FAIL plus convergence refusal.

```bash
ec=0; out="$(cd "$REPO7" && drv verification run --feature-dir "$FD7" 2>/dev/null)" || ec=$?
check "verification run: a passing command is PASS from its exit" "1" "$(grep -c '^| GE-001 | .* | PASS | `python3 -c .* -> exit 0 |$' "$DOCS7/VERIFICATION.md")"
check "verification run: a failing command is FAIL from its exit" "1" "$(grep -c '^| GE-002 | .* | FAIL | `python3 -m unittest .* -> exit [1-9][0-9]* |$' "$DOCS7/VERIFICATION.md")"
check "verification run: a failing row is exit 1" "1" "$ec"
check "verification run: the answer lists each row's exit" "PASS FAIL" "$(jq -r '[.ran[] | select(.row | startswith("GE")) | .status] | join(" ")' <<<"$out")"
check "verification run: the output block is the command's output" "1" "$(grep -c '^(no output, exit 0)$' "$DOCS7/VERIFICATION.md")"
check "verification run: the floor refuses convergence on the FAIL row" "1" "$(jq -r '.flags[]' <<<"$out" | grep -c '^FLOOR GE-002')"
```

**Application gotchas**

- The current writer still assigns identity by position (`lib/graph/driver.py:2434-2435`); this is the defect to replace.
- Output truncation and command deduplication are presentation choices, not requirement-revision or code-state provenance. The new contract needs independently validated observations.

## Concept: Approved intent isolated from mutable implementation

**Closest analog:** `lib/spec_intent.py:12-42`; approval caller `lib/graph/driver.py:2269-2288`.

**Why this analog:** The digest covers only frozen sections, and existing approvals are verified rather than replaced.

**Imports**

```python
import hashlib
import json
import re
```

**Core pattern**

```python
    for key in ("goal", "boundary"):
        if key not in sections or not "".join(sections[key][1:]).strip():
            raise ValueError("SPEC.md needs a non-empty " + key + " section before approval")
    content = json.dumps(sections, sort_keys=True, ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(content).hexdigest()


def verify_intent(text, approval):
    if (not isinstance(approval, dict) or not isinstance(approval.get("sha256"), str)
            or not re.fullmatch(r"[a-f0-9]{64}", approval["sha256"])):
        raise ValueError("SPEC.md Goal and Boundary have no recorded approval")
    if intent_digest(text) != approval["sha256"]:
        raise ValueError("SPEC.md Goal or Boundary changed after approval; restore the approved intent and route the intent gap to the human")
```

**Error handling:** Missing or repeated frozen sections raise ValueError (`lib/spec_intent.py:25-32`); the state writer rejects any changed existing specApproval (`lib/feature_write.py:114-117`).

**Test analog:** `tests/lib/spec-intent.test.sh:61-75` proves implementation changes pass, changed goals fail even after commit, and reapproval retains the old record.

**Application gotchas**

- Requirement revisions need their own normalization and digest; reusing the intent digest would freeze the wrong content.
- Migration cannot replace approval or infer new execution evidence from the old approved document.

## Concept: Explicit legacy migration

**Closest analog:** Partial only: staging migration in `lib/decisions.sh:109-120`, called during workspace initialization at `lib/graph/driver.py:1025`.

**Why this analog:** An explicit command moves a durable record and a missing source makes replay a no-op.

**Imports:** Bash with jq for record construction; no Python module.

**Core pattern**

```bash
  migrate)
    staging="${2:-}"; feature="${3:-}"
    if [[ -z "$staging" || -z "$feature" ]]; then
      echo "usage: decisions.sh migrate <staging_dir> <feature_dir>" >&2
      exit 1
    fi
    src="$staging/$FILE_NAME"
    [[ -f "$src" ]] || { echo "nothing to migrate"; exit 0; }
    mkdir -p "$feature"
    cat "$src" >> "$feature/$FILE_NAME"
    rm "$src"
    echo "migrated"
```

**Error handling:** Missing arguments fail before mutation (`lib/decisions.sh:110-114`).

**Test analog:** `tests/lib/decisions.test.sh:57-62` covers moving staging records and replay after source removal.

**Application gotchas**

- Append then delete can duplicate records after interruption. This is not a recoverable publication protocol and must not be copied as one.
- The existing state validator accepts schema 7 explicitly (`lib/feature-validation.sh:20-38`); it is not an artifact-contract version dispatcher.

## Open questions for the planner

The SPEC now selects the shared versioned inventory, canonical revision rules, clean
examined revision, and migration transaction gate. Those choices are settled for PLAN
(`docs/loop-spec/features/release-7-0/SPEC.md:184-216`,
`docs/loop-spec/features/release-7-0/SPEC.md:244-289`). Remaining task-level details:

- Define the supported toolchain/external-input probe contract and offline fixtures, as required by `docs/loop-spec/features/release-7-0/SPEC.md:253-257`.
- Name the new modules, commands, tests, and documentation, and update the footprint before dispatch (`docs/loop-spec/features/release-7-0/SPEC.md:162-167`).

## Concepts with no clear analog

- Recoverable multi-file legacy artifact migration with approved preview, immutable originals, and rollback. The inspected staging migration and single-file state publisher cover only parts.
- Stable requirement/scenario identity with retirement history and semantic revision checks. Existing positional writer and intent digest do not supply this contract.
