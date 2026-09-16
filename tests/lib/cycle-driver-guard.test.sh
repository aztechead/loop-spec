#!/usr/bin/env bash
# Tests for lib/cycle-driver.sh, part 5 of 5: a merged record is not a live cycle, workspace liveness guards. Split so
# tests/run-all.sh runs the five parts in parallel; the serial file set the wall clock.
. "$(dirname "$0")/cycle-driver.common.sh"

# --- a merged record is not a live cycle (6.6.7) --------------------------------------
# currentPhase alone used to be the guard: a feature.json a prior delivered cycle
# committed, or one a fresh clone inherited, carries a phase the graph still calls live
# with none of THIS checkout's own evidence — no branch, no state ref, no armed run.
R12="$(new_repo merged-record)"
mkdir -p "$R12/.loop-spec/features/old"
printf '{"schemaVersion":7,"slug":"old","currentPhase":"deliver","branch":"feat/old"}\n' > "$R12/.loop-spec/features/old/feature.json"
git -C "$R12" add -f "$R12/.loop-spec/features/old/feature.json"
git -C "$R12" -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -m "merged record"
ec=0; drv init --dir "$R12" --slug fresh --title fresh --style auto --profile standard >/dev/null 2>&1 || ec=$?
check "init: a merged record with no branch, ref, or armed run is not a live cycle" "0" "$ec"

R13="$(new_repo merged-record-decline)"
mkdir -p "$R13/.loop-spec/features/old"
printf '{"schemaVersion":7,"slug":"old","currentPhase":"deliver","branch":"feat/old"}\n' > "$R13/.loop-spec/features/old/feature.json"
git -C "$R13" add -f "$R13/.loop-spec/features/old/feature.json"
git -C "$R13" -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -m "merged record"
ec=0; drv decline --dir "$R13" --reason "a question" >/dev/null 2>&1 || ec=$?
check "decline: a merged record is not a live cycle either" "0" "$ec"
check "decline: the mismatch is still published" "protocol-mismatch" "$(jq -r '.outcome' "$R13/.loop-spec/last-result.json")"

# --- a state ref alone is bookkeeping, not a running cycle (a hand-merged feature leaves one behind)
R14="$(new_repo state-ref-only)"
mkdir -p "$R14/.loop-spec/features/held"
printf '{"schemaVersion":7,"slug":"held","currentPhase":"execute","branch":"feat/held"}\n' > "$R14/.loop-spec/features/held/feature.json"
bash "$REPO_ROOT/lib/state-ref.sh" commit "$R14/.loop-spec/features/held" "state @ execute" >/dev/null
ec=0; err="$(drv init --dir "$R14" --slug other --title other --style auto --profile standard 2>&1 >/dev/null)" || ec=$?
check "init: a state ref with the branch not checked out is not a live cycle" "0" "$ec"

# --- a pre-6.6.7 delivered record in the same checkout is harmless --------------------
# The branch is still here (not checked out, so no evidence on its own), but a terminal
# delivery sidecar answers first: finished work waiting on its report, not a cycle in
# flight, so a record written before this fix does not need normalizing to unblock.
R15="$(new_repo delivered-record)"
mkdir -p "$R15/.loop-spec/features/done"
printf '{"schemaVersion":7,"slug":"done","currentPhase":"deliver","branch":"feat/done"}\n' > "$R15/.loop-spec/features/done/feature.json"
printf '{"status":"ready-for-review","nextPhase":"completed"}\n' > "$R15/.loop-spec/features/done/delivery.json"
git -C "$R15" branch feat/done
ec=0; drv init --dir "$R15" --slug other --title other --style auto --profile standard >/dev/null 2>&1 || ec=$?
check "init: a terminal delivery sidecar counts as finished even with the branch still here" "0" "$ec"

# --- already-satisfied: a completed result.json closes the feature too ----------------
# deliver_stalled's no-change completion never reaches finish (its sidecar says
# no-changes), so the result record is the terminal evidence for one written before 6.6.7.
R16="$(new_repo already-satisfied)"
mkdir -p "$R16/.loop-spec/features/same"
printf '{"schemaVersion":7,"slug":"same","currentPhase":"deliver","branch":"feat/same"}\n' > "$R16/.loop-spec/features/same/feature.json"
printf '{"status":"no-changes","nextPhase":"deliver"}\n' > "$R16/.loop-spec/features/same/delivery.json"
printf '{"schema":1,"status":"completed","outcome":"no-change-needed"}\n' > "$R16/.loop-spec/features/same/result.json"
git -C "$R16" branch feat/same
ec=0; drv init --dir "$R16" --slug other --title other --style auto --profile standard >/dev/null 2>&1 || ec=$?
check "init: a completed result.json counts as finished even with the branch still here" "0" "$ec"

# --- a leftover branch that is not checked out is not a running cycle ----------------
R17="$(new_repo leftover-branch)"
mkdir -p "$R17/.loop-spec/features/held"
printf '{"schemaVersion":7,"slug":"held","currentPhase":"execute","branch":"feat/held"}\n' > "$R17/.loop-spec/features/held/feature.json"
git -C "$R17" branch feat/held
ec=0; drv init --dir "$R17" --slug other --title other --style auto --profile standard >/dev/null 2>&1 || ec=$?
check "init: a branch that exists but is not checked out is not a live cycle" "0" "$ec"

# --- the branch checked out in a linked worktree is this repository's running cycle ---
R18="$(new_repo worktree-branch)"
mkdir -p "$R18/.loop-spec/features/held"
printf '{"schemaVersion":7,"slug":"held","currentPhase":"execute","branch":"feat/held"}\n' > "$R18/.loop-spec/features/held/feature.json"
git -C "$R18" worktree add -q "$WORK/r18-wt" -b feat/held
ec=0; err="$(drv init --dir "$R18" --slug other --title other --style auto --profile standard 2>&1 >/dev/null)" || ec=$?
check "init: a branch checked out in a linked worktree is a live cycle" "1" "$ec"
check "init: the refusal says the branch is checked out" "1" "$(grep -c 'branch feat/held is checked out here' <<<"$err")"
check "init: the refusal forbids clearing other features' records" "1" "$(grep -c 'Never delete, edit, or commit' <<<"$err")"

# --- workspace liveness: the evidence is each repo's own branch -------------------------
# A workspace feature keeps the top-level branch null, cuts no state ref, and loses
# active-run.json at the first published result; its repos' feat/<slug> heads are the
# checkout's evidence. Both decline and a second init must refuse over one. The record's
# workspace.root points elsewhere on purpose: the branch is looked for under the root
# being scanned, so a moved workspace still answers for the checkout it is in.
WS="$WORK/ws"; mkdir -p "$WS/a"
git -C "$WS/a" init -q -b main
git -C "$WS/a" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$WS/a" checkout -q -b feat/held
mkdir -p "$WS/.loop-spec/features/held"
printf '{"schemaVersion":7,"slug":"held","currentPhase":"execute","branch":null,"workspace":{"root":"%s","mode":"workspace","repos":[{"name":"a","path":"a","branch":"feat/held"}]}}\n' "$WORK/moved-away" > "$WS/.loop-spec/features/held/feature.json"
ec=0; err="$(drv decline --dir "$WS" --reason "a question" 2>&1 >/dev/null)" || ec=$?
check "decline: a workspace feature with a live repo branch has begun" "1" "$ec"
check "decline: the workspace refusal names the feature" "1" "$(grep -c 'feature held has begun (phase execute)' <<<"$err")"
ec=0; err="$(drv init --dir "$WS" --slug other --title other --style auto --profile standard 2>&1 >/dev/null)" || ec=$?
check "init: a workspace feature with a live repo branch refuses a second feature" "1" "$ec"
check "init: the workspace refusal names the repo branch" "1" "$(grep -c 'already active in this workspace (phase execute; branch feat/held is checked out in workspace repo a)' <<<"$err")"
git -C "$WS/a" checkout -q main
ec=0; drv decline --dir "$WS" --reason "a question" >/dev/null 2>&1 || ec=$?
check "decline: the same workspace record with the branch not checked out is not live" "0" "$ec"


echo
echo "cycle-driver-guard: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
