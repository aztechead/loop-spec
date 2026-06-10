#!/usr/bin/env bash
# Helpers for agent-team operations.
#
# Functions:
#   team_name_for_phase <phase> <slug>  -> "super-spec-<phase>-<slug>"
#   assert_team_env                     -> exits 2 if CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS != "1"
#   feature_json_path <slug>            -> ".super-spec/features/<slug>/feature.json"
#
# Exit codes (assert_team_env):
#   0  env var is set to "1"
#   2  env var missing or not "1"
set -euo pipefail

team_name_for_phase() {
  echo "super-spec-${1}-${2}"
}

assert_team_env() {
  if [[ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" != "1" ]]; then
    echo "ERROR: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS must be set to 1" >&2
    exit 2
  fi
}

feature_json_path() {
  echo ".super-spec/features/${1}/feature.json"
}

# CLI dispatcher: allows `bash lib/team-ops.sh <function_name> [args...]`.
# Restricted to an explicit allowlist so an attacker cannot invoke arbitrary shell
# functions or bash builtins (e.g. `eval`, `source`, `exec`) by passing a crafted
# first argument when this script is driven by external input.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 1 ]]; then
    echo "usage: team-ops.sh <function_name> [args...]" >&2
    echo "  functions: team_name_for_phase, assert_team_env, feature_json_path" >&2
    exit 1
  fi
  case "$1" in
    team_name_for_phase|assert_team_env|feature_json_path)
      "$@"
      ;;
    *)
      echo "team-ops: unknown function: $1" >&2
      echo "  allowed: team_name_for_phase, assert_team_env, feature_json_path" >&2
      exit 1
      ;;
  esac
fi
