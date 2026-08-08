#!/usr/bin/env bash
# Unit tests for lib/graph/run.sh — dry-run, routes, human pause, loops, resume.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/graph/run.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-graph-run.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/feat" "$WORK/bin"
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
chmod +x "$SCRIPT"

# --- dry-run visits seven phase nodes, no body dispatch ---
out="$(bash "$SCRIPT" --dry-run --feature-dir "$WORK/feat" "$ROOT/graph/cycle.graph.json")"
rc=$?
check "dry-run exit 0" "0" "$rc"
for phase in spec discuss plan execute verify iterate deliver; do
  echo "$out" | grep -q "^${phase}"$'\t'
  check "dry-run visits $phase" "0" "$?"
done
# Order: spec before discuss before plan before execute before verify before iterate before deliver
python3 - <<PY
import sys
text='''$out'''
order=['spec','discuss','plan','execute','verify','iterate','deliver']
idxs=[]
for line in text.splitlines():
    node=line.split('\t')[0]
    if node in order and node not in idxs:
        idxs.append(node)
sys.exit(0 if idxs==order else 1)
PY
check "dry-run phase order" "0" "$?"

# --- stub probe route taken / not taken ---
printf '#!/usr/bin/env bash\necho MATCHED\nexit 0\n' > "$WORK/bin/probe-yes.sh"
printf '#!/usr/bin/env bash\necho NOPE\nexit 1\n' > "$WORK/bin/probe-no.sh"
chmod +x "$WORK/bin/probe-yes.sh" "$WORK/bin/probe-no.sh"

cat > "$WORK/route.json" <<EOF
{
  "entry": "a",
  "nodes": [
    {"id":"a","kind":"function","reads":[],"writes":[],"effort":"system1"},
    {"id":"b","kind":"function","reads":[],"writes":[],"effort":"system1"},
    {"id":"c","kind":"function","reads":[],"writes":[],"effort":"system1"}
  ],
  "edges": [
    {"from":"a","to":"b","kind":"route","condition":{"probe":"$WORK/bin/probe-yes.sh","expects":"MATCHED"}},
    {"from":"a","to":"c","kind":"chain"}
  ]
}
EOF
# Make probes repo-relative by copying into WORK under a fake root trick:
# validate resolves against repo root — use absolute probe paths (validate allows abs)
# Our validate joins repo_root for relative; absolute should work if isabs.
out="$(bash "$SCRIPT" --dry-run --feature-dir "$WORK/feat2" "$WORK/route.json" 2>&1)" || true
mkdir -p "$WORK/feat2"
# Absolute probes: update validate already supports isabs
bash "$ROOT/lib/graph/validate.sh" "$WORK/route.json" >/dev/null 2>&1 || {
  # If validate rejects abs outside repo, point probes at copied files under repo tmp
  mkdir -p "$ROOT/.tmp-probes-$$"
  cp "$WORK/bin/probe-yes.sh" "$ROOT/.tmp-probes-$$/probe-yes.sh"
  chmod +x "$ROOT/.tmp-probes-$$/probe-yes.sh"
  jq --arg p ".tmp-probes-$$/probe-yes.sh" \
    '.edges[0].condition.probe=$p' "$WORK/route.json" > "$WORK/route2.json"
  mv "$WORK/route2.json" "$WORK/route.json"
}
out="$(bash "$SCRIPT" --dry-run --feature-dir "$WORK/feat2" "$WORK/route.json")"
echo "$out" | grep -q $'^b\t'
check "route taken when probe matches" "0" "$?"

# not-taken: expects never matches -> falls through to chain c
jq '.edges[0].condition.expects="NEVER"' "$WORK/route.json" > "$WORK/route-no.json"
out="$(bash "$SCRIPT" --dry-run --feature-dir "$WORK/feat3" "$WORK/route-no.json")"
echo "$out" | grep -q $'^c\t'
check "route not taken falls to chain" "0" "$?"

# --- human pause ---
cat > "$WORK/human.json" <<'EOF'
{
  "entry": "start",
  "nodes": [
    {"id":"start","kind":"function","reads":[],"writes":[],"effort":"system1"},
    {"id":"ask","kind":"human","reads":[],"writes":[],"effort":"system1"},
    {"id":"done","kind":"function","reads":[],"writes":[],"effort":"system1"}
  ],
  "edges": [
    {"from":"start","to":"ask","kind":"chain"},
    {"from":"ask","to":"done","kind":"chain"}
  ]
}
EOF
mkdir -p "$WORK/feat-human"
# seed feature.json for checkpoint hashing
jq -n '{slug:"h",schemaVersion:7}' > "$WORK/feat-human/feature.json"
rc=0
bash "$SCRIPT" --feature-dir "$WORK/feat-human" "$WORK/human.json" >/dev/null 2>&1 || rc=$?
check "human pause exit 4" "4" "$rc"
[[ -f "$WORK/feat-human/graph-pause.json" ]]
check "pause record written" "0" "$?"
node="$(jq -r '.node' "$WORK/feat-human/graph-pause.json")"
check "pause node is ask" "ask" "$node"

# resume continues at ask (will pause again immediately in non-dry — so dry-run resume)
# Append checkpoint at ask already exists; dry-run --resume should start at ask
out="$(bash "$SCRIPT" --dry-run --resume --feature-dir "$WORK/feat-human" "$WORK/human.json")"
first="$(echo "$out" | head -1 | cut -f1)"
check "resume starts at interrupted node" "ask" "$first"

# --- loop ceiling ---
cat > "$WORK/loop.json" <<'EOF'
{
  "entry": "a",
  "nodes": [
    {"id":"a","kind":"function","reads":[],"writes":[],"effort":"system1"},
    {"id":"b","kind":"function","reads":[],"writes":[],"effort":"system1"}
  ],
  "edges": [
    {"from":"a","to":"b","kind":"chain"},
    {"from":"b","to":"a","kind":"loop","ceiling":2,"strategy":"unroll"},
    {"from":"b","to":"a","kind":"loop","ceiling":2,"strategy":"contain"}
  ]
}
EOF
# simplify - one loop edge
cat > "$WORK/loop.json" <<'EOF'
{
  "entry": "a",
  "nodes": [
    {"id":"a","kind":"function","reads":[],"writes":[],"effort":"system1"},
    {"id":"b","kind":"function","reads":[],"writes":[],"effort":"system1"},
    {"id":"z","kind":"function","reads":[],"writes":[],"effort":"system1"}
  ],
  "edges": [
    {"from":"a","to":"b","kind":"chain"},
    {"from":"b","to":"a","kind":"loop","ceiling":2,"strategy":"unroll"},
    {"from":"b","to":"z","kind":"chain"}
  ]
}
EOF
out="$(bash "$SCRIPT" --dry-run --feature-dir "$WORK/feat-loop" "$WORK/loop.json")"
# a appears at most 1 + ceiling times
acount="$(echo "$out" | grep -c $'^a\t' || true)"
check "loop respects ceiling (a count <= 3)" "1" "$([[ "$acount" -le 3 ]] && echo 1 || echo 0)"
echo "$out" | grep -q $'^z\t'
check "loop eventually proceeds to z" "0" "$?"

# --- completes without stall (deadlock guard) ---
rc=0
bash "$SCRIPT" --dry-run --feature-dir "$WORK/feat" "$ROOT/graph/cycle.graph.json" >/dev/null || rc=$?
check "cycle dry-run completes" "0" "$rc"

# --- result keys ---
mkdir -p "$WORK/feat-result"
jq -n '{slug:"r",schemaVersion:7}' > "$WORK/feat-result/feature.json"
bash "$SCRIPT" --feature-dir "$WORK/feat-result" "$WORK/human.json" >/dev/null 2>&1 || true
[[ -f "$WORK/feat-result/result.json" ]]
check "result.json written" "0" "$?"
for key in schema status summary converged warnings; do
  jq -e --arg k "$key" 'has($k)' "$WORK/feat-result/result.json" >/dev/null
  check "result has $key" "0" "$?"
done

# --- no harness branching in engine ---
if grep -nE 'CLAUDE_CODE|opencode|pi\.dev|LOOP_SPEC_HARNESS' "$SCRIPT" | grep -v 'harness-neutral\|lib/harness' >/dev/null; then
  check "engine harness-neutral" "0" "1"
else
  check "engine harness-neutral" "0" "0"
fi

rm -rf "$ROOT"/.tmp-probes-*

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
