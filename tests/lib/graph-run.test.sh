#!/usr/bin/env bash
# Unit tests for lib/graph/run.sh — routes, admit/skip, resume, --step, abort,
# and mutation proofs for the two shipped-3.0 route-evaluation bugs
# (docs/loop-spec/features/gdd/REMEDIATION-CONTRACT.md).
#
# Synthetic graphs isolate each routing contract below. Section 0 also requires
# the shipped cycle graph to validate and traverse its primary phases.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/graph/run.sh"
ENGINE="$ROOT/lib/graph/engine.py"
WORK="${TMPDIR:-/tmp}/loop-spec-graph-run.$$"
trap 'cp "$BACKUP" "$ENGINE" 2>/dev/null || true; rm -rf "$WORK"' EXIT
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

[[ -f "$SCRIPT" && -f "$ENGINE" ]] || { echo "FAIL: missing graph launcher or engine"; exit 1; }
chmod +x "$SCRIPT"
BACKUP="$WORK/engine.py.orig"
cp "$ENGINE" "$BACKUP"

new_feat() {
  local dir="$1"; shift
  mkdir -p "$dir"
  jq -n "$@" > "$dir/feature.json"
}

## --- 0. cycle.graph.json.
##      Route conditions ARE evaluated during --dry-run (only body dispatch is
##      skipped), so a real feature.json is seeded to route past every gate
##      cleanly: no security signal, no iterate gap, delivery complete, auto
##      style so every human node's admit resolves to skip.
if bash "$ROOT/lib/graph/validate.sh" "$ROOT/graph/cycle.graph.json" >/dev/null 2>&1; then
  # plan-critique.sh (unlike a synthetic stub) resolves via a real `git diff`
  # against feature.json.baseSha inside an actual repo -- a throwaway one, so
  # this stays outside the tree under test.
  mkdir -p "$WORK/cyclerepo"
  git -C "$WORK/cyclerepo" init -q
  git -C "$WORK/cyclerepo" config user.email t@example.com
  git -C "$WORK/cyclerepo" config user.name tester
  : > "$WORK/cyclerepo/README.md"
  git -C "$WORK/cyclerepo" -c commit.gpgsign=false add README.md
  git -C "$WORK/cyclerepo" -c commit.gpgsign=false commit -q -m base
  base_sha="$(git -C "$WORK/cyclerepo" rev-parse HEAD)"
  mkdir -p "$WORK/cyclerepo/.loop-spec/features/cyclecheck"
  jq -n --arg base "$base_sha" '{slug:"cyclecheck",schemaVersion:7,execStyle:"auto",
    baseSha:$base,iterate:{used:0,feedback:null},
    delivery:{nextPhase:"completed"}}' \
    > "$WORK/cyclerepo/.loop-spec/features/cyclecheck/feature.json"
  set +e
  out="$(cd "$WORK/cyclerepo" && bash "$SCRIPT" --dry-run \
    --feature-dir ".loop-spec/features/cyclecheck" "$ROOT/graph/cycle.graph.json")"
  rc=$?
  set -e
  check "cycle.graph.json dry-run: execStyle auto reaches completed without pausing (rc 0)" "0" "$rc"
  for phase in spec discuss plan execute verify iterate deliver completed; do
    echo "$out" | grep -q "^${phase}"$'\t'
    check "cycle.graph.json dry-run visits $phase" "0" "$?"
  done
else
  check "cycle.graph.json validates" "0" "1"
fi

## --- 1. dry-run: structural walk, no state/dispatch side effects ---
cat > "$WORK/basic.json" <<'EOF'
{
  "entry": "a",
  "nodes": [
    {"id":"a","kind":"function","reads":[],"writes":[],"effort":"system1"},
    {"id":"b","kind":"function","reads":[],"writes":[],"effort":"system1"}
  ],
  "edges": [{"from":"a","to":"b","kind":"chain"}]
}
EOF
out="$(bash "$SCRIPT" --dry-run --feature-dir "$WORK/feat-basic" "$WORK/basic.json")"
check "dry-run exit 0" "0" "$?"
echo "$out" | grep -q $'^a\tentry\tfunction\ta$'
check "dry-run prints node/edge/kind for a" "0" "$?"
echo "$out" | grep -q $'^b\tchain:a->b\tfunction\tb$'
check "dry-run prints node/edge/kind for b" "0" "$?"
check "dry-run writes no checkpoint ledger" "1" "$([[ -f "$WORK/feat-basic/graph-checkpoints.jsonl" ]] && echo 0 || echo 1)"

## --- 2. route: EXACT match required (contract sec 1-2), never substring ---
cat > "$WORK/bin/prefix-probe.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--answers" ]]; then printf 'AB\nABC\n'; exit 0; fi
echo "ABC reason=token-is-a-superstring-of-the-declared-expects"
exit 0
EOF
chmod +x "$WORK/bin/prefix-probe.sh"
cat > "$WORK/route-exact.json" <<EOF
{
  "entry": "a",
  "nodes": [
    {"id":"a","kind":"function","reads":[],"writes":[],"effort":"system1","routeDefault":"c"},
    {"id":"b","kind":"function","reads":[],"writes":[],"effort":"system1"},
    {"id":"c","kind":"function","reads":[],"writes":[],"effort":"system1"}
  ],
  "edges": [
    {"from":"a","to":"b","kind":"route","condition":{"probe":"$WORK/bin/prefix-probe.sh","args":[],"expects":"AB"}},
    {"from":"a","to":"c","kind":"chain"}
  ]
}
EOF
bash "$ROOT/lib/graph/validate.sh" "$WORK/route-exact.json" >/dev/null
check "route-exact graph validates" "0" "$?"
new_feat "$WORK/feat-exact" '{slug:"exact",schemaVersion:7}'
out="$(bash "$SCRIPT" --feature-dir "$WORK/feat-exact" "$WORK/route-exact.json")"
check "exact-match: probe token ABC does not satisfy expects AB (b not visited)" "0" "$(echo "$out" | grep -c $'^b\t')"
check "exact-match: falls to routeDefault c, not a bare chain fallthrough" "1" "$(echo "$out" | grep -c $'^c\t')"

## --- 3. route: `args` substitution + probe args actually reach the probe ---
cat > "$WORK/bin/echo-args-probe.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--answers" ]]; then printf 'saw-args\nno-args\n'; exit 0; fi
if [[ "${1:-}" == "--feature-dir" && -n "${2:-}" && -d "$2" ]]; then
  echo "saw-args reason=featureDir-substituted-to-$2"
else
  echo "no-args reason=args-empty-or-unresolved"
fi
exit 0
EOF
chmod +x "$WORK/bin/echo-args-probe.sh"
cat > "$WORK/route-args.json" <<EOF
{
  "entry": "a",
  "nodes": [
    {"id":"a","kind":"function","reads":[],"writes":[],"effort":"system1"},
    {"id":"b","kind":"function","reads":[],"writes":[],"effort":"system1"}
  ],
  "edges": [
    {"from":"a","to":"b","kind":"route","condition":{"probe":"$WORK/bin/echo-args-probe.sh","args":["--feature-dir","{featureDir}"],"expects":"saw-args"}}
  ]
}
EOF
bash "$ROOT/lib/graph/validate.sh" "$WORK/route-args.json" >/dev/null
check "route-args graph validates" "0" "$?"
new_feat "$WORK/feat-args" '{slug:"args",schemaVersion:7}'
out="$(bash "$SCRIPT" --feature-dir "$WORK/feat-args" "$WORK/route-args.json")"
echo "$out" | grep -q $'^b\t'
check "route args (contract sec 1: {featureDir} substituted, args reach probe)" "0" "$?"

## --- 4. expects:"none" is an ordinary token — fails closed on a crashing probe ---
cat > "$WORK/bin/crash-probe.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--answers" ]]; then printf 'none\nmatched\n'; exit 0; fi
exit 2   # simulates a probe invoked with missing/wrong args
EOF
chmod +x "$WORK/bin/crash-probe.sh"
cat > "$WORK/gate-none.json" <<EOF
{
  "entry": "gate",
  "nodes": [
    {"id":"gate","kind":"function","reads":[],"writes":[],"effort":"system1","routeDefault":"heavy"},
    {"id":"skip","kind":"function","reads":[],"writes":[],"effort":"system1"},
    {"id":"heavy","kind":"function","reads":[],"writes":[],"effort":"system1"}
  ],
  "edges": [
    {"from":"gate","to":"skip","kind":"route","condition":{"probe":"$WORK/bin/crash-probe.sh","args":[],"expects":"none"}},
    {"from":"gate","to":"heavy","kind":"chain"}
  ]
}
EOF
bash "$ROOT/lib/graph/validate.sh" "$WORK/gate-none.json" >/dev/null
check "gate-none graph validates" "0" "$?"
new_feat "$WORK/feat-none" '{slug:"none",schemaVersion:7}'
out="$(bash "$SCRIPT" --feature-dir "$WORK/feat-none" "$WORK/gate-none.json")"
check "crashed probe with expects=none never satisfies (skip not visited)" "0" "$(echo "$out" | grep -c $'^skip\t')"
check "falls to routeDefault heavy, the security-sensitive path stays live" "1" "$(echo "$out" | grep -c $'^heavy\t')"

## --- 5. abort: route edges present, none satisfied, no routeDefault -> exit 5, no chain fallthrough ---
cat > "$WORK/abort.json" <<EOF
{
  "entry": "a",
  "nodes": [
    {"id":"a","kind":"function","reads":[],"writes":[],"effort":"system1"},
    {"id":"b","kind":"function","reads":[],"writes":[],"effort":"system1"},
    {"id":"c","kind":"function","reads":[],"writes":[],"effort":"system1"}
  ],
  "edges": [
    {"from":"a","to":"b","kind":"route","condition":{"probe":"$ROOT/lib/graph/probes/exec-style.sh","args":["--feature-dir","{featureDir}"],"expects":"style=interactive"}},
    {"from":"a","to":"c","kind":"chain"}
  ]
}
EOF
bash "$ROOT/lib/graph/validate.sh" "$WORK/abort.json" >/dev/null
check "abort graph validates" "0" "$?"
new_feat "$WORK/feat-abort" '{slug:"abortme",schemaVersion:7,execStyle:"auto"}'
set +e
out="$(bash "$SCRIPT" --feature-dir "$WORK/feat-abort" "$WORK/abort.json" 2>&1)"
rc=$?
set -e
check "unsatisfied route with no routeDefault: exit 5" "5" "$rc"
check "unsatisfied route: chain c is NEVER silently taken" "0" "$(echo "$out" | grep -c $'^c\t')"
echo "$out" | grep -q "no route satisfied at node 'a'"
check "abort diagnostic names the node" "0" "$?"

## --- 6. human node: execStyle auto traverses the WHOLE graph without pausing ---
cat > "$WORK/human.json" <<EOF
{
  "entry": "a",
  "nodes": [
    {"id":"a","kind":"function","reads":[],"writes":[],"effort":"system1"},
    {"id":"human.after-a","kind":"human","reads":[],"writes":[],"effort":"system1",
     "admit":{"probe":"$ROOT/lib/graph/probes/exec-style.sh","args":["--feature-dir","{featureDir}"],"expects":"style=step"}},
    {"id":"b","kind":"function","reads":[],"writes":[],"effort":"system1"}
  ],
  "edges": [
    {"from":"a","to":"human.after-a","kind":"chain"},
    {"from":"human.after-a","to":"b","kind":"chain"}
  ]
}
EOF
bash "$ROOT/lib/graph/validate.sh" "$WORK/human.json" >/dev/null
check "human graph validates" "0" "$?"

new_feat "$WORK/feat-auto" '{slug:"h-auto",schemaVersion:7,execStyle:"auto"}'
set +e
out="$(bash "$SCRIPT" --feature-dir "$WORK/feat-auto" "$WORK/human.json")"
rc=$?
set -e
check "execStyle auto: exit 0 (no pause)" "0" "$rc"
check "execStyle auto: reaches terminal node b" "1" "$(echo "$out" | grep -c $'^b\t')"
check "execStyle auto: no pause record written" "1" "$([[ -f "$WORK/feat-auto/graph-pause.json" ]] && echo 0 || echo 1)"

new_feat "$WORK/feat-review" '{slug:"h-review",schemaVersion:7,execStyle:"review-only"}'
set +e
out="$(bash "$SCRIPT" --feature-dir "$WORK/feat-review" "$WORK/human.json")"
rc=$?
set -e
check "execStyle review-only: exit 0 (no pause)" "0" "$rc"
check "execStyle review-only: reaches terminal node b" "1" "$(echo "$out" | grep -c $'^b\t')"

## --- 7. human node: execStyle step DOES pause, and never re-enters on resume ---
new_feat "$WORK/feat-step" '{slug:"h-step",schemaVersion:7,execStyle:"step"}'
set +e
out="$(bash "$SCRIPT" --feature-dir "$WORK/feat-step" "$WORK/human.json" 2>&1)"
rc=$?
set -e
check "execStyle step: exit 4 (paused)" "4" "$rc"
check "execStyle step: does not reach b in the same invocation" "0" "$(echo "$out" | grep -c $'^b\t')"
[[ -f "$WORK/feat-step/graph-pause.json" ]]
check "pause record written" "0" "$?"
check "pause record names the human node" "human.after-a" "$(jq -r '.node' "$WORK/feat-step/graph-pause.json")"

out="$(bash "$SCRIPT" --resume --feature-dir "$WORK/feat-step" "$WORK/human.json")"
first_node="$(echo "$out" | head -1 | cut -f1)"
check "resume starts at the SUCCESSOR of the paused node (b), never re-enters it" "b" "$first_node"
check "resume deletes the pause record" "1" "$([[ -f "$WORK/feat-step/graph-pause.json" ]] && echo 0 || echo 1)"

## --- 8. resume, pre-3.0 compatibility path: feature.json.currentPhase, empty ledger ---
cat > "$WORK/phases.json" <<'EOF'
{
  "entry": "spec",
  "nodes": [
    {"id":"spec","kind":"function","reads":[],"writes":["currentPhase"],"effort":"system1"},
    {"id":"discuss","kind":"function","reads":[],"writes":["currentPhase"],"effort":"system1"},
    {"id":"plan","kind":"function","reads":[],"writes":["currentPhase"],"effort":"system1"},
    {"id":"execute","kind":"function","reads":[],"writes":["currentPhase"],"effort":"system1"},
    {"id":"verify","kind":"function","reads":[],"writes":["currentPhase"],"effort":"system1"}
  ],
  "edges": [
    {"from":"spec","to":"discuss","kind":"chain"},
    {"from":"discuss","to":"plan","kind":"chain"},
    {"from":"plan","to":"execute","kind":"chain"},
    {"from":"execute","to":"verify","kind":"chain"}
  ]
}
EOF
bash "$ROOT/lib/graph/validate.sh" "$WORK/phases.json" >/dev/null
check "phases graph validates" "0" "$?"
new_feat "$WORK/feat-pre3" '{slug:"pre3",schemaVersion:6,currentPhase:"verify"}'
out="$(bash "$SCRIPT" --resume --feature-dir "$WORK/feat-pre3" "$WORK/phases.json")"
first_node="$(echo "$out" | head -1 | cut -f1)"
check "pre-3.0 resume (empty ledger) starts at feature.json.currentPhase, not graph entry" "verify" "$first_node"
check "pre-3.0 resume: spec is NEVER re-entered" "0" "$(echo "$out" | grep -c $'^spec\t')"
check "pre-3.0 resume: currentPhase is UNCHANGED afterward (verify is terminal here)" "verify" "$(jq -r '.currentPhase' "$WORK/feat-pre3/feature.json")"

## --- 9. resume from a non-empty ledger: successor of the last checkpointed node ---
new_feat "$WORK/feat-ledger" '{slug:"ledger",schemaVersion:7}'
bash "$ROOT/lib/graph/checkpoint.sh" append --feature-dir "$WORK/feat-ledger" \
  --node plan --edge 'chain:discuss->plan' --effort system2
out="$(bash "$SCRIPT" --resume --feature-dir "$WORK/feat-ledger" "$WORK/phases.json")"
first_node="$(echo "$out" | head -1 | cut -f1)"
check "ledger resume starts at successor of the last checkpointed node" "execute" "$first_node"

## --- 10. --step: agent nodes defer routing to a subsequent call (state may
##         not exist yet); non-agent kinds resolve nextEdge immediately ---
cat > "$WORK/step-agent.json" <<'EOF'
{
  "entry": "iterate",
  "nodes": [
    {"id":"iterate","kind":"agent","reads":[],"writes":[],"effort":"system2","body":"skills/iterate/SKILL.md"},
    {"id":"planX","kind":"function","reads":[],"writes":[],"effort":"system1"},
    {"id":"doneX","kind":"function","reads":[],"writes":[],"effort":"system1"}
  ],
  "edges": [
    {"from":"iterate","to":"planX","kind":"route","condition":{"probe":"lib/graph/probes/iterate-gap.sh","args":["--feature-dir","{featureDir}"],"expects":"gap=plan"}},
    {"from":"iterate","to":"doneX","kind":"route","condition":{"probe":"lib/graph/probes/iterate-gap.sh","args":["--feature-dir","{featureDir}"],"expects":"gap=none"}}
  ]
}
EOF
bash "$ROOT/lib/graph/validate.sh" "$WORK/step-agent.json" >/dev/null
check "step-agent graph validates" "0" "$?"
new_feat "$WORK/feat-step-agent" '{slug:"stepagent",schemaVersion:7,iterate:{used:0,feedback:null}}'
step1="$(bash "$SCRIPT" --step --feature-dir "$WORK/feat-step-agent" "$WORK/step-agent.json")"
check "step 1: descriptor names the agent node" "iterate" "$(jq -r '.node' <<<"$step1")"
check "step 1: descriptor has a human-facing label" "iterate" "$(jq -r '.label' <<<"$step1")"
check "step 1: graph descriptor stays model-neutral" "false" "$(jq 'has("model")' <<<"$step1")"
check "step 1: agent kind never dispatches body itself" "agent" "$(jq -r '.kind' <<<"$step1")"
check "step 1: nextEdge deferred (null) — routing depends on state the caller hasn't written yet" "null" "$(jq -r '.nextEdge' <<<"$step1")"

jq '.iterate.feedback = {type:"plan",description:"x",fix_first:null}' \
  "$WORK/feat-step-agent/feature.json" > "$WORK/feat-step-agent/feature.json.tmp"
mv "$WORK/feat-step-agent/feature.json.tmp" "$WORK/feat-step-agent/feature.json"

step2="$(bash "$SCRIPT" --step --feature-dir "$WORK/feat-step-agent" "$WORK/step-agent.json")"
check "step 2 (after caller's dispatch wrote fresh state): resolves the real route" "planX" "$(jq -r '.node' <<<"$step2")"
check "step 2: nextEdge reflects the route actually taken" "route:iterate->planX" "$(jq -r '.nextEdge' <<<"$step2")"
check "step 2: terminal (no further edges from planX)" "true" "$(jq -r '.terminal' <<<"$step2")"

## --- 11. --step: function/gate dispatched in-process; human admit pauses too ---
new_feat "$WORK/feat-step-human" '{slug:"stephuman",schemaVersion:7,execStyle:"step"}'
s1="$(bash "$SCRIPT" --step --feature-dir "$WORK/feat-step-human" "$WORK/human.json")"
check "step 1: node a (function), not paused" "false" "$(jq -r '.paused' <<<"$s1")"
set +e
s2="$(bash "$SCRIPT" --step --feature-dir "$WORK/feat-step-human" "$WORK/human.json")"
rc=$?
set -e
check "step 2: exit 4 at the admitted human node" "4" "$rc"
check "step 2: descriptor reports paused" "true" "$(jq -r '.paused' <<<"$s2")"

## --- 12. wiring: state.sh assert-reads is enforced on node entry ---
cat > "$WORK/reads-fail.json" <<'EOF'
{
  "entry": "a",
  "nodes": [{"id":"a","kind":"function","reads":["prUrl"],"writes":[],"effort":"system1"}],
  "edges": []
}
EOF
bash "$ROOT/lib/graph/validate.sh" "$WORK/reads-fail.json" >/dev/null
check "reads-fail graph validates" "0" "$?"
new_feat "$WORK/feat-reads" '{slug:"reads",schemaVersion:7}'
set +e
out="$(bash "$SCRIPT" --feature-dir "$WORK/feat-reads" "$WORK/reads-fail.json" 2>&1)"
rc=$?
set -e
check "unsatisfied declared read is enforced (state.sh wired, not orphaned): exit 1" "1" "$rc"
echo "$out" | grep -q "assert-reads"
check "diagnostic names assert-reads" "0" "$?"

## --- 13. wiring: gate body failure invokes conflict-monitor.sh and blocks the phase ---
cat > "$WORK/bin/failing-gate.sh" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$WORK/bin/failing-gate.sh"
cp "$WORK/bin/failing-gate.sh" "$ROOT/.tmp-gate-$$.sh"
chmod +x "$ROOT/.tmp-gate-$$.sh"
cat > "$WORK/gate-fail.json" <<EOF
{
  "entry": "g",
  "nodes": [
    {"id":"g","kind":"gate","reads":[],"writes":[],"effort":"system1","body":".tmp-gate-$$.sh"},
    {"id":"after","kind":"function","reads":[],"writes":[],"effort":"system1"}
  ],
  "edges": [{"from":"g","to":"after","kind":"chain"}]
}
EOF
bash "$ROOT/lib/graph/validate.sh" "$WORK/gate-fail.json" >/dev/null
check "gate-fail graph validates" "0" "$?"
new_feat "$WORK/feat-gatefail" '{slug:"gatefail",schemaVersion:7}'
set +e
out="$(bash "$SCRIPT" --feature-dir "$WORK/feat-gatefail" "$WORK/gate-fail.json" 2>&1)"
rc=$?
set -e
rm -f "$ROOT/.tmp-gate-$$.sh"
check "gate nodes ARE dispatched and a failing gate blocks the phase: exit 1" "1" "$rc"
check "failing gate never reaches its chain successor" "0" "$(echo "$out" | grep -c $'^after\t')"
echo "$out" | grep -q "conflict="
check "conflict-monitor.sh wired (its answer appears in the diagnostic)" "0" "$?"

## --- 14. wiring: trace stamps the REAL probe/token, never the literal
##          probe="none" reason="admitting-edge" stamp — needs a route that
##          actually FIRES (route-args.json's probe always matches) ---
new_feat "$WORK/feat-trace" '{slug:"tracecheck",schemaVersion:7}'
trace_rc=0
bash "$SCRIPT" --feature-dir "$WORK/feat-trace" "$WORK/route-args.json" >/dev/null 2>&1 || trace_rc=$?
route_event="$(jq -c 'select(.probe != null and .probe != "none")' "$WORK/feat-trace/events.jsonl" 2>/dev/null | tail -1)"
check "a route-taken edge is traced with a real probe path (not \"none\")" "0" "$([[ -n "$route_event" ]] && echo 0 || echo 1)"
check "route trace records the real answer token, not the literal \"admitting-edge\" stamp" \
  "saw-args" "$(jq -r '.probeReason' <<<"$route_event" 2>/dev/null | grep -o '^saw-args')"

## --- 15. wiring: the `completed` node's body (lib/cycle-result.sh) is invoked
##          with real arguments, publishing .loop-spec/last-result.json —
##          never a hand-built result object, never a bare no-args dispatch ---
GITWORK="$WORK/gitrepo"
mkdir -p "$GITWORK"
git -C "$GITWORK" init -q
git -C "$GITWORK" config user.email t@example.com
git -C "$GITWORK" config user.name tester
: > "$GITWORK/README.md"
git -C "$GITWORK" add README.md
git -C "$GITWORK" commit -q -m base
mkdir -p "$GITWORK/.loop-spec/features/f1"
jq -n '{slug:"f1",schemaVersion:7,currentPhase:"deliver",delivery:{}}' \
  > "$GITWORK/.loop-spec/features/f1/feature.json"
cat > "$WORK/completed.json" <<EOF
{
  "entry": "done",
  "nodes": [{"id":"done","kind":"function","reads":["delivery","currentPhase"],"writes":["currentPhase"],"effort":"system1","body":"lib/cycle-result.sh"}],
  "edges": []
}
EOF
bash "$ROOT/lib/graph/validate.sh" "$WORK/completed.json" >/dev/null
check "completed graph validates" "0" "$?"
( cd "$GITWORK" && bash "$SCRIPT" --feature-dir ".loop-spec/features/f1" "$WORK/completed.json" >/dev/null )
[[ -f "$GITWORK/.loop-spec/last-result.json" ]]
check "completed node publishes .loop-spec/last-result.json via the canonical constructor" "0" "$?"
check "published result has status completed" "completed" "$(jq -r '.status' "$GITWORK/.loop-spec/last-result.json" 2>/dev/null)"

## --- 16. subgraph: real execution, not an unconditional dry-run ---
cat > "$WORK/nested.json" <<'EOF'
{
  "entry": "inner",
  "nodes": [{"id":"inner","kind":"function","reads":[],"writes":[],"effort":"system1","body":"lib/events.sh"}],
  "edges": []
}
EOF
jq --arg body "$WORK/bin/inner-marker.sh" '.nodes[0].body = $body' \
  "$WORK/nested.json" > "$WORK/nested.json.tmp"
mv "$WORK/nested.json.tmp" "$WORK/nested.json"
cat > "$WORK/bin/inner-marker.sh" <<EOF
#!/usr/bin/env bash
: > "$WORK/inner-ran.marker"
EOF
chmod +x "$WORK/bin/inner-marker.sh"
cat > "$WORK/parent-sub.json" <<EOF
{
  "entry": "outer",
  "nodes": [{"id":"outer","kind":"subgraph","reads":[],"writes":[],"effort":"system2","graph":"$WORK/nested.json"}],
  "edges": []
}
EOF
bash "$ROOT/lib/graph/validate.sh" "$WORK/parent-sub.json" >/dev/null
check "parent-sub graph validates" "0" "$?"
rm -f "$WORK/inner-ran.marker"
new_feat "$WORK/feat-sub" '{slug:"sub",schemaVersion:7}'
bash "$SCRIPT" --feature-dir "$WORK/feat-sub" "$WORK/parent-sub.json" >/dev/null
check "subgraph node executes its nested graph for real (body actually ran)" "0" "$([[ -f "$WORK/inner-ran.marker" ]] && echo 0 || echo 1)"

## --- 17. loop ceiling: bounded, then terminates (no unbounded traversal) ---
cat > "$WORK/loop.json" <<'EOF'
{
  "entry": "a",
  "nodes": [
    {"id":"a","kind":"function","reads":[],"writes":[],"effort":"system1"},
    {"id":"b","kind":"function","reads":[],"writes":[],"effort":"system1"}
  ],
  "edges": [
    {"from":"a","to":"b","kind":"chain"},
    {"from":"b","to":"a","kind":"loop","ceiling":2,"strategy":"unroll"}
  ]
}
EOF
bash "$ROOT/lib/graph/validate.sh" "$WORK/loop.json" >/dev/null
check "loop graph validates" "0" "$?"
out="$(bash "$SCRIPT" --dry-run --feature-dir "$WORK/feat-loop" "$WORK/loop.json")"
acount="$(echo "$out" | grep -c $'^a\t')" || acount=0
check "loop respects ceiling (a visited ceiling+1 = 3 times, never more)" "3" "$acount"
bcount="$(echo "$out" | grep -c $'^b\t')" || bcount=0
check "loop's target b visited once per pass" "3" "$bcount"

## --- 18. no harness branching / no LOOP_SPEC_GRAPH opt-in in the engine ---
if grep -nE 'CLAUDE_CODE|opencode|pi\.dev|LOOP_SPEC_HARNESS' "$SCRIPT" "$ENGINE" \
    | grep -v 'harness-neutral\|lib/harness' >/dev/null; then
  check "engine harness-neutral" "0" "1"
else
  check "engine harness-neutral" "0" "0"
fi
if grep -nE 'LOOP_SPEC_GRAPH' "$SCRIPT" "$ENGINE" "$ROOT/lib/graph/state.sh" \
    "$ROOT/lib/graph/handoff.sh" >/dev/null; then
  check "no LOOP_SPEC_GRAPH in engine libs" "0" "1"
else
  check "no LOOP_SPEC_GRAPH in engine libs" "0" "0"
fi

## --- 19. engine advances currentPhase on phase-node entry; dry-run never mutates ---
cat > "$WORK/phase-advance.json" <<'EOF'
{
  "entry": "spec",
  "nodes": [
    {"id":"spec","kind":"function","reads":[],"writes":["currentPhase"],"effort":"system1"},
    {"id":"discuss","kind":"function","reads":[],"writes":["currentPhase"],"effort":"system1"}
  ],
  "edges": [{"from":"spec","to":"discuss","kind":"chain"}]
}
EOF
new_feat "$WORK/feat-phase" '{slug:"p",schemaVersion:7,currentPhase:"spec"}'
bash "$SCRIPT" --feature-dir "$WORK/feat-phase" "$WORK/phase-advance.json" >/dev/null
check "engine sets currentPhase to discuss" "discuss" "$(jq -r '.currentPhase' "$WORK/feat-phase/feature.json")"
new_feat "$WORK/feat-phase" '{slug:"p",schemaVersion:7,currentPhase:"spec"}'
bash "$SCRIPT" --dry-run --feature-dir "$WORK/feat-phase" "$WORK/phase-advance.json" >/dev/null
check "dry-run leaves currentPhase untouched" "spec" "$(jq -r '.currentPhase' "$WORK/feat-phase/feature.json")"

## --- 21. phase_start/phase_end are emitted by the engine at node
##         transitions. The cycle skill used to ask the agent to run
##         events.sh as prose; a coder who ran the work inline emitted
##         nothing, and the console hid the bar (phase=unknown).
cat > "$WORK/phase-markers.json" <<'EOF'
{
  "entry": "spec",
  "nodes": [
    {"id":"spec","kind":"agent","reads":[],"writes":["currentPhase"],"effort":"system1","body":"skills/spec/SKILL.md"},
    {"id":"discuss","kind":"agent","reads":[],"writes":["currentPhase"],"effort":"system1","body":"skills/discuss/SKILL.md"},
    {"id":"completed","kind":"function","reads":[],"writes":["currentPhase"],"effort":"system1"}
  ],
  "edges": [
    {"from":"spec","to":"discuss","kind":"chain"},
    {"from":"discuss","to":"completed","kind":"chain"}
  ]
}
EOF
bash "$ROOT/lib/graph/validate.sh" "$WORK/phase-markers.json" >/dev/null
check "phase-markers graph validates" "0" "$?"
new_feat "$WORK/feat-markers" '{slug:"markers",schemaVersion:7,currentPhase:"spec"}'

step1="$(bash "$SCRIPT" --step --feature-dir "$WORK/feat-markers" "$WORK/phase-markers.json" 2>"$WORK/markers-err1")"
check "step 1 stdout is parseable JSON (markers must not mix with the descriptor)" \
  "spec" "$(jq -r '.node' <<<"$step1")"
check "step 1 stdout carries no LOOP_SPEC_PHASE marker" "0" \
  "$(grep -c LOOP_SPEC_PHASE <<<"$step1" || true)"
check "step 1 stderr emits LOOP_SPEC_PHASE_START for spec" "1" \
  "$(grep -c '^LOOP_SPEC_PHASE_START' "$WORK/markers-err1" || true)"
check "step 1 stderr emits [SPEC] start" "1" \
  "$(grep -c '\[SPEC\] start' "$WORK/markers-err1" || true)"
check "step 1 writes phase_start to events.jsonl" "spec" \
  "$(jq -r 'select(.event=="phase_start") | .phase' "$WORK/feat-markers/events.jsonl" | tail -1)"
check "step 1 does not write phase_end yet (the agent has not left spec)" "0" \
  "$(jq -r 'select(.event=="phase_end") | .phase' "$WORK/feat-markers/events.jsonl" | grep -c . || true)"

step2="$(bash "$SCRIPT" --step --feature-dir "$WORK/feat-markers" "$WORK/phase-markers.json" 2>"$WORK/markers-err2")"
check "step 2 stdout is parseable JSON" "discuss" "$(jq -r '.node' <<<"$step2")"
check "step 2 stderr emits LOOP_SPEC_PHASE_END for spec" "1" \
  "$(grep -c '^LOOP_SPEC_PHASE_END' "$WORK/markers-err2" || true)"
check "step 2 phase_end next is discuss" "discuss" \
  "$(jq -r 'select(.event=="phase_end" and .phase=="spec") | .next' "$WORK/feat-markers/events.jsonl" | tail -1)"
check "step 2 stderr emits LOOP_SPEC_PHASE_START for discuss" "1" \
  "$(grep -c '^LOOP_SPEC_PHASE_START' "$WORK/markers-err2" || true)"

new_feat "$WORK/feat-markers-dry" '{slug:"mdry",schemaVersion:7,currentPhase:"spec"}'
bash "$SCRIPT" --dry-run --feature-dir "$WORK/feat-markers-dry" "$WORK/phase-markers.json" \
  >/dev/null 2>"$WORK/markers-dry-err"
check "dry-run emits no LOOP_SPEC_PHASE markers" "0" \
  "$(grep -c LOOP_SPEC_PHASE "$WORK/markers-dry-err" || true)"
check "dry-run writes no events.jsonl" "1" \
  "$([[ -f "$WORK/feat-markers-dry/events.jsonl" ]] && echo 0 || echo 1)"

new_feat "$WORK/feat-nophase" '{slug:"nophase",schemaVersion:7}'
bash "$SCRIPT" --step --feature-dir "$WORK/feat-nophase" "$WORK/basic.json" \
  >/dev/null 2>"$WORK/nophase-err"
check "non-phase function node emits no LOOP_SPEC_PHASE_START" "0" \
  "$(grep -c LOOP_SPEC_PHASE_START "$WORK/nophase-err" || true)"

## --- 20. MUTATION PROOF (required) ---
# Re-introduce each of the two shipped-3.0 route-evaluation bugs one at a
# time and prove the suite above (specifically the tests it exists for)
# FAILS, then restore the fixed file. A test that cannot catch these bugs is
# worthless -- the original shipped engine passed 154 suites with both live.

run_check_silently() {
  # Re-run one specific scenario's assertion and report PASS/FAIL without
  # touching the running suite's own $PASS/$FAIL counters.
  local expected="$1" actual="$2"
  [[ "$expected" == "$actual" ]]
}

echo ""
echo "--- mutation proof 1: substring match (\"expects in text\") ---"
python3 - "$ENGINE" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    source = fh.read()
source = source.replace(
    'result["satisfied"] = (token == expects)',
    'result["satisfied"] = (expects in first_line)  # MUTATED',
)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(source)
PYEOF
mkdir -p "$WORK/feat-exact-mut"
out="$(bash "$SCRIPT" --feature-dir "$WORK/feat-exact-mut" "$WORK/route-exact.json")"
if run_check_silently "0" "$(echo "$out" | grep -c $'^b\t')"; then
  echo "FAIL: mutation 1 (substring match) was NOT caught -- test is worthless"
  FAIL=$((FAIL + 1))
else
  echo "PASS: mutation 1 (substring match) makes the exact-match test fail, as required"
  PASS=$((PASS + 1))
fi
cp "$BACKUP" "$ENGINE"

echo "--- mutation proof 2: fail-open for expects==\"none\" on probe crash ---"
python3 - "$ENGINE" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as fh:
    src = fh.read()
old = '''    if proc.returncode != 0:
        result["reason"] = "exit=%d" % proc.returncode
        return result'''
new = '''    if proc.returncode != 0:
        result["reason"] = "exit=%d" % proc.returncode
        if expects == "none":
            result["resolved"] = True
            result["satisfied"] = True
            result["token"] = "none"
        return result'''
assert old in src, "mutation anchor not found"
src = src.replace(old, new, 1)
with open(path, "w") as fh:
    fh.write(src)
PYEOF
mkdir -p "$WORK/feat-none-mut"
out="$(bash "$SCRIPT" --feature-dir "$WORK/feat-none-mut" "$WORK/gate-none.json")"
if run_check_silently "0" "$(echo "$out" | grep -c $'^skip\t')"; then
  echo "FAIL: mutation 2 (fail-open expects=none) was NOT caught -- test is worthless"
  FAIL=$((FAIL + 1))
else
  echo "PASS: mutation 2 (fail-open expects=none) makes the fail-closed test fail, as required"
  PASS=$((PASS + 1))
fi
cp "$BACKUP" "$ENGINE"
diff -q "$BACKUP" "$ENGINE" >/dev/null
check "engine file restored byte-identical after mutation proofs" "0" "$?"

rm -rf "$ROOT"/.tmp-gate-* "$ROOT"/.tmp-probes-* 2>/dev/null || true

## --- 14. effort: the probe runs, and may only RAISE the declared default ---
## Contract sec 7. lib/verification-gap-scan.sh found this: every other wired
## component (assert-reads, conflict-monitor, last-result, subgraph, trace) had
## a behavioural assertion and effort had none, so nothing held engine.py's
## raise-never-lower rule in place. Note --dry-run short-circuits to the
## declared value, so these must be real steps.
cat > "$WORK/effort.json" <<'EOF'
{
  "entry": "cheap",
  "nodes": [
    {"id":"cheap","kind":"function","reads":[],"writes":[],"effort":"system1"},
    {"id":"careful","kind":"function","reads":[],"writes":[],"effort":"system2"}
  ],
  "edges": [{"from":"cheap","to":"careful","kind":"chain"}]
}
EOF
bash "$ROOT/lib/graph/validate.sh" "$WORK/effort.json" >/dev/null
check "effort graph validates" "0" "$?"
new_feat "$WORK/feat-effort" '{slug:"effort",schemaVersion:7}'

# Declared system1 + probe says system2 -> RAISED.
raised="$(LOOP_SPEC_EFFORT=system2 bash "$SCRIPT" --step --feature-dir "$WORK/feat-effort" "$WORK/effort.json")"
check "declared system1 is RAISED to system2 when the probe says so" \
  "system2" "$(jq -r '.effort' <<<"$raised")"

# Declared system2 + probe says system1 -> NOT lowered.
new_feat "$WORK/feat-effort2" '{slug:"effort2",schemaVersion:7}'
cat > "$WORK/effort2.json" <<'EOF'
{
  "entry": "careful",
  "nodes": [{"id":"careful","kind":"function","reads":[],"writes":[],"effort":"system2"}],
  "edges": []
}
EOF
lowered="$(LOOP_SPEC_EFFORT=system1 bash "$SCRIPT" --step --feature-dir "$WORK/feat-effort2" "$WORK/effort2.json")"
check "declared system2 is NOT lowered even when the probe says system1" \
  "system2" "$(jq -r '.effort' <<<"$lowered")"

# The probe is actually consulted: system1 declared + system1 probe stays system1,
# so the raise above came from the probe rather than a blanket default.
# A FRESH feature dir -- stepping an already-stepped one advances to the next
# node, which would silently measure `careful` (declared system2) instead.
new_feat "$WORK/feat-effort3" '{slug:"effort3",schemaVersion:7}'
kept="$(LOOP_SPEC_EFFORT=system1 bash "$SCRIPT" --step --feature-dir "$WORK/feat-effort3" "$WORK/effort.json")"
check "the kept-case really measures the system1 node" "cheap" "$(jq -r '.node' <<<"$kept")"
check "declared system1 stays system1 when the probe agrees" \
  "system1" "$(jq -r '.effort' <<<"$kept")"

## --- 20. cycle.graph.json: the maintenance profile takes a SHORTER declared path
##          through the same graph -- same nodes, same ledger, same terminal result ---
if [[ -d "$WORK/cyclerepo" ]]; then
  short_feat="$WORK/cyclerepo/.loop-spec/features/shortpath"
  mkdir -p "$short_feat"
  seed_short() {
    jq -n --arg base "$base_sha" --arg profile "$1" \
      '{slug:"shortpath",schemaVersion:7,execStyle:"auto",baseSha:$base,
        executionProfile:$profile,iterate:{used:0,feedback:null},
        delivery:{nextPhase:"completed"}}' > "$short_feat/feature.json"
    ( cd "$WORK/cyclerepo" && bash "$SCRIPT" --dry-run \
      --feature-dir ".loop-spec/features/shortpath" "$ROOT/graph/cycle.graph.json" ) | cut -f1
  }
  full_path="$(seed_short standard)"
  short_path="$(seed_short maintenance)"
  check "the standard profile still walks DISCUSS and its critique" "1" \
    "$(grep -cx 'discuss.critique' <<<"$full_path")"
  check "the short path skips DISCUSS" "0" "$(grep -cx 'discuss' <<<"$short_path")"
  check "the short path skips the spec critique protocol" "0" \
    "$(grep -cx 'discuss.critique' <<<"$short_path")"
  check "the standard profile still walks the code-review agent" "1" \
    "$(grep -cx 'verify.code-review' <<<"$full_path")"
  check "the short path skips the code-review agent" "0" \
    "$(grep -cx 'verify.code-review' <<<"$short_path")"
  # Dry-run records VISITS, not body execution. The .sh VERIFY gates are
  # dispatched by tests/lib/graph-gate-dispatch.test.sh; this pins they remain
  # on both declared paths so a non-dry run would reach them.
  for gate in verify.marker verify.tamper verify.acceptance; do
    check "the short path still visits $gate" "1" "$(grep -cx "$gate" <<<"$short_path")"
  done
  # PLAN critique is NOT a short-path bypass: the gate stays on the path and
  # plan-critique.sh decides whether the subgraph runs.
  check "the short path still visits plan.critique.gate" "1" \
    "$(grep -cx 'plan.critique.gate' <<<"$short_path")"
  # Continuity: a shorter path is still the SAME cycle, ending the same way.
  for phase in spec plan execute verify iterate deliver completed; do
    check "the short path still reaches $phase" "1" "$(grep -cx "$phase" <<<"$short_path")"
  done
  check "the short path is strictly shorter" "1" \
    "$([[ "$(wc -l <<<"$short_path")" -lt "$(wc -l <<<"$full_path")" ]] && echo 1 || echo 0)"
  check "cycle graph declares no skippable field" "0" \
    "$(jq '[.nodes[] | select(has("skippable"))] | length' "$ROOT/graph/cycle.graph.json")"
  # Path-length rule 2: every short-path bypass is paired with a full-path
  # route, and the branching node defaults to that full-path successor.
  pair_rc=0
  pair_out="$(python3 - "$ROOT/graph/cycle.graph.json" 2>&1 <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
nodes = {n["id"]: n for n in g["nodes"]}
froms = sorted({
    e["from"] for e in g["edges"]
    if e.get("kind") == "route"
    and (e.get("condition") or {}).get("probe") == "lib/graph/probes/short-path.sh"
})
failed = []
for nid in froms:
    routes = [
        e for e in g["edges"]
        if e.get("from") == nid and e.get("kind") == "route"
        and (e.get("condition") or {}).get("probe") == "lib/graph/probes/short-path.sh"
    ]
    shorts = {e["to"] for e in routes if e["condition"].get("expects") == "path=short"}
    fulls = {e["to"] for e in routes if e["condition"].get("expects") == "path=full"}
    default = nodes[nid].get("routeDefault")
    if len(shorts) != 1 or len(fulls) != 1 or default not in fulls:
        failed.append("%s short=%s full=%s routeDefault=%s" % (
            nid, sorted(shorts), sorted(fulls), default))
if not froms:
    print("no short-path routes")
    sys.exit(1)
if failed:
    print("\n".join(failed))
    sys.exit(1)
print("%d branch(es)" % len(froms))
PY
)" || pair_rc=$?
  check "every short-path bypass pairs with routeDefault to the long path" "0" "$pair_rc"
  if [[ "$pair_rc" != 0 ]]; then
    echo "$pair_out" | sed 's/^/    /'
  fi
  check "the pairing check found the three short-path branches" "3 branch(es)" "$pair_out"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
