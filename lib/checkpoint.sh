#!/usr/bin/env bash
# Checkpoint tagging and history-safe rollback for loop-spec phase boundaries.
#
# Usage: checkpoint.sh [-C <path>] <subcommand> [args]
#
# Options:
#   -C <path>   Run git operations against the repo at <path> (absolute or relative).
#               When set, rollback restores the target repo's tree, not the caller cwd.
#
# Subcommands:
#   tag <type>      Create a git tag loop-spec-checkpoint-{type}-YYYYMMDD-HHMMSS
#   rollback <tag>  Restore files to <tag> via git checkout (requires LOOP_SPEC_ROLLBACK_CONFIRMED=1)
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
Usage: checkpoint.sh [-C <path>] <subcommand> [args]

Options:
  -C <path>   Target git repo path (default: current directory)

Subcommands:
  tag <type>      Create git tag loop-spec-checkpoint-{type}-YYYYMMDD-HHMMSS
  rollback <tag>  Restore to <tag> via git checkout TAG -- :/ (creates new commit)
                  Requires env var: LOOP_SPEC_ROLLBACK_CONFIRMED=1

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

# Parse optional leading -C <path>
G=(git)
if [[ "${1:-}" == "-C" ]]; then
  if [[ -z "${2:-}" ]]; then
    echo "checkpoint.sh: -C requires a path argument" >&2
    usage
    exit 2
  fi
  G=(git -C "$2")
  shift 2
fi

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
    tag_name="loop-spec-checkpoint-${type}-$(date +%Y%m%d-%H%M%S)"
    "${G[@]}" tag "$tag_name"
    echo "Created checkpoint tag: $tag_name"
    ;;
  rollback)
    tag="${2:-}"
    if [[ -z "$tag" ]]; then
      echo "checkpoint.sh rollback: missing <tag> argument" >&2
      usage
      exit 2
    fi
    if [[ "${LOOP_SPEC_ROLLBACK_CONFIRMED:-}" != "1" ]]; then
      echo "checkpoint.sh rollback: set LOOP_SPEC_ROLLBACK_CONFIRMED=1 to proceed" >&2
      exit 1
    fi
    # Use ":/" as the pathspec so git resolves paths relative to the repo root,
    # not the caller's cwd. This ensures -C <path> restores the target repo's
    # tree even when invoked from an unrelated directory.
    "${G[@]}" checkout "$tag" -- :/
    "${G[@]}" add -A
    "${G[@]}" commit -m "chore: NO_JIRA rollback to $tag"
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
