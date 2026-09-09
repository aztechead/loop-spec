#!/usr/bin/env bash
# Pin the eval record's reading of the driver's redo events: the driver emits one per
# REDO answer with the flag classes, and evals/eval_run.py counts them into the record
# and the summary, so a live run says which gate bounced the lead
# (docs/loop-spec/orchestrator-port-followup-3.md, N1).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

checks=(
  $'lib/graph/driver.py\tlib("events", "emit", feature_dir, "redo", "--phase", returned,'
  $'lib/graph/driver.py\t"classes": classes'
  $'evals/eval_run.py\tif e.get("event") == "redo":'
  $'evals/eval_run.py\t"format_redo": sum(redo["by_class"].get(c, 0) for c in FORMAT_CLASSES)'
  $'evals/eval_run.py\tFORMAT_CLASSES = ("artifact-lint", "verification-grounding", "misplaced"'
  $'evals/eval_run.py\tREDO rounds: {redo[\'rounds\']}'
  $'evals/README.md\tformat_redo'
)

check_fixed_strings "${checks[@]}"

# The pass bar in each task is the plan's figure (orchestrator-port-plan.md, WP1 done
# condition), not a copy that can drift from it (followup-3, N7).
PLAN="docs/loop-spec/orchestrator-port-plan.md"
plan_done="$(tr '\n' ' ' < "$PLAN")"
for row in "slugify-bug 0.25 50 3" "wc-json 0.60 100 5"; do
  set -- $row
  task="evals/tasks/$1/task.json"
  got="$(jq -r '"\(.bar.cost_usd) \(.bar.artifact_lines) \(.bar.minutes)"' "$task")"
  if [[ "$got" == "$(printf '%s %s %s' "$(printf '%g' "$2")" "$3" "$4")" ]] \
     && grep -qF "at most $2 USD, at most $3 artifact lines, at most $4 minutes" <<<"$plan_done"; then
    echo "PASS: $1 bar ($2 USD, $3 lines, $4 minutes) is the plan's"; PASS=$((PASS+1))
  else
    echo "FAIL: $1 bar is not the plan's (task: $got; plan says: $(grep -o "On \`$1\`[^.]*\." <<<"$plan_done" | head -1))"; FAIL=$((FAIL+1))
  fi
done

finish_fixed_string_coverage
