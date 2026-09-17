#!/usr/bin/env bash
# Behavioral checks for route-sized design budgets and optional telemetry.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/design-budget-test.$$"
mkdir -p "$WORK/feature"
trap 'rm -rf "$WORK"' EXIT
FD="$WORK/feature"; DB="$ROOT/lib/design-budget.sh"
printf '%s\n' '{"autonomousClassification":{"estimatedFiles":7,"criteriaCount":5},"currentPhase":"spec"}' > "$FD/feature.json"
check() { local name="$1" expected="$2" actual="$3"; [[ "$actual" == "$expected" ]] || { echo "FAIL: $name (expected '$expected', got '$actual')" >&2; exit 1; }; echo "PASS: $name"; }
out="$(bash "$DB" --feature-dir "$FD" --phase spec)"
check "route estimate" "budget=29 elapsed=0 remaining=29 exhausted=false budgetReason=route-size-estimate:7-files-5-criteria" "$out"
check "repeated calls deterministic" "$out" "$(bash "$DB" --feature-dir "$FD" --phase spec)"
jq '.autonomousClassification = {estimatedFiles:40, criteriaCount:20}' "$FD/feature.json" > "$FD/tmp" && mv "$FD/tmp" "$FD/feature.json"
check "budget caps at sixty" "budget=60" "$(bash "$DB" --feature-dir "$FD" --phase plan | cut -d' ' -f1)"
jq '.autonomousClassification = {reviewableEstimatedFiles:3, estimatedFiles:40, criteriaCount:2}' "$FD/feature.json" > "$FD/tmp" && mv "$FD/tmp" "$FD/feature.json"
check "reviewable estimate wins" "budgetReason=route-size-estimate:3-files-2-criteria" "$(bash "$DB" --feature-dir "$FD" --phase discuss | awk '{print $NF}')"
jq '.autonomousClassification = {estimatedFiles:true, criteriaCount:2}' "$FD/feature.json" > "$FD/tmp" && mv "$FD/tmp" "$FD/feature.json"
check "boolean estimate falls back" "budgetReason=route-size-estimate-unavailable" "$(bash "$DB" --feature-dir "$FD" --phase spec | awk '{print $NF}')"
check "operator override" "budgetReason=operator-design-budget-override" "$(LOOP_SPEC_DESIGN_BUDGET_MINS=17 bash "$DB" --feature-dir "$FD" --phase spec | awk '{print $NF}')"
ec=0; LOOP_SPEC_DESIGN_BUDGET_MINS=0 bash "$DB" --feature-dir "$FD" --phase spec >/dev/null 2>&1 || ec=$?
check "invalid override rejected" "2" "$ec"
ec=0; LOOP_SPEC_DESIGN_BUDGET_MINS=$'１２' bash "$DB" --feature-dir "$FD" --phase spec >/dev/null 2>&1 || ec=$?
check "unicode override rejected" "2" "$ec"
ec=0; LOOP_SPEC_DESIGN_BUDGET_MINS=999999999999999999999999 bash "$DB" --feature-dir "$FD" --phase spec >/dev/null 2>&1 || ec=$?
check "oversized override rejected" "2" "$ec"
jq '.autonomousClassification = {estimatedFiles:1, criteriaCount:1} | .currentPhaseStartedAt = null' "$FD/feature.json" > "$FD/tmp" && mv "$FD/tmp" "$FD/feature.json"
printf '%s\n' '{"event":"phase_end","phase":"spec","attemptId":"a","elapsedSeconds":120}' '{"event":"phase_end","phase":"spec","attemptId":"a","elapsedSeconds":120}' '{"event":"phase_end","phase":"discuss","attemptId":"b","data":{"elapsedSeconds":60}}' '{"event":"phase_end","phase":"plan","attemptId":"bad","elapsedSeconds":true}' > "$FD/events.jsonl"
check "duplicate and invalid telemetry" "elapsed=3" "$(bash "$DB" --feature-dir "$FD" --phase spec | cut -d' ' -f2)"
jq '.currentPhaseStartedAt = "2020-01-01T00:00:00Z"' "$FD/feature.json" > "$FD/tmp" && mv "$FD/tmp" "$FD/feature.json"
printf '%s\n' '{"event":"phase_end","phase":"spec","attemptId":"closed","ts":"2020-01-02T00:00:00Z","elapsedSeconds":120}' > "$FD/events.jsonl"
check "closed phase is not counted as open" "elapsed=2" "$(bash "$DB" --feature-dir "$FD" --phase spec | cut -d' ' -f2)"
printf '[]\n' > "$FD/feature.json"
printf '%s\n' '{"event":"phase_end","phase":"spec","attemptId":[],"elapsedSeconds":Infinity}' > "$FD/events.jsonl"
check "malformed feature and non-finite telemetry are safe" "elapsed=0" "$(bash "$DB" --feature-dir "$FD" --phase spec | cut -d' ' -f2)"
printf '%s\n' '{"autonomousClassification":{"estimatedFiles":1,"criteriaCount":1},"currentPhase":"plan","currentPhaseStartedAt":null}' > "$FD/feature.json"
printf '%s\n' \
  '{"event":"phase_end","phase":"spec","attemptId":"initial-spec","elapsedSeconds":1800,"ts":"2026-01-01T00:01:00Z"}' \
  '{"event":"phase_end","phase":"discuss","attemptId":"initial-discuss","elapsedSeconds":1800,"ts":"2026-01-01T00:31:00Z"}' \
  '{"event":"phase_end","phase":"plan","attemptId":"initial-plan","elapsedSeconds":1800,"ts":"2026-01-01T01:01:00Z"}' > "$FD/events.jsonl"
check "initial design pass exhausts" "elapsed=90" "$(bash "$DB" --feature-dir "$FD" --phase plan | cut -d' ' -f2)"
printf '%s\n' \
  '{"event":"phase_start","phase":"execute","ts":"2026-01-01T01:02:00Z"}' \
  '{"event":"phase_end","phase":"execute","ts":"2026-01-01T01:10:00Z"}' \
  '{"event":"phase_start","phase":"iterate","ts":"2026-01-01T01:11:00Z"}' \
  '{"event":"phase_end","phase":"iterate","ts":"2026-01-01T01:12:00Z"}' \
  '{"event":"phase_end","phase":"plan","attemptId":"fresh-plan","elapsedSeconds":120,"ts":"2026-01-01T01:13:00Z"}' >> "$FD/events.jsonl"
check "execution and iterate reset design allowance" "elapsed=2" "$(bash "$DB" --feature-dir "$FD" --phase plan | cut -d' ' -f2)"
printf '%s\n' '{"event":"phase_end","phase":"plan","attemptId":"fresh-plan","elapsedSeconds":120,"ts":"2026-01-01T01:14:00Z"}' >> "$FD/events.jsonl"
check "repeated design attempt is charged once" "elapsed=2" "$(bash "$DB" --feature-dir "$FD" --phase plan | cut -d' ' -f2)"
printf '%s\n' \
  '{"event":"phase_end","phase":"plan","attemptId":"same-after-boundary","elapsedSeconds":60,"ts":"2026-01-01T01:15:00Z"}' \
  '{"event":"phase_start","phase":"verify","ts":"2026-01-01T01:16:00Z"}' \
  '{"event":"phase_end","phase":"plan","attemptId":"same-after-boundary","elapsedSeconds":60,"ts":"2026-01-01T01:17:00Z"}' >> "$FD/events.jsonl"
check "reused attempt id after boundary is charged again" "elapsed=1" "$(bash "$DB" --feature-dir "$FD" --phase plan | cut -d' ' -f2)"
boundary="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "{\"autonomousClassification\":{\"estimatedFiles\":1,\"criteriaCount\":1},\"currentPhase\":\"plan\",\"currentPhaseStartedAt\":\"$boundary\"}" > "$FD/feature.json"
printf '%s\n' \
  '{"event":"phase_end","phase":"plan","attemptId":"old-plan","elapsedSeconds":600,"ts":"2026-01-01T00:01:00Z"}' \
  "{\"event\":\"phase_start\",\"phase\":\"iterate\",\"ts\":\"$boundary\"}" > "$FD/events.jsonl"
check "open plan after rewind ignores preboundary usage" "elapsed=0" "$(bash "$DB" --feature-dir "$FD" --phase plan | cut -d' ' -f2)"
printf '%s\n' "{\"autonomousClassification\":{\"estimatedFiles\":1,\"criteriaCount\":1},\"currentPhase\":\"spec\",\"currentPhaseStartedAt\":\"$boundary\"}" > "$FD/feature.json"
check "open spec after rewind ignores preboundary usage" "elapsed=0" "$(bash "$DB" --feature-dir "$FD" --phase spec | cut -d' ' -f2)"
PYTHONPATH="$ROOT/lib" python3 - "$FD" <<'PY'
import contextlib
import io
import json
import sys
from unittest.mock import patch
import design_budget

fd = sys.argv[1]
boundary = 1760000000
events = [
    {"event": "phase_end", "phase": "plan", "attemptId": "old", "elapsedSeconds": 600,
     "ts": "2025-10-09T08:52:00Z"},
    {"event": "phase_start", "phase": "iterate", "ts": "2025-10-09T08:53:20Z"},
]
with open(fd + "/events.jsonl", "w", encoding="utf-8") as fh:
    for event in events:
        fh.write(json.dumps(event) + "\n")

def measure(phase, started, now):
    with open(fd + "/feature.json", "w", encoding="utf-8") as fh:
        json.dump({"autonomousClassification": {"estimatedFiles": 1, "criteriaCount": 1},
                   "currentPhase": phase, "currentPhaseStartedAt": started}, fh)
    output = io.StringIO()
    with patch.object(design_budget.time, "time", return_value=now), contextlib.redirect_stdout(output):
        design_budget.main(fd, phase)
    return output.getvalue().split()[1]

for phase in ("plan", "spec"):
    if measure(phase, "2025-10-09T08:53:20Z", boundary + 120) != "elapsed=2":
        raise SystemExit("FAIL: equal-boundary open %s was not charged" % phase)
    if measure(phase, "2025-10-09T08:53:19Z", boundary + 120) != "elapsed=0":
        raise SystemExit("FAIL: stale open %s was charged" % phase)
    print("PASS: frozen equal-boundary and stale open %s" % phase)
PY
echo "Results: design-budget passed"
