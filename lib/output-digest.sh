#!/usr/bin/env bash
# Bounded command output: the whole log to disk, a head/tail digest to the model.
#
# Usage:
#   output-digest.sh run   --log FILE [--label TEXT] [--max-lines N] -- <cmd> [args...]
#   output-digest.sh print --log FILE [--label TEXT] [--max-lines N] [--status N]
#
# Why: a cycle runs one continuous main-thread context across seven phases, and the
# largest thing accumulating in it is command output the lead re-reads and never needs
# again -- EXECUTE's per-task `verifyCommand` re-run alone lands a full suite log per
# merged task. Truncating in the caller loses the evidence; keeping everything spends
# the window. This keeps both: the complete output is a file the lead can grep or cite,
# and what enters context is a fixed-size excerpt that names where the rest lives.
#
# `run` executes and logs; `print` digests a log another runner already wrote, so
# lib/run-with-watchdog.sh (which owns the deadlines and already writes --log) composes
# with this rather than being duplicated by it.
#
# The digest never changes an outcome: `run` exits with the command's own code, so a
# caller branching on failure keeps working.
#
# Exit: the command's exit code (`run`); 0 (`print`); 1 unreadable/unwritable log;
# 2 bad invocation.
set -uo pipefail

DEFAULT_MAX_LINES=40

usage() {
  cat >&2 <<'EOF'
usage: output-digest.sh run   --log FILE [--label TEXT] [--max-lines N] -- <cmd> [args...]
       output-digest.sh print --log FILE [--label TEXT] [--max-lines N] [--status N]
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage
cmd="$1"; shift

log=""; label="output"; max_lines=""; status=""
argv=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --log) log="${2:-}"; shift 2 ;;
    --label) label="${2:-}"; shift 2 ;;
    --max-lines) max_lines="${2:-}"; shift 2 ;;
    --status) status="${2:-}"; shift 2 ;;
    --) shift; argv=("$@"); break ;;
    *) usage ;;
  esac
done

[[ -n "$log" ]] || usage
# An explicit flag outranks the environment; 0 is refused because it reads as "no
# limit" and would silently restore the unbounded dump this exists to remove.
[[ -n "$max_lines" ]] || max_lines="${LOOP_SPEC_DIGEST_MAX_LINES:-$DEFAULT_MAX_LINES}"
[[ "$max_lines" =~ ^[0-9]+$ && "$max_lines" -gt 0 ]] || {
  echo "output-digest: --max-lines must be a positive integer" >&2
  exit 2
}

# head + tail, split evenly, with at least one line on each side.
emit_digest() {
  local total head_n tail_n
  total="$(wc -l < "$log" | tr -d ' ')"
  printf '%s: exit=%s lines=%s log=%s\n' "$label" "$status" "$total" "$log"
  if [[ "$total" -le "$max_lines" ]]; then
    cat "$log"
    return 0
  fi
  head_n=$(( max_lines / 2 )); [[ "$head_n" -lt 1 ]] && head_n=1
  tail_n=$(( max_lines - head_n )); [[ "$tail_n" -lt 1 ]] && tail_n=1
  head -n "$head_n" "$log"
  printf '... %s lines elided; full output at %s ...\n' "$(( total - head_n - tail_n ))" "$log"
  tail -n "$tail_n" "$log"
}

case "$cmd" in
  run)
    [[ "${#argv[@]}" -ge 1 ]] || usage
    mkdir -p "$(dirname "$log")" 2>/dev/null || true
    : > "$log" 2>/dev/null || {
      echo "output-digest: cannot write log: $log" >&2
      exit 1
    }
    "${argv[@]}" > "$log" 2>&1
    status=$?
    emit_digest
    exit "$status"
    ;;
  print)
    [[ -f "$log" ]] || {
      echo "output-digest: log not found: $log" >&2
      exit 1
    }
    [[ -n "$status" ]] || status="unknown"
    emit_digest
    exit 0
    ;;
  *)
    usage
    ;;
esac
