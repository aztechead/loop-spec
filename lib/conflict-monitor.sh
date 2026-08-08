#!/usr/bin/env bash
# Report whether deliberation should wake for a node's next attempt.
#
# Four deterministic signals only: a failing test command, a [major] gate
# finding, contradictory outputs from two agents on the same node, and N
# consecutive identical failures. Forward escalation only — never rewinds,
# never replays a checkpoint, never blocks.
#
# Usage:
#   conflict-monitor.sh check \
#     --test-exit <code> \
#     [--gate-log <file>] \
#     [--agent-outputs <file-a> <file-b>] \
#     [--consecutive <n>] \
#     [--checkpoint-ledger <file>]
#
# Output (one line): conflict=(yes|no) reason=<text>
# Exit: 0 on well-formed invocation; 2 on bad usage.
#
# N defaults to LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD (default 2), matching
# hooks/team/strategy-rotation.sh.
set -euo pipefail

usage() {
  echo "usage: conflict-monitor.sh check --test-exit <code> [--gate-log <file>] [--agent-outputs <a> <b>] [--consecutive <n>] [--checkpoint-ledger <file>]" >&2
  exit 2
}

[[ "${1:-}" == "check" ]] || usage
shift

test_exit=""
gate_log=""
agent_a=""
agent_b=""
consecutive=0
checkpoint_ledger=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-exit)
      [[ $# -ge 2 ]] || usage
      test_exit="$2"; shift 2
      ;;
    --gate-log)
      [[ $# -ge 2 ]] || usage
      gate_log="$2"; shift 2
      ;;
    --agent-outputs)
      [[ $# -ge 3 ]] || usage
      agent_a="$2"; agent_b="$3"; shift 3
      ;;
    --consecutive)
      [[ $# -ge 2 ]] || usage
      consecutive="$2"; shift 2
      ;;
    --checkpoint-ledger)
      [[ $# -ge 2 ]] || usage
      checkpoint_ledger="$2"; shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$test_exit" ]] || usage
[[ "$test_exit" =~ ^-?[0-9]+$ ]] || usage
[[ "$consecutive" =~ ^[0-9]+$ ]] || usage

# Ledger path is accepted so callers can prove we never touch it; do not read
# or write it. Existence is irrelevant.
: "${checkpoint_ledger:=}"

threshold="${LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD:-2}"
if ! [[ "$threshold" =~ ^[0-9]+$ ]]; then
  threshold=2
fi

if [[ "$test_exit" -ne 0 ]]; then
  echo "conflict=yes reason=test-exit:${test_exit}"
  exit 0
fi

if [[ -n "$gate_log" && -f "$gate_log" ]]; then
  if grep -q '\[major\]' "$gate_log"; then
    echo "conflict=yes reason=major-gate:${gate_log}"
    exit 0
  fi
fi

if [[ -n "$agent_a" && -n "$agent_b" ]]; then
  if [[ ! -f "$agent_a" || ! -f "$agent_b" ]]; then
    # Unresolvable comparison fails safe toward conflict (wake deliberation).
    echo "conflict=yes reason=contradiction:unreadable-agent-output"
    exit 0
  fi
  hash_a="$(cksum <"$agent_a" | awk '{print $1" "$2}')"
  hash_b="$(cksum <"$agent_b" | awk '{print $1" "$2}')"
  if [[ "$hash_a" != "$hash_b" ]]; then
    echo "conflict=yes reason=contradiction:agent-outputs-differ"
    exit 0
  fi
fi

if [[ "$consecutive" -ge "$threshold" ]]; then
  echo "conflict=yes reason=consecutive-failures:${consecutive}>=${threshold}"
  exit 0
fi

echo "conflict=no reason=none"
exit 0
