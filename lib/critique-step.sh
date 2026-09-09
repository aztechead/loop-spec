#!/usr/bin/env bash
# critique-step.sh - One critique-gate step per call: open, findings, fail, revised, delta, pass.
#
# Why: skills/shared/critique-gate-protocol.md asked the lead to write each reply into a
# gate-log by hand, count the round, emit the event, append the fail entry, ask the
# probe, snapshot the artifact, diff it, paste the diff into the delta brief, and run
# the delta lint, each as its own tool call with the whole reply in the lead's
# context twice. A PLAN critique on Opus spent an hour and fifty dollars that way.
# Every one of those steps is deterministic. The lead keeps adjudication (which
# findings become the fix-list), the messages to the teammates, and the probes.
#
# Usage:
#   critique-step.sh open     --feature-dir DIR --phase P --gate G --artifact PATH
#       lib/graph/gate.sh open, the gate-logs dir, and the artifact path the later
#       steps read. Prints {gate, phase, artifact, logDir}.
#   critique-step.sh findings --feature-dir DIR --reply <path|->
#       Round 1: writes gate-logs/<gate>-round-1.md, counts the round, emits gate_round.
#       Prints {round, verdict: "findings"|"no-findings", lines: [...]} where lines are
#       the reply's non-empty lines after the FINDINGS:/NO-FINDINGS: header.
#   critique-step.sh fail     --feature-dir DIR --fix-list <path|->
#       One fix-list item per line, verbatim (the deadlock rule matches on identity).
#       Appends the fail entry, asks the probe. rerun: snapshots the artifact to
#       gate-logs/<name>.pre-revision.md and prints {answer: "rerun", reason, fixList}
#       with fixList numbered for the author. close: writes gate-logs/<gate>-residue.md,
#       appends the cap-reached pass entry, and prints {answer: "close", reason, residue}.
#   critique-step.sh revised  --feature-dir DIR
#       After the author's revision: diffs the snapshot against the artifact into
#       gate-logs/<gate>-delta.diff. Prints {diffPath, changed, diff, fixList}.
#   critique-step.sh delta    --feature-dir DIR --reply <path|-> [--flags <path>]
#       Round N: writes the delta gate-log, counts the round, emits gate_round, runs
#       lib/delta-findings-lint.sh over the reply (DROP lines land in the gate-log),
#       and adds every non-empty line of --flags (a re-run mechanical gate's FLAG lines)
#       to the survivors. Nothing survives: appends the delta-verified pass entry.
#       Prints {round, verified, survivors: [...]}.
#   critique-step.sh pass     --feature-dir DIR [--convergence C]
#       The fix-list-empty close after round 1 (default convergence single-critic).
#
# Exit: 0 the step answered; 1 no open gate, an unreadable input, or a failed write
# (message on stderr); 2 bad invocation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib() { bash "$SCRIPT_DIR/$1.sh" "${@:2}"; }
gate() { bash "$SCRIPT_DIR/graph/gate.sh" "$@"; }
usage() { sed -n '2,40p' "$0" | grep -E '^#( |$)' | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "critique-step: $*" >&2; exit 1; }

cmd="${1:-}"; shift || true
feature_dir="" phase="" gate_name="" artifact="" reply="" fix_list="" flags="" convergence="single-critic"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}" ;; --phase) phase="${2:-}" ;; --gate) gate_name="${2:-}" ;;
    --artifact) artifact="${2:-}" ;; --reply) reply="${2:-}" ;; --fix-list) fix_list="${2:-}" ;;
    --flags) flags="${2:-}" ;; --convergence) convergence="${2:-}" ;;
    *) usage ;;
  esac
  shift 2 || usage
done
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] || usage
fj="$feature_dir/feature.json"
logs="$feature_dir/gate-logs"
fget() { jq -r "$1" "$fj"; }

# `-` means stdin; slurp it so every reader below sees a real file.
slurp() {
  local src="$1"
  if [[ "$src" == "-" ]]; then stdin_tmp="$(mktemp "${TMPDIR:-/tmp}/critique-step.XXXXXX")"; cat > "$stdin_tmp"; echo "$stdin_tmp"
  else [[ -r "$src" ]] || die "cannot read $src"; echo "$src"; fi
}
stdin_tmp=""
trap '[[ -n "$stdin_tmp" ]] && rm -f "$stdin_tmp"' EXIT

# The open gate and the artifact it guards; every step after open reads both here.
load_state() {
  phase="$(fget '.currentGate.phase // empty')"; gate_name="$(fget '.currentGate.gate // empty')"
  [[ -n "$phase" && -n "$gate_name" ]] || die "no gate is open; run 'critique-step.sh open' first"
  state="$logs/$gate_name-state.json"
  [[ -f "$state" ]] || die "$state missing: the gate was opened without critique-step.sh open"
  artifact="$(jq -r '.artifact' "$state")"
  [[ -f "$artifact" ]] || die "artifact $artifact missing"
  snapshot="$logs/$(basename "$artifact" .md).pre-revision.md"
  delta_diff="$logs/$gate_name-delta.diff"
  round="$(fget '.currentGate.round // 0')"
  model="$(fget '.models.challenger // "inherit"')"
}

emit_round() {
  lib events emit "$feature_dir" gate_round --phase "$phase" \
    --data "$(jq -cn --arg g "$gate_name" --argjson r "$1" --arg m "$2" '{gate:$g, round:$r, mode:$m}')" >/dev/null 2>&1 || true
}

# Lines after the reply's header, non-empty, list numbering kept for the gate-log.
reply_lines() { sed -n '2,$p' "$1" | sed '/^[[:space:]]*$/d'; }

case "$cmd" in
  open)
    [[ -n "$phase" && -n "$gate_name" && -n "$artifact" ]] || usage
    [[ -f "$artifact" ]] || die "artifact $artifact missing"
    artifact="$(cd "$(dirname "$artifact")" && pwd -P)/$(basename "$artifact")"
    gate open --feature-dir "$feature_dir" --phase "$phase" --gate "$gate_name" --challenger challenger-1 || exit 1
    mkdir -p "$logs"
    jq -n --arg a "$artifact" '{artifact:$a}' > "$logs/$gate_name-state.json"
    jq -n --arg g "$gate_name" --arg p "$phase" --arg a "$artifact" --arg l "$logs" \
      '{gate:$g, phase:$p, artifact:$a, logDir:$l}'
    ;;
  findings)
    load_state; [[ -n "$reply" ]] || usage; src="$(slurp "$reply")"
    verdict=findings
    grep -qiE '^[[:space:]]*NO-FINDINGS:' "$src" && verdict=no-findings
    { printf '# %s Round 1 (single-critic)\n\n## challenger-1\n' "$gate_name"; cat "$src"; } > "$logs/$gate_name-round-1.md"
    n="$(gate round --feature-dir "$feature_dir")" || exit 1
    emit_round "$n" single-critic
    jq -n --argjson r "$n" --arg v "$verdict" --rawfile body "$src" \
      '{round:$r, verdict:$v, lines: ($body | split("\n") | .[1:] | map(select(test("^[[:space:]]*$") | not)))}'
    ;;
  fail)
    load_state; [[ -n "$fix_list" ]] || usage; src="$(slurp "$fix_list")"
    items="$(sed '/^[[:space:]]*$/d' "$src" | jq -R . | jq -cs .)"
    [[ "$(jq 'length' <<<"$items")" != "0" ]] || die "the fix-list is empty; call 'pass' instead"
    conv=single-critic; (( round > 1 )) && conv=delta-verified
    gate fail --feature-dir "$feature_dir" --rounds "$round" --convergence "$conv" \
      --challenger-model "$model" --findings "$items" >/dev/null || exit 1
    answer="$(gate next --feature-dir "$feature_dir")" || exit 1
    reason="${answer#*REASON=}"
    if [[ "$answer" == ANSWER=rerun* ]]; then
      cp "$artifact" "$snapshot"
      jq -n --arg r "$reason" --argjson items "$items" \
        '{answer:"rerun", reason:$r, fixList: ([$items | to_entries[] | "\(.key + 1). \(.value)"] | join("\n"))}'
    else
      residue="$logs/$gate_name-residue.md"
      { printf '# %s residue (%s)\n\n' "$gate_name" "$reason"; jq -r '.[] | "- " + .' <<<"$items"; } > "$residue"
      gate pass --feature-dir "$feature_dir" --rounds "$round" --convergence cap-reached \
        --challenger-model "$model" --notes "$(jq -r 'join("; ")' <<<"$items")" >/dev/null || exit 1
      jq -n --arg r "$reason" --arg p "$residue" '{answer:"close", reason:$r, residue:$p}'
    fi
    ;;
  revised)
    load_state
    [[ -f "$snapshot" ]] || die "$snapshot missing: 'fail' answered close, or was never called"
    diff -u "$snapshot" "$artifact" > "$delta_diff"; changed=$(( $? == 1 ))
    fixlist="$(jq -r --arg p "$phase" --arg g "$gate_name" '
      [.gateHistory[]? | select(.phase == $p and .gate == $g and .result == "fail")] | last
      | (.findingsAddressed // []) | to_entries[] | "\(.key + 1). \(.value)"' "$fj")"
    jq -n --arg d "$delta_diff" --argjson c "$changed" --rawfile diff "$delta_diff" --arg f "$fixlist" \
      '{diffPath:$d, changed:($c == 1), diff:$diff, fixList:$f}'
    ;;
  delta)
    load_state; [[ -n "$reply" ]] || usage; src="$(slurp "$reply")"
    [[ -f "$delta_diff" ]] || die "$delta_diff missing: run 'revised' before the delta brief goes out"
    n="$(gate round --feature-dir "$feature_dir")" || exit 1
    log="$logs/$gate_name-round-$n.md"
    { printf '# %s Round %s (delta re-verify)\n\n## challenger-1\n' "$gate_name" "$n"; cat "$src"; } > "$log"
    lint_err="$(mktemp "${TMPDIR:-/tmp}/critique-step-lint.XXXXXX")"
    survivors="$(lib delta-findings-lint filter --diff "$delta_diff" "$src" 2>"$lint_err")" || { cat "$lint_err" >&2; rm -f "$lint_err"; exit 1; }
    { printf '\n## delta-findings-lint\n'; cat "$lint_err"; } >> "$log"; rm -f "$lint_err"
    if [[ -n "$flags" ]]; then
      [[ -r "$flags" ]] || die "cannot read $flags"
      survivors="$(printf '%s\n%s\n' "$survivors" "$(sed '/^[[:space:]]*$/d' "$flags")")"
    fi
    items="$(sed '/^[[:space:]]*$/d' <<<"$survivors" | jq -R . | jq -cs .)"
    emit_round "$n" delta
    if [[ "$(jq 'length' <<<"$items")" == "0" ]]; then
      gate pass --feature-dir "$feature_dir" --rounds "$n" --convergence delta-verified \
        --challenger-model "$model" >/dev/null || exit 1
    fi
    jq -n --argjson r "$n" --argjson s "$items" '{round:$r, verified:($s | length == 0), survivors:$s}'
    ;;
  pass)
    load_state
    gate pass --feature-dir "$feature_dir" --rounds "$round" --convergence "$convergence" \
      --challenger-model "$model" >/dev/null || exit 1
    jq -n --argjson r "$round" --arg c "$convergence" '{passed:true, rounds:$r, convergence:$c}'
    ;;
  *) usage ;;
esac
