#!/usr/bin/env bash
# decisions.sh - Durable record of self-answered (assumed) decisions.
#
# Autonomous mode's audit trail (skills/shared/autonomous-mode.md): every question
# the orchestrator self-answers lands here. Previously, setup answers made before
# SPEC.md exists (workspace repos, resume choice, detected commands) were "buffered
# in memory" — which means buffered in model context, where compaction or session
# death silently drops them. The audit trail IS the point of autonomous mode, so it
# lives in a file from the moment the first assumption is made.
#
# Store: JSONL, one decision per line: {ts, phase, question, answer, rationale}
# Location: <dir>/decisions.jsonl where <dir> is the feature dir once it exists.
# Before the feature dir exists (cycle Steps 0-4), callers use the staging file
# .loop-spec/decisions-staging.jsonl and `migrate` moves it into the feature dir.
#
# Usage:
#   decisions.sh add <dir> <phase> <question> <answer> <rationale>
#       Append one decision. Creates <dir> if missing.
#   decisions.sh list <dir>
#       Print the raw JSONL (empty output when none). Exit 0 always.
#   decisions.sh count <dir>
#       Print the number of recorded decisions.
#   decisions.sh render <dir>
#       Print the markdown list for SPEC.md's "## Decisions (assumed — autonomous)"
#       block: "- **{question}** → {answer} — {rationale}". Empty output when none.
#   decisions.sh migrate <staging_dir> <feature_dir>
#       Append staging decisions onto the feature's record and delete the staging
#       file. No-op (exit 0) when the staging file does not exist.
#
# Exit codes: 0 success, 1 bad invocation.
set -euo pipefail

FILE_NAME="decisions.jsonl"

case "${1:-}" in
  add)
    dir="${2:-}"; phase="${3:-}"; question="${4:-}"; answer="${5:-}"; rationale="${6:-}"
    if [[ -z "$dir" || -z "$phase" || -z "$question" || -z "$answer" ]]; then
      echo "usage: decisions.sh add <dir> <phase> <question> <answer> <rationale>" >&2
      exit 1
    fi
    mkdir -p "$dir"
    jq -cn \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg phase "$phase" --arg q "$question" --arg a "$answer" --arg r "$rationale" \
      '{ts: $ts, phase: $phase, question: $q, answer: $a, rationale: $r}' \
      >> "$dir/$FILE_NAME"
    echo "recorded"
    ;;
  list)
    dir="${2:-}"
    [[ -n "$dir" ]] || { echo "usage: decisions.sh list <dir>" >&2; exit 1; }
    [[ -f "$dir/$FILE_NAME" ]] && cat "$dir/$FILE_NAME"
    exit 0
    ;;
  count)
    dir="${2:-}"
    [[ -n "$dir" ]] || { echo "usage: decisions.sh count <dir>" >&2; exit 1; }
    if [[ -f "$dir/$FILE_NAME" ]]; then
      # NOT `|| echo 0`: grep prints "0" AND exits 1 on zero matches.
      grep -c . "$dir/$FILE_NAME" || true
    else
      echo 0
    fi
    ;;
  render)
    dir="${2:-}"
    [[ -n "$dir" ]] || { echo "usage: decisions.sh render <dir>" >&2; exit 1; }
    [[ -f "$dir/$FILE_NAME" ]] || exit 0
    jq -r '"- **\(.question)** → \(.answer) — \(.rationale)"' "$dir/$FILE_NAME"
    ;;
  migrate)
    staging="${2:-}"; feature="${3:-}"
    if [[ -z "$staging" || -z "$feature" ]]; then
      echo "usage: decisions.sh migrate <staging_dir> <feature_dir>" >&2
      exit 1
    fi
    src="$staging/$FILE_NAME"
    [[ -f "$src" ]] || { echo "nothing to migrate"; exit 0; }
    mkdir -p "$feature"
    cat "$src" >> "$feature/$FILE_NAME"
    rm "$src"
    echo "migrated"
    ;;
  *)
    echo "usage: decisions.sh add|list|count|render|migrate" >&2
    exit 1
    ;;
esac
