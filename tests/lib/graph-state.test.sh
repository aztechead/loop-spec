#!/usr/bin/env bash
# Unit tests for lib/graph/state.sh — typed channel over feature.json.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/graph/state.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-graph-state.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/feature" "$WORK/graph" "$WORK/bin"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

[[ -f "$SCRIPT" ]] || { echo "FAIL: missing $SCRIPT"; exit 1; }

# Minimal graph with one node declaration
cat > "$WORK/graph/cycle.graph.json" <<'EOF'
{
  "entry": "spec",
  "nodes": [
    {
      "id": "spec",
      "kind": "agent",
      "reads": ["slug"],
      "writes": ["currentPhase", "artifacts"],
      "effort": "system2"
    }
  ],
  "edges": []
}
EOF

# Seed feature.json via real feature-init + write path
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bash "$ROOT/lib/feature-init.sh" skeleton --mode single \
  --slug gdd-state --now "$NOW" --style step --title "state test" \
  --branch feat/gdd-state --base-sha deadbeef --base-branch main \
  --worktree "" --prepare "" --test "" --lint "" --typecheck "" \
  > "$WORK/feature/feature.json"
# null worktree
python3 - <<PY
import json
from pathlib import Path
p=Path("$WORK/feature/feature.json")
d=json.loads(p.read_text())
d["worktreePath"]=None
d["executionRootMode"]="in-place"
p.write_text(json.dumps(d, indent=2)+"\n")
PY

GRAPH_FLAG=(--graph "$WORK/graph/cycle.graph.json")

# --- undeclared write rejected, no mutation ---
cp "$WORK/feature/feature.json" "$WORK/feature/feature.json.before"
rc=0
bash "$SCRIPT" write --feature-dir "$WORK/feature" --node spec "${GRAPH_FLAG[@]}" --key mergeQueue '[]' 2>/dev/null || rc=$?
check "undeclared write non-zero" "1" "$rc"
cmp -s "$WORK/feature/feature.json" "$WORK/feature/feature.json.before"
check "undeclared write no mutation" "0" "$?"

# --- declared write delegates to feature-write (bak rotated) ---
rm -f "$WORK/feature/feature.json.bak"
rc=0
bash "$SCRIPT" write --feature-dir "$WORK/feature" --node spec "${GRAPH_FLAG[@]}" --key currentPhase '"plan"' || rc=$?
check "declared write exit 0" "0" "$rc"
phase="$(jq -r '.currentPhase' "$WORK/feature/feature.json")"
check "declared write applied" "plan" "$phase"
[[ -f "$WORK/feature/feature.json.bak" ]]
check "bak rotated via feature-write" "0" "$?"

# --- assert-reads fails when key null/absent ---
# slug is present; remove it via feature-write to null
bash "$ROOT/lib/feature-write.sh" set "$WORK/feature" slug 'null'
rc=0
bash "$SCRIPT" assert-reads --feature-dir "$WORK/feature" --node spec "${GRAPH_FLAG[@]}" 2>/dev/null || rc=$?
check "unsatisfied read non-zero" "1" "$rc"

# restore slug
bash "$ROOT/lib/feature-write.sh" set "$WORK/feature" slug '"gdd-state"'
rc=0
bash "$SCRIPT" assert-reads --feature-dir "$WORK/feature" --node spec "${GRAPH_FLAG[@]}" || rc=$?
check "satisfied reads exit 0" "0" "$rc"

# --- delegate stub: when FEATURE_WRITE points at stub, no write without stub invoke ---
printf '#!/usr/bin/env bash\necho STUB_CALLED >> "%s/stub.log"\nexit 0\n' "$WORK" > "$WORK/bin/feature-write.sh"
chmod +x "$WORK/bin/feature-write.sh"
rm -f "$WORK/stub.log"
cp "$WORK/feature/feature.json" "$WORK/feature/feature.json.before"
# Use env override if supported; else test via LOOP_SPEC_FEATURE_WRITE
rc=0
LOOP_SPEC_FEATURE_WRITE="$WORK/bin/feature-write.sh" \
  bash "$SCRIPT" write --feature-dir "$WORK/feature" --node spec "${GRAPH_FLAG[@]}" --key currentPhase '"verify"' || rc=$?
check "stub delegate exit 0" "0" "$rc"
grep -q STUB_CALLED "$WORK/stub.log"
check "stub was invoked" "0" "$?"
# With stub that does not write, feature.json unchanged proves no direct mutation path
cmp -s "$WORK/feature/feature.json" "$WORK/feature/feature.json.before"
check "no direct feature.json mutation" "0" "$?"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
