#!/usr/bin/env bash
# critique-step.sh - One critique-gate step per call: open, findings, fail, revised, delta, pass, resume.
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
#       steps read. Prints {gate, phase, artifact, logDir, model}: model is the Agent
#       alias to pass on the challenger call, null when the role inherits (a lead that
#       decided this itself omitted the key and lost the sonnet default).
#   critique-step.sh findings --feature-dir DIR --reply <path|->
#       Round 1: snapshots the artifact the challenger read to
#       gate-logs/<name>.pre-revision.md (so the author may edit before or after
#       `fail`), writes gate-logs/<gate>-round-1.md, counts the round, emits gate_round.
#       Prints {round, verdict: "findings"|"no-findings", lines: [...]} where lines are
#       the reply's non-empty lines after the FINDINGS:/NO-FINDINGS: header.
#   critique-step.sh fail     --feature-dir DIR --fix-list <path|->
#       One fix-list item per line, verbatim (the deadlock rule matches on identity).
#       Every item tagged [minor] at its start: appends the minors-applied pass entry,
#       closes the gate, and prints {answer: "apply", reason, fixList} for the lead to
#       edit in directly. Otherwise appends the fail entry and asks the probe. rerun:
#       prints {answer: "rerun", reason, fixList} with fixList numbered for the author.
#       close: writes gate-logs/<gate>-residue.md, appends the cap-reached pass entry,
#       adds each item to feature.json warnings (the PR body's "Shipped with warnings"),
#       and prints {answer: "close", reason, residue}.
#   critique-step.sh revised  --feature-dir DIR
#       After the author's revision: diffs the snapshot against the artifact into
#       gate-logs/<gate>-delta.diff. Prints {diffPath, changed, lines, fixList}; the diff
#       stays in the file for the challenger to Read, never in the lead's context. Mints
#       a fresh nonce into the delta packet; a reply to an older packet no longer passes.
#   critique-step.sh delta    --feature-dir DIR --reply <path|-> [--flags <path>]
#       Refuses a reply whose first line is not the packet's `NONCE: <token>` or that
#       has no DELTA-VERIFIED:/DELTA-FINDINGS: line, and a round past the ceiling.
#       Round N: writes the delta gate-log, counts the round, emits gate_round, runs
#       lib/delta-findings-lint.sh over the reply (DROP lines land in the gate-log),
#       and adds every non-empty line of --flags (a re-run mechanical gate's FLAG lines)
#       to the survivors. Nothing survives: appends the delta-verified pass entry.
#       Prints {round, verified, survivors: [...]}.
#   critique-step.sh pass     --feature-dir DIR [--convergence C]
#       The fix-list-empty close after round 1 (default convergence single-critic).
#   critique-step.sh resume   --feature-dir DIR
#       Reuse or regenerate the current gate's persisted dispatch packet without
#       opening or incrementing the gate. Prints {gate, round, kind, promptFile, model}.
#
# Exit: 0 the step answered; 1 no open gate, an unreadable input, or a failed write
# (message on stderr); 2 bad invocation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib() { bash "$SCRIPT_DIR/$1.sh" "${@:2}"; }
gate() { bash "$SCRIPT_DIR/graph/gate.sh" "$@"; }
usage() { sed -n '2,40p' "$0" | grep -E '^#( |$)' | sed 's/^# \{0,1\}//' >&2 || true; exit 2; }
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
[[ -n "$feature_dir" ]] || usage
feature_dir="$(cd "$feature_dir" 2>/dev/null && pwd -P)" || usage
[[ -f "$feature_dir/feature.json" ]] || usage
fj="$feature_dir/feature.json"
logs="$feature_dir/gate-logs"
fget() { bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" -r --filter "$1"; }

# `-` means stdin; slurp it so every reader below sees a real file.
slurp() {
  local src="$1"
  if [[ "$src" == "-" ]]; then stdin_tmp="$(mktemp "${TMPDIR:-/tmp}/critique-step.XXXXXX")"; cat > "$stdin_tmp"; echo "$stdin_tmp"
  else [[ -r "$src" ]] || die "cannot read $src"; echo "$src"; fi
}
stdin_tmp=""
packet_tmp=""
structure_tasks=""
reply_body=""
trap '[[ -z "$reply_body" ]] || rm -f "$reply_body"; [[ -z "$structure_tasks" ]] || rm -f "$structure_tasks"; [[ -n "$stdin_tmp" ]] && rm -f "$stdin_tmp"; [[ -n "$packet_tmp" ]] && rm -f "$packet_tmp"' EXIT

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
  prompt_file="$(jq -r '.promptFile // empty' "$state")"
}

critic_template_for_phase() {
  local snapshot_root="$feature_dir/instruction-snapshots" candidate manifest recorded has_instructions
  next_phase="$(fget '.driverNext.phase // empty')"
  recorded=""
  [[ "$next_phase" == "$phase" ]] && recorded="$(fget '.driverNext.instructions.manifest // empty')"
  has_instructions="$(fget 'if .driverNext.instructions != null then "yes" else "no" end')"
  if [[ -n "$recorded" && "$recorded" != null ]]; then
    [[ -d "$snapshot_root" ]] || die "immutable instruction snapshot missing: $snapshot_root"
    manifest="$snapshot_root/$(basename "$(dirname "$recorded")")/manifest.json"
    candidate="$(dirname "$manifest")/skills/shared/team-prompts/critic.md"
    [[ -r "$manifest" ]] || die "immutable critic manifest missing: $manifest"
    record_json="$(fget '.driverNext.instructions')"
    python3 "$SCRIPT_DIR/critique_prompt.py" --verify-manifest "$manifest" --record-json "$record_json" --feature-dir "$feature_dir" \
      || die "immutable critic snapshot verification failed: $manifest"
  else
    [[ "$has_instructions" == no ]] || die "driverNext instructions do not match active phase '$phase'"
    candidate="$SCRIPT_DIR/../skills/shared/team-prompts/critic.md"
  fi
  [[ -r "$candidate" ]] || die "immutable critic contract missing for phase '$phase' in $snapshot_root"
  printf '%s' "$candidate"
}
prompt_packet() {
  local kind="$1" destination="$2" slug template transport root spec_path evidence_path
  template="$(critic_template_for_phase)"
  slug="$(fget '.slug // empty')"
  [[ -n "$slug" ]] || slug="$(basename "$feature_dir")"
  root="$(fget '.workspace.root // empty')"
  [[ -n "$root" && "$root" != null ]] || root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$root" ]] || root="$(cd "$feature_dir/../../.." 2>/dev/null && pwd -P || true)"
  [[ -n "$root" ]] || die "cannot resolve feature checkout root for critique paths: $feature_dir"
  spec_path="$(fget '.artifacts.spec // empty')"
  evidence_path="$(fget '.artifacts.evidence // empty')"
  [[ -n "$spec_path" && "$spec_path" != null ]] || spec_path="docs/loop-spec/features/$slug/SPEC.md"
  [[ -n "$evidence_path" && "$evidence_path" != null ]] || evidence_path="docs/loop-spec/features/$slug/EVIDENCE.md"
  [[ "$spec_path" = /* ]] || spec_path="$root/$spec_path"
  [[ "$evidence_path" = /* ]] || evidence_path="$root/$evidence_path"
  transport="the caller's active harness transport (team messages in teams mode; the Agent result channel in one-shot mode)"
  if [[ "$kind" == delta ]]; then
    python3 "$SCRIPT_DIR/critique_prompt.py" --template "$template" --kind "$kind" \
      --slug "$slug" --phase "$phase" --artifact "$artifact" --spec "$spec_path" --evidence "$evidence_path" --diff "$delta_diff" \
      --fix-list "$fixlist" --transport "$transport" --output "$destination" \
      || die "could not render immutable critique packet: $destination"
    # `delta` accepted any text as the reply, and a 6.9.1 lead submitted its own; only the
    # challenger that read this packet can echo the token.
    local nonce
    nonce="$(jq -r '.nonce // empty' "$state")"
    if [[ -z "$nonce" ]]; then
      nonce="$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
      jq --arg n "$nonce" '.nonce=$n' "$state" > "$state.tmp" && mv "$state.tmp" "$state" || die "cannot record the delta nonce in $state"
    fi
    printf '\nBegin your reply with this exact line, before the DELTA-VERIFIED: or DELTA-FINDINGS: report:\n\nNONCE: %s\n' "$nonce" >> "$destination"
  else
    python3 "$SCRIPT_DIR/critique_prompt.py" --template "$template" --kind "$kind" \
      --slug "$slug" --phase "$phase" --artifact "$artifact" --spec "$spec_path" --evidence "$evidence_path" \
      --fix-list "" --transport "$transport" --output "$destination" \
      || die "could not render immutable critique packet: $destination"
  fi
}

emit_round() {
  lib events emit "$feature_dir" gate_round --phase "$phase" \
    --data "$(jq -cn --arg g "$gate_name" --argjson r "$1" --arg m "$2" '{gate:$g, round:$r, mode:$m}')" >/dev/null 2>&1 || true
}

# Lines after the reply's header, non-empty, list numbering kept for the gate-log.
reply_lines() { sed -n '2,$p' "$1" | sed '/^[[:space:]]*$/d'; }

check_plan_structure() {
  # Check the authored artifact, not a possibly stale tasks.json. Failure leaves
  # gate state and review packets untouched so ownership is repaired before review.
  if [[ "$phase" == plan ]]; then
    structure_tasks="$(mktemp "${TMPDIR:-/tmp}/plan-critique-tasks.XXXXXX")"
    lib plan-tasks extract "$artifact" > "$structure_tasks" \
      || die "PLAN extraction failed; repair the task blocks before critique"
    lib plan-conflicts edges "$structure_tasks" >/dev/null \
      || die "PLAN inferred dependencies are invalid; repair them before critique"
    lib plan-structure "$feature_dir" "$structure_tasks" >&2 \
      || die "PLAN structure failed; repair ownership/dependencies in PLAN.md, re-extract, and retry"
    rm -f "$structure_tasks"; structure_tasks=""
  fi
}

case "$cmd" in
  open)
    [[ -n "$phase" && -n "$gate_name" && -n "$artifact" ]] || usage
    [[ -f "$artifact" ]] || die "artifact $artifact missing"
    artifact="$(cd "$(dirname "$artifact")" && pwd -P)/$(basename "$artifact")"
    check_plan_structure
    mkdir -p "$logs"
    prompt_file="$logs/$gate_name-round-1-prompt.md"
    packet_tmp="$(mktemp "$logs/.critique-packet.XXXXXX")"
    prompt_packet findings "$packet_tmp"
    gate open --feature-dir "$feature_dir" --phase "$phase" --gate "$gate_name" --challenger challenger-1 || exit 1
    mv "$packet_tmp" "$prompt_file"
    packet_tmp=""
    jq -n --arg a "$artifact" --arg p "$prompt_file" '{artifact:$a, promptFile:$p, kind:"findings"}' > "$logs/$gate_name-state.json"
    model="$(fget '.models.challenger // "inherit"')"
    jq -n --arg g "$gate_name" --arg p "$phase" --arg a "$artifact" --arg l "$logs" --arg m "$model" --arg pf "$prompt_file" \
      '{gate:$g, phase:$p, artifact:$a, logDir:$l, promptFile:$pf, model:(if $m == "inherit" or $m == "" then null else $m end)}'
    ;;
  findings)
    load_state; [[ -n "$reply" ]] || usage; src="$(slurp "$reply")"
    verdict=findings
    grep -qiE '^[[:space:]]*NO-FINDINGS:' "$src" && verdict=no-findings
    cp "$artifact" "$snapshot"
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
    # Every item [minor] means polish the lead applies itself: the protocol already had
    # the lead apply accepted minors as direct edits at close. A 6.6.5 live PLAN critique
    # spent an author re-dispatch, a tasks.json re-extract, and a challenger delta round
    # on a fix-list of minors alone, and the cycle never reached EXECUTE.
    if jq -e 'all(test("^[[:space:]]*\\[minor\\]"; "i"))' <<<"$items" >/dev/null; then
      gate pass --feature-dir "$feature_dir" --rounds "$round" --convergence minors-applied \
        --challenger-model "$model" --notes "$(jq -r 'join("; ")' <<<"$items")" >/dev/null || exit 1
      jq -n --argjson items "$items" \
        '{answer:"apply", reason:"every fix-list item is [minor]: apply them as lead edits, no re-verify",
          fixList: ([$items | to_entries[] | "\(.key + 1). \(.value)"] | join("\n"))}'
      exit 0
    fi
    conv=single-critic; (( round > 1 )) && conv=delta-verified
    gate fail --feature-dir "$feature_dir" --rounds "$round" --convergence "$conv" \
      --challenger-model "$model" --findings "$items" >/dev/null || exit 1
    answer="$(gate next --feature-dir "$feature_dir")" || exit 1
    reason="${answer#*REASON=}"
    if [[ "$answer" == ANSWER=rerun* ]]; then
      [[ -f "$snapshot" ]] || cp "$artifact" "$snapshot"
      jq -n --arg r "$reason" --argjson items "$items" \
        '{answer:"rerun", reason:$r, fixList: ([$items | to_entries[] | "\(.key + 1). \(.value)"] | join("\n"))}'
    else
      residue="$logs/$gate_name-residue.md"
      { printf '# %s residue (%s)\n\n' "$gate_name" "$reason"; jq -r '.[] | "- " + .' <<<"$items"; } > "$residue"
      gate pass --feature-dir "$feature_dir" --rounds "$round" --convergence cap-reached \
        --challenger-model "$model" --notes "$(jq -r 'join("; ")' <<<"$items")" >/dev/null || exit 1
      # A ceiling close used to be silent: a 22-task PLAN critique closed with 8 new
      # majors still open and nothing said so at the phase boundary. Name the count
      # and the residue path so an operator sees what shipped unresolved.
      echo "NOTE [critique] $(jq 'length' <<<"$items") finding(s) unresolved at the ceiling: $residue" >&2
      # The residue file was write-only, so "already fixed in the artifact" went unchecked
      # to the PR (6.9.1 upstream report); a warning puts each item in front of the reviewer.
      while IFS= read -r w; do lib feature-write append "$feature_dir" warnings "$w" >/dev/null || exit 1
      done < <(jq -c --arg p "$phase $gate_name" '.[] | "critique-ceiling (\($p)): unresolved: \(.)"' <<<"$items")
      jq -n --arg r "$reason" --arg p "$residue" '{answer:"close", reason:$r, residue:$p}'
    fi
    ;;
  revised)
    load_state
    check_plan_structure
    [[ -f "$snapshot" ]] || die "$snapshot missing: 'findings' was never called, or 'fail' answered close"
    # diff exits 1 on the ordinary case (the revision changed the artifact); capture that.
    diff -u "$snapshot" "$artifact" > "$delta_diff" || diff_rc=$?
    changed=$(( ${diff_rc:-0} == 1 ))
    fixlist="$(bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" -r --filter '
      [.gateHistory[]? | select(.phase == $p and .gate == $g and .result == "fail")] | last
      | (.findingsAddressed // []) | to_entries[] | "\(.key + 1). \(.value)"' -- --arg p "$phase" --arg g "$gate_name")"
    prompt_file="$logs/$gate_name-round-$((round + 1))-prompt.md"
    jq '.nonce=null' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
    prompt_packet delta "$prompt_file"
    jq --arg p "$prompt_file" '.promptFile=$p | .kind="delta"' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
    jq -n --arg d "$delta_diff" --argjson c "$changed" --argjson n "$(wc -l < "$delta_diff")" --arg f "$fixlist" --arg p "$prompt_file" \
      '{diffPath:$d, changed:($c == 1), lines:$n, fixList:$f, promptFile:$p}'
    ;;
  delta)
    load_state; [[ -n "$reply" ]] || usage; src="$(slurp "$reply")"
    [[ -f "$delta_diff" ]] || die "$delta_diff missing: run 'revised' before the delta brief goes out"
    nonce="$(jq -r '.nonce // empty' "$state")"
    [[ -n "$nonce" ]] || die "no delta packet is outstanding; run 'revised' and dispatch the challenger on its packet"
    [[ "$(sed '/^[[:space:]]*$/d' "$src" | head -1)" == "NONCE: $nonce" ]] \
      || die "the reply does not start with the packet's 'NONCE: <token>' line; pass the challenger's reply verbatim, never the lead's own text"
    grep -qE '^[[:space:]]*(DELTA-VERIFIED|DELTA-FINDINGS):' "$src" \
      || die "the reply has no DELTA-VERIFIED: or DELTA-FINDINGS: line; pass the challenger's report verbatim"
    # The budget was enforced only in `fail`, so a revised-delta loop that skipped it ran
    # three rounds on a ceiling of one (6.9.1 upstream report).
    answer="$(gate next --feature-dir "$feature_dir")" || exit 1
    [[ "$answer" != ANSWER=close* ]] || die "no delta round left (${answer#*REASON=}); call 'fail' with the open findings to close the gate"
    n="$(gate round --feature-dir "$feature_dir")" || exit 1
    jq '.nonce=null' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
    reply_body="$(mktemp "${TMPDIR:-/tmp}/critique-step-reply.XXXXXX")"
    grep -vFx "NONCE: $nonce" "$src" > "$reply_body" || true
    src="$reply_body"
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
  resume)
    load_state
    check_plan_structure
    stored_kind="$(jq -r '.kind // empty' "$state")"
    resume_kind="${stored_kind:-findings}"
    [[ "$resume_kind" == findings || "$resume_kind" == delta ]] || die "critique resume sidecar has invalid kind: $resume_kind"
    if [[ "$prompt_file" != /* && -n "$prompt_file" ]]; then
      prompt_file="$logs/$(basename "$prompt_file")"
    fi
    if [[ "$resume_kind" == delta ]]; then
      delta_diff="$logs/$gate_name-delta.diff"
      [[ -r "$delta_diff" ]] || die "critique resume diff missing: $delta_diff"
    fi
    if [[ -z "$prompt_file" ]]; then
      if [[ "$resume_kind" == delta ]]; then
        prompt_file="$logs/$gate_name-round-$((round + 1))-prompt.md"
      else
        prompt_file="$logs/$gate_name-round-1-prompt.md"
      fi
    fi
    packet_tmp="$(mktemp "$logs/.critique-resume.XXXXXX")"
    if [[ "$resume_kind" == delta ]]; then
      fixlist="$(bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" -r --filter '
        [.gateHistory[]? | select(.phase == $p and .gate == $g and .result == "fail")] | last
        | (.findingsAddressed // []) | to_entries[] | "\(.key + 1). \(.value)"' -- --arg p "$phase" --arg g "$gate_name")"
      prompt_packet delta "$packet_tmp"
    else
      prompt_packet findings "$packet_tmp"
      if [[ "$round" -gt 0 ]]; then
        printf '\nResume context: prior reviewer reports (read these only; preserve first-pass independence from author explanations):\n' >> "$packet_tmp"
        for ((review_round=1; review_round<=round; review_round++)); do
          review_log="$logs/$gate_name-round-$review_round.md"
          [[ -r "$review_log" ]] || die "critique resume reviewer log missing: $review_log"
          printf -- '- `%s`\n' "$review_log" >> "$packet_tmp"
        done
      fi
    fi
    mv "$packet_tmp" "$prompt_file"
    packet_tmp=""
    jq --arg p "$prompt_file" --arg k "$resume_kind" '.promptFile=$p | .kind=$k' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
    [[ -r "$prompt_file" ]] || die "critique resume packet missing: $prompt_file"
    jq -n --arg p "$prompt_file" --arg g "$gate_name" --argjson r "$round" --arg k "$resume_kind" --arg m "$model" \
      '{gate:$g, round:$r, kind:$k, promptFile:$p, model:(if $m == "inherit" or $m == "" then null else $m end)}'
    ;;
  *) usage ;;
esac
