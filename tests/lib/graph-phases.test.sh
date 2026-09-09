#!/usr/bin/env bash
# Tests for lib/graph/phases.sh: the phase vocabulary is the graph's, and adding a phase
# to a graph is one edit every consumer of the vocabulary sees.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/lib/graph/phases.sh"
PASS=0; FAIL=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then echo "PASS: $name"; PASS=$((PASS+1))
  else echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL+1)); fi
}
WORK="$(mktemp -d "${TMPDIR:-/tmp}/graph-phases-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

check "list: the shipped graph's phases in order" "spec oneshot discuss plan execute verify iterate deliver" "$(bash "$LIB" list | paste -sd' ')"
check "regex: an alternation" "spec|oneshot|discuss|plan|execute|verify|iterate|deliver" "$(bash "$LIB" regex)"
check "validate: a phase exits 0" "0" "$(bash "$LIB" validate verify >/dev/null 2>&1; echo $?)"
check "validate: a gate node is not a phase" "1" "$(bash "$LIB" validate verify.acceptance >/dev/null 2>&1; echo $?)"
check "validate: the message names the phases" "1" "$(bash "$LIB" validate nope 2>&1 | grep -c 'phase must be one of: spec | oneshot | discuss')"
check "suffix: uppercased id" "DELIVER" "$(bash "$LIB" suffix deliver)"
check "bad invocation exits 2" "2" "$(bash "$LIB" bogus >/dev/null 2>&1; echo $?)"
# The short route is one session: the edge into oneshot carries sameSession, and the
# walk passes through the human node between the two phases. Every other boundary
# hands off.
check "same-session: spec to oneshot stays in the session" "0" "$(bash "$LIB" same-session spec oneshot >/dev/null 2>&1; echo $?)"
check "same-session: spec to discuss hands off" "1" "$(bash "$LIB" same-session spec discuss >/dev/null 2>&1; echo $?)"
check "same-session: oneshot to deliver hands off" "1" "$(bash "$LIB" same-session oneshot deliver >/dev/null 2>&1; echo $?)"
check "same-session: every full-path boundary hands off" "0" "$(for pair in 'discuss plan' 'plan execute' 'execute verify' 'verify iterate' 'iterate deliver'; do bash "$LIB" same-session $pair >/dev/null 2>&1 && echo "$pair"; done | wc -l | tr -d ' ')"
check "same-session: one id is a bad invocation" "2" "$(bash "$LIB" same-session spec >/dev/null 2>&1; echo $?)"
check "unreadable graph exits 2" "2" "$(bash "$LIB" list --graph "$WORK/none.json" >/dev/null 2>&1; echo $?)"

# Every consumer reads a graph copy through LOOP_SPEC_GRAPH, so one graph edit adds a phase.
jq '.nodes += [{"id":"triage","label":"Triage the report","kind":"agent","reads":["slug"],"writes":["artifacts","currentPhase"],"effort":"system1","body":"skills/triage/SKILL.md"}]' \
  "$ROOT/graph/cycle.graph.json" > "$WORK/graph.json"
check "a graph copy with a new phase lists it" "1" "$(bash "$LIB" list --graph "$WORK/graph.json" | grep -cx triage)"
# The validator runs on the copy and names exactly what the stub lacks: its body file
# and the edge that would reach it. Nothing else about the copy is a finding.
vout="$(bash "$ROOT/lib/graph/validate.sh" "$WORK/graph.json" 2>&1)"; vrc=$?
check "validate.py runs on the copy and flags it" "1" "$vrc"
check "validate.py names the stub's missing body" "1" "$(grep -c 'skills/triage/SKILL.md' <<<"$vout" | awk '{print ($1 > 0)}')"
check "validate.py names the unreachable node" "1" "$(grep -ci 'triage.*reachab\|reachab.*triage' <<<"$vout" | awk '{print ($1 > 0)}')"
check "LOOP_SPEC_GRAPH selects the copy for every caller" "1" "$(LOOP_SPEC_GRAPH="$WORK/graph.json" bash "$LIB" list | grep -cx triage)"
check "feature-init validates the new phase from the copy" "0" \
  "$(LOOP_SPEC_GRAPH="$WORK/graph.json" bash "$ROOT/lib/feature-init.sh" phase-model triage >/dev/null 2>&1; echo $?)"
check "feature-init resolves LOOP_SPEC_PHASE_MODEL_TRIAGE for it" "sonnet" \
  "$(LOOP_SPEC_GRAPH="$WORK/graph.json" LOOP_SPEC_HARNESS=claude LOOP_SPEC_PHASE_MODEL_TRIAGE=sonnet bash "$ROOT/lib/feature-init.sh" phase-model triage 2>/dev/null)"
check "feature-init refuses it against the shipped graph" "1" \
  "$(bash "$ROOT/lib/feature-init.sh" phase-model triage >/dev/null 2>&1; echo $?)"
check "the hooks' alternation carries it" "1" \
  "$(LOOP_SPEC_GRAPH="$WORK/graph.json" bash "$LIB" regex | grep -c '|triage')"
check "the engine keeps no literal phase list (tests/lib/graph-run.test.sh proves the derived one)" "0" \
  "$(grep -c '"spec", "discuss", "plan"' "$ROOT/lib/graph/engine.py")"

# The phase's door and exit are data on its node: phase-entry.sh and phase-exit.sh run
# the new phase from the copy with nothing else edited (orchestrator-port-plan.md, WP2).
jq '(.nodes[] | select(.id == "triage")) += {
      "ingress": {"fields": ["slug", "execStyle"], "required": [{"writer": "SPEC", "path": "{docs}/SPEC.md"}],
                  "optional": ["{featureDir}/triage-notes.md"]},
      "egress": {"required": [{"label": "triage", "path": "{docs}/TRIAGE.md"}],
                 "gates": [{"label": "grounding-lint", "body": "lib/grounding-lint.sh", "args": ["{docs}/TRIAGE.md"]},
                           {"label": "never", "body": "lib/does-not-run.sh", "args": [], "when": {"field": "execStyle", "equals": "nope"}}],
                 "writes": ["artifacts.triage"],
                 "artifacts": {"triage": "{docs}/TRIAGE.md"},
                 "commit": {"message": "triage: {slug} in {f:execStyle} style", "paths": ["{docs}/TRIAGE.md"]},
                 "checkpoint": "post-triage", "close": "always"}}' "$WORK/graph.json" > "$WORK/graph2.json"
REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LOOP_SPEC_HARNESS=codex LOOP_SPEC_TEAMS_MODE=none LOOP_SPEC_WORKFLOWS_AVAILABLE=0 LOOP_SPEC_CHECKPOINT_PR=0
( cd "$REPO" && bash "$ROOT/lib/cycle-driver.sh" start --dir "$REPO" -- my feature >/dev/null 2>&1
  bash "$ROOT/lib/cycle-driver.sh" init --dir "$REPO" --slug my-feature --title "my feature" \
    --style auto --profile standard --autonomous 0 >/dev/null 2>&1 )
FD="$REPO/.loop-spec/features/my-feature"; DOCS="$REPO/docs/loop-spec/features/my-feature"; mkdir -p "$DOCS"
ENTRY="$ROOT/lib/phase-entry.sh"; EXIT_="$ROOT/lib/phase-exit.sh"

check "phase-entry refuses the phase against the shipped graph" "2" "$(bash "$ENTRY" triage --feature-dir "$FD" >/dev/null 2>&1; echo $?)"
out="$(LOOP_SPEC_GRAPH="$WORK/graph2.json" bash "$ENTRY" triage --feature-dir "$FD" 2>&1)"; ec=$?
check "phase-entry: the copy's required file is flagged with its writer" "1" "$(grep -c "^FLAG \[ingress\] $DOCS/SPEC.md missing: SPEC did not write it" <<<"$out")"
check "phase-entry: exit 1 on the missing file" "1" "$ec"
printf '# spec\n' > "$DOCS/SPEC.md"; printf 'notes\n' > "$FD/triage-notes.md"
out="$(LOOP_SPEC_GRAPH="$WORK/graph2.json" bash "$ENTRY" triage --feature-dir "$FD" 2>&1)"; ec=$?
check "phase-entry: the copy's phase opens clean" "phase-entry: ok (triage)" "$(tail -1 <<<"$out")"
check "phase-entry: the packet is the node's fields" '{"slug":"my-feature","execStyle":"auto"}' "$(grep '^fields=' <<<"$out" | sed 's/^fields=//')"
check "phase-entry: required and optional files are the reading list" "2" "$(grep -c '^read=' <<<"$out")"

check "phase-exit refuses the phase against the shipped graph" "2" "$(bash "$EXIT_" triage --feature-dir "$FD" >/dev/null 2>&1; echo $?)"
out="$(LOOP_SPEC_GRAPH="$WORK/graph2.json" bash "$EXIT_" triage --feature-dir "$FD" 2>&1)"; ec=$?
check "phase-exit: the copy's required artifact is flagged under its label" "1" "$(grep -c "^FLAG \[triage\] docs/loop-spec/features/my-feature/TRIAGE.md missing" <<<"$out")"
check "phase-exit: a gate on the absent artifact relays under its label" "1" "$(grep -c '^FLAG \[grounding-lint\] ' <<<"$out" | awk '{print ($1 > 0)}')"
check "phase-exit: a gate whose when clause does not match never runs" "0" "$(grep -c 'does-not-run' <<<"$out")"
printf '# Triage\n\n## Grounding\n\n- none\n' > "$DOCS/TRIAGE.md"
out="$(LOOP_SPEC_GRAPH="$WORK/graph2.json" bash "$EXIT_" triage --feature-dir "$FD" 2>&1)"; ec=$?
check "phase-exit: the copy's phase closes clean" "phase-exit: ok (triage)" "$(tail -1 <<<"$out")"
check "phase-exit: the artifact pointer is the node's" "docs/loop-spec/features/my-feature/TRIAGE.md" "$(jq -r '.artifacts.triage' "$FD/feature.json")"
check "phase-exit: the commit message resolves {slug} and {f:key}" "1" "$(git -C "$REPO" log --oneline | grep -c 'triage: my-feature in auto style')"
check "phase-exit: the checkpoint is tagged" "1" "$(git -C "$REPO" tag | grep -c 'post-triage')"
check "phase-exit: the phase is closed" "triage" "$(jq -r '.completedPhases[-1]' "$FD/feature.json")"
check "phase-exit: the egress snapshot is consumed" "missing" "$([[ -f "$FD/.phase-entry.json" ]] && echo present || echo missing)"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
