#!/usr/bin/env bash
# profile.sh - Resolve the run profile: one named preset plus project overrides, as env.
#
# Why: docs/loop-spec/configuration.md lists more than 150 variable rows, and a
# supervisor embedding loop-spec copied the cloud-run block of eighteen exports by hand.
# A profile names the policy once. `.loop-spec/profile.json` holds a preset name and
# overrides; this script turns it into environment. The precedence rule from the
# configuration contract holds: a variable already set in the environment wins over
# the file, and the file wins over the built-in default.
#
# The file:
#   { "preset": "supervised", "env": { "LOOP_SPEC_ITERATE_MAX_ITERATIONS": "3" } }
#
# Usage:
#   profile.sh presets                    -> preset names, one per line
#   profile.sh show <preset>              -> that preset's variables, KEY=value lines
#   profile.sh resolve [--file F]         -> {preset, source, env:{...}} on one line
#   profile.sh env [--file F] [--all]     -> `export KEY='value'` lines for eval; a variable
#                                            already set in the environment is skipped
#                                            unless --all
#   profile.sh validate [--file F]        -> findings on stderr; exit 1 when any
#
# File resolution: --file, else $LOOP_SPEC_PROFILE, else
# ${CLAUDE_PROJECT_DIR:-$PWD}/.loop-spec/profile.json. Preset resolution:
# $LOOP_SPEC_PROFILE_PRESET, else the file's "preset", else "interactive". With no
# file and no preset variable, `env` and `resolve` answer the empty interactive profile
# without reading anything, so the consumers that eval this on every call pay nothing.
#
# Exit codes:
#   0 resolved / valid
#   1 validate found findings, or an unreadable file on resolve/env
#   2 bad invocation or unknown preset
set -euo pipefail

# A preset is env only. It cannot switch a gate off: the authority scripts
# (trust.sh, autonomous-chain.sh, task-route.sh) never read this file. Only
# `supervised` names a supervisor as the oracle: `cloud` is launched by `claude -p`
# as often as by an SDK, and a question nobody answers is a wasted round trip, so it
# self-answers unless the file's env says LOOP_SPEC_ORACLE=supervisor.
PRESETS='{
  "interactive": {},
  "autonomous": {
    "LOOP_SPEC_AUTONOMOUS": "1",
    "LOOP_SPEC_NON_INTERACTIVE": "1",
    "LOOP_SPEC_ORACLE": "self"
  },
  "supervised": {
    "LOOP_SPEC_AUTONOMOUS": "1",
    "LOOP_SPEC_NON_INTERACTIVE": "1",
    "LOOP_SPEC_ORACLE": "supervisor",
    "LOOP_SPEC_PHASE_HANDOFF": "1",
    "LOOP_SPEC_CHECKPOINT_EACH_PHASE": "1"
  },
  "cloud": {
    "LOOP_SPEC_AUTONOMOUS": "1",
    "LOOP_SPEC_NON_INTERACTIVE": "1",
    "LOOP_SPEC_ORACLE": "self",
    "LOOP_SPEC_PHASE_HANDOFF": "1",
    "LOOP_SPEC_CHECKPOINT_EACH_PHASE": "1",
    "LOOP_SPEC_WORKTREES": "0",
    "LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS": "1",
    "LOOP_SPEC_MAX_PARALLEL_SUBAGENTS": "1",
    "LOOP_SPEC_TEAMS_MODE": "none",
    "LOOP_SPEC_EXECUTE_LOOPS": "0",
    "LOOP_SPEC_EXECUTE_WORKFLOW": "0",
    "LOOP_SPEC_PLAN_MULTI_ANGLE": "0",
    "LOOP_SPEC_SHARE_DEPENDENCIES": "1",
    "LOOP_SPEC_PREPARE_TIMEOUT_SECS": "1200",
    "LOOP_SPEC_PREPARE_IDLE_TIMEOUT_SECS": "300",
    "LOOP_SPEC_BASELINE_TIMEOUT_SECS": "1800",
    "LOOP_SPEC_BASELINE_IDLE_TIMEOUT_SECS": "300"
  }
}'

usage() {
  echo "usage: profile.sh presets | show <preset> | resolve [--file F] | env [--file F] [--all] | validate [--file F]" >&2
  exit 2
}

op="${1:-}"; shift || true
file=""; all=0; preset_arg=""
case "$op" in
  presets) ;;
  show) preset_arg="${1:-}"; [[ -n "$preset_arg" ]] || usage ;;
  resolve|env|validate)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --file) file="${2:-}"; [[ -n "$file" ]] || usage; shift 2 ;;
        --all) all=1; shift ;;
        *) usage ;;
      esac
    done
    ;;
  *) usage ;;
esac

if [[ "$op" == "presets" ]]; then
  jq -r 'keys[]' <<<"$PRESETS"
  exit 0
fi
if [[ "$op" == "show" ]]; then
  jq -e --arg p "$preset_arg" 'has($p)' <<<"$PRESETS" >/dev/null \
    || { echo "profile: unknown preset '$preset_arg' (bash lib/profile.sh presets)" >&2; exit 2; }
  jq -r --arg p "$preset_arg" '.[$p] | to_entries[] | "\(.key)=\(.value)"' <<<"$PRESETS"
  exit 0
fi

[[ -n "$file" ]] || file="${LOOP_SPEC_PROFILE:-${CLAUDE_PROJECT_DIR:-$PWD}/.loop-spec/profile.json}"

# The empty profile is the common case on every interactive install: answer it
# before touching jq so the per-call consumers stay cheap.
if [[ ! -e "$file" && -z "${LOOP_SPEC_PROFILE_PRESET:-}" ]]; then
  case "$op" in
    resolve) printf '{"preset":"interactive","source":"default","env":{}}\n' ;;
    validate) ;;
  esac
  exit 0
fi

doc='{}'; source="default"
if [[ -e "$file" ]]; then
  doc="$(jq -c . "$file" 2>/dev/null)" || {
    echo "profile: $file is not valid JSON" >&2
    exit 1
  }
  source="$file"
fi

findings=0
finding() { echo "profile: $1" >&2; findings=$((findings + 1)); }

preset="$(jq -r '.preset // "interactive"' <<<"$doc")"
if [[ -n "${LOOP_SPEC_PROFILE_PRESET:-}" ]]; then
  preset="$LOOP_SPEC_PROFILE_PRESET"; source="LOOP_SPEC_PROFILE_PRESET"
fi
jq -e --arg p "$preset" 'has($p)' <<<"$PRESETS" >/dev/null \
  || finding "unknown preset '$preset' (bash lib/profile.sh presets)"

overrides="$(jq -c '.env // {}' <<<"$doc")"
[[ "$(jq -r 'type' <<<"$overrides")" == "object" ]] \
  || { finding "\"env\" must be an object of LOOP_SPEC_* strings"; overrides='{}'; }
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  [[ "$key" =~ ^LOOP_SPEC_[A-Z0-9_]+$ ]] || finding "env key '$key' is not a LOOP_SPEC_* name"
  [[ "$(jq -r --arg k "$key" '.[$k] | type' <<<"$overrides")" == "string" ]] \
    || finding "env value for '$key' must be a string (quote numbers and 0/1)"
done < <(jq -r 'keys[]' <<<"$overrides")
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  case "$key" in preset|env) ;; *) finding "unknown top-level key '$key' (only preset and env)" ;; esac
done < <(jq -r 'keys[]' <<<"$doc")

if [[ "$op" == "validate" ]]; then
  (( findings == 0 )) || exit 1
  echo "profile: ok (preset=$preset source=$source)"
  exit 0
fi
(( findings == 0 )) || exit 1

resolved="$(jq -cn --argjson presets "$PRESETS" --arg p "$preset" --argjson o "$overrides" \
  '($presets[$p] // {}) + ($o | with_entries(select(.value | type == "string")))')"

if [[ "$op" == "resolve" ]]; then
  jq -cn --arg p "$preset" --arg s "$source" --argjson e "$resolved" '{preset:$p, source:$s, env:$e}'
  exit 0
fi

while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  if (( all == 0 )) && [[ -n "${!key+set}" ]]; then continue; fi
  jq -r --arg k "$key" '"export \($k)=\(.[$k] | @sh)"' <<<"$resolved"
done < <(jq -r 'keys[]' <<<"$resolved")
