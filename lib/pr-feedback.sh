#!/usr/bin/env bash
# pr-feedback.sh - Deterministic terminal PR feedback ownership and observation.
#
# Usage: pr-feedback.sh check <pr-number | --fixture file> [--repo owner/repo]
# Modes: LOOP_SPEC_PR_FEEDBACK_MODE=local (default) | external
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMENTS_BIN="${LOOP_SPEC_PR_COMMENTS_BIN:-$SCRIPT_DIR/pr-comments.sh}"
bash "$SCRIPT_DIR/runtime-preflight.sh" check-jq || exit 2

if [[ "${1:-}" == "record" ]]; then
  delivery_file="${2:-}"
  target_name="${3:-}"
  feedback_json="${4:-}"
  [[ -f "$delivery_file" && -n "$target_name" ]] || {
    echo "usage: pr-feedback.sh record <delivery.json> <target-name> <feedback-json>" >&2; exit 2; }
  jq -e 'type == "object" and has("observationStatus")' <<<"$feedback_json" >/dev/null 2>&1 || {
    echo "pr-feedback: invalid feedback JSON" >&2; exit 2; }
  jq -e --arg name "$target_name" '.targets | any(.name == $name)' "$delivery_file" >/dev/null 2>&1 || {
    echo "pr-feedback: target not found in delivery sidecar: $target_name" >&2; exit 2; }
  tmp="${delivery_file}.feedback.tmp.$$"
  jq --arg name "$target_name" --argjson feedback "$feedback_json" \
    '.targets |= map(if .name == $name then . + {feedback:$feedback} else . end)' \
    "$delivery_file" > "$tmp" || { rm -f "$tmp"; exit 2; }
  mv "$tmp" "$delivery_file" || { rm -f "$tmp"; exit 2; }
  exit 0
fi

[[ "${1:-}" == "check" ]] || { echo "usage: pr-feedback.sh check|record ..." >&2; exit 2; }
shift

mode="${LOOP_SPEC_PR_FEEDBACK_MODE:-local}"
case "$mode" in
  local|external) ;;
  *) echo "pr-feedback: LOOP_SPEC_PR_FEEDBACK_MODE must be local or external" >&2; exit 2 ;;
esac

if [[ "$mode" == "external" ]]; then
  owner="${LOOP_SPEC_PR_FEEDBACK_OWNER:-external-orchestrator}"
  jq -cn --arg owner "$owner" '{schema:1,observationStatus:"delegated",owner:$owner,
    reviewDecision:null,changesRequested:null,requestedReviewers:[],unresolved:null,items:[],error:null}'
  exit 0
fi

[[ $# -gt 0 ]] || { echo "usage: pr-feedback.sh check <pr> [--repo owner/repo]" >&2; exit 2; }
summary=""
rc=0
summary="$(bash "$COMMENTS_BIN" summary "$@")" || rc=$?
if [[ "$rc" -ne 0 ]] || ! jq -e 'type == "object" and has("reviewDecision")' <<<"$summary" >/dev/null 2>&1; then
  jq -cn --arg error "feedback observation failed" '{schema:1,observationStatus:"degraded",owner:"loop-spec",
    reviewDecision:null,changesRequested:null,requestedReviewers:[],unresolved:null,items:[],error:$error}'
  exit 0
fi

if [[ "$(jq -r '.metadataStatus // "complete"' <<<"$summary")" == "degraded" ]]; then
  jq -c '. + {schema:1,observationStatus:"degraded",owner:"loop-spec",
    error:"PR metadata observation failed"}' <<<"$summary"
  exit 0
fi

jq -c '. + {schema:1,observationStatus:"complete",owner:"loop-spec",error:null}' <<<"$summary"
