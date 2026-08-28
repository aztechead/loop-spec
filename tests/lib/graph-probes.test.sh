#!/usr/bin/env bash
# Offline unit suite for lib/graph/probes/*.sh -- the route probes that
# graph/cycle.graph.json and graph/critique.graph.json name in their route
# conditions and human `admit` gates. Each probe is checked against the house
# contract (docs/loop-spec/features/gdd/REMEDIATION-CONTRACT.md sec 2): exactly
# one `<key>=<value> reason=<text>` line and exit 0 when resolved; silent and
# non-zero when unresolved; a `--answers` verb listing its full answer-token set.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROBES="$ROOT/lib/graph/probes"
WORK="${TMPDIR:-/tmp}/loop-spec-graph-probes.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
PASS=0; FAIL=0

check() {
  local name="$1" expected_rc="$2"; shift 2
  local rc=0 out
  out="$(bash "$@" 2>&1)" || rc=$?
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
  out="$(bash "$@" 2>&1)" || rc=$?
  if grep -qF "$pattern" <<<"$out"; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (output missing '$pattern')"; echo "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  fi
}

check_silent() {
  # An unresolved probe must print NOTHING on stdout (contract sec 2/3) -- a
  # non-zero exit with leaked stdout could still read as an accidental answer
  # to a caller that does not check the exit code.
  local name="$1"; shift
  local out
  local rc=0
  out="$(bash "$@" 2>/dev/null)" || rc=$?
  if [[ -z "$out" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected silent stdout, got: $out)"; FAIL=$((FAIL + 1))
  fi
}

feature_dir() {
  # feature_dir <name> <json-body> -- writes a fixture feature.json under a
  # fresh directory and prints its path.
  local dir="$WORK/$1"
  mkdir -p "$dir"
  printf '%s' "$2" > "$dir/feature.json"
  printf '%s' "$dir"
}

# =====================================================================
# iterate-gap.sh
# =====================================================================
ITERATE_GAP="$PROBES/iterate-gap.sh"

out="$(bash "$ITERATE_GAP" --answers)"
check "iterate-gap --answers exits 0" 0 "$ITERATE_GAP" --answers
[[ "$out" == $'gap=execute\ngap=plan\ngap=spec\ngap=none' ]] \
  && { echo "PASS: iterate-gap --answers lists exactly the four gap tokens"; PASS=$((PASS+1)); } \
  || { echo "FAIL: iterate-gap --answers lists exactly the four gap tokens (got: $out)"; FAIL=$((FAIL+1)); }

d="$(feature_dir gap-execute '{"iterate":{"feedback":{"type":"execute","fix_first":"x"}}}')"
check "iterate-gap resolves gap=execute" 0 "$ITERATE_GAP" --feature-dir "$d"
check_output "iterate-gap execute answer line" "gap=execute reason=" "$ITERATE_GAP" --feature-dir "$d"

d="$(feature_dir gap-plan '{"iterate":{"feedback":{"type":"plan"}}}')"
check_output "iterate-gap resolves gap=plan" "gap=plan reason=" "$ITERATE_GAP" --feature-dir "$d"

d="$(feature_dir gap-spec '{"iterate":{"feedback":{"type":"spec"}}}')"
check_output "iterate-gap resolves gap=spec" "gap=spec reason=" "$ITERATE_GAP" --feature-dir "$d"

d="$(feature_dir gap-none '{"iterate":{"feedback":null}}')"
check_output "iterate-gap resolves gap=none on a cleared (converged) feedback" "gap=none reason=" "$ITERATE_GAP" --feature-dir "$d"

d="$(feature_dir gap-no-feedback-key '{"iterate":{"used":0}}')"
check "iterate-gap is unresolved when iterate.feedback is absent (not merely null)" 1 "$ITERATE_GAP" --feature-dir "$d"
check_silent "iterate-gap prints nothing when iterate.feedback is absent" "$ITERATE_GAP" --feature-dir "$d"

d="$(feature_dir gap-no-iterate-block '{"slug":"x"}')"
check "iterate-gap is unresolved when the iterate block itself is absent" 1 "$ITERATE_GAP" --feature-dir "$d"

d="$(feature_dir gap-unknown-type '{"iterate":{"feedback":{"type":"deliver"}}}')"
check "iterate-gap is unresolved on an unknown gap type" 1 "$ITERATE_GAP" --feature-dir "$d"

check "iterate-gap is unresolved when feature.json is missing" 1 "$ITERATE_GAP" --feature-dir "$WORK/does-not-exist"
check "iterate-gap usage error on missing --feature-dir" 2 "$ITERATE_GAP"

# =====================================================================
# exec-style.sh
# =====================================================================
EXEC_STYLE="$PROBES/exec-style.sh"

out="$(bash "$EXEC_STYLE" --answers)"
[[ "$out" == $'style=auto\nstyle=step\nstyle=interactive\nstyle=review-only' ]] \
  && { echo "PASS: exec-style --answers lists exactly the four style tokens"; PASS=$((PASS+1)); } \
  || { echo "FAIL: exec-style --answers lists exactly the four style tokens (got: $out)"; FAIL=$((FAIL+1)); }

for style in auto step interactive review-only; do
  d="$(feature_dir "style-$style" "{\"execStyle\":\"$style\"}")"
  check_output "exec-style resolves style=$style" "style=$style reason=" "$EXEC_STYLE" --feature-dir "$d"
done

d="$(feature_dir style-bogus '{"execStyle":"whenever"}')"
check "exec-style is unresolved on an unknown execStyle value" 1 "$EXEC_STYLE" --feature-dir "$d"
check_silent "exec-style prints nothing on an unknown execStyle value" "$EXEC_STYLE" --feature-dir "$d"

d="$(feature_dir style-missing '{}')"
check "exec-style is unresolved when execStyle is absent" 1 "$EXEC_STYLE" --feature-dir "$d"

check "exec-style usage error on an unrecognized flag" 2 "$EXEC_STYLE" --bogus

# =====================================================================
# deliver-next.sh
# =====================================================================
DELIVER_NEXT="$PROBES/deliver-next.sh"

out="$(bash "$DELIVER_NEXT" --answers)"
[[ "$out" == $'nextPhase=execute\nnextPhase=completed\nnextPhase=deliver' ]] \
  && { echo "PASS: deliver-next --answers lists all three nextPhase tokens"; PASS=$((PASS+1)); } \
  || { echo "FAIL: deliver-next --answers lists all three nextPhase tokens (got: $out)"; FAIL=$((FAIL+1)); }

d="$(feature_dir next-execute '{"delivery":{"nextPhase":"execute"}}')"
check_output "deliver-next resolves tracked nextPhase=execute" \
  "nextPhase=execute reason=feature.json.delivery.nextPhase=execute" \
  "$DELIVER_NEXT" --feature-dir "$d"

d="$(feature_dir next-completed '{"delivery":{"nextPhase":"completed"}}')"
check_output "deliver-next resolves tracked nextPhase=completed" \
  "nextPhase=completed reason=feature.json.delivery.nextPhase=completed" \
  "$DELIVER_NEXT" --feature-dir "$d"

# "deliver" IS an answer. skills/deliver/SKILL.md sets it for push/identity/
# check-oracle failures and documents the behaviour as "stop resumably rather
# than claiming completion". Leaving it out of the answer set turned that
# EXPECTED failure into an unresolved-probe abort, whose exit-5 "no route
# satisfied" diagnostic reads as a graph defect rather than a delivery retry.
# The graph declares a bounded self-loop for it instead; exhausting the ceiling
# still aborts, but only after the retry the skill calls for.
d="$(feature_dir next-retry '{"delivery":{"nextPhase":"deliver"}}')"
check_output "deliver-next resolves tracked nextPhase=deliver (bounded retry)" \
  "nextPhase=deliver reason=feature.json.delivery.nextPhase=deliver" \
  "$DELIVER_NEXT" --feature-dir "$d"

retry_route="$(jq -r '[.edges[]|select(.from=="deliver" and .to=="deliver" and .kind=="route" and .condition.expects=="nextPhase=deliver")]|length' "$ROOT/graph/cycle.graph.json")"
retry_loop="$(jq -r '[.edges[]|select(.from=="deliver" and .to=="deliver" and .kind=="loop" and .ceiling>0)]|length' "$ROOT/graph/cycle.graph.json")"
if [[ "$retry_route" == "1" && "$retry_loop" == "1" ]]; then
  echo "PASS: delivery retry is declared and bounded"; PASS=$((PASS + 1))
else
  echo "FAIL: delivery retry route=$retry_route loop=$retry_loop (need one of each)"; FAIL=$((FAIL + 1))
fi

d="$(feature_dir next-missing '{"delivery":{}}')"
check "deliver-next is unresolved when delivery.nextPhase is absent" 1 "$DELIVER_NEXT" --feature-dir "$d"

# lib/deliver.sh writes success/retry only to the sidecar. The production
# post-delivery route must resolve from that file even when tracked
# nextPhase is still null — or worse, leftover execute from an earlier
# CI-remediation hop.
d="$(feature_dir sidecar-completed '{"delivery":{"status":"pending","nextPhase":null}}')"
printf '%s' '{"schema":1,"ok":true,"status":"ready-for-review","nextPhase":"completed"}' \
  > "$d/delivery.json"
check_output "deliver-next resolves sidecar nextPhase=completed" \
  "nextPhase=completed reason=delivery.json.nextPhase=completed" \
  "$DELIVER_NEXT" --feature-dir "$d"

d="$(feature_dir sidecar-wins-stale '{"delivery":{"status":"checks-failed","nextPhase":"execute"}}')"
printf '%s' '{"schema":1,"ok":true,"status":"ready-for-review","nextPhase":"completed"}' \
  > "$d/delivery.json"
check_output "deliver-next sidecar completed beats stale tracked execute" \
  "nextPhase=completed reason=delivery.json.nextPhase=completed" \
  "$DELIVER_NEXT" --feature-dir "$d"

d="$(feature_dir sidecar-retry '{"delivery":{}}')"
printf '%s' '{"schema":1,"ok":false,"status":"push-failed","nextPhase":"deliver"}' \
  > "$d/delivery.json"
check_output "deliver-next resolves sidecar nextPhase=deliver" \
  "nextPhase=deliver reason=delivery.json.nextPhase=deliver" \
  "$DELIVER_NEXT" --feature-dir "$d"

# A sidecar that names a non-answer must fail closed, not fall through to
# tracked execute and silently take the remediation route.
d="$(feature_dir sidecar-bogus '{"delivery":{"nextPhase":"execute"}}')"
printf '%s' '{"nextPhase":"pending"}' > "$d/delivery.json"
check "deliver-next is unresolved on a sidecar nextPhase outside the answer set" \
  1 "$DELIVER_NEXT" --feature-dir "$d"
check_silent "deliver-next prints nothing on a sidecar nextPhase outside the answer set" \
  "$DELIVER_NEXT" --feature-dir "$d"

# =====================================================================
# execute-fanout.sh
# =====================================================================
# The execute node body already runs the selected rung to completion.
# Walking the unconditional fanout then dispatched loop-spec:implementer
# against an empty mergeQueue. mergeQueue is the worker subgraph's input.
EXECUTE_FANOUT="$PROBES/execute-fanout.sh"

out="$(bash "$EXECUTE_FANOUT" --answers)"
[[ "$out" == $'fanout=skip\nfanout=worker' ]] \
  && { echo "PASS: execute-fanout --answers lists skip and worker"; PASS=$((PASS+1)); } \
  || { echo "FAIL: execute-fanout --answers lists skip and worker (got: $out)"; FAIL=$((FAIL+1)); }

d="$(feature_dir fanout-empty '{"mergeQueue":[]}')"
check_output "execute-fanout skips when mergeQueue is empty" \
  "fanout=skip reason=mergeQueue-empty" \
  "$EXECUTE_FANOUT" --feature-dir "$d"

d="$(feature_dir fanout-absent '{"slug":"no-queue"}')"
check_output "execute-fanout skips when mergeQueue is absent" \
  "fanout=skip reason=mergeQueue-empty" \
  "$EXECUTE_FANOUT" --feature-dir "$d"

d="$(feature_dir fanout-null '{"mergeQueue":null}')"
check_output "execute-fanout skips when mergeQueue is null" \
  "fanout=skip reason=mergeQueue-empty" \
  "$EXECUTE_FANOUT" --feature-dir "$d"

d="$(feature_dir fanout-worker '{"mergeQueue":["task-001","task-002"]}')"
check_output "execute-fanout admits the worker when mergeQueue has work" \
  "fanout=worker reason=mergeQueue-length=2" \
  "$EXECUTE_FANOUT" --feature-dir "$d"

d="$(feature_dir fanout-bogus '{"mergeQueue":"task-001"}')"
check "execute-fanout is unresolved when mergeQueue is not an array" \
  1 "$EXECUTE_FANOUT" --feature-dir "$d"
check_silent "execute-fanout prints nothing when mergeQueue is not an array" \
  "$EXECUTE_FANOUT" --feature-dir "$d"

check "execute-fanout is unresolved without a feature.json" \
  1 "$EXECUTE_FANOUT" --feature-dir "$WORK/no-such-dir"
check_silent "execute-fanout prints nothing without a feature.json" \
  "$EXECUTE_FANOUT" --feature-dir "$WORK/no-such-dir"

skip_route="$(jq -r '[.edges[]|select(.from=="execute" and .to=="human.after-execute" and .kind=="route" and .condition.expects=="fanout=skip")]|length' "$ROOT/graph/cycle.graph.json")"
worker_route="$(jq -r '[.edges[]|select(.from=="execute" and .to=="execute.worker" and .kind=="route" and .condition.expects=="fanout=worker")]|length' "$ROOT/graph/cycle.graph.json")"
if [[ "$skip_route" == "1" && "$worker_route" == "1" ]]; then
  echo "PASS: execute skip and worker routes are declared"; PASS=$((PASS + 1))
else
  echo "FAIL: execute skip=$skip_route worker=$worker_route (need one of each)"; FAIL=$((FAIL + 1))
fi

declared="$(bash "$EXECUTE_FANOUT" --answers)"
missing=0
while IFS= read -r expects; do
  [[ -z "$expects" ]] && continue
  grep -qxF "$expects" <<<"$declared" || { echo "  undeclared: $expects"; missing=$((missing + 1)); }
done < <(jq -r '[.edges[].condition]
  | map(select(. != null and (.probe | test("execute-fanout.sh$")))) | .[].expects' \
  "$ROOT/graph/cycle.graph.json")
if [[ "$missing" -eq 0 ]]; then
  echo "PASS: every execute-fanout route expects a declared answer"; PASS=$((PASS + 1))
else
  echo "FAIL: $missing execute-fanout route(s) expect an undeclared answer"; FAIL=$((FAIL + 1))
fi

exec_default="$(jq -r '.nodes[] | select(.id=="execute") | .routeDefault // empty' "$ROOT/graph/cycle.graph.json")"
if [[ "$exec_default" == "human.after-execute" ]]; then
  echo "PASS: execute routeDefault is the skip target, not the worker"; PASS=$((PASS + 1))
else
  echo "FAIL: execute routeDefault is '$exec_default', expected human.after-execute"; FAIL=$((FAIL + 1))
fi

# =====================================================================
# plan-critique.sh (wraps lib/security-signal.sh over a real git diff)
# =====================================================================
PLAN_CRITIQUE="$PROBES/plan-critique.sh"

out="$(bash "$PLAN_CRITIQUE" --answers)"
[[ "$out" == $'signal=matched\nsignal=none' ]] \
  && { echo "PASS: plan-critique --answers lists exactly the two signal tokens"; PASS=$((PASS+1)); } \
  || { echo "FAIL: plan-critique --answers lists exactly the two signal tokens (got: $out)"; FAIL=$((FAIL+1)); }

REPO="$WORK/repo"
git init -q "$REPO"
git -C "$REPO" config user.email t@t.com
git -C "$REPO" config user.name t
echo "hello world" > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -qm init
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
FDIR="$REPO/.loop-spec/features/demo"
mkdir -p "$FDIR"
printf '{"workspace":null,"baseSha":"%s"}' "$BASE_SHA" > "$FDIR/feature.json"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "add feature dir"

# No changes yet past the recorded base -> a determined empty change set.
check_output "plan-critique resolves signal=none on an empty diff" "signal=none reason=" "$PLAN_CRITIQUE" --feature-dir "$FDIR"

echo "just some ordinary prose" >> "$REPO/a.txt"
git -C "$REPO" -C "$REPO" add a.txt 2>/dev/null || git -C "$REPO" add a.txt
git -C "$REPO" commit -qm "benign change"
check_output "plan-critique resolves signal=none on a benign diff" "signal=none reason=" "$PLAN_CRITIQUE" --feature-dir "$FDIR"

echo "rotate the auth credential" > "$REPO/b.txt"
git -C "$REPO" add b.txt
git -C "$REPO" commit -qm "add auth handling"
check_output "plan-critique resolves signal=matched on a security-relevant diff" "signal=matched reason=" "$PLAN_CRITIQUE" --feature-dir "$FDIR"

# A deleted-only change: nothing left to scan, still a determined signal=none.
git -C "$REPO" rm -q b.txt
git -C "$REPO" commit -qm "remove the auth file again"
check_output "plan-critique resolves signal=none when the only change is a deletion" "signal=none reason=" "$PLAN_CRITIQUE" --feature-dir "$FDIR"

# Cannot determine the change set -> unresolved, never signal=none.
printf '{"workspace":null,"baseSha":""}' > "$FDIR/feature.json"
check "plan-critique is unresolved when baseSha is missing" 1 "$PLAN_CRITIQUE" --feature-dir "$FDIR"
check_silent "plan-critique prints nothing when baseSha is missing" "$PLAN_CRITIQUE" --feature-dir "$FDIR"

printf '{"workspace":null,"baseSha":"0000000000000000000000000000000000dead"}' > "$FDIR/feature.json"
check "plan-critique is unresolved when baseSha does not resolve to a commit" 1 "$PLAN_CRITIQUE" --feature-dir "$FDIR"

check "plan-critique is unresolved when feature.json is missing" 1 "$PLAN_CRITIQUE" --feature-dir "$WORK/does-not-exist"

# --- human-gate: which styles pause at a human node ---
# Regression: every human node's admit once pinned `style=step`, so `interactive`
# -- the style that pauses the MOST -- skipped every human gate. An admit holds
# one token, so the pausing/non-pausing split has to live in the probe.
HUMAN_GATE="$ROOT/lib/graph/probes/human-gate.sh"
HG="$WORK/hg"; mkdir -p "$HG"

for style in step interactive; do
  printf '{"execStyle":"%s"}' "$style" > "$HG/feature.json"
  check_output "human-gate pauses for $style" "gate=pause reason=" "$HUMAN_GATE" --feature-dir "$HG"
done
for style in auto review-only; do
  printf '{"execStyle":"%s"}' "$style" > "$HG/feature.json"
  check_output "human-gate skips for $style" "gate=skip reason=" "$HUMAN_GATE" --feature-dir "$HG"
done

printf '{"execStyle":"bogus"}' > "$HG/feature.json"
check "human-gate is unresolved on an unknown style" 1 "$HUMAN_GATE" --feature-dir "$HG"
check_silent "human-gate prints nothing on an unknown style" "$HUMAN_GATE" --feature-dir "$HG"
check "human-gate is unresolved when feature.json is missing" 1 "$HUMAN_GATE" --feature-dir "$WORK/does-not-exist"

# Every human node must admit through this probe, not a style token.
bad_admits="$(jq -r '[.nodes[]|select(.kind=="human")|select(.admit.expects != "gate=pause")]|length' "$ROOT/graph/cycle.graph.json")"
if [[ "$bad_admits" == "0" ]]; then
  echo "PASS: every human node admits on gate=pause"; PASS=$((PASS + 1))
else
  echo "FAIL: $bad_admits human node(s) admit on something other than gate=pause"; FAIL=$((FAIL + 1))
fi

# --- iterate-approval: the compound spec-rewind gate ---
# Regression: gap and style lived in separate routes, and the engine takes the
# first satisfied route in declaration order -- so `gap=spec` matched before the
# style routes and the approval gate was UNREACHABLE. step/interactive silently
# lost the approval they opted into. Also: a spec gap rewinds to DISCUSS (the
# autonomous refinement mode), never to SPEC -- see skills/iterate/SKILL.md.
APPROVAL="$ROOT/lib/graph/probes/iterate-approval.sh"
IA="$WORK/ia"; mkdir -p "$IA"
set_state() {
  python3 -c "
import json,sys
fb = None if sys.argv[2]=='none' else {'type': sys.argv[2]}
json.dump({'execStyle': sys.argv[3], 'iterate': {'feedback': fb}}, open(sys.argv[1],'w'))
" "$IA/feature.json" "$1" "$2"
}

for style in step interactive; do
  set_state spec "$style"
  check_output "iterate-approval requires approval for a spec gap under $style" \
    "approval=required reason=" "$APPROVAL" --feature-dir "$IA"
done
for style in auto review-only; do
  set_state spec "$style"
  check_output "iterate-approval is autonomous for a spec gap under $style" \
    "approval=none reason=" "$APPROVAL" --feature-dir "$IA"
done
for gap in execute plan none; do
  set_state "$gap" step
  check_output "iterate-approval does not gate a $gap gap under step" \
    "approval=none reason=" "$APPROVAL" --feature-dir "$IA"
done

printf '{"execStyle":"step","iterate":{}}' > "$IA/feature.json"
check "iterate-approval is unresolved when no verdict is recorded" 1 "$APPROVAL" --feature-dir "$IA"
check_silent "iterate-approval prints nothing when unresolved" "$APPROVAL" --feature-dir "$IA"

# --- short-path: may this run take the shorter declared path through the cycle? ---
SHORT_PATH="$PROBES/short-path.sh"
SP="$WORK/shortpath"
mkdir -p "$SP"
check_output "short-path enumerates its answer set" "path=short" "$SHORT_PATH" --answers
check_output "short-path enumerates the long answer too" "path=full" "$SHORT_PATH" --answers
check "short-path needs a feature dir" 2 "$SHORT_PATH"

seed_sp() { jq -n --argjson a "$2" --arg p "$1" \
  '{slug:"sp",executionProfile:$p,artifacts:$a}' > "$SP/feature.json"; }

# Both conditions must hold, and each answers with its own reason.
seed_sp maintenance '{}'
check_output "maintenance profile with no artifacts takes the short path" \
  "path=short reason=" "$SHORT_PATH" --feature-dir "$SP"
seed_sp standard '{}'
check_output "the standard profile takes the long path" \
  "path=full reason=executionProfile=standard" "$SHORT_PATH" --feature-dir "$SP"

# The security signal is re-checked against the artifacts the run has WRITTEN, not
# trusted from classification time: SPEC and DISCUSS author them after the profile
# was chosen, so a change that turns out to touch a security surface lengthens its
# own path.
printf '# Spec\n\nRotate the OAuth2 credential.\n' > "$SP/SPEC.md"
seed_sp maintenance "$(jq -n --arg s "$SP/SPEC.md" '{spec:$s}')"
check_output "a security signal in a written artifact forces the long path" \
  "path=full reason=security signal" "$SHORT_PATH" --feature-dir "$SP"
printf '# Spec\n\nBump the pinned version.\n' > "$SP/SPEC.md"
check_output "a clean artifact keeps the short path" \
  "path=short reason=" "$SHORT_PATH" --feature-dir "$SP"

# A boundary mention is not a security surface (lib/security-signal.sh context rules).
printf '# Spec\n\nBump the pin.\n\n## Non-Goals\n\n- Rotating the OAuth2 credentials.\n' \
  > "$SP/SPEC.md"
check_output "a non-goal mention does not lengthen the path" \
  "path=short reason=" "$SHORT_PATH" --feature-dir "$SP"

# Anything undeterminable answers with the LONG path -- never a silent short-circuit.
check_output "a missing feature.json answers path=full" \
  "path=full reason=no feature.json" "$SHORT_PATH" --feature-dir "$WORK/no-such-dir"
seed_sp maintenance '{}'
printf 'not json\n' > "$SP/feature.json"
check_output "an unreadable feature.json answers path=full" \
  "path=full reason=" "$SHORT_PATH" --feature-dir "$SP"

# Every route naming this probe expects a token the probe declares (the same rule
# lib/graph/validate.sh applies, asserted here against the shipped graph).
declared="$(bash "$SHORT_PATH" --answers)"
missing=0
while IFS= read -r expects; do
  [[ -z "$expects" ]] && continue
  grep -qxF "$expects" <<<"$declared" || { echo "  undeclared: $expects"; missing=$((missing + 1)); }
done < <(jq -r '[.edges[].condition]
  | map(select(. != null and (.probe | test("short-path.sh$")))) | .[].expects' \
  "$ROOT/graph/cycle.graph.json")
if [[ "$missing" -eq 0 ]]; then
  echo "PASS: every short-path route expects a declared answer"; PASS=$((PASS + 1))
else
  echo "FAIL: $missing short-path route(s) expect an undeclared answer"; FAIL=$((FAIL + 1))
fi

# The spec rewind target, asserted against the graph itself.
spec_target="$(jq -r '.edges[]|select(.from=="iterate" and .condition.expects=="gap=spec")|.to' "$ROOT/graph/cycle.graph.json")"
if [[ "$spec_target" == "discuss" ]]; then
  echo "PASS: spec gap rewinds to discuss"; PASS=$((PASS + 1))
else
  echo "FAIL: spec gap rewinds to '$spec_target', expected 'discuss'"; FAIL=$((FAIL + 1))
fi

# --- discuss-critique: skip the spec-critique subgraph without skipping the grill ---
DISCUSS_CRITIQUE="$PROBES/discuss-critique.sh"
DC="$WORK/discuss-critique"
mkdir -p "$DC"
check_output "discuss-critique enumerates gate=run" "gate=run" "$DISCUSS_CRITIQUE" --answers
check_output "discuss-critique enumerates gate=skip" "gate=skip" "$DISCUSS_CRITIQUE" --answers
check "discuss-critique needs a feature dir" 2 "$DISCUSS_CRITIQUE"

write_spec() {
  local path="$1" gate="$2" unresolved="$3"
  cat > "$path" <<EOF
---
ambiguity_scores:
  goal_clarity: 0.90
  boundary_clarity: 0.90
  constraint_clarity: 0.90
  acceptance_clarity: 0.90
  ambiguity: 0.10
  rounds_completed: 2
  gate_passed: $gate
  unresolved_dimensions: $unresolved
---

# Spec

Bump the pinned version.
EOF
}

seed_dc() {
  jq -n --arg spec "$DC/SPEC.md" --argjson fb "$2" --arg p "$1" \
    '{slug:"dc",executionProfile:$p,iterate:{feedback:$fb},artifacts:{spec:$spec}}' \
    > "$DC/feature.json"
}

write_spec "$DC/SPEC.md" true '[]'
seed_dc standard 'null'
check_output "an already-gated spec skips critique" \
  "gate=skip reason=spec already gated" "$DISCUSS_CRITIQUE" --feature-dir "$DC"

write_spec "$DC/SPEC.md" false '[]'
check_output "an ungated spec runs critique" \
  "gate=run reason=spec not already gated" "$DISCUSS_CRITIQUE" --feature-dir "$DC"

write_spec "$DC/SPEC.md" true '[goal_clarity]'
check_output "unresolved dimensions force critique" \
  "gate=run reason=spec not already gated" "$DISCUSS_CRITIQUE" --feature-dir "$DC"

write_spec "$DC/SPEC.md" true '[]'
seed_dc standard '{"type":"spec"}'
check_output "iterate re-entry runs critique even when gated" \
  "gate=run reason=iterate re-entry" "$DISCUSS_CRITIQUE" --feature-dir "$DC"

seed_dc maintenance 'null'
check_output "maintenance profile skips critique when the spec is clean" \
  "gate=skip reason=maintenance profile, no security signal" \
  "$DISCUSS_CRITIQUE" --feature-dir "$DC"

printf '# Spec\n\nRotate the OAuth2 credential.\n' > "$DC/SPEC.md"
seed_dc standard 'null'
check_output "a security signal forces critique even on a gated-looking skip path" \
  "gate=run reason=security signal" "$DISCUSS_CRITIQUE" --feature-dir "$DC"

check_output "a missing feature.json fails closed to run" \
  "gate=run reason=no feature.json" "$DISCUSS_CRITIQUE" --feature-dir "$WORK/no-such-dir"

declared="$(bash "$DISCUSS_CRITIQUE" --answers)"
missing=0
while IFS= read -r expects; do
  [[ -z "$expects" ]] && continue
  grep -qxF "$expects" <<<"$declared" || { echo "  undeclared: $expects"; missing=$((missing + 1)); }
done < <(jq -r '[.edges[].condition]
  | map(select(. != null and (.probe | test("discuss-critique.sh$")))) | .[].expects' \
  "$ROOT/graph/cycle.graph.json")
if [[ "$missing" -eq 0 ]]; then
  echo "PASS: every discuss-critique route expects a declared answer"; PASS=$((PASS + 1))
else
  echo "FAIL: $missing discuss-critique route(s) expect an undeclared answer"; FAIL=$((FAIL + 1))
fi

debate_nodes="$(jq -r '[.nodes[]|select(.id=="critique.debate" or .id=="critique.escalate")]|length' \
  "$ROOT/graph/critique.graph.json")"
if [[ "$debate_nodes" == "0" ]]; then
  echo "PASS: critique graph has no advocate debate nodes"; PASS=$((PASS + 1))
else
  echo "FAIL: critique graph still declares $debate_nodes debate/escalate node(s)"; FAIL=$((FAIL + 1))
fi

# The approval route must be declared BEFORE the gap routes or it is dead.
order="$(jq -r '[.edges[]|select(.from=="iterate" and .kind=="route")|.condition.expects]|index("approval=required")' "$ROOT/graph/cycle.graph.json")"
if [[ "$order" == "0" ]]; then
  echo "PASS: approval route is evaluated before the gap routes"; PASS=$((PASS + 1))
else
  echo "FAIL: approval route is at index $order; must be 0 or it is unreachable"; FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
