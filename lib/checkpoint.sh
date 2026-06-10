#!/usr/bin/env bash
# Checkpoint tagging and history-safe rollback for super-spec phase boundaries.
#
# Subcommands:
#   tag <type>      Create a git tag super-spec-checkpoint-{type}-YYYYMMDD-HHMMSS
#   rollback <tag>  Restore files to <tag> via git checkout (requires SUPER_SPEC_ROLLBACK_CONFIRMED=1)
#
# Valid types: post-discuss, post-plan, post-execute, post-verify, pre-rollback, manual
#
# Exit codes:
#   0 success
#   1 unknown subcommand
#   2 invalid type or missing argument
set -euo pipefail

VALID_TYPES="post-discuss post-plan post-execute post-verify pre-rollback manual"

usage() {
  cat >&2 <<'EOF'
Usage: checkpoint.sh <subcommand> [args]

Subcommands:
  tag <type>      Create git tag super-spec-checkpoint-{type}-YYYYMMDD-HHMMSS
  rollback <tag>  Restore to <tag> via git checkout TAG -- . (creates new commit)
                  Requires env var: SUPER_SPEC_ROLLBACK_CONFIRMED=1

Valid types for tag: post-discuss, post-plan, post-execute, post-verify, pre-rollback, manual
EOF
}

is_valid_type() {
  local t="$1"
  for v in $VALID_TYPES; do
    [[ "$t" == "$v" ]] && return 0
  done
  return 1
}

cmd="${1:-}"

case "$cmd" in
  tag)
    type="${2:-}"
    if [[ -z "$type" ]]; then
      echo "checkpoint.sh tag: missing <type> argument" >&2
      usage
      exit 2
    fi
    if ! is_valid_type "$type"; then
      echo "checkpoint.sh tag: invalid type '$type'. Valid types: $VALID_TYPES" >&2
      usage
      exit 2
    fi
    tag_name="super-spec-checkpoint-${type}-$(date +%Y%m%d-%H%M%S)"
    git tag "$tag_name"
    echo "Created checkpoint tag: $tag_name"
    ;;
  rollback)
    tag="${2:-}"
    if [[ -z "$tag" ]]; then
      echo "checkpoint.sh rollback: missing <tag> argument" >&2
      usage
      exit 2
    fi
    if [[ "${SUPER_SPEC_ROLLBACK_CONFIRMED:-}" != "1" ]]; then
      echo "checkpoint.sh rollback: set SUPER_SPEC_ROLLBACK_CONFIRMED=1 to proceed" >&2
      exit 1
    fi
    git checkout "$tag" -- .
    git add -A
    git commit -m "chore: NO_JIRA rollback to $tag"
    echo "Rolled back to checkpoint: $tag"
    ;;
  ""|--help|-h)
    usage
    exit 0
    ;;
  *)
    echo "checkpoint.sh: unknown subcommand '$cmd'" >&2
    usage
    exit 1
    ;;
esac
