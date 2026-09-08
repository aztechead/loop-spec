#!/usr/bin/env bash
# PostToolUse hook: lint a cycle artifact the moment it is written, for whoever wrote it.
#
# Why: every artifact lint ran only at phase exit, after a subagent had authored a
# 600-line PLAN.md and reported DONE. On a live run (evals/findings-2026-09-07-tf-meldn.md)
# that placement turned three 20-millisecond checks into three planner round trips: the
# template shape (35 flags), the bare-grep criteria (37 flags), and the decisions-verbatim
# rule the planner pre-checked by hand. This hook runs the matching lint on the file a
# Write or Edit just touched and hands the FLAG lines back to the author, lead or
# subagent, so the fix happens inside the same dispatch. The phase exit stays the backstop.
#
# Claude Code contract (PostToolUse):
#   exit 0 = nothing to say
#   exit 2 = stderr is shown to the model as feedback; the write already happened
#
# Recognized paths (anywhere under docs/loop-spec/features/<slug>/ or .loop-spec/features/<slug>/):
#   SPEC.md -> artifact-lint spec     PLAN.md -> artifact-lint plan
#   PATTERNS.md -> artifact-lint patterns   tasks.json -> artifact-lint tasks + acceptance-lint
#   VERIFICATION.md -> artifact-lint verification + converged-floor (the ITERATE floor
#   wants an exact `## Acceptance criteria` table; a live verifier learned that two
#   phases later) + verification-grounding-lint (the `## Repository grounding` rows)
#
# Kill switch: LOOP_SPEC_ARTIFACT_LINT_FEEDBACK=0 -> exit 0.
# Fail-open: no payload, malformed JSON, missing lint, no python3 -> exit 0.
set -euo pipefail

if [[ "${LOOP_SPEC_ARTIFACT_LINT_FEEDBACK:-1}" == "0" ]]; then
  exit 0
fi

trap 'exit 0' ERR
command -v python3 &>/dev/null || exit 0

INPUT=$(cat 2>/dev/null) || true
[[ -z "$INPUT" ]] && exit 0

FILE=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    p = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if str(p.get("tool_name") or "") not in ("Write", "Edit", "MultiEdit"):
    raise SystemExit(0)
print(str((p.get("tool_input") or {}).get("file_path") or ""))
')
[[ -n "$FILE" && -f "$FILE" ]] || exit 0
case "$FILE" in
  */docs/loop-spec/features/*/SPEC.md) kind=spec ;;
  */docs/loop-spec/features/*/PLAN.md) kind=plan ;;
  */docs/loop-spec/features/*/PATTERNS.md) kind=patterns ;;
  */docs/loop-spec/features/*/VERIFICATION.md) kind=verification ;;
  */.loop-spec/features/*/tasks.json) kind=tasks ;;
  *) exit 0 ;;
esac

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"
[[ -x "$LIB/artifact-lint.sh" || -f "$LIB/artifact-lint.sh" ]] || exit 0

out=""
rc=0
out="$(bash "$LIB/artifact-lint.sh" "$kind" "$FILE" 2>&1)" || rc=$?
# The floor and the grounding lint need the sibling SPEC.md; without one there is
# nothing to hold the record to. A live verifier learned the missing `## Repository
# grounding` section from the phase exit, one round later.
if [[ "$kind" == "verification" && -f "$(dirname "$FILE")/SPEC.md" ]]; then
  if [[ -f "$LIB/converged-floor.sh" ]]; then
    floor=""; frc=0
    floor="$(bash "$LIB/converged-floor.sh" "$(dirname "$FILE")/SPEC.md" "$FILE" 2>&1)" || frc=$?
    if [[ "$frc" -eq 1 ]]; then out="$out"$'\n'"$(grep '^FLOOR' <<<"$floor" | sed 's/^/converged-floor: /')"; rc=1; fi
  fi
  if [[ -f "$LIB/verification-grounding-lint.sh" ]]; then
    ground=""; grc=0
    ground="$(bash "$LIB/verification-grounding-lint.sh" "$FILE" --repo "$(git -C "$(dirname "$FILE")" rev-parse --show-toplevel 2>/dev/null || dirname "$FILE")" --spec "$(dirname "$FILE")/SPEC.md" 2>&1)" || grc=$?
    if [[ "$grc" -eq 1 ]]; then out="$out"$'\n'"$(grep '^FLAG' <<<"$ground" | sed 's/^/verification-grounding: /')"; rc=1; fi
  fi
fi
if [[ "$kind" == "tasks" ]]; then
  acc=""; arc=0
  acc="$(bash "$LIB/acceptance-lint.sh" "$FILE" 2>&1)" || arc=$?
  # Exit 2 is a usage error (unreadable or non-JSON input), not a finding.
  if [[ "$arc" -eq 1 ]]; then out="$out"$'\n'"$acc"; rc=1; fi
fi
[[ "$rc" -eq 0 ]] && exit 0

{
  echo "artifact-lint: $(basename "$FILE") does not pass the $kind lint the phase exit will run. Fix these before reporting DONE:"
  printf '%s\n' "$out" | grep -E '^(FLAG|acceptance-lint:|converged-floor:|verification-grounding:)' | head -40
} >&2
exit 2
