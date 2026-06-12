#!/usr/bin/env bash
# Generates two crash-recovery artifacts for a loop-spec feature:
#   HANDOFF.json       - machine-readable snapshot (7 keys)
#   .continue-here.md  - human-readable resume guide with severity-tagged sections
#
# Usage:
#   bash lib/pause-snapshot.sh [--feature-dir <path>] [--dry-run]
#   bash lib/pause-snapshot.sh --dry-run [--feature-dir <path>]
#
# Arguments:
#   --feature-dir <path>  Path to the feature directory (contains feature.json).
#                         Defaults to scanning .loop-spec/features/*/feature.json.
#   --dry-run             Output HANDOFF.json to stdout; write no files.
#
# Exit codes:
#   0  success
#   1  no feature.json found
#   2  IO error writing HANDOFF.json (primary artifact)
#
# Kill switch:
#   LOOP_SPEC_PAUSE=0  Exit 0 immediately without reading or writing any file.
set -euo pipefail

# Kill switch.
if [[ "${LOOP_SPEC_PAUSE:-1}" == "0" ]]; then
  exit 0
fi

# Fail-open: IO errors on non-critical paths must not cascade.
# We override this locally for the primary HANDOFF.json write (exit 2).
trap 'exit 0' ERR

# Parse arguments.
DRY_RUN=0
FEATURE_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --feature-dir)
      if [[ $# -lt 2 ]]; then
        echo "pause-snapshot: --feature-dir requires a path argument" >&2
        exit 1
      fi
      FEATURE_DIR="$2"
      shift 2
      ;;
    *)
      echo "pause-snapshot: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Locate feature.json.
FEATURE_JSON_PATH=""

if [[ -n "$FEATURE_DIR" ]]; then
  FEATURE_JSON_PATH="$FEATURE_DIR/feature.json"
else
  REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  FEATURE_JSON_PATH=$(find "$REPO_ROOT/.loop-spec/features" -maxdepth 2 -name "feature.json" 2>/dev/null | head -1 || true)
fi

if [[ -z "$FEATURE_JSON_PATH" || ! -f "$FEATURE_JSON_PATH" ]]; then
  echo "pause-snapshot: no feature.json found" >&2
  exit 1
fi

# Determine the feature dir from the path (needed for writing artifacts).
RESOLVED_FEATURE_DIR="$(dirname "$FEATURE_JSON_PATH")"

# Extract fields from feature.json using python3 inline pattern.
CURRENT_PHASE=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get('currentPhase', ''))
except Exception:
    print('')
" "$FEATURE_JSON_PATH")

# Extract arrays as JSON strings.
COMPLETED_TASKS=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    phases = d.get('completedPhases', [])
    # Include completed gate tasks if present.
    tasks = d.get('completedTasks', phases)
    print(json.dumps(tasks))
except Exception:
    print('[]')
" "$FEATURE_JSON_PATH")

PENDING_TASKS=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    tasks = d.get('pendingRemediationTasks', [])
    print(json.dumps(tasks))
except Exception:
    print('[]')
" "$FEATURE_JSON_PATH")

BLOCKERS=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    blockers = d.get('blockers', [])
    print(json.dumps(blockers))
except Exception:
    print('[]')
" "$FEATURE_JSON_PATH")

DECISIONS=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    decisions = d.get('decisions', [])
    print(json.dumps(decisions))
except Exception:
    print('[]')
" "$FEATURE_JSON_PATH")

# Collect uncommitted files.
# In workspace mode: iterate workspace.repos[] running git -C <abs repo> for each.
# In single mode: run from the repo root (CWD if not in a git repo, fail-open to empty array).
WORKSPACE_JSON=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    w = d.get('workspace')
    if w and isinstance(w, dict) and w.get('root') and isinstance(w.get('repos'), list):
        print(json.dumps(w))
    else:
        print('null')
except Exception:
    print('null')
" "$FEATURE_JSON_PATH")

if [[ "$WORKSPACE_JSON" != "null" ]]; then
  # Workspace mode: collect per-repo uncommitted files with headings.
  # UNCOMMITTED_JSON will hold a list of strings (repo headings + file entries).
  UNCOMMITTED_JSON=$(python3 -c "
import json, sys, subprocess
w = json.loads(sys.argv[1])
root = w['root']
repos = w['repos']
entries = []
for repo in repos:
    name = repo.get('name', '')
    path = repo.get('path', '')
    abs_repo = root.rstrip('/') + '/' + path
    entries.append('### ' + name)
    try:
        result = subprocess.run(
            ['git', '-C', abs_repo, 'diff', '--name-only', 'HEAD'],
            capture_output=True, text=True
        )
        files = [f for f in result.stdout.splitlines() if f]
        entries.extend(files)
    except Exception:
        pass
    try:
        result2 = subprocess.run(
            ['git', '-C', abs_repo, 'status', '--porcelain'],
            capture_output=True, text=True
        )
        porcelain = [ln for ln in result2.stdout.splitlines() if ln]
        entries.extend(porcelain)
    except Exception:
        pass
print(json.dumps(entries))
" "$WORKSPACE_JSON")
else
  # Single mode: original behavior.
  UNCOMMITTED_FILES=$(git diff --name-only HEAD 2>/dev/null || true)
  UNCOMMITTED_JSON=$(python3 -c "
import json, sys
raw = sys.stdin.read().strip()
files = [f for f in raw.splitlines() if f] if raw else []
print(json.dumps(files))
" <<< "$UNCOMMITTED_FILES")
fi

# contextNotes is a static advisory note for human readers.
CONTEXT_NOTES="Snapshot generated by lib/pause-snapshot.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ). Review BLOCKING CONSTRAINTS in .continue-here.md before resuming."

# Build HANDOFF.json using python3 to guarantee valid JSON.
HANDOFF_JSON=$(python3 -c "
import json, sys

current_phase = sys.argv[1]
completed_tasks = json.loads(sys.argv[2])
pending_tasks = json.loads(sys.argv[3])
blockers = json.loads(sys.argv[4])
decisions = json.loads(sys.argv[5])
uncommitted_files = json.loads(sys.argv[6])
context_notes = sys.argv[7]

doc = {
    'currentPhase': current_phase,
    'completedTasks': completed_tasks,
    'pendingTasks': pending_tasks,
    'blockers': blockers,
    'decisions': decisions,
    'uncommittedFiles': uncommitted_files,
    'contextNotes': context_notes,
}
print(json.dumps(doc, indent=2))
" \
  "$CURRENT_PHASE" \
  "$COMPLETED_TASKS" \
  "$PENDING_TASKS" \
  "$BLOCKERS" \
  "$DECISIONS" \
  "$UNCOMMITTED_JSON" \
  "$CONTEXT_NOTES")

if [[ "$DRY_RUN" == "1" ]]; then
  printf '%s\n' "$HANDOFF_JSON"
  exit 0
fi

# Write HANDOFF.json (primary artifact - use exit 2 on failure).
HANDOFF_PATH="$RESOLVED_FEATURE_DIR/HANDOFF.json"
if ! printf '%s\n' "$HANDOFF_JSON" > "$HANDOFF_PATH"; then
  echo "pause-snapshot: IO error writing $HANDOFF_PATH" >&2
  exit 2
fi

# Write .continue-here.md (human-readable resume guide).
# Fail-open for this secondary artifact.
CONTINUE_PATH="$RESOLVED_FEATURE_DIR/.continue-here.md"
{
printf '%s\n' "# Resume guide - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' ""
printf '%s\n' "Feature: ${CURRENT_PHASE:-unknown} phase"
printf '%s\n' ""
printf '%s\n' "## BLOCKING CONSTRAINTS"
printf '%s\n' ""
printf '%s\n' "These items must be resolved before auto-resuming. Severity: blocking."
printf '%s\n' ""
printf '%s\n' "- [blocking: verify HANDOFF.json is current before dispatching any task]"
printf '%s\n' "- [blocking: confirm feature branch is up to date with base before writing new commits]"
printf '%s\n' "- [blocking: if uncommittedFiles is non-empty, stage or stash before resuming]"
printf '%s\n' ""
printf '%s\n' "## ANTI-PATTERNS"
printf '%s\n' ""
printf '%s\n' "Patterns that have caused problems in prior sessions. Severity varies."
printf '%s\n' ""
printf '%s\n' "- [advisory: do not skip the verify command when marking a task complete]"
printf '%s\n' "- [advisory: do not batch multiple task commits without running tests between them]"
printf '%s\n' "- [advisory: do not modify files outside the task files list without noting it in the report]"
printf '%s\n' "- [blocking: do not push or merge without the verifier agent sign-off]"
printf '%s\n' ""
printf '%s\n' "## REQUIRED READING"
printf '%s\n' ""
printf '%s\n' "Ordered list of files to read before writing any code in a resumed session."
printf '%s\n' ""
printf '%s\n' "1. HANDOFF.json (this feature dir) - current phase, pending tasks, blockers"
printf '%s\n' "2. docs/loop-spec/features/resilience-ops/PLAN.md - full task DAG and acceptance criteria"
printf '%s\n' "3. feature.json (this feature dir) - gate history, retry budget, branch info"
} > "$CONTINUE_PATH" 2>/dev/null || true

exit 0
