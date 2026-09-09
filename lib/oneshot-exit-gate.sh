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
# baseSha (the same bodies VERIFY's gate nodes run), every footprint file in that diff,
# the frozen Intent block unchanged since SPEC committed it, a recorded code-reviewer
# dispatch, artifact-lint verification, verification-grounding-lint, review-triage-lint
# over the findings, and the converged floor (every Good Enough row PASS).
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
# The footprint is a promise: every file it names is in the diff. The first wc-json run
# on the route named the test file, never touched it, and shipped without the test the
# spec's own footprint had committed to. Single-repo only: a workspace repo carries its
# own baseSha and the footprint is repo-relative to it.
base_sha="$(fget '.baseSha // ""')"
if [[ -z "$ws_root" && -n "$base_sha" ]]; then
  changed="$(git diff --name-only "$base_sha" HEAD -- 2>/dev/null || true)"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    grep -qxF "$f" <<<"$changed" \
      || flag "[footprint] $f is in SPEC.md's footprint but not in the diff since $base_sha: make the change there, or drop it from the footprint with a line under Implementation notes saying why"
  done < <(sed -n '/^footprint:/,/^[^ ]/p' "$spec" | sed -n 's/^  - //p; s/^footprint: *\[\(.*\)\]$/\1/p' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sed '/^$/d')
fi
# The Intent block is the ask and it is frozen: ONESHOT changes code to meet it, never
# the block to meet the code. A changed ask is an escalation (route: full), not an edit.
intent_block() { sed -n '/^<!-- intent: frozen/,/^<!-- \/intent -->$/p'; }
rel="${spec#"$root/"}"
committed="$(git show "HEAD:$rel" 2>/dev/null | intent_block)"
if [[ -n "$committed" && "$committed" != "$(intent_block < "$spec")" ]]; then
  flag "[intent] the frozen Intent block of $rel changed since its commit: restore it (git show HEAD:$rel); when the ask itself is wrong, escalate with route: full instead"
fi
# One review pass, and it happened: the dispatch event the skill emits when it launches
# the reviewer (skills/shared/dispatch.md). The first slugify run on the route wrote
# "No findings" under Code review with nobody dispatched.
if ! jq -e 'select(.event == "dispatch" and .phase == "oneshot" and ((.data.role // "") | test("code-reviewer")))' \
    "$feature_dir/events.jsonl" >/dev/null 2>&1; then
  flag "[review] no code-reviewer dispatch recorded for oneshot in $feature_dir/events.jsonl: dispatch loop-spec:code-reviewer once and emit the dispatch event (skills/oneshot/SKILL.md, One review pass)"
fi
if [[ -f "$docs/VERIFICATION.md" ]]; then
  run_gate artifact-lint lib artifact-lint verification "$docs/VERIFICATION.md"
  run_gate verification-grounding lib verification-grounding-lint "$docs/VERIFICATION.md" --repo "$root" --spec "$spec"
  run_gate review-triage lib review-triage-lint "$docs/VERIFICATION.md"
  run_gate converged-floor lib converged-floor "$spec" "$docs/VERIFICATION.md"
else
  flag "[verification] $docs/VERIFICATION.md missing: ONESHOT writes it after the criteria pass (skills/oneshot/SKILL.md, Verify)"
fi
(( flags == 0 )) || exit 1
exit 0
