#!/usr/bin/env bash
# Conformance test (gdd task-004): the phase skills and graph/cycle.graph.json
# must declare the same topology. Claims are extracted from the skills (forward
# chain, ITERATE rewind targets, gap-class routes, VERIFY's deterministic gates,
# escalation re-entries) and checked against the declared graph, collapsing
# through non-phase nodes (human pauses, critique subgraphs, gate ladder, fanout
# workers). Carries its own negative cases: mutated in-memory copies of the
# graph must be detected, so a vacuously-passing checker cannot ship.
# task-016 repurposes this file once the prose routing is deleted.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GRAPH="$ROOT/graph/cycle.graph.json"
PASS=0; FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if bash "$ROOT/lib/graph/validate.sh" "$GRAPH" >/dev/null 2>&1; then
  pass "shipped cycle graph passes lib/graph/validate.sh (conformance precondition)"
else
  fail "shipped cycle graph fails lib/graph/validate.sh; conformance results would be meaningless"
fi

# --- claim extraction from the skills (fails loudly if a rewording empties it) ---

require() {
  local value="$1" what="$2"
  if [[ -z "$value" ]]; then
    echo "FAIL: extraction produced nothing for $what (skill wording changed? update this test's extraction)"
    exit 1
  fi
}

# skills/cycle/SKILL.md: the forward chain (SPEC -> DISCUSS -> ... -> DELIVER),
# plus the terminal completed hop that DELIVER signals via delivery.nextPhase.
FORWARD_CHAIN="$(grep -oE 'SPEC( -> [A-Z]+)+' "$ROOT/skills/cycle/SKILL.md" \
  | head -1 | tr '[:upper:]' '[:lower:]' | sed 's/ -> / /g')"
require "$FORWARD_CHAIN" "the cycle forward chain"
if grep -q 'nextPhase == "completed"' "$ROOT/skills/deliver/SKILL.md"; then
  FORWARD_CHAIN="$FORWARD_CHAIN completed"
  pass "deliver skill claims the terminal completed hop"
else
  fail "deliver skill no longer claims nextPhase completed (update this test)"
fi
read -r -a chain_arr <<<"$FORWARD_CHAIN"
if (( ${#chain_arr[@]} < 7 )); then
  fail "forward chain extraction found only ${#chain_arr[@]} phases: $FORWARD_CHAIN"
else
  pass "forward chain extracted from cycle skill: $FORWARD_CHAIN"
fi

# skills/cycle/SKILL.md: "matches the explicit rewind set" (wraps to the next line).
REWIND_TARGETS="$(grep -A1 'explicit rewind set' "$ROOT/skills/cycle/SKILL.md" \
  | grep -oE '`[a-z]+(\|[a-z]+)+`' | head -1 | tr -d '`' | tr '|' ' ')"
require "$REWIND_TARGETS" "the cycle explicit rewind set"
if (( $(wc -w <<<"$REWIND_TARGETS") < 3 )); then
  fail "rewind extraction found fewer than 3 targets: $REWIND_TARGETS"
else
  pass "rewind targets extracted from cycle skill: $REWIND_TARGETS"
fi

# skills/iterate/SKILL.md: the gap-class routing bullets ("- **`execute`** — ...").
GAP_CLASSES="$(grep -oE '^- \*\*`[a-z]+`\*\*' "$ROOT/skills/iterate/SKILL.md" \
  | grep -o '`[a-z]*`' | tr -d '`' | sort -u | tr '\n' ' ')"
require "$GAP_CLASSES" "the iterate gap-class bullets"
if [[ "$(wc -w <<<"$GAP_CLASSES")" -ne 3 ]]; then
  fail "expected exactly 3 iterate gap classes, extracted: $GAP_CLASSES"
else
  pass "gap classes extracted from iterate skill: $GAP_CLASSES"
fi

# skills/verify/SKILL.md: deterministic diff gates run against {baseSha}.
VERIFY_GATE_SCRIPTS="$(grep -oE 'lib/[a-z-]+\.sh" "\{baseSha\}"' "$ROOT/skills/verify/SKILL.md" \
  | grep -oE 'lib/[a-z-]+\.sh' | sort -u | tr '\n' ' ')"
require "$VERIFY_GATE_SCRIPTS" "the verify deterministic gate scripts"
if (( $(wc -w <<<"$VERIFY_GATE_SCRIPTS") < 2 )); then
  fail "expected at least 2 verify gate scripts, extracted: $VERIFY_GATE_SCRIPTS"
else
  pass "verify gate scripts extracted: $VERIFY_GATE_SCRIPTS"
fi

# Escalation claims: gate failures re-enter execute.
VERIFY_ESCALATES_TO_EXECUTE=0
grep -q 'currentPhase = "execute"' "$ROOT/skills/verify/SKILL.md" \
  && grep -q 'pendingRemediationTasks' "$ROOT/skills/verify/SKILL.md" \
  && VERIFY_ESCALATES_TO_EXECUTE=1
DELIVER_ESCALATES_TO_EXECUTE=0
grep -q 'currentPhase = "execute"' "$ROOT/skills/deliver/SKILL.md" \
  && DELIVER_ESCALATES_TO_EXECUTE=1
[[ "$VERIFY_ESCALATES_TO_EXECUTE" == "1" ]] \
  && pass "verify skill claims gate escalation to execute via pendingRemediationTasks" \
  || fail "verify skill no longer claims gate escalation to execute (update this test)"
[[ "$DELIVER_ESCALATES_TO_EXECUTE" == "1" ]] \
  && pass "deliver skill claims failed-checks re-entry to execute" \
  || fail "deliver skill no longer claims re-entry to execute (update this test)"

# Corroborate each forward hop in the phase skill that persists it. iterate and
# deliver signal their exits through the verdict/delivery records, so the
# pairwise sweep covers spec through verify.
for ((i = 0; i + 3 < ${#chain_arr[@]}; i++)); do
  p="${chain_arr[$i]}"; s="${chain_arr[$((i + 1))]}"
  if grep -qE "currentPhase( =)? \"$s\"" "$ROOT/skills/$p/SKILL.md"; then
    pass "skills/$p persists currentPhase \"$s\" at phase exit"
  else
    fail "skills/$p/SKILL.md does not persist currentPhase \"$s\" claimed by the cycle forward chain"
  fi
done

# Script/agent bodies the graph may bind gates to must be referenced by a skill.
SKILL_REFS="$(grep -rhoE 'lib/[a-z-]+\.sh|loop-spec:[a-z-]+' "$ROOT/skills" \
  --include=SKILL.md | sort -u | tr '\n' ' ')"
require "$SKILL_REFS" "the skill script/agent reference corpus"

export FORWARD_CHAIN REWIND_TARGETS GAP_CLASSES VERIFY_GATE_SCRIPTS \
  VERIFY_ESCALATES_TO_EXECUTE DELIVER_ESCALATES_TO_EXECUTE SKILL_REFS

# --- the checker: graph JSON arrives in GRAPH_JSON so mutations stay in memory ---

CHECKER="$(cat <<'PY'
import json, os, sys

graph = json.loads(os.environ["GRAPH_JSON"])
forward = os.environ["FORWARD_CHAIN"].split()
rewinds = set(os.environ["REWIND_TARGETS"].split())
gaps = set(os.environ["GAP_CLASSES"].split())
gate_scripts = os.environ["VERIFY_GATE_SCRIPTS"].split()
skill_refs = set(os.environ["SKILL_REFS"].split())

nodes = {n["id"]: n for n in graph.get("nodes", [])}
adj = {}
for e in graph.get("edges", []):
    adj.setdefault(e.get("from"), []).append(e)

phases = set(forward)
fails = []


def phase_successors(start):
    """Phase nodes reachable from start, collapsing through non-phase nodes."""
    out, seen, frontier = set(), set(), [start]
    while frontier:
        for e in adj.get(frontier.pop(), []):
            t = e.get("to")
            if t in phases:
                out.add(t)
            elif t not in seen:
                seen.add(t)
                frontier.append(t)
    return out


if graph.get("entry") != forward[0]:
    fails.append("entry-mismatch: skills start the cycle at '%s' but the graph entry is '%s'"
                 % (forward[0], graph.get("entry")))

for p, s in zip(forward, forward[1:]):
    if p not in nodes:
        fails.append("skill-successor-missing: phase '%s' from the skills' forward chain has no graph node" % p)
    elif s not in phase_successors(p):
        fails.append("skill-successor-missing: skills declare %s -> %s but the graph has no path from '%s' to '%s'"
                     % (p, s, p, s))

iterate_successors = phase_successors("iterate") if "iterate" in nodes else set()
for t in sorted(rewinds):
    if t not in iterate_successors:
        fails.append("skill-rewind-missing: skills declare ITERATE may rewind to '%s' but the graph has no iterate path to it" % t)

for e in adj.get("iterate", []):
    if e.get("kind") != "route":
        continue
    t = e.get("to")
    for r in sorted({t} if t in phases else phase_successors(t)):
        if r not in rewinds:
            fails.append("unimplemented-rewind-target: graph routes iterate -> %s (reaching phase '%s') but no skill implements that rewind"
                         % (t, r))

route_expects = {(e.get("condition") or {}).get("expects")
                 for e in adj.get("iterate", []) if e.get("kind") == "route"}
for g in sorted(gaps):
    if "gap=%s" % g not in route_expects:
        fails.append("gap-route-missing: skills classify a '%s' gap but no iterate route edge expects 'gap=%s'" % (g, g))

gate_bodies = {n.get("body") for n in graph.get("nodes", []) if n.get("kind") == "gate"}
for s in gate_scripts:
    if s not in gate_bodies:
        fails.append("gate-node-missing: skills/verify runs deterministic gate '%s' but the graph declares no gate node with that body" % s)
for n in graph.get("nodes", []):
    body = n.get("body") or ""
    # Symbolic gate bodies (e.g. plan-critique-fastpath) are engine-internal
    # conditions; only script/agent bodies must be implemented by a skill.
    if n.get("kind") == "gate" and (body.startswith("lib/") or body.startswith("loop-spec:")) \
            and body not in skill_refs:
        fails.append("unimplemented-gate: graph gate node '%s' names body '%s' which no skill references"
                     % (n.get("id"), body))

if os.environ["DELIVER_ESCALATES_TO_EXECUTE"] == "1":
    if not any(e.get("to") == "execute" and e.get("kind") in ("route", "loop")
               for e in adj.get("deliver", [])):
        fails.append("deliver-escalation-missing: skills/deliver re-enters execute on failed checks but the graph has no deliver -> execute route/loop edge")

if os.environ["VERIFY_ESCALATES_TO_EXECUTE"] == "1":
    channel = ("pendingRemediationTasks" in nodes.get("verify", {}).get("writes", [])
               and "pendingRemediationTasks" in nodes.get("execute", {}).get("reads", [])
               and any(e.get("kind") == "route" and e.get("to") == "execute"
                       for e in adj.get("iterate", [])))
    if not channel:
        fails.append("verify-escalation-channel-missing: skills/verify escalates gate failures to execute via pendingRemediationTasks, but the graph does not declare that channel (verify writes / execute reads / iterate -> execute route)")

for f in fails:
    print("CONFORMANCE FAIL: " + f)
if fails:
    sys.exit(1)
print("conformance: ok (%d phases, %d rewind targets, %d gap routes, %d verify gates)"
      % (len(forward), len(rewinds), len(gaps), len(gate_scripts)))
PY
)"

conform() { python3 -c "$CHECKER" 2>&1; }

expect_ok() {
  local name="$1" out rc=0
  out="$(conform)" || rc=$?
  if [[ "$rc" == "0" ]]; then
    pass "$name"
  else
    fail "$name (checker exited $rc)"; sed 's/^/    /' <<<"$out"
  fi
}

expect_flag() {
  local name="$1" pattern="$2" out rc=0
  out="$(conform)" || rc=$?
  if [[ "$rc" != "0" ]] && grep -qF "$pattern" <<<"$out"; then
    pass "$name"
  else
    fail "$name (rc=$rc, expected nonzero + message containing '$pattern')"
    sed 's/^/    /' <<<"$out"
  fi
}

# --- positive case: the tree as shipped conforms ---

GRAPH_JSON="$(cat "$GRAPH")" expect_ok "skills agree with graph/cycle.graph.json as shipped"

# --- negative cases: each mutated in-memory copy must be detected ---

GRAPH_JSON="$(jq '(.edges[] | select(.from=="human.after-plan" and .to=="execute") | .to) = "verify"' "$GRAPH")" \
  expect_flag "retargeted forward edge (plan no longer reaches execute) flags" \
  "skill-successor-missing: skills declare plan -> execute"

GRAPH_JSON="$(jq '.edges |= map(select((.from=="iterate" and .to=="spec" and .kind=="route") | not))' "$GRAPH")" \
  expect_flag "deleted iterate -> spec route flags the missing rewind" \
  "skill-rewind-missing: skills declare ITERATE may rewind to 'spec'"

GRAPH_JSON="$(jq '(.edges[] | select(.from=="iterate" and .to=="plan" and .kind=="route") | .to) = "completed"' "$GRAPH")" \
  expect_flag "route to a rewind target no skill implements flags" \
  "unimplemented-rewind-target: graph routes iterate -> completed"

GRAPH_JSON="$(jq '(.edges[] | select(.from=="iterate" and .to=="execute" and .kind=="route") | .condition.expects) = "gap=refactor"' "$GRAPH")" \
  expect_flag "reworded gap probe expectation flags the orphaned gap class" \
  "gap-route-missing: skills classify a 'execute' gap"

GRAPH_JSON="$(jq '(.nodes[] | select(.id=="verify.tamper") | .body) = "lib/unregistered-gate.sh"' "$GRAPH")" \
  expect_flag "gate node body swap flags the skill gate with no node" \
  "gate-node-missing: skills/verify runs deterministic gate 'lib/test-tamper-scan.sh'"

GRAPH_JSON="$(jq '(.nodes[] | select(.id=="verify.tamper") | .body) = "lib/unregistered-gate.sh"' "$GRAPH")" \
  expect_flag "gate node body swap flags the graph gate no skill references" \
  "unimplemented-gate: graph gate node 'verify.tamper'"

GRAPH_JSON="$(jq '.nodes |= map(if .id == "verify" then .writes -= ["pendingRemediationTasks"] else . end)' "$GRAPH")" \
  expect_flag "dropped remediation write on verify flags the escalation channel" \
  "verify-escalation-channel-missing"

GRAPH_JSON="$(jq '.edges |= map(select((.from=="deliver" and .to=="execute") | not))' "$GRAPH")" \
  expect_flag "deleted deliver -> execute edges flag the CI-failure re-entry" \
  "deliver-escalation-missing"

GRAPH_JSON="$(jq '.entry = "plan"' "$GRAPH")" \
  expect_flag "moved graph entry flags the mismatch with the skills' start phase" \
  "entry-mismatch"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
