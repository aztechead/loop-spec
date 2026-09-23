#!/usr/bin/env bash
# verify-prepare.sh - VERIFY's pre-team scans in one call, as one JSON object.
#
# Why: the placeholder scan, the tamper scan, the repository-wide validation, and the
# advisory regression scan are four lead calls the skill asked for one at a time, and a
# failing scan then asked the lead to append remediation tasks, a gate entry, and an
# event by hand. All of it is deterministic. This runs it and records the failure
# itself, so the lead reads one route and returns to the cycle.
#
# Usage:
#   verify-prepare.sh run --feature-dir DIR
#
# Output (one JSON object):
#   {mode:{...phase-mode verify...},
#    placeholder:{ran,ok,signals[]}, tamper:{ran,ok,signals[]},
#    validation:{ran,rc,outcome,result},          rc 20 regression, 21 infrastructure
#    regression:{ran,result},
#    route:"continue"|"remediate"|"escalate", class:null|"marker"|"tamper"|"suite-regression"|"infrastructure",
#    remediationTasks:[...]}
#
# On remediate: one full-shape task per signal (or one for a suite regression) is appended
# to pendingRemediationTasks[], the acceptance gate records a fail entry through
# lib/graph/gate.sh, a verify_failure event is emitted, and the team fields are cleared.
#
# A repeat call on the same clean HEADs, commands, baseline, and mode replays the stored
# answer with cached:true: no scan or suite re-runs and no second gate entry; only tasks
# missing from the queue are re-queued. An escalate answer is never stored.
#
# Exit: 0 continue; 1 remediate; 21 escalate (infrastructure); 2 bad invocation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib() { bash "$SCRIPT_DIR/$1.sh" "${@:2}"; }

[[ "${1:-}" == "run" ]] || { echo "usage: verify-prepare.sh run --feature-dir DIR" >&2; exit 2; }
shift
feature_dir=""
while [[ $# -gt 0 ]]; do case "$1" in --feature-dir) feature_dir="${2:-}"; shift 2 || { echo "verify-prepare: $1 needs a value" >&2; exit 2; } ;; *) echo "verify-prepare: unknown argument '$1'" >&2; exit 2 ;; esac; done
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] || { echo "usage: verify-prepare.sh run --feature-dir DIR" >&2; exit 2; }
feature_dir="$(cd "$feature_dir" && pwd -P)"
fj="$feature_dir/feature.json"
fget() { bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" -r --filter "$1"; }

mode_line="$(lib phase-mode verify --feature-dir "$feature_dir")"
mode="$(python3 -c '
import json, re, sys
print(json.dumps({m.group(1): m.group(2) for m in re.finditer(r"(\w+)=(.*?)(?=\s+\w+=|$)", sys.argv[1].strip())}))' "$mode_line")"
want() { [[ "$(jq -r --arg k "$1" '.[$k] // "run"' <<<"$mode")" == "run" ]]; }

# The suite takes minutes, and the 6.9.1 upstream run called this eight times in 25
# minutes, four on an unchanged tree, each appending another acceptance fail. The
# comparison already refuses a dirty tree, so clean HEADs plus what shapes the answer
# are the whole key; a dirty tree gets no key and runs as before.
top="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null || true)"
cache=""; key=""
if [[ -n "$top" ]]; then
  cache="$(git -C "$top" rev-parse --git-path "loop-spec/validation/$(fget '.slug')/verify-prepare.json")"
  [[ "$cache" == /* ]] || cache="$top/$cache"
  key="$({ fget '[.commands, .verificationBaseline, .workspace] | tojson'
           printf '%s\n' "$mode_line" "${LOOP_SPEC_INTEGRATION_CANDIDATE:-}"
           while IFS= read -r r; do
             [[ -z "$(git -C "$r" status --porcelain 2>/dev/null)" ]] || exit 1
             git -C "$r" rev-parse HEAD
           done < <(bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" -r --filter \
             'if .workspace == null then $top else (.workspace.root as $w | .workspace.repos[] | $w + "/" + .path) end' -- --arg top "$top")
         } | git hash-object --stdin)" || key=""
fi
if [[ -n "$key" && -f "$cache" ]] && jq -e --arg k "$key" '.key == $k' "$cache" >/dev/null 2>&1; then
  out="$(jq -c '.output | .cached = true' "$cache")"
  queued="$(fget '.pendingRemediationTasks // [] | tojson')"
  while IFS= read -r t; do [[ -n "$t" ]] && lib feature-write append "$feature_dir" pendingRemediationTasks "$t" >/dev/null
  done < <(jq -c --argjson q "$queued" '($q | map(.id)) as $ids | .remediationTasks[] | select(.id as $id | $ids | index($id) | not)' <<<"$out")
  printf '%s\n' "$out"
  exit "$(jq -r '.exit' "$cache")"
fi

scan() {
  # scan NAME SCRIPT -> {ran, ok, signals[]}; signals are the scan's "file:line: signal" lines.
  local name="$1" script="$2" out rc=0
  if ! want "$name"; then jq -cn '{ran:false, ok:true, signals:[]}'; return 0; fi
  out="$(lib feature-scan-each "$SCRIPT_DIR/$script.sh" --feature-dir "$feature_dir" 2>&1)" || rc=$?
  if (( rc == 0 )); then jq -cn '{ran:true, ok:true, signals:[]}'
  elif (( rc == 1 )); then jq -cn --argjson s "$(grep -E '^[^ ]+:[0-9]+:' <<<"$out" | jq -R . | jq -cs .)" '{ran:true, ok:false, signals:$s}'
  else jq -cn --arg e "$out" '{ran:true, ok:false, signals:[("scan could not run: " + $e)]}'; fi
}

placeholder="$(scan placeholder placeholder-scan)"
tamper="$(scan tamper test-tamper-scan)"

validation='{"ran":false,"rc":0,"outcome":null,"result":null}'
if want validation; then
  vrc=0; vout="$(lib feature-validation compare "$feature_dir" 2>/dev/null)" || vrc=$?
  vjson="$(jq -c . <<<"$vout" 2>/dev/null || echo null)"
  validation="$(jq -cn --argjson rc "$vrc" --argjson r "$vjson" '{ran:true, rc:$rc, outcome:($r.outcome // null), result:$r}')"
fi

regression='{"ran":false,"result":null}'
if want regression; then
  root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null || pwd)"
  rout="$(lib regression-scan "$root" 2>/dev/null || echo null)"
  regression="$(jq -cn --argjson r "$(jq -c . <<<"$rout" 2>/dev/null || echo null)" '{ran:true, result:$r}')"
fi

route=continue; class=null; tasks='[]'
default_verify="$(fget '.commands.test // ""')"
task() { jq -cn --arg id "$1" --arg subject "$2" --arg verify "$default_verify" --arg crit "$3" \
  '{id:$id, subject:$subject, files:[], verifyCommand:$verify, acceptanceCriteria:[$crit], blockedBy:[], retries:0}'; }
if [[ "$(jq -r '.ok' <<<"$placeholder")" == "false" ]]; then
  route=remediate; class=marker
  tasks="$(jq -c '.signals' <<<"$placeholder" | jq -c 'to_entries | map({id:("task-verify-marker-" + (.key + 1 | tostring)), subject:("Fix placeholder: " + .value), files:[(.value | split(":")[0])], acceptanceCriteria:[("no placeholder marker at " + .value)], blockedBy:[], retries:0})')"
elif [[ "$(jq -r '.ok' <<<"$tamper")" == "false" ]]; then
  route=remediate; class=tamper
  tasks="$(jq -c '.signals' <<<"$tamper" | jq -c 'to_entries | map({id:("task-verify-tamper-" + (.key + 1 | tostring)), subject:("Undo test tampering: " + .value), files:[(.value | split(":")[0])], acceptanceCriteria:[("the test at " + .value + " runs unmodified")], blockedBy:[], retries:0})')"
elif [[ "$(jq -r '.rc' <<<"$validation")" == "21" ]]; then
  route=escalate; class=infrastructure
elif [[ "$(jq -r '.rc' <<<"$validation")" == "20" ]]; then
  route=remediate; class=suite-regression
  # The added lines are what the comparison counts as a regression; without them the
  # implementer could only fix every pre-existing failure or delete tests (6.9.0 run).
  # With no baseline every failing line is new, and the comparison carries no addedLines,
  # so the failing commands and their fingerprint lines stand in (6.9.1 upstream report).
  added="$(jq -c '[.result.targets[]?.comparison // empty
      | if .baselineMissing then (.commands[]? | select(.status == "fail")
          | ("`" + .command + "` exits 0"), ((.fingerprintLines // {})[] | "this failure no longer appears: " + .))
        else (.commands[]?.addedLines[]? | "this failure no longer appears: " + .) end] | .[:10]' <<<"$validation")"
  tasks="$(jq -cn --argjson t "$(task task-verify-suite-1 "Fix the repository-wide suite regression" "the repository-wide test, lint, and typecheck commands pass as before the change")" \
    --argjson added "$added" '[$t | .acceptanceCriteria += $added]')"
fi
tasks="$(jq -c --arg v "$default_verify" 'map(.verifyCommand = (.verifyCommand // $v))' <<<"$tasks")"

if [[ "$route" == "remediate" ]]; then
  while IFS= read -r t; do [[ -n "$t" ]] && lib feature-write append "$feature_dir" pendingRemediationTasks "$t" >/dev/null; done < <(jq -c '.[]' <<<"$tasks")
  lib graph/gate open --feature-dir "$feature_dir" --phase verify --gate acceptance >/dev/null 2>&1 || true
  lib graph/gate fail --feature-dir "$feature_dir" --rounds 1 --convergence scan --challenger-model none \
    --findings "$(jq -c 'map(.subject)' <<<"$tasks")" >/dev/null 2>&1 || true
  lib events emit "$feature_dir" verify_failure --phase verify --data "$(jq -cn --arg c "$class" --argjson n "$(jq 'length' <<<"$tasks")" '{class:$c, tasks:$n}')" >/dev/null 2>&1 || true
  lib feature-write set "$feature_dir" currentTeamName null >/dev/null; lib feature-write set "$feature_dir" currentTeammates '[]' >/dev/null
fi

out="$(jq -cn --argjson m "$mode" --argjson p "$placeholder" --argjson t "$tamper" --argjson v "$validation" --argjson r "$regression" \
  --arg route "$route" --argjson class "$( [[ "$class" == null ]] && echo null || jq -Rn --arg c "$class" '$c' )" --argjson tasks "$tasks" \
  '{mode:$m, placeholder:$p, tamper:$t, validation:$v, regression:$r, route:$route, class:$class, remediationTasks:$tasks, cached:false}')"
case "$route" in continue) rc=0 ;; remediate) rc=1 ;; escalate) rc=21 ;; esac
# An infrastructure failure can clear without a commit, so only a verdict is replayed.
if [[ -n "$key" && "$route" != escalate ]]; then
  mkdir -p "$(dirname "$cache")" && jq -cn --arg k "$key" --argjson o "$out" --argjson e "$rc" '{key:$k, output:$o, exit:$e}' > "$cache" \
    || echo "verify-prepare: could not store the result at $cache; the next call re-runs the suite" >&2
fi
printf '%s\n' "$out"
exit "$rc"
