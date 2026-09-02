#!/usr/bin/env bash
# Fable 5.1 prompt coverage: each applicable model-behavior nudge belongs in
# the shared contract that owns it, rather than being copied into one harness.
# simplicity: standalone suites keep their local preamble; a shared test harness would couple entrypoints.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

check() {
  local label="$1" file="$2" needle="$3"
  if grep -Fqi "$needle" "$file"; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label ($file missing: $needle)"; FAIL=$((FAIL + 1))
  fi
}

check "reports progress during tool work" \
  skills/shared/report-style.md "progress update"
check "batches independent tool calls" \
  skills/shared/report-style.md "Batch independent tool calls"
check "uses readable chat formatting" \
  output-styles/loop-spec.md "Use headings and lists"
check "avoids mannered prose" \
  skills/shared/report-style.md "mannered prose"
check "marks source quotations" \
  skills/shared/grounding-protocol.md "mark it as a quotation"
check "searches fast-moving names" \
  skills/shared/grounding-protocol.md "fast-moving"
check "finishes authorized autonomous work" \
  skills/shared/autonomous-mode.md "Do not ask for permission"
check "preserves compaction constraints" \
  skills/shared/autonomous-mode.md "Compaction summaries preserve"
check "keeps scope and tests bounded" \
  skills/shared/execution-discipline.md "pre-existing bug"
check "prefers targeted edits" \
  skills/shared/execution-discipline.md "surgically edit"
check "keeps the lead productive" \
  skills/shared/dispatch.md "independent lead work"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
