#!/usr/bin/env bash
# oneshot-exit-gate.sh - ONESHOT's exit: an escalated spec closes with nothing to
# check; otherwise the change is scanned and VERIFICATION.md proves every criterion.
#
# Why: the oneshot route (docs/loop-spec/orchestrator-port-plan.md, WP1) folds
# EXECUTE's scans and VERIFY's record into one phase, so its exit has two readings that
# phase-exit.sh's data cannot key on: `route: full` lives in SPEC.md's frontmatter, not
# feature.json. This script reads it once. The `oneshot` node of graph/cycle.graph.json
# lists it as a gate; lib/graph/probes/oneshot.sh --after then routes the escalated
# run to DISCUSS and the finished one to DELIVER.
#
# Usage: oneshot-exit-gate.sh <feature-dir>
# Output: `FLAG [<gate>] <finding>` lines; exit 1 when any, 0 when clean, 2 bad call.
# Gates on a finished run: placeholder scan and test-tamper scan over the diff since
# baseSha (the same bodies VERIFY's gate nodes run), artifact-lint verification,
# verification-grounding-lint, and the converged floor (every Good Enough row PASS).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/exit-gate-prelude.sh" "${1:-}"
spec="$(fget '.artifacts.spec // ""')"; [[ -n "$spec" ]] || spec="$docs/SPEC.md"

case "$(bash "$SCRIPT_DIR/graph/probes/oneshot.sh" --feature-dir "$feature_dir" --after 2>/dev/null)" in
  route=full*) exit 0 ;;
  route=oneshot*) ;;
  *) echo "FLAG [oneshot] lib/graph/probes/oneshot.sh --after returned an error for $spec (route line expected)"; exit 1 ;;
esac

run_gate placeholder lib feature-scan-each "$SCRIPT_DIR/placeholder-scan.sh" --feature-dir "$feature_dir"
run_gate tamper lib feature-scan-each "$SCRIPT_DIR/test-tamper-scan.sh" --feature-dir "$feature_dir"
if [[ -f "$docs/VERIFICATION.md" ]]; then
  run_gate artifact-lint lib artifact-lint verification "$docs/VERIFICATION.md"
  run_gate verification-grounding lib verification-grounding-lint "$docs/VERIFICATION.md" --repo "$root" --spec "$spec"
  run_gate converged-floor lib converged-floor "$spec" "$docs/VERIFICATION.md"
else
  flag "[verification] $docs/VERIFICATION.md missing: ONESHOT writes it after the criteria pass (skills/oneshot/SKILL.md, Verify)"
fi
(( flags == 0 )) || exit 1
exit 0
