#!/usr/bin/env bash
# Dispatch the SHIPPED VERIFY gate nodes through lib/graph/run.sh.
#
# The gate scripts already have standalone unit tests, and those kept passing while
# every graph-driven cycle was blocked at VERIFY: the engine invoked each body with
# no arguments, the scan exited 2 (a usage error), and the gate node read that as a
# finding. Standalone coverage cannot see that class of defect, so these cases run
# each gate the way a cycle runs it -- through dispatch, on the node declarations
# read out of graph/cycle.graph.json rather than a copy that could drift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/graph/run.sh"
CYCLE_GRAPH="$ROOT/graph/cycle.graph.json"
WORK="${TMPDIR:-/tmp}/loop-spec-graph-gate-dispatch.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

check "verify.marker bodyArgs take feature-scan-each --feature-dir" \
  "true" \
  "$(jq -r '.nodes[] | select(.id=="verify.marker") | (.body == "lib/feature-scan-each.sh" and (.bodyArgs | index("--feature-dir") != null) and (.bodyArgs | index("{featureDir}") != null))' "$CYCLE_GRAPH")"
check "verify.tamper bodyArgs take feature-scan-each --feature-dir" \
  "true" \
  "$(jq -r '.nodes[] | select(.id=="verify.tamper") | (.body == "lib/feature-scan-each.sh" and (.bodyArgs | index("--feature-dir") != null) and (.bodyArgs | index("{featureDir}") != null))' "$CYCLE_GRAPH")"

# A single-gate graph built from the shipped node, so the bodyArgs under test are
# the ones a real cycle dispatches.
gate_graph() {
  local node_id="$1" out="$2"
  # routeDefault names a successor that this one-node graph deliberately does not
  # carry; dropping it keeps the extraction about the node's DISPATCH contract.
  jq --arg id "$node_id" \
    '{entry: $id, nodes: [.nodes[] | select(.id == $id) | del(.routeDefault)], edges: []}' \
    "$CYCLE_GRAPH" > "$out"
}

# A throwaway project repo: the scans diff a real tree, and the feature under test
# must not be the tree these tests run in.
REPO="$WORK/project"
mkdir -p "$REPO/tests"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name tester
printf 'def add(a, b):\n    return a + b\n' > "$REPO/app.py"
printf 'def test_add():\n    assert True\n' > "$REPO/tests/test_app.py"
git -C "$REPO" -c commit.gpgsign=false add -A
git -C "$REPO" -c commit.gpgsign=false commit -q -m base
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"

FEAT_REL=".loop-spec/features/gatecheck"
FEAT="$REPO/$FEAT_REL"
mkdir -p "$FEAT"

seed_feature() {
  jq -n --arg base "$BASE_SHA" \
    '{slug:"gatecheck", schemaVersion:7, baseSha:$base, warnings:[],
      artifacts:{tasks:".loop-spec/features/gatecheck/tasks.json"},
      commands:{test:"true", lint:"", typecheck:"", prepare:""}}' \
    > "$FEAT/feature.json"
  rm -f "$FEAT/graph-checkpoints.jsonl" "$FEAT/events.jsonl" "$FEAT/graph-pause.json"
}

# Committed, because the marker and tamper scans diff <base>..HEAD.
commit_all() {
  git -C "$REPO" -c commit.gpgsign=false add -A
  git -C "$REPO" -c commit.gpgsign=false commit -q -m "$1"
}

run_gate() {
  local graph="$1" rc=0
  ( cd "$REPO" && bash "$SCRIPT" --feature-dir "$FEAT_REL" "$graph" ) >"$WORK/out.txt" 2>&1 || rc=$?
  echo "$rc"
}

## --- 1. verify.marker: a clean diff passes, an added TODO blocks ---
gate_graph "verify.marker" "$WORK/marker.json"
seed_feature
printf 'def sub(a, b):\n    return a - b\n' >> "$REPO/app.py"
commit_all "clean change"
check "verify.marker passes a clean diff through graph dispatch" "0" "$(run_gate "$WORK/marker.json")"

seed_feature
printf '# TODO: finish this\n' >> "$REPO/app.py"
commit_all "stub"
check "verify.marker blocks an added placeholder marker" "1" "$(run_gate "$WORK/marker.json")"
check "the blocked gate reports the scan's own finding, not a bare usage error" "1" \
  "$(grep -c "placeholder marker" "$WORK/out.txt")"

git -C "$REPO" -c commit.gpgsign=false revert --no-edit HEAD >/dev/null

## --- 2. verify.tamper: a clean diff passes, an added skip blocks ---
gate_graph "verify.tamper" "$WORK/tamper.json"
seed_feature
check "verify.tamper passes an untampered diff through graph dispatch" "0" "$(run_gate "$WORK/tamper.json")"

seed_feature
printf '@pytest.mark.skip\ndef test_more():\n    assert True\n' >> "$REPO/tests/test_app.py"
commit_all "skip a test"
check "verify.tamper blocks an added skip annotation" "1" "$(run_gate "$WORK/tamper.json")"
check "the blocked tamper gate reports the tampering signal" "1" \
  "$(grep -c "skip/focus added" "$WORK/out.txt")"

git -C "$REPO" -c commit.gpgsign=false revert --no-edit HEAD >/dev/null

## --- 3. verify.acceptance: reads the persisted tasks.json, not stdin ---
gate_graph "verify.acceptance" "$WORK/acceptance.json"
seed_feature
echo '[{"id":"task-001","acceptanceCriteria":["pytest tests/test_app.py passes"]}]' \
  > "$FEAT/tasks.json"
check "verify.acceptance passes behavioral criteria through graph dispatch" "0" \
  "$(run_gate "$WORK/acceptance.json")"

seed_feature
echo '[{"id":"task-002","acceptanceCriteria":["grep -c \"add\" app.py returns 2"]}]' \
  > "$FEAT/tasks.json"
check "verify.acceptance blocks a bare-substring grep criterion" "1" \
  "$(run_gate "$WORK/acceptance.json")"
check "the blocked acceptance gate names the offending task" "1" \
  "$(grep -c "task-002" "$WORK/out.txt")"

## --- 4. Missing single-repo baseSha is a scan-target failure, not a bare usage error ---
seed_feature
jq 'del(.baseSha)' "$FEAT/feature.json" > "$FEAT/feature.json.tmp"
mv "$FEAT/feature.json.tmp" "$FEAT/feature.json"
check "a shipped marker gate without baseSha blocks" "1" "$(run_gate "$WORK/marker.json")"
check "the missing baseSha is named, not an unresolved {baseSha} placeholder" "1" \
  "$(grep -c "no baseSha" "$WORK/out.txt")"
check "the diagnostic is not the old unresolved-placeholder abort" "0" \
  "$(grep -c "unresolved bodyArgs placeholder" "$WORK/out.txt" || true)"

## --- 4b. An unresolvable bodyArgs placeholder is still a named dispatch failure ---
cat > "$WORK/unresolved.json" <<'EOF'
{
  "entry": "g",
  "nodes": [{"id":"g","kind":"gate","reads":[],"writes":[],"effort":"system1",
             "body":"lib/placeholder-scan.sh","bodyArgs":["{baseSha}"]}],
  "edges": []
}
EOF
seed_feature
jq 'del(.baseSha)' "$FEAT/feature.json" > "$FEAT/feature.json.tmp"
mv "$FEAT/feature.json.tmp" "$FEAT/feature.json"
check "a gate whose bodyArgs cannot resolve blocks" "1" "$(run_gate "$WORK/unresolved.json")"
check "the unresolved placeholder is named in the diagnostic" "1" \
  "$(grep -c "unresolved bodyArgs placeholder" "$WORK/out.txt")"

## --- 5. Workspace mode: per-repo SHAs, workspace root is not a git repo ---
WS="$WORK/workspace"
mkdir -p "$WS/fe/tests" "$WS/be/tests"
init_ws_repo() {
  local d="$1"
  git -C "$d" init -q
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name tester
  printf 'def add(a, b):\n    return a + b\n' > "$d/app.py"
  printf 'def test_add():\n    assert True\n' > "$d/tests/test_app.py"
  git -C "$d" -c commit.gpgsign=false add -A
  git -C "$d" -c commit.gpgsign=false commit -q -m base
}
init_ws_repo "$WS/fe"
init_ws_repo "$WS/be"
FE_SHA="$(git -C "$WS/fe" rev-parse HEAD)"
BE_SHA="$(git -C "$WS/be" rev-parse HEAD)"
# Workspace root must not be a git work tree — that is the production layout.
if git -C "$WS" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "FAIL: workspace fixture root is a git repo"; FAIL=$((FAIL + 1))
else
  echo "PASS: workspace fixture root is not a git repo"; PASS=$((PASS + 1))
fi

WS_FEAT_REL=".loop-spec/features/wsgate"
WS_FEAT="$WS/$WS_FEAT_REL"
mkdir -p "$WS_FEAT"
bash "$ROOT/lib/feature-init.sh" skeleton --mode workspace \
  --slug wsgate --now 2026-01-01T00:00:00Z --style auto \
  --ws-root "$WS" \
  --repos "$(jq -nc --arg fe "$FE_SHA" --arg be "$BE_SHA" \
    '[{"name":"fe","path":"fe","branch":"feat/wsgate","baseSha":$fe,"baseBranch":"main"},
      {"name":"be","path":"be","branch":"feat/wsgate","baseSha":$be,"baseBranch":"main"}]')" \
  > "$WS_FEAT/feature.json"

printf 'def sub(a, b):\n    return a - b\n' >> "$WS/fe/app.py"
git -C "$WS/fe" -c commit.gpgsign=false add -A
git -C "$WS/fe" -c commit.gpgsign=false commit -q -m "clean change"

run_ws_gate() {
  local graph="$1" rc=0
  bash "$SCRIPT" --feature-dir "$WS_FEAT" "$graph" >"$WORK/out.txt" 2>&1 || rc=$?
  echo "$rc"
}

gate_graph "verify.marker" "$WORK/ws-marker.json"
check "workspace verify.marker passes a clean per-repo diff" "0" \
  "$(run_ws_gate "$WORK/ws-marker.json")"
check "workspace marker did not abort on unresolved placeholders" "0" \
  "$(grep -c "unresolved bodyArgs placeholder" "$WORK/out.txt" || true)"

printf '# TODO: finish this\n' >> "$WS/be/app.py"
git -C "$WS/be" -c commit.gpgsign=false add -A
git -C "$WS/be" -c commit.gpgsign=false commit -q -m stub
check "workspace verify.marker blocks a placeholder in one repo" "1" \
  "$(run_ws_gate "$WORK/ws-marker.json")"
check "workspace marker finding names the dirty repo" "1" \
  "$(grep -c "be: .*placeholder marker" "$WORK/out.txt")"

git -C "$WS/be" -c commit.gpgsign=false revert --no-edit HEAD >/dev/null
gate_graph "verify.tamper" "$WORK/ws-tamper.json"
check "workspace verify.tamper passes an untampered workspace" "0" \
  "$(run_ws_gate "$WORK/ws-tamper.json")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
