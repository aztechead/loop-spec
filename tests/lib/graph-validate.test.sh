#!/usr/bin/env bash
# Offline unit suite for lib/graph/validate.sh — the schema and referential
# validator over a declared workflow graph. One accepting case, one rejection
# per rule (probe-shaped route conditions, probe existence, edge endpoints,
# reachability, loop ceilings, fanin joins, non-loop DAG-ness), plus the
# invocation contract (exit 2 on missing/unreadable args) and the rules added
# for docs/loop-spec/features/gdd/REMEDIATION-CONTRACT.md: expects membership
# in the probe's own --answers set, '|' alternation rejection, per-(from,to)
# loop-pair scoping of the acyclicity carve-out, node body path existence, and
# the derived (not hardcoded) feature-init skeleton key space.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/graph/validate.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-graph-validate.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
PASS=0; FAIL=0

check() {
  local name="$1" expected_rc="$2"; shift 2
  local rc=0 out
  out="$(bash "$SCRIPT" "$@" 2>&1)" || rc=$?
  if [[ "$rc" == "$expected_rc" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected rc=$expected_rc, got rc=$rc)"; echo "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  fi
}

check_output() {
  local name="$1" pattern="$2"; shift 2
  local out
  local rc=0
  out="$(bash "$SCRIPT" "$@" 2>&1)" || rc=$?
  if grep -qF "$pattern" <<<"$out"; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (output missing '$pattern')"; echo "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  fi
}

# A fixture probe conforming to the route-probe answer contract (REMEDIATION-
# CONTRACT.md sec 2): exits 0 with one `<token> reason=...` line for a real
# invocation, and a fixed answer set for --answers. Kept absolute so it
# resolves regardless of repo-root-relative path handling under test.
PROBE="$WORK/probe.sh"
cat > "$PROBE" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--answers" ]]; then
  printf 'yes\nno\n'
  exit 0
fi
echo "yes reason=fixture"
EOF
chmod +x "$PROBE"

# --- invocation ---
check "no args is usage error" 2
check "missing graph file is a bad-invocation error, never 0" 2 "$WORK/does-not-exist.json"

# --- accepting case ---
cat > "$WORK/good.json" <<EOF
{
  "id": "demo",
  "entry": "start",
  "nodes": [
    {"id": "start",  "kind": "agent",    "reads": [],       "writes": ["slug"],      "effort": "system2"},
    {"id": "branch", "kind": "gate",     "reads": ["slug"], "writes": [],            "effort": "system2"},
    {"id": "work",   "kind": "agent",    "reads": ["slug"], "writes": ["artifacts"], "effort": "system2"},
    {"id": "merge",  "kind": "function", "reads": [],       "writes": [],            "effort": "system1"},
    {"id": "done",   "kind": "human",    "reads": [],       "writes": [],            "effort": "system2",
     "admit": {"probe": "$PROBE", "args": ["--feature-dir", "{featureDir}"], "expects": "yes"}}
  ],
  "edges": [
    {"from": "start",  "to": "branch", "kind": "chain"},
    {"from": "branch", "to": "work",   "kind": "route", "condition": {"probe": "$PROBE", "args": ["--feature-dir", "{featureDir}"], "expects": "yes"}},
    {"from": "branch", "to": "merge",  "kind": "fanout"},
    {"from": "work",   "to": "merge",  "kind": "fanin", "join": "all"},
    {"from": "merge",  "to": "done",   "kind": "chain"},
    {"from": "done",   "to": "work",   "kind": "loop",  "ceiling": 3, "strategy": "unroll"}
  ]
}
EOF
check "valid graph passes" 0 "$WORK/good.json"
check_output "valid graph prints the ok answer line" "graph-validate: ok" "$WORK/good.json"

# --- rule 1: route condition must be a {probe, args, expects} object ---
jq '.edges[1].condition = "escalate if this looks security-relevant"' \
  "$WORK/good.json" > "$WORK/prose-condition.json"
check "free-text route condition flags" 1 "$WORK/prose-condition.json"
check_output "prose condition names the required shape" "{probe, args, expects}" "$WORK/prose-condition.json"
check_output "prose condition emits a FLAG line" "FLAG " "$WORK/prose-condition.json"

jq 'del(.edges[1].condition)' "$WORK/good.json" > "$WORK/no-condition.json"
check "route edge without a condition flags" 1 "$WORK/no-condition.json"

# --- rule: args is required (mutation: drop it from an otherwise-valid condition) ---
jq 'del(.edges[1].condition.args)' "$WORK/good.json" > "$WORK/no-args.json"
check "route condition missing args flags" 1 "$WORK/no-args.json"
check_output "missing args is named" "missing: ['args']" "$WORK/no-args.json"

# --- rule 2: route probe must exist and be executable in the tree ---
jq '.edges[1].condition.probe = "lib/does-not-exist.sh"' \
  "$WORK/good.json" > "$WORK/probe-missing.json"
check "nonexistent probe path flags" 1 "$WORK/probe-missing.json"
check_output "missing probe is named" "lib/does-not-exist.sh" "$WORK/probe-missing.json"

jq '.edges[1].condition.probe = "README.md"' "$WORK/good.json" > "$WORK/probe-noexec.json"
check "non-executable probe flags" 1 "$WORK/probe-noexec.json"
check_output "non-executable probe is named" "not executable" "$WORK/probe-noexec.json"

# --- rule (contract sec 2/3): expects must be a member of the probe's
# --answers set. This is the rule that would have caught the shipped engine's
# PLAN-critique-skip / lost-ITERATE-rewind bug: a route naming a probe that
# never emits the token the route expects. ---
jq '.edges[1].condition.expects = "maybe"' "$WORK/good.json" > "$WORK/expects-not-in-answers.json"
check "expects outside the probe's --answers set flags" 1 "$WORK/expects-not-in-answers.json"
check_output "unverifiable expects is named" "is not a member of" "$WORK/expects-not-in-answers.json"
# ...and restores clean once expects names a real answer token again.
check "expects back in the answer set passes" 0 "$WORK/good.json"

# --- rule: '|' alternation inside expects is illegal ---
jq '.edges[1].condition.expects = "yes|no"' "$WORK/good.json" > "$WORK/expects-alternation.json"
check "expects with '|' alternation flags" 1 "$WORK/expects-alternation.json"
check_output "alternation is named illegal" "alternation is illegal" "$WORK/expects-alternation.json"

# --- rule: admit is the same {probe, args, expects} shape, restricted to human nodes ---
jq --arg p "$PROBE" '.nodes[2].admit = {"probe": $p, "args": [], "expects": "yes"}' \
  "$WORK/good.json" > "$WORK/admit-on-agent.json"
check "admit on a non-human node flags" 1 "$WORK/admit-on-agent.json"
check_output "admit-on-agent is named" "only human nodes may declare admit" "$WORK/admit-on-agent.json"

jq '.nodes[4].admit.expects = "maybe"' "$WORK/good.json" > "$WORK/admit-bad-expects.json"
check "admit with an unverifiable expects flags" 1 "$WORK/admit-bad-expects.json"
check_output "admit-bad-expects is named" "is not a member of" "$WORK/admit-bad-expects.json"

# --- rule: routeDefault must name a declared node ---
jq '.nodes[1].routeDefault = "nowhere"' "$WORK/good.json" > "$WORK/route-default-bad.json"
check "routeDefault naming an undeclared node flags" 1 "$WORK/route-default-bad.json"
check_output "bad routeDefault is named" "routeDefault names undeclared node" "$WORK/route-default-bad.json"

jq '.nodes[1].routeDefault = "merge"' "$WORK/good.json" > "$WORK/route-default-ok.json"
check "routeDefault naming a declared node passes" 0 "$WORK/route-default-ok.json"

# --- rule: a node body that looks like a path (contains '/') must exist ---
jq '.nodes[2].body = "lib/does-not-exist.sh"' "$WORK/good.json" > "$WORK/body-missing.json"
check "node body path that does not exist flags" 1 "$WORK/body-missing.json"
check_output "missing body path is named" "body path does not exist" "$WORK/body-missing.json"

jq '.nodes[2].body = "lib/graph/validate.sh"' "$WORK/good.json" > "$WORK/body-present.json"
check "node body path that exists passes" 0 "$WORK/body-present.json"

jq '.nodes[2].body = "loop-spec:implementer"' "$WORK/good.json" > "$WORK/body-opaque.json"
check "node body with no '/' is not checked as a path" 0 "$WORK/body-opaque.json"

# --- rule 3: edge endpoints must name declared nodes ---
jq '.edges[0].to = "ghost"' "$WORK/good.json" > "$WORK/unknown-to.json"
check "edge to an undeclared node flags" 1 "$WORK/unknown-to.json"
check_output "undeclared endpoint is named" "ghost" "$WORK/unknown-to.json"

jq '.edges[0].from = "phantom"' "$WORK/good.json" > "$WORK/unknown-from.json"
check "edge from an undeclared node flags" 1 "$WORK/unknown-from.json"

# --- rule 4: every node reachable from an entry node ---
jq '.nodes += [{"id": "island", "kind": "agent", "reads": [], "writes": [], "effort": "system2"}]' \
  "$WORK/good.json" > "$WORK/unreachable.json"
check "node unreachable from entry flags" 1 "$WORK/unreachable.json"
check_output "unreachable node is named" "island" "$WORK/unreachable.json"

# --- rule 5: loop edge must carry a numeric ceiling ---
jq 'del(.edges[5].ceiling)' "$WORK/good.json" > "$WORK/loop-no-ceiling.json"
check "loop edge without a ceiling flags" 1 "$WORK/loop-no-ceiling.json"

jq '.edges[5].ceiling = "three"' "$WORK/good.json" > "$WORK/loop-string-ceiling.json"
check "loop edge with a non-numeric ceiling flags" 1 "$WORK/loop-string-ceiling.json"

# --- rule 6: fanin must name a join rule ---
jq 'del(.edges[3].join)' "$WORK/good.json" > "$WORK/fanin-no-join.json"
check "fanin edge without a join rule flags" 1 "$WORK/fanin-no-join.json"

# --- rule 7: chain/route/fanout/fanin edges must form a DAG ---
# A literal back-edge among the acyclic kinds is a cycle...
cat > "$WORK/back-edge.json" <<'EOF'
{
  "id": "cyc",
  "entry": "a",
  "nodes": [
    {"id": "a", "kind": "agent", "reads": [], "writes": [], "effort": "system2"},
    {"id": "b", "kind": "agent", "reads": [], "writes": [], "effort": "system2"}
  ],
  "edges": [
    {"from": "a", "to": "b", "kind": "chain"},
    {"from": "b", "to": "a", "kind": "chain"}
  ]
}
EOF
check "non-loop back-edge cycle flags" 1 "$WORK/back-edge.json"
check_output "cycle flag names the involved edge kinds" "chain/route/fanout/fanin" "$WORK/back-edge.json"

# ...but the same shape declared as a bounded loop edge is legal iteration.
jq '.edges[1] = {"from": "b", "to": "a", "kind": "loop", "ceiling": 2, "strategy": "contain"}' \
  "$WORK/back-edge.json" > "$WORK/loop-back-edge.json"
check "bounded loop back-edge passes (loop excluded from DAG check)" 0 "$WORK/loop-back-edge.json"

# --- rule 9 (contract sec 9): the loop carve-out is scoped to the exact
# (from,to) pair, not the source node alone. A node with TWO route back-edges
# where only ONE target has a matching loop edge must still flag the other —
# the shipped bug (loop_sources keyed on source alone) would have wrongly
# exempted both. ---
cat > "$WORK/two-back-edges.json" <<EOF
{
  "id": "pair-scope",
  "entry": "a",
  "nodes": [
    {"id": "a", "kind": "agent", "reads": [], "writes": [], "effort": "system2"},
    {"id": "b", "kind": "agent", "reads": [], "writes": [], "effort": "system2"},
    {"id": "c", "kind": "agent", "reads": [], "writes": [], "effort": "system2"}
  ],
  "edges": [
    {"from": "a", "to": "b", "kind": "chain"},
    {"from": "a", "to": "c", "kind": "chain"},
    {"from": "b", "to": "a", "kind": "route", "condition": {"probe": "$PROBE", "args": [], "expects": "yes"}},
    {"from": "c", "to": "a", "kind": "route", "condition": {"probe": "$PROBE", "args": [], "expects": "no"}},
    {"from": "b", "to": "a", "kind": "loop", "ceiling": 3, "strategy": "contain"}
  ]
}
EOF
check "the uncovered (c,a) back-edge still flags as a cycle even though (b,a) has a loop edge" 1 "$WORK/two-back-edges.json"
check_output "cycle flag fires for the pair without its own loop edge" \
  "cycle among chain/route/fanout/fanin" "$WORK/two-back-edges.json"

jq '.edges += [{"from": "c", "to": "a", "kind": "loop", "ceiling": 3, "strategy": "contain"}]' \
  "$WORK/two-back-edges.json" > "$WORK/two-back-edges-covered.json"
check "both back-edges pass once each has its own exact-pair loop edge" 0 "$WORK/two-back-edges-covered.json"

# --- schema enforcement beyond the rules above ---
printf 'not json' > "$WORK/bad.json"
check "unparseable graph flags, never exits 0" 1 "$WORK/bad.json"

jq '.nodes[0].kind = "wizard"' "$WORK/good.json" > "$WORK/unknown-kind.json"
check "unknown node kind flags" 1 "$WORK/unknown-kind.json"

jq '.entry = "nowhere"' "$WORK/good.json" > "$WORK/bad-entry.json"
check "entry naming an undeclared node flags" 1 "$WORK/bad-entry.json"

# --- answer line shape on rejection ---
check_output "rejection prints the flag-count answer line" "flag(s)" "$WORK/prose-condition.json"

# --- skippable gate without licensing probe ---
cat > "$WORK/badskip.json" <<'EOFSKIP'
{
  "entry": "g",
  "nodes": [
    {"id": "g", "kind": "gate", "reads": [], "writes": [], "effort": "system1", "skippable": {}}
  ],
  "edges": []
}
EOFSKIP
check "skippable without probe exit 1" 1 "$WORK/badskip.json"
check_output "skippable without probe FLAG" "skippable" "$WORK/badskip.json"

# --- delivery-authorizing node with system1 ---
cat > "$WORK/baddel.json" <<'EOFDEL'
{
  "entry": "d",
  "nodes": [
    {"id": "d", "kind": "agent", "reads": [], "writes": [], "effort": "system1", "authorizesDelivery": true}
  ],
  "edges": []
}
EOFDEL
check "delivery system1 exit 1" 1 "$WORK/baddel.json"
check_output "delivery system1 FLAG" "system1" "$WORK/baddel.json"

# --- rule: the skeleton key space is derived from a live `feature-init.sh
# skeleton` run at validate time, not a third hardcoded copy. That hardcoded
# copy (a verbatim mirror of the schema.json stateKey enum) had already
# drifted -- lib/feature-init.sh actually emits currentPhaseStartedAt and
# iterate too, which is what REMEDIATION-CONTRACT.md sec 10's "already
# drifted" note is about. Both names are outside the schema.json stateKey
# enum today (a separate, differently-scoped list -- fixing IT is cross-file
# with skills/shared/feature-state-schema.md, out of this file's ownership),
# so they cannot yet be exercised through a node's reads[]; this asserts the
# derivation source directly instead. ---
skeleton_keys="$(bash "$ROOT/lib/feature-init.sh" skeleton --mode single \
  --slug t --now 1970-01-01T00:00:00Z --style auto --title t --branch t \
  --base-sha 0000000000000000000000000000000000000000 --base-branch main \
  --worktree "" --prepare "" --test "" --lint "" --typecheck "" | jq -r 'keys[]')"
if grep -qx "currentPhaseStartedAt" <<<"$skeleton_keys" && grep -qx "iterate" <<<"$skeleton_keys"; then
  echo "PASS: feature-init.sh skeleton emits currentPhaseStartedAt and iterate (the drifted keys)"; PASS=$((PASS + 1))
else
  echo "FAIL: feature-init.sh skeleton is missing currentPhaseStartedAt and/or iterate"; FAIL=$((FAIL + 1))
fi

# The producer/consumer rule reads that live set, not a hardcoded copy: a
# read of a real schema-enum key that is never written by any node (e.g.
# stalenessHours) passes only because it is seeded by the skeleton.
jq '.nodes[0].reads = ["stalenessHours"]' "$WORK/good.json" > "$WORK/skeleton-read.json"
check "reading a real skeleton key with no writer passes" 0 "$WORK/skeleton-read.json"

jq '.nodes[0].reads = ["harnessTaskMetadataMode"]' "$WORK/good.json" > "$WORK/nonskeleton-read.json"
check "reading an in-enum key that is not a skeleton key and has no writer flags" 1 "$WORK/nonskeleton-read.json"
check_output "nonskeleton read is named" "never written by any node and is not a feature-init skeleton key" "$WORK/nonskeleton-read.json"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
