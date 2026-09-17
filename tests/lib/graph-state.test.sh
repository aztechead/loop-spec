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

# --- optionalReads: a documented-nullable key is never asserted on entry ---
# The startup baseline is opt-in; with it disabled verificationBaseline stays
# null by design, and hard-requiring it forced the VERIFY node to capture one
# mid-phase -- exactly the opt-out the schema documents, undone at runtime.
cat > "$WORK/graph/optional.graph.json" <<'EOF'
{
  "entry": "verify",
  "nodes": [
    {
      "id": "verify",
      "kind": "agent",
      "reads": ["slug"],
      "optionalReads": ["verificationBaseline"],
      "writes": ["warnings"],
      "effort": "system2"
    }
  ],
  "edges": []
}
EOF
bash "$ROOT/lib/feature-write.sh" set "$WORK/feature" verificationBaseline 'null'
rc=0
bash "$SCRIPT" assert-reads --feature-dir "$WORK/feature" --node verify \
  --graph "$WORK/graph/optional.graph.json" || rc=$?
check "null optionalReads key does not block node entry" "0" "$rc"

# The same key declared as an ordinary read still blocks, so the exemption comes
# from the declaration and not from the key's name.
jq '.nodes[0].reads += ["verificationBaseline"] | del(.nodes[0].optionalReads)' \
  "$WORK/graph/optional.graph.json" > "$WORK/graph/required.graph.json"
rc=0
bash "$SCRIPT" assert-reads --feature-dir "$WORK/feature" --node verify \
  --graph "$WORK/graph/required.graph.json" 2>/dev/null || rc=$?
check "the same key as a plain read still blocks" "1" "$rc"

# --- workspace identity keys: top-level branch/baseSha/baseBranch are null
#     by design; per-repo values satisfy a declared read. The shipped execute
#     node reads "branch", so a flat None check blocked every workspace run.
SHIPPED="$ROOT/graph/cycle.graph.json"
mkdir -p "$WORK/ws-feature"
bash "$ROOT/lib/feature-init.sh" skeleton --mode workspace \
  --slug ws-exec --now "$NOW" --style auto --title "workspace assert-reads" \
  --ws-root /ws \
  --repos '[{"name":"fe","path":"fe","branch":"feat/ws-exec","baseSha":"abc","baseBranch":"main"},{"name":"be","path":"be","branch":"feat/ws-exec","baseSha":"def","baseBranch":"main"}]' \
  > "$WORK/ws-feature/feature.json"

for node in execute execute.worker verify.code-review deliver; do
  rc=0
  bash "$SCRIPT" assert-reads --feature-dir "$WORK/ws-feature" --node "$node" \
    --graph "$SHIPPED" || rc=$?
  check "workspace $node: per-repo identity satisfies shipped reads[]" "0" "$rc"
done

# A repo that did not actually record its branch still fails — the relocation
# is not a blanket skip of the key.
jq '.workspace.repos[1].branch = null' "$WORK/ws-feature/feature.json" \
  > "$WORK/ws-feature/feature.json.tmp"
mv "$WORK/ws-feature/feature.json.tmp" "$WORK/ws-feature/feature.json"
rc=0
err="$(bash "$SCRIPT" assert-reads --feature-dir "$WORK/ws-feature" --node execute \
  --graph "$SHIPPED" 2>&1)" || rc=$?
check "workspace execute fails when a repo has no branch" "1" "$rc"
echo "$err" | grep -qx 'branch' && named=0 || named=1
check "workspace execute names the unsatisfied key" "0" "$named"

# Empty repos[] is a workspace with no authoritative identity.
jq '.workspace.repos = []' "$WORK/ws-feature/feature.json" \
  > "$WORK/ws-feature/feature.json.tmp"
mv "$WORK/ws-feature/feature.json.tmp" "$WORK/ws-feature/feature.json"
rc=0
bash "$SCRIPT" assert-reads --feature-dir "$WORK/ws-feature" --node execute \
  --graph "$SHIPPED" 2>/dev/null || rc=$?
check "workspace execute fails when repos[] is empty" "1" "$rc"

# Single-mode still requires the top-level key. The existing fixture has a
# branch; null it and the shipped execute node must fail.
bash "$ROOT/lib/feature-write.sh" set "$WORK/feature" branch 'null'
rc=0
bash "$SCRIPT" assert-reads --feature-dir "$WORK/feature" --node execute \
  --graph "$SHIPPED" 2>/dev/null || rc=$?
check "single-mode execute still fails when top-level branch is null" "1" "$rc"
bash "$ROOT/lib/feature-write.sh" set "$WORK/feature" branch '"feat/gdd-state"'

# Only branch/baseSha/baseBranch are relocated. A non-relocated null key still
# blocks in workspace mode, exactly as it does in single mode.
bash "$ROOT/lib/feature-init.sh" skeleton --mode workspace \
  --slug ws-wt --now "$NOW" --style auto \
  --ws-root /ws \
  --repos '[{"name":"fe","path":"fe","branch":"feat/ws-wt","baseSha":"abc","baseBranch":"main"}]' \
  > "$WORK/ws-feature/feature.json"
bash "$ROOT/lib/feature-write.sh" set "$WORK/ws-feature" slug 'null'
rc=0
bash "$SCRIPT" assert-reads --feature-dir "$WORK/ws-feature" --node spec \
  --graph "$WORK/graph/cycle.graph.json" 2>/dev/null || rc=$?
check "workspace mode still fails a null non-identity read" "1" "$rc"

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

# The in-process engine and CLI share the validator module. Compare the missing
# key answer on the malformed workspace fixture.
cli_missing="$(bash "$SCRIPT" assert-reads --feature-dir "$WORK/ws-feature" --node spec \
  --graph "$WORK/graph/cycle.graph.json" 2>&1 || true)"
direct_missing="$(PYTHONPATH="$ROOT/lib/graph:$ROOT/lib" python3 - "$WORK/ws-feature" <<'PY'
import sys
import feature_read
from state_reads import unsatisfied_reads
feature = feature_read.load_state(sys.argv[1])
projected = {key: feature.get(key) for key in feature_read.state_keys()}
print("\n".join(unsatisfied_reads(projected, ["slug"])))
PY
)"
printf '%s\n' "$cli_missing" | grep -qx 'slug'
check "CLI and in-process validator agree on missing read" "slug" "$direct_missing"

# Exercise the real engine entry point, including node lookup and a fresh state
# read after mutation (the old shell boundary could hide stale assumptions).
PYTHONPATH="$ROOT/lib/graph:$ROOT/lib" python3 - "$ROOT" "$WORK" <<'PY'
import json
import sys
from pathlib import Path
import engine

root, work = sys.argv[1:]
graph = str(Path(work) / "graph" / "cycle.graph.json")
feature_dir = str(Path(work) / "feature")
Path(feature_dir, "feature.json").write_text(json.dumps({"slug": None}), encoding="utf-8")
engine.configure(graph, feature_dir, False, True, True, root, str(Path(root) / "lib" / "graph"))

ok, err = engine.assert_reads("spec")
if ok or "slug" not in err:
    raise SystemExit("FAIL: engine missing read: %s" % err)
Path(feature_dir, "feature.json").write_text(json.dumps({"slug": "fresh"}), encoding="utf-8")
ok, err = engine.assert_reads("spec")
if not ok or err:
    raise SystemExit("FAIL: engine fresh mutation read")
ok, err = engine.assert_reads("missing-node")
if ok or "unknown node: missing-node" not in err:
    raise SystemExit("FAIL: engine unknown node")
print("PASS: engine assert_reads validates fresh state and unknown nodes")
PY

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
