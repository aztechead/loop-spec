#!/usr/bin/env bash
# Graph schema validator + residual-prose check (gdd task-016).
#
# Repurposed from the task-004 skills-match-graph conformance test: the prose
# routing it extracted is deleted, so graph/cycle.graph.json is now the single
# routing authority. This suite:
#   (a) validates the declared graph's own shape — entry, node presence,
#       successor reachability, rewind routes and their gap probes, the
#       remediation channel, fanout/fanin, subgraph reuse, and that every
#       script/agent gate body is referenced by a skill; and
#   (b) fails when routing declarations the graph owns — successor/rewind
#       phase-pointer assignments, direct successor invocations, retry budgets
#       duplicating loop ceilings, or a LOOP_SPEC_GRAPH opt-in — reappear in
#       the seven phase skills.
# Carries its own negative cases: a mutated graph and synthetic residual prose
# must both be detected, so a vacuously-passing checker cannot ship.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GRAPH="$ROOT/graph/cycle.graph.json"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

[[ -f "$GRAPH" ]] || { echo "FAIL: missing $GRAPH"; exit 1; }
if bash "$ROOT/lib/graph/validate.sh" "$GRAPH" >/dev/null 2>&1; then
  check "cycle graph passes lib/graph/validate.sh" "0" "0"
else
  check "cycle graph passes lib/graph/validate.sh" "0" "1"
fi

# --- graph shape: the topology the engine executes ---

check "graph entry is spec" "spec" "$(jq -r '.entry' "$GRAPH")"

# Shipped graphs are review surfaces, not just engine input. `validate.sh --strict`
# owns that rule so an extension author can hold their own graph to it; synthetic
# graphs still validate without labels and fall back to their id.
for published_graph in "$ROOT/graph/cycle.graph.json" "$ROOT/graph/critique.graph.json"; do
  strict_rc=0
  bash "$ROOT/lib/graph/validate.sh" --strict "$published_graph" >/dev/null 2>&1 || strict_rc=$?
  check "$(basename "$published_graph") passes strict validation (every node labelled)" "0" "$strict_rc"
done

# Phase agent nodes present
for phase in spec discuss plan execute verify iterate deliver; do
  n="$(jq -r --arg p "$phase" '[.nodes[] | select(.id==$p)] | length' "$GRAPH")"
  check "phase node $phase present" "1" "$n"
done

# Forward chain: SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY -> ITERATE -> DELIVER.
# Allow intermediate human/subgraph/gate nodes: reachability via BFS on all edges.
reachable() {
  local start="$1" goal="$2"
  python3 - "$GRAPH" "$start" "$goal" <<'PY'
import json, sys
g=json.load(open(sys.argv[1]))
start, goal = sys.argv[2], sys.argv[3]
adj={}
for e in g["edges"]:
    adj.setdefault(e["from"], []).append(e["to"])
seen=set(); stack=[start]
while stack:
    cur=stack.pop()
    if cur==goal:
        sys.exit(0)
    if cur in seen: continue
    seen.add(cur)
    stack.extend(adj.get(cur, []))
sys.exit(1)
PY
}

for pair in "spec:discuss" "discuss:plan" "plan:execute" "execute:verify" "verify:iterate" "iterate:deliver" "deliver:completed"; do
  from="${pair%%:*}"; to="${pair##*:}"
  if reachable "$from" "$to"; then
    check "successor $from->$to" "1" "1"
  else
    check "successor $from->$to" "1" "0"
  fi
done

# ITERATE rewind routes, each keyed on a deterministic gap probe
# The gap CLASS and the target PHASE are not the same thing: a spec-level gap
# rewinds to DISCUSS (autonomous refinement mode), never to SPEC. Asserting
# to==spec here is what let that regression through in the first place.
for pair in "execute:execute" "plan:plan" "spec:discuss"; do
  gap="${pair%%:*}"; target="${pair##*:}"
  n="$(jq -r --arg t "$target" --arg e "gap=$gap" '[.edges[] | select(.from=="iterate" and .kind=="route" and .to==$t and .condition.expects==$e)] | length' "$GRAPH")"
  check "iterate rewind route: gap=$gap -> $target" "1" "$([[ "$n" -ge 1 ]] && echo 1 || echo 0)"
  g="$(jq -r --arg e "gap=$gap" '[.edges[] | select(.from=="iterate" and .kind=="route" and .condition.expects==$e)] | length' "$GRAPH")"
  check "iterate route expects gap=$gap" "1" "$([[ "$g" -ge 1 ]] && echo 1 || echo 0)"
done

# Remediation channel: verify writes the tasks, execute reads them, and the
# rewind route consumes them (this is what replaced verify's prose escalation).
chan="$(jq -r '
  ([.nodes[] | select(.id=="verify") | .writes[]?] | index("pendingRemediationTasks") != null) and
  ([.nodes[] | select(.id=="execute") | .reads[]?] | index("pendingRemediationTasks") != null) and
  ([.edges[] | select(.from=="iterate" and .kind=="route" and .to=="execute")] | length > 0)
' "$GRAPH")"
check "verify->execute remediation channel declared" "true" "$chan"

# DELIVER's CI-failure re-entry and its bounded retry loop
d="$(jq -r '[.edges[] | select(.from=="deliver" and .to=="execute" and .kind=="route")] | length' "$GRAPH")"
check "deliver->execute CI-remediation route" "1" "$([[ "$d" -ge 1 ]] && echo 1 || echo 0)"
dl="$(jq -r '[.edges[] | select(.from=="deliver" and .to=="execute" and .kind=="loop" and .ceiling > 0)] | length' "$GRAPH")"
check "deliver->execute retry loop has a ceiling" "1" "$([[ "$dl" -ge 1 ]] && echo 1 || echo 0)"

# ITERATE's round budget lives on the graph loop edge, nowhere else
il="$(jq -r '[.edges[] | select(.from=="iterate" and .to=="verify" and .kind=="loop" and .ceiling > 0)] | length' "$GRAPH")"
check "iterate->verify round loop has a ceiling" "1" "$([[ "$il" -ge 1 ]] && echo 1 || echo 0)"

# EXECUTE fanout/fanin
fanout="$(jq '[.edges[] | select(.kind=="fanout")] | length' "$GRAPH")"
fanin="$(jq '[.edges[] | select(.kind=="fanin")] | length' "$GRAPH")"
check "execute fanout present" "1" "$([[ "$fanout" -ge 1 ]] && echo 1 || echo 0)"
check "execute fanin present" "1" "$([[ "$fanin" -ge 1 ]] && echo 1 || echo 0)"

# Critique subgraph referenced twice
crit="$(jq '[.nodes[] | select(.kind=="subgraph" and .graph=="graph/critique.graph.json")] | length' "$GRAPH")"
check "critique subgraph reused" "2" "$crit"

# Script/agent gate bodies must be referenced by a skill — the graph may not
# bind a gate to an implementation nothing invokes. Symbolic bodies (e.g.
# plan-critique-fastpath) are engine-internal conditions and are exempt.
SKILL_REFS="$(grep -rhoE 'lib/[a-z-]+\.sh|loop-spec:[a-z-]+' "$ROOT/skills" \
  --include=SKILL.md | sort -u)"
while IFS= read -r body; do
  [[ -n "$body" ]] || continue
  if grep -qxF "$body" <<<"$SKILL_REFS"; then
    check "gate body $body referenced by a skill" "1" "1"
  else
    check "gate body $body referenced by a skill" "1" "0"
  fi
done < <(jq -r '.nodes[] | select(.kind=="gate") | .body // empty
                | select(startswith("lib/") or startswith("loop-spec:"))' "$GRAPH")

# Negative case: mutated graph must be detected
mut="$ROOT/graph/.cycle.mutated.$$.json"
jq 'del(.edges[] | select(.from=="spec"))' "$GRAPH" > "$mut"
rc=0
bash "$ROOT/lib/graph/validate.sh" "$mut" >/dev/null 2>&1 || rc=$?
rm -f "$mut"
check "mutated graph detected (non-zero)" "1" "$([[ "$rc" -ne 0 ]] && echo 1 || echo 0)"
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: conformance-negative: mutated graph was accepted" >&2
fi

# --- Residual-prose check (task-016 cutover) ---
# The graph owns successors, rewind targets, gate escalation triggers, and retry
# budgets. A phase skill re-declaring any of them in prose is drift: two routing
# implementations guarantee the unexercised one decays untested.
#
# Banned per phase skill:
#   1. currentPhase assignment to a phase literal — a successor or rewind
#      declaration the graph declares as an edge. The one carve-out is
#      "deliver": the terminal advance/stay pointer write is phase-exit
#      bookkeeping, not route selection (pinned present by
#      tests/delivery-phase-coverage.test.sh).
#   2. direct successor invocation ("Route to `loop-spec:<phase>`") — the
#      engine selects nodes; a skill never invokes its successor.
#   3. a numeric retry budget duplicating a graph loop ceiling ("fixed at N",
#      "bounded to two/N persisted ...").
#   4. any LOOP_SPEC_GRAPH mention — there is no opt-in flag and no prose
#      fallback path; the graph is unconditionally authoritative.
ROUTE_TARGETS='(spec|discuss|plan|execute|verify|iterate)'

residual_prose() {
  # Prints offending lines; returns 0 when the file is clean, 1 when residual found.
  local f="$1" hits
  hits="$(grep -nE \
    -e "currentPhase[[:space:]]*=[[:space:]]*\"${ROUTE_TARGETS}\"" \
    -e "set[[:space:]]+currentPhase[[:space:]]+\"${ROUTE_TARGETS}\"" \
    -e "[Rr]oute to .?loop-spec:(spec|discuss|plan|execute|verify|iterate|deliver)" \
    -e "fixed at [0-9]+" \
    -e "bounded to (two|[0-9]+) persisted" \
    -e "LOOP_SPEC_GRAPH" \
    "$f")" || hits=""
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits"
    return 1
  fi
  return 0
}

for phase in spec discuss plan execute verify iterate deliver; do
  skill="$ROOT/skills/$phase/SKILL.md"
  if out="$(residual_prose "$skill")"; then
    check "no residual routing prose in $phase" "clean" "clean"
  else
    echo "residual routing prose in skills/$phase/SKILL.md:" >&2
    printf '%s\n' "$out" >&2
    check "no residual routing prose in $phase" "clean" "residual"
  fi
done

# Deferral pins: the escalation trigger and rewind routes stay attributed to the
# graph. Losing these citations is how an independent prose declaration creeps back.
cite() {
  local name="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$ROOT/$file"; then
    check "$name" "1" "1"
  else
    echo "missing graph citation: $file lacks '$needle'" >&2
    check "$name" "1" "0"
  fi
}
cite "plan escalation defers to critique graph"    skills/plan/SKILL.md    "graph/critique.graph.json"
cite "discuss escalation defers to critique graph" skills/discuss/SKILL.md "graph/critique.graph.json"
cite "iterate rewinds defer to cycle graph"        skills/iterate/SKILL.md "graph/cycle.graph.json"
cite "verify remediation defers to cycle graph"    skills/verify/SKILL.md  "graph/cycle.graph.json"
cite "deliver CI budget defers to cycle graph"     skills/deliver/SKILL.md "graph/cycle.graph.json"

# Negative case: a synthetic skill carrying each banned declaration class must be
# flagged — a residual check that cannot fail is not a check.
neg="$(mktemp "${TMPDIR:-/tmp}/residual-neg.XXXXXX.md")"
cat > "$neg" <<'MD'
# synthetic phase skill
- Set `currentPhase = "execute"` and go to Phase exit.
MD
if residual_prose "$neg" >/dev/null; then
  check "residual-prose negative (assignment flagged)" "flagged" "missed"
else
  check "residual-prose negative (assignment flagged)" "flagged" "flagged"
fi
cat > "$neg" <<'MD'
# synthetic phase skill
Set LOOP_SPEC_GRAPH=1 to enable the graph engine.
MD
if residual_prose "$neg" >/dev/null; then
  check "residual-prose negative (opt-in flagged)" "flagged" "missed"
else
  check "residual-prose negative (opt-in flagged)" "flagged" "flagged"
fi
cat > "$neg" <<'MD'
# synthetic phase skill
Gate retries: Route to `loop-spec:execute`. This route is bounded to two persisted attempts.
MD
if residual_prose "$neg" >/dev/null; then
  check "residual-prose negative (route/budget flagged)" "flagged" "missed"
else
  check "residual-prose negative (route/budget flagged)" "flagged" "flagged"
fi
rm -f "$neg"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
