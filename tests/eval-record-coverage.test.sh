#!/usr/bin/env bash
# Pin the eval record's reading of the driver's redo events: the driver emits one per
# REDO answer with the flag classes, and evals/eval_run.py counts them into the record
# and the summary, so a live run says which gate bounced the lead
# (port audit 3, N1).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

checks=(
  $'lib/graph/driver.py\tlib("events", "emit", feature_dir, "redo", "--phase", returned,'
  $'lib/graph/driver.py\t"classes": classes'
  $'evals/eval_run.py\tif e.get("event") == "redo":'
  $'evals/eval_run.py\t"format_redo": sum(redo["by_class"].get(c, 0) for c in FORMAT_CLASSES)'
  $'evals/eval_run.py\tFORMAT_CLASSES = ("artifact-lint", "verification-grounding", "misplaced"'
  $'evals/eval_run.py\tREDO rounds: {redo[\'rounds\']}'
  $'evals/README.md\tformat_redo'
  $'evals/eval_run.py\tdef first_turn_input_tokens'
  $'evals/README.md\tfirst_turn_input_tokens'
)

check_fixed_strings "${checks[@]}"

# The pass bar in each task is the port plan's WP1 done condition (the reference implementation's measured
# figures plus DELIVER: a delivered run in one round at or under the cost, the artifact
# lines, and the minutes), held here as the one literal so the two task files cannot
# drift from it or from each other (port audit 3, N7). The plan is a record on the audit
# branch, not a file in this tree.
for row in "slugify-bug 0.25 50 3" "wc-json 0.60 100 5"; do
  set -- $row
  task="evals/tasks/$1/task.json"
  got="$(jq -r '"\(.bar.cost_usd) \(.bar.artifact_lines) \(.bar.minutes) \(.bar.rounds)"' "$task")"
  if [[ "$got" == "$(printf '%s %s %s 1' "$(printf '%g' "$2")" "$3" "$4")" ]]; then
    echo "PASS: $1 bar ($2 USD, $3 lines, $4 minutes, one round) is the plan's"; PASS=$((PASS+1))
  else
    echo "FAIL: $1 bar is not the plan's (task: $got; plan: $2 USD, $3 lines, $4 minutes, one round)"; FAIL=$((FAIL+1))
  fi
done

# Replay saved events without launching a model or requiring its discarded workspace.
if python3 - <<'PYTEST'
import importlib.util
import json
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("eval_run", "evals/eval_run.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    message = "FLAG [footprint] tests/test_wc_tool.py is absent from the diff"
    events = [
        {"event": "phase_start", "phase": "oneshot"},
        {"event": "redo", "phase": "oneshot", "data": {
            "attempt": 1, "flags": 1, "classes": {"footprint": 1}, "messages": [message]}},
        {"event": "redo", "phase": "spec", "data": {
            "attempt": 2, "flags": 1, "classes": {"artifact-lint": 1}}},
    ]
    (root / "events.jsonl").write_text("\n".join(json.dumps(e) for e in events) + "\nnot json\n")
    count, redo = module.read_gate_events(root)
    assert count == 4
    assert redo["rounds"] == 2
    assert redo["by_class"] == {"footprint": 1, "artifact-lint": 1}
    assert redo["events"][0]["messages"] == [message]
    assert redo["events"][0]["phase"] == "oneshot"
    assert "messages" not in redo["events"][1]
    assert module.read_gate_events(None) == (0, {"rounds": 0, "by_class": {}, "events": []})
PYTEST
then
  echo "PASS: eval records preserve gate evidence and read older records"; PASS=$((PASS+1))
else
  echo "FAIL: eval records lost gate evidence or rejected an older record"; FAIL=$((FAIL+1))
fi

finish_fixed_string_coverage
