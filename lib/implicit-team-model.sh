#!/usr/bin/env bash
# Decide whether a named implicit-team spawn can honor a model selector.
#
# Named Agent({name}) on Claude Code >= 2.1.178 (teamsMode=implicit) starts an
# in-process teammate that inherits the lead session model. The Agent `model`
# parameter and the agent definition's `model:` frontmatter are ignored
# (task_type: in_process_teammate). That is harness behavior, not a loop-spec
# bug. A role or phase alias therefore has to spawn as a nameless one-shot
# Agent, which does honor the alias enum. Rework for that role follows
# skills/shared/dispatch.md.
#
# Usage:
#   implicit-team-model.sh spawn-kind --teams-mode MODE --selector SELECTOR
#       Print `KIND REASON` on one line.
#       KIND is named | oneshot.
#       MODE is none | explicit | implicit (anything else fails safe to oneshot).
#       SELECTOR is inherit, empty, a Claude Agent alias, or any other value.
#
# Exit codes: 0 success; 2 bad invocation.
set -euo pipefail

[[ "${1:-}" == "spawn-kind" ]] || {
  echo "usage: implicit-team-model.sh spawn-kind --teams-mode MODE --selector SELECTOR" >&2
  exit 2
}
shift

teams_mode=""
selector=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --teams-mode) teams_mode="${2:-}"; shift 2 ;;
    --selector) selector="${2:-}"; shift 2 ;;
    *) echo "implicit-team-model: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[[ -n "$teams_mode" ]] || {
  echo "implicit-team-model: --teams-mode is required" >&2
  exit 2
}

# Empty means the role inherits. Full IDs never reach Agent({model:}) — feature-init
# rejects them on Claude roles — so they take the same oneshot path as an alias:
# do not name the spawn; the caller still omits an unusable model key.
case "$selector" in
  ""|inherit) inherit="true" ;;
  *) inherit="false" ;;
esac

case "$teams_mode" in
  none)
    printf 'oneshot no-teams\n'
    ;;
  explicit)
    printf 'named explicit-roster\n'
    ;;
  implicit)
    if [[ "$inherit" == "true" ]]; then
      printf 'named inherit-session\n'
    else
      printf 'oneshot implicit-named-ignores-model\n'
    fi
    ;;
  *)
    printf 'oneshot unknown-teams-mode\n'
    ;;
esac
