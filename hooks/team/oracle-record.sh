#!/usr/bin/env bash
# PostToolUse / PostToolUseFailure hook (AskUserQuestion): record the supervisor's
# answers as `supervised` decisions, deterministically, from the tool payload.
#
# Why: on the supervised path (skills/shared/autonomous-mode.md) the record of what
# the supervisor answered used to be the model's to write, and the first live run
# under a named supervisor never asked, then wrote a rationale that satisfied the
# phase-exit gate. On Claude Code and the Agent SDK the question tool's own payload
# is the evidence: this hook writes the `supervised` decision (or `oracle-unavailable`
# when the call failed) with the write token lib/decisions.sh requires for those
# kinds, so a `supervised` entry means a question really reached the callback.
#
# Claude Code contract:
#   exit 0 always; this hook records, never blocks.
#
# Payload: tool_input.questions[] and tool_response.answers{question: label} on
# PostToolUse; tool_input.questions[] and error on PostToolUseFailure. The feature
# directory is .loop-spec/active-run.json's featureDir, else the one open feature
# under .loop-spec/features; the phase is that feature's currentPhase.
#
# Scope: only when lib/supervisor/oracle.sh answers `supervisor` for that feature.
# Fail-open: missing payload, no feature, or a write failure -> exit 0 with a trace.
# Kill switch: LOOP_SPEC_ORACLE_RECORD=0 -> exit 0.
set -euo pipefail

trap 'exit 0' ERR
[[ "${LOOP_SPEC_ORACLE_RECORD:-1}" != "0" ]] || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
[[ -d "$PROJECT_DIR/.loop-spec" || -d "$PWD/.loop-spec" ]] || exit 0
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

INPUT="$(cat 2>/dev/null)" || true
[[ -n "$INPUT" ]] || exit 0
[[ "$(jq -r '.tool_name // ""' <<<"$INPUT" 2>/dev/null)" == "AskUserQuestion" ]] || exit 0

# feature_dir ROOT: active-run.json's featureDir, else the one open feature.
feature_dir() {
  local root="$1" active="$1/.loop-spec/active-run.json" dir="" open=() d
  if [[ -f "$active" ]]; then
    dir="$(jq -r '.featureDir // empty' "$active" 2>/dev/null || true)"
    [[ -n "$dir" && -f "$dir/feature.json" ]] && { printf '%s' "$dir"; return 0; }
  fi
  for d in "$root"/.loop-spec/features/*/; do
    [[ -f "$d/feature.json" ]] || continue
    [[ "$(jq -r '.currentPhase // ""' "$d/feature.json" 2>/dev/null)" == "completed" ]] && continue
    open+=("${d%/}")
  done
  [[ ${#open[@]} -eq 1 ]] && printf '%s' "${open[0]}"
}
FEATURE_DIR="$(feature_dir "$PWD")"
[[ -n "$FEATURE_DIR" ]] || FEATURE_DIR="$(feature_dir "$PROJECT_DIR")"
[[ -n "$FEATURE_DIR" ]] || exit 0

mode="$(bash "$PLUGIN_ROOT/lib/supervisor/oracle.sh" mode --feature-dir "$FEATURE_DIR" 2>/dev/null || true)"
[[ "$mode" == oracle=supervisor* ]] || exit 0

phase="$(jq -r '.currentPhase // "cycle"' "$FEATURE_DIR/feature.json" 2>/dev/null || echo cycle)"
event="$(jq -r '.hook_event_name // "PostToolUse"' <<<"$INPUT")"

if [[ "$event" == "PostToolUseFailure" ]]; then
  err="$(jq -r '.error // .tool_response.error // "question tool failed"' <<<"$INPUT" 2>/dev/null | head -c 300)"
  while IFS= read -r q; do
    [[ -n "$q" ]] || continue
    LOOP_SPEC_ORACLE_WRITE=1 bash "$PLUGIN_ROOT/lib/decisions.sh" add "$FEATURE_DIR" "$phase" "$q" "(unanswered)" \
      "oracle unavailable: $err" oracle-unavailable >/dev/null 2>&1 || true
  done < <(jq -r '.tool_input.questions[]?.question // empty' <<<"$INPUT" 2>/dev/null)
  exit 0
fi

while IFS=$'\t' read -r q a; do
  [[ -n "$q" ]] || continue
  LOOP_SPEC_ORACLE_WRITE=1 bash "$PLUGIN_ROOT/lib/decisions.sh" add "$FEATURE_DIR" "$phase" "$q" "${a:-(no answer)}" \
    "supervisor answered through the question tool" supervised >/dev/null 2>&1 || true
done < <(jq -r '
  (.tool_response.answers // .tool_input.answers // {}) as $ans
  | .tool_input.questions[]? | [.question, (($ans[.question] // "") | if type == "array" then join(", ") else tostring end)] | @tsv
' <<<"$INPUT" 2>/dev/null)
exit 0
