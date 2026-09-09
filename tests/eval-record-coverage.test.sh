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

finish_fixed_string_coverage
