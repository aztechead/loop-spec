#!/usr/bin/env bash
# verify-gate.sh - Apply VERIFY's two agent verdicts and the deterministic exit in one call.
#
# Why: after the verifier and the code reviewer report, the skill asked the lead to run
# the exit lint, read two DONE lines, append remediation tasks, a gate entry, an event, a
# backlog line per Minor, a rule on a repeat, and tear the team down, one Bash call each
# (the 2026-09-06 live evals, finding 7). Only the verdicts are model work. This takes
# them as arguments and does the rest.
#
# Usage:
#   verify-gate.sh run --feature-dir DIR --verifier ALL_PASS|FAIL --suite PASS|FAIL|N/A \
#       --reviewer PASS|PASS_WITH_MINOR|BLOCK [--remediation-tasks JSON] [--minors JSON]
#       --remediation-tasks: the lead's full-shape tasks for failed criteria or blocking
#         findings; when absent on a failure, one task per exit FLAG or one per verdict is
#         synthesized with the project test command.
#       --minors: a JSON array of "file:line - claim" strings for the backlog.
#       Both arrays accept @path (a file holding the JSON; for --minors, one finding
#       per line is enough) so shell quoting never decides whether a gate call parses.
#
# Output (one JSON object):
#   {exit:{ok,flags[]}, route:"redo"|"pass"|"remediate", class:null|"acceptance"|"suite-regression"|"code-review",
#    tasks:[...], minorsQueued:N, repeat:bool}
#   redo: lib/phase-exit.sh verify FLAGged VERIFICATION.md (format or evidence rows); fix
#   the file and call again. Nothing is recorded for a redo.
#
# On remediate: tasks are appended to pendingRemediationTasks[], the gate (acceptance or
# code-review) records a fail entry through lib/graph/gate.sh, a verify_failure event is
# emitted, a repeated failure of the same finding records a rule, and the team fields are
# cleared. On pass: the acceptance gate records a pass entry.
#
# Exit: 0 pass; 1 redo or remediate (the route says which); 2 bad invocation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib() { bash "$SCRIPT_DIR/$1.sh" "${@:2}"; }
usage() { sed -n '2,30p' "$0" | grep -E '^#( |$)' | sed 's/^# \{0,1\}//' >&2; exit 2; }

[[ "${1:-}" == "run" ]] || usage
shift
feature_dir="" verifier="" suite="N/A" reviewer="" tasks='[]' minors='[]'
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}" ;; --verifier) verifier="${2:-}" ;; --suite) suite="${2:-}" ;;
    --reviewer) reviewer="${2:-}" ;; --remediation-tasks) tasks="${2:-[]}" ;; --minors) minors="${2:-[]}" ;; *) usage ;;
  esac
  shift 2
done
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] || usage
case "$verifier" in ALL_PASS|FAIL) ;; *) usage ;; esac
case "$suite" in PASS|FAIL|N/A) ;; *) usage ;; esac
case "$reviewer" in PASS|PASS_WITH_MINOR|BLOCK) ;; *) usage ;; esac
# `@path` reads the array from a file: a live lead's inline --minors carried a `\.github`
# path whose backslash is not a JSON escape, and the call died on quoting, not substance.
[[ "$tasks" == @* ]] && { tasks="$(cat "${tasks#@}" 2>/dev/null)" || { echo "verify-gate: cannot read ${tasks#@}" >&2; exit 2; }; }
if [[ "$minors" == @* ]]; then
  minors="$(cat "${minors#@}" 2>/dev/null)" || { echo "verify-gate: cannot read ${minors#@}" >&2; exit 2; }
  # A file of one finding per line needs no JSON at all (the live failure was `\.`, an
  # escape JSON does not have, inside an inline array).
  jq -e 'type == "array"' <<<"$minors" >/dev/null 2>&1 || minors="$(jq -R . <<<"$minors" | jq -cs 'map(select(. != ""))')"
fi
jq -e 'type == "array"' <<<"$tasks" >/dev/null 2>&1 || { echo "verify-gate: --remediation-tasks must be a JSON array (write it to a file and pass @path when quoting bites)" >&2; exit 2; }
jq -e 'type == "array"' <<<"$minors" >/dev/null 2>&1 || { echo "verify-gate: --minors must be a JSON array (write it to a file and pass @path when quoting bites)" >&2; exit 2; }
feature_dir="$(cd "$feature_dir" && pwd -P)"
fj="$feature_dir/feature.json"
fget() { bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" -r --filter "$1"; }
slug="$(fget '.slug')"
default_verify="$(fget '.commands.test // ""')"

exit_rc=0; exit_out="$(lib phase-exit verify --feature-dir "$feature_dir" 2>&1)" || exit_rc=$?
flags="$(grep '^FLAG' <<<"$exit_out" | jq -R . | jq -cs .)"
exit_ok=true; (( exit_rc == 0 )) || exit_ok=false

# An exit FLAG is VERIFICATION.md drifting from its format or its evidence rows: the lead
# fixes the file and calls again. It is not a verdict, so it records nothing; the 6.2.0
# smoke run logged fifteen acceptance fails and re-ran both reviewers fifteen times
# because a formatting flag was read as a verifier FAIL.
if [[ "$exit_ok" == false ]]; then
  jq -cn --argjson flags "$flags" '{exit:{ok:false, flags:$flags}, route:"redo", class:null, tasks:[], minorsQueued:0, repeat:false}'
  exit 1
fi
route=pass; class=null
if [[ "$verifier" == "FAIL" ]]; then route=remediate; class=acceptance
elif [[ "$suite" == "FAIL" ]]; then route=remediate; class=suite-regression
elif [[ "$reviewer" == "BLOCK" ]]; then route=remediate; class=code-review
fi

if [[ "$route" == "remediate" && "$(jq 'length' <<<"$tasks")" == "0" ]]; then
  # No tasks from the lead: one for the verdict itself.
  tasks="$(jq -cn --arg c "$class" --arg v "$default_verify" '[{id:("task-verify-" + $c + "-1"), subject:("Fix the " + $c + " failure VERIFY reported"), files:[], verifyCommand:$v, acceptanceCriteria:[("VERIFY " + $c + " gate passes")], blockedBy:[], retries:0}]')"
fi
tasks="$(jq -c --arg v "$default_verify" 'map(.verifyCommand = (if (.verifyCommand // "") == "" then $v else .verifyCommand end) | .blockedBy = (.blockedBy // []) | .files = (.files // []) | .retries = (.retries // 0) | .acceptanceCriteria = (if (.acceptanceCriteria // []) == [] then [.subject] else .acceptanceCriteria end))' <<<"$tasks")"

minors_queued=0
while IFS= read -r m; do
  [[ -n "$m" ]] || continue
  lib backlog add "$slug" verify-deferred "$m" >/dev/null 2>&1 && minors_queued=$((minors_queued + 1))
done < <(jq -r '.[]' <<<"$minors")

repeat=false
if [[ "$route" == "remediate" ]]; then
  gate="acceptance"; [[ "$class" == "code-review" ]] && gate="code-review"
  findings="$(jq -c 'map(.subject)' <<<"$tasks")"
  # A finding the same gate already failed on is a lesson worth a rule, recorded once.
  if bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" -e --filter '[.gateHistory[]? | select(.phase == "verify" and .gate == $g and .result == "fail") | .findingsAddressed[]?] as $prior | ($f | map(select(. as $x | $prior | index($x) != null)) | length) > 0' -- --arg g "$gate" --argjson f "$findings" >/dev/null 2>&1; then
    repeat=true
    lib rules add "VERIFY repeat-fail on '$(jq -r '.[0]' <<<"$findings")' ($slug): the first remediation did not hold" --check "$default_verify" >/dev/null 2>&1 || true
  fi
  while IFS= read -r t; do [[ -n "$t" ]] && lib feature-write append "$feature_dir" pendingRemediationTasks "$t" >/dev/null; done < <(jq -c '.[]' <<<"$tasks")
  lib graph/gate open --feature-dir "$feature_dir" --phase verify --gate "$gate" >/dev/null 2>&1 || true
  lib graph/gate fail --feature-dir "$feature_dir" --rounds 1 --convergence verdict --challenger-model none --findings "$findings" >/dev/null 2>&1 || true
  lib events emit "$feature_dir" verify_failure --phase verify --data "$(jq -cn --arg c "$class" --argjson n "$(jq 'length' <<<"$tasks")" '{class:$c, tasks:$n}')" >/dev/null 2>&1 || true
  lib feature-write set "$feature_dir" currentTeamName null >/dev/null; lib feature-write set "$feature_dir" currentTeammates '[]' >/dev/null
else
  lib graph/gate open --feature-dir "$feature_dir" --phase verify --gate acceptance >/dev/null 2>&1 || true
  lib graph/gate pass --feature-dir "$feature_dir" --rounds 1 --convergence verdict --challenger-model none >/dev/null 2>&1 || true
fi

jq -cn --argjson ok "$exit_ok" --argjson flags "$flags" --arg route "$route" \
  --argjson class "$( [[ "$class" == null ]] && echo null || jq -Rn --arg c "$class" '$c' )" \
  --argjson tasks "$( [[ "$route" == remediate ]] && printf '%s' "$tasks" || echo '[]' )" --argjson mq "$minors_queued" --argjson repeat "$repeat" \
  '{exit:{ok:$ok, flags:$flags}, route:$route, class:$class, tasks:$tasks, minorsQueued:$mq, repeat:$repeat}'
[[ "$route" == "pass" ]] && exit 0 || exit 1
