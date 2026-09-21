#!/usr/bin/env bash
# Resolve the small set of concurrency bounds shared by every dispatch rung.
#
# Defaults are deliberately conservative: one implementer and one child agent at
# a time. Operators can opt into wider waves with the LOOP_SPEC_* variables; this
# helper is the single validation point so capability probes and dispatch agree.
# `env` exports only what an operator set: a materialized default would read as an
# operator setting in every child (execute-rung.sh derives the wave cap from the
# plan's width only while both variables are unset).
set -euo pipefail

usage() {
  echo "usage: resource-bounds.sh resolve | env | get <implementers|subagents>" >&2
  exit 2
}

positive() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "resource-bounds: $name must be a positive integer" >&2
    exit 2
  }
  printf '%s' "$value"
}

read_bound() {
  local name="$1" value="" fallback="$2"
  if [[ "${!name+x}" == x ]]; then
    value="${!name}"
  fi
  if [[ -n "$value" ]]; then
    positive "$name" "$value"
  else
    printf '%s' "$fallback"
  fi
}

worktrees="${LOOP_SPEC_WORKTREES:-1}"
case "$worktrees" in
  0|1) ;;
  *)
    echo "resource-bounds: LOOP_SPEC_WORKTREES must be 0 or 1" >&2
    exit 2
    ;;
esac

subagents="$(read_bound LOOP_SPEC_MAX_PARALLEL_SUBAGENTS 1)"
if [[ -n "${LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS-}" ]]; then
  requested_implementers="$(read_bound LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS 1)"
  if [[ -z "${LOOP_SPEC_MAX_PARALLEL_SUBAGENTS-}" ]]; then
    subagents="$requested_implementers"
    implementers="$requested_implementers"
  elif (( requested_implementers < subagents )); then
    implementers="$requested_implementers"
  else
    implementers="$subagents"
  fi
else
  implementers="$subagents"
fi

if [[ "$worktrees" == "0" ]]; then
  subagents=1
  implementers=1
fi

# `explicit` says whether an operator set either bound. The record is persisted at
# cycle start and restored at EXECUTE, and a restored default read as an operator
# setting there, which silenced the width-aware default (the 6.9.0 full-route live
# run planned width 3 and still ran one implementer at a time). The startup `env`
# step made the same mistake one process earlier: it exported the defaults, and
# `resolve` then recorded them as explicit.
explicit=false
[[ -n "${LOOP_SPEC_MAX_PARALLEL_SUBAGENTS-}" || -n "${LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS-}" ]] && explicit=true

case "${1-}" in
  resolve)
    jq -cn --argjson i "$implementers" --argjson s "$subagents" --argjson e "$explicit" \
      '{maxParallelImplementers:$i,maxParallelSubagents:$s,explicit:$e}'
    ;;
  env)
    [[ "$explicit" == true ]] || exit 0
    printf "export LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS=%q\n" "$implementers"
    printf "export LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=%q\n" "$subagents"
    ;;
  get)
    case "${2-}" in
      implementers) printf '%s\n' "$implementers" ;;
      subagents) printf '%s\n' "$subagents" ;;
      *) usage ;;
    esac
    ;;
  *) usage ;;
esac
