#!/usr/bin/env bash
# iterate-judged.sh - ITERATE's bookkeeping around the judge, one call per step.
#
# Why: ITERATE asked the lead for a limit check, a verdict extraction, three state
# writes, an event, a floor check, a feedback write, remediation tasks per gap, and on a
# spent budget a harvest into warnings and the backlog, each a Bash call
# (the 2026-09-06 live evals, finding 7). The judge is the only model work here.
#
# Usage:
#   iterate-judged.sh limit   --feature-dir DIR
#       Before dispatching: {route:"judge"|"confirmation"|"harvest", used, max}.
#       confirmation = budget spent and the once-only confirmation pass is still owed
#       (it is marked used here); harvest = budget spent and confirmed; judge = rounds left.
#   iterate-judged.sh record  --feature-dir DIR --judge-out FILE [--confirmation]
#       Extracts the verdict JSON from the judge's completion message, records it, emits
#       iterate_verdict, runs the converged floor, writes iterate.feedback and the
#       remediation tasks a gap needs. Prints
#       {verdict, converged, floor:[...], route:"deliver"|"execute"|"plan"|"spec"|"harvest"|"escalate", tasks:[...]}.
#       escalate = the gap needs an operator (gap.needs_operator, or the same fix_first
#       survived a remediation round); the cycle's `next` ends the run escalated.
#       --confirmation never increments used and never rewinds: converged -> deliver,
#       otherwise -> harvest.
#   iterate-judged.sh harvest --feature-dir DIR
#       Budget spent: every gap of the freshest verdict goes to warnings[] (prefixed
#       iterate-budget-spent:) and the backlog with its deterministic id; a second limit on
#       the same backlog entry is iterate-terminal: and closes it. Prints
#       {route:"deliver", warnings:[...], terminal:bool}.
#
# Exit: 0 answered; 1 the judge's output holds no usable verdict (re-dispatch once, then
# escalate); 2 bad invocation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib() { loop_spec_publication_lib "$SCRIPT_DIR" "$@"; }
usage() { sed -n '2,30p' "$0" | grep -E '^#( |$)' | sed 's/^# \{0,1\}//' >&2; exit 2; }

cmd="${1:-}"; shift || true
feature_dir="" judge_out="" confirmation=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; shift 2 ;; --judge-out) judge_out="${2:-}"; shift 2 ;;
    --confirmation) confirmation=1; shift ;; *) usage ;;
  esac
done
case "$cmd" in limit|record|harvest) ;; *) usage ;; esac
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] || usage
feature_dir="$(cd "$feature_dir" && pwd -P)"
. "$SCRIPT_DIR/feature-write.sh"
loop_spec_publication_begin "$feature_dir" || exit 1
fj="$feature_dir/feature.json"
fget() { bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" -r --filter "$1"; }
fset() { lib feature-write set "$feature_dir" "$1" "$2" >/dev/null; }
slug="$(fget '.slug')"
used="$(fget '.iterate.used // 0')"; max="$(fget '.iterate.maxIterations // 10')"
root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null || pwd)"
docs="$root/docs/loop-spec/features/$slug"
default_verify="$(fget '.commands.test // ""')"

case "$cmd" in
  limit)
    route=judge
    if (( used >= max )); then
      if (( used > 0 )) && [[ "$(fget '.iterate.confirmationUsed // false')" != "true" ]]; then
        fset iterate.confirmationUsed true; route=confirmation
      else
        route=harvest
      fi
    fi
    jq -cn --arg r "$route" --argjson u "$used" --argjson m "$max" '{route:$r, used:$u, max:$m}'
    ;;
  record)
    [[ -n "$judge_out" && -r "$judge_out" ]] || usage
    verdict="$(python3 - "$judge_out" <<'PY'
import json, re, sys
txt = open(sys.argv[1]).read()
m = re.search(r"```json\s*(\{.*?\})\s*```", txt, re.S) or re.search(r"(\{.*\})", txt, re.S)
if not m: sys.exit("iterate-judged: no JSON verdict found")
try: d = json.loads(m.group(1))
except ValueError as exc: sys.exit("iterate-judged: verdict is not JSON: %s" % exc)
for k in ("converged", "deterministic_gate_passed", "summary"):
    if k not in d: sys.exit("iterate-judged: verdict missing '%s'" % k)
print(json.dumps(d))
PY
)" || { echo "iterate-judged: malformed judge verdict; re-dispatch once, then escalate" >&2; exit 1; }
    # The same judge output recorded twice is one round, not two: the 6.2.0 smoke run
    # counted four iterations from one converged verdict.
    judge_hash="$(cksum "$judge_out" | cut -d' ' -f1)"
    if [[ "$(fget '.iterate.lastJudgeHash // ""')" == "$judge_hash" ]]; then
      prior_route="$(fget '.iterate.lastRoute // ""')"
      [[ -n "$prior_route" ]] && { jq -cn --argjson v "$(fget '.iterate.lastVerdict')" --arg r "$prior_route" '{verdict:$v, converged:$v.converged, floor:[], route:$r, tasks:[], repeated:true}'; exit 0; }
    fi
    fset iterate.lastJudgeHash "\"$judge_hash\""
    iteration=$((used + 1)); (( confirmation )) && iteration="$used"
    (( confirmation )) || fset iterate.used "$iteration"
    fset iterate.lastVerdict "$verdict"
    lib feature-write append "$feature_dir" iterate.history "$verdict" >/dev/null
    converged="$(jq -r '.converged' <<<"$verdict")"
    lib events emit "$feature_dir" iterate_verdict --phase iterate \
      --data "$(jq -cn --arg v "$([[ "$converged" == true ]] && echo converged || echo not-converged)" --argjson i "$iteration" --arg g "$(jq -r '.gap.type // "none"' <<<"$verdict")" '{verdict:$v, iteration:$i, gap:$g}')" >/dev/null 2>&1 || true
    floor='[]'; route=""; tasks='[]'
    if [[ "$converged" == "true" ]]; then
      frc=0; fout="$(lib converged-floor "$docs/SPEC.md" "$docs/VERIFICATION.md" --feature-dir "$feature_dir" 2>&1)" || frc=$?
      if (( frc == 0 )); then
        fset iterate.feedback null; route=deliver
      else
        floor="$(grep '^FLOOR' <<<"$fout" | jq -R . | jq -cs .)"
        first="$(jq -r '.[0] // "verification record does not support the verdict"' <<<"$floor")"
        # A FAIL row is code work; anything else (a missing grounding row, a non-PASS
        # result) is a verification record VERIFY has to complete. Rewinding those to
        # EXECUTE dispatched an implementer with nothing to do (the port plan,
        # defect 2).
        floor_type=verify
        grep -q 'still FAIL' <<<"$fout" && floor_type=execute
        verdict="$(jq -c --arg f "$first" --arg t "$floor_type" '.converged = false | .gap = {type:$t, description:("converged floor: " + $f), fix_first:$f}' <<<"$verdict")"
        fset iterate.lastVerdict "$verdict"
      fi
    fi
    if [[ -z "$route" ]]; then
      if (( confirmation )); then route=harvest
      else
        gap="$(jq -c '.gap // {type:"execute", description:"goal not met", fix_first:(.weakest // .summary)}' <<<"$verdict")"
        fset iterate.feedback "$gap"
        route="$(jq -r '.type // "execute"' <<<"$gap")"
        case "$route" in execute|plan|spec|verify) ;; *) route=execute ;; esac
        # A gap only an operator can close (expired credentials, an approval, a network
        # the sandbox lacks) is not a rewind target: a live run rewound EXECUTE to re-run
        # a plan against a locked gcloud token, judged the identical gap, then asked a
        # question nobody was there to answer (PR 93). The judge marks such a gap
        # needs_operator; the same fix_first surviving a remediation round says the same
        # thing without the judge's help. Either way the cycle's `next` ends the run
        # escalated with the fix as the reason.
        prior_fix="$(fget '(.iterate.history // [])[-2].gap.fix_first // ""' | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')"
        this_fix="$(jq -r '.fix_first // ""' <<<"$gap" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')"
        if [[ "$(jq -r '.needs_operator // false' <<<"$gap")" == "true" ]] \
           || [[ -n "$this_fix" && "$this_fix" == "$prior_fix" ]]; then
          route=escalate
        fi
        if [[ "$route" == "execute" ]]; then
          tasks="$(jq -c --arg v "$default_verify" --argjson g "$gap" '
            ([$g] + [(.remaining_gaps // [])[] | select(.type == "execute")])
            | to_entries | map({id:("task-iterate-" + (.key + 1 | tostring)), subject:("Iterate fix: " + (.value.fix_first // .value.description)),
                files:(.value.files // []), verifyCommand:$v, acceptanceCriteria:[(.value.fix_first // .value.description)], blockedBy:[], retries:0})' <<<"$verdict")"
          while IFS= read -r t; do [[ -n "$t" ]] && lib feature-write append "$feature_dir" pendingRemediationTasks "$t" >/dev/null; done < <(jq -c '.[]' <<<"$tasks")
        fi
      fi
    fi
    fset iterate.lastRoute "\"$route\""
    jq -cn --argjson v "$verdict" --arg r "$route" --argjson f "$floor" --argjson t "$tasks" \
      '{verdict:$v, converged:$v.converged, floor:$f, route:$r, tasks:$t, repeated:false}'
    ;;
  harvest)
    verdict="$(fget '.iterate.lastVerdict // null')"
    warnings='[]'; terminal=false
    entry_id="$(fget '.backlogEntryId // ""')"
    while IFS= read -r gap; do
      [[ -n "$gap" ]] || continue
      desc="$(jq -r '.description // "gap"' <<<"$gap")"; fix="$(jq -r '.fix_first // .description // "gap"' <<<"$gap")"
      gid="$(lib backlog gap-id "$fix" 2>/dev/null || echo "")"
      if [[ -n "$entry_id" && "$gid" == "$entry_id" ]]; then
        terminal=true
        warnings="$(jq -c --arg w "iterate-terminal: $desc — fix first: $fix" '. + [$w]' <<<"$warnings")"
        lib backlog terminal "$gid" "two iteration limits spent on $slug; approach wrong" >/dev/null 2>&1 || true
        lib rules add "iterate limit spent on $slug with a $(jq -r '.type // "execute"' <<<"$gap")-level gap: $desc" --check "bash lib/criteria-coverage.sh $docs/SPEC.md $docs/PLAN.md" >/dev/null 2>&1 || true
      else
        warnings="$(jq -c --arg w "iterate-budget-spent: $desc — fix first: $fix" '. + [$w]' <<<"$warnings")"
        lib backlog add "$slug" iterate-gap "$desc — fix first: $fix" ${gid:+--id "$gid"} >/dev/null 2>&1 || true
      fi
    done < <(jq -c 'if . == null then empty else ([.gap // empty] + (.remaining_gaps // []))[] end' <<<"$verdict")
    [[ "$(jq 'length' <<<"$warnings")" != "0" ]] || warnings='["iterate-budget-spent: final remediation was never re-judged against the original goal"]'
    while IFS= read -r w; do [[ -n "$w" ]] && lib feature-write append "$feature_dir" warnings "$w" >/dev/null; done < <(jq -c '.[]' <<<"$warnings")
    fset iterate.feedback null
    jq -cn --argjson w "$warnings" --argjson t "$terminal" '{route:"deliver", warnings:$w, terminal:$t}'
    ;;
esac
