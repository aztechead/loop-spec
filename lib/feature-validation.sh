#!/usr/bin/env bash
# Prepare and compare repository-wide quality commands for one feature candidate.
# Exit: 0 no new failures; 2 invocation/state; 20 regression; 21 infrastructure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ "${1:-}" == "compare" && -n "${2:-}" && $# -eq 2 ]] || {
  echo "usage: feature-validation.sh compare <feature_dir>" >&2
  exit 2
}

feature_dir="$2"
[[ -f "$feature_dir/feature.json" ]] || {
  echo "feature-validation: feature.json not found in $feature_dir" >&2
  exit 2
}
feature_dir="$(cd "$feature_dir" && pwd -P)" || exit 2
feature_json="$feature_dir/feature.json"
jq -e '
  .schemaVersion == 7 and
  (if .workspace == null then
     (.branch | type == "string" and length > 0) and
     (.baseSha | type == "string" and length > 0) and
     (.commands | type == "object")
   else
     (.workspace.root | type == "string" and length > 0) and
     (.workspace.repos | type == "array" and length > 0) and
     all(.workspace.repos[];
       (.name | type == "string" and length > 0) and
       (.path | type == "string" and length > 0) and
       (.branch | type == "string" and length > 0) and
       (.baseSha | type == "string" and length > 0) and
       (.commands | type == "object"))
   end)
' "$feature_json" >/dev/null 2>&1 || {
  echo "feature-validation: unsupported or malformed feature state" >&2
  exit 2
}

slug="$(jq -er '.slug | select(type == "string" and length > 0)' "$feature_json" 2>/dev/null)" || exit 2
targets='[]'
overall="accepted"

run_target() {
  local name="$1" root="$2" branch="$3" base_sha="$4" commands="$5" baseline="$6"
  local prepare_command prepare_json prepare_rc prepare_key git_path state_dir baseline_file log_dir
  local compare_json compare_rc outcome record actual_branch actual_head integration_candidate

  if [[ ! -d "$root" ]] || ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    record="$(jq -cn --arg name "$name" --arg root "$root" \
      '{name:$name,root:$root,outcome:"infra_error",stage:"state",detail:"repository root is unavailable"}')"
    targets="$(jq -c --argjson record "$record" '. + [$record]' <<<"$targets")"
    overall="infra_error"
    return
  fi
  actual_branch="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  integration_candidate="${LOOP_SPEC_INTEGRATION_CANDIDATE:-}"
  actual_head="$(git -C "$root" rev-parse --verify HEAD 2>/dev/null || true)"
  if [[ -n "$integration_candidate" && "$actual_head" != "$integration_candidate" ]]; then
    record="$(jq -cn --arg name "$name" --arg root "$root" --arg expected "$integration_candidate" --arg actual "$actual_head" \
      '{name:$name,root:$root,outcome:"infra_error",stage:"state",detail:("integration candidate mismatch: expected " + $expected + ", found " + $actual)}')"
    targets="$(jq -c --argjson record "$record" '. + [$record]' <<<"$targets")"
    overall="infra_error"
    return
  elif [[ -z "$integration_candidate" && "$actual_branch" != "$branch" ]]; then
    record="$(jq -cn --arg name "$name" --arg root "$root" --arg expected "$branch" --arg actual "$actual_branch" \
      '{name:$name,root:$root,outcome:"infra_error",stage:"state",detail:("branch mismatch: expected " + $expected + ", found " + $actual)}')"
    targets="$(jq -c --argjson record "$record" '. + [$record]' <<<"$targets")"
    overall="infra_error"
    return
  fi

  prepare_command="$(jq -r '.prepare // ""' <<<"$commands")"
  prepare_rc=0
  prepare_json="$(bash "$SCRIPT_DIR/prepare-environment.sh" run --root "$root" \
    --command "$prepare_command")" || prepare_rc=$?
  if [[ "$prepare_rc" -ne 0 ]]; then
    record="$(jq -cn --arg name "$name" --arg root "$root" --argjson detail "${prepare_json:-null}" \
      --argjson exitCode "$prepare_rc" \
      '{name:$name,root:$root,outcome:"infra_error",stage:"prepare",exitCode:$exitCode,detail:$detail}')"
    targets="$(jq -c --argjson record "$record" '. + [$record]' <<<"$targets")"
    overall="infra_error"
    return
  fi
  prepare_key="$(jq -r '.key // ""' <<<"$prepare_json")"

  git_path="$(git -C "$root" rev-parse --git-path "loop-spec/validation/$slug/$name" 2>/dev/null)" || {
    record="$(jq -cn --arg name "$name" --arg root "$root" \
      '{name:$name,root:$root,outcome:"infra_error",stage:"state",detail:"cannot resolve Git-local validation path"}')"
    targets="$(jq -c --argjson record "$record" '. + [$record]' <<<"$targets")"
    overall="infra_error"
    return
  }
  [[ "$git_path" == /* ]] || git_path="$root/$git_path"
  state_dir="$git_path"
  baseline_file="$state_dir/baseline.json"
  log_dir="$state_dir/candidate-logs"
  if ! mkdir -p "$state_dir" "$log_dir"; then
    overall="infra_error"
    return
  fi
  if [[ "$baseline" == "null" ]]; then
    rm -f "$baseline_file"
  else
    printf '%s\n' "$baseline" > "$baseline_file" || {
      overall="infra_error"
      return
    }
  fi

  compare_rc=0
  compare_json="$(bash "$SCRIPT_DIR/verification-baseline.sh" compare \
    --root "$root" --base-sha "$base_sha" --prepare-key "$prepare_key" \
    --log-dir "$log_dir" --baseline "$baseline_file" \
    --test "$(jq -r '.test // ""' <<<"$commands")" \
    --lint "$(jq -r '.lint // ""' <<<"$commands")" \
    --typecheck "$(jq -r '.typecheck // ""' <<<"$commands")")" || compare_rc=$?
  case "$compare_rc" in
    0) outcome="accepted" ;;
    20) outcome="regression"; [[ "$overall" == "infra_error" ]] || overall="regression" ;;
    *) outcome="infra_error"; overall="infra_error" ;;
  esac
  record="$(jq -cn --arg name "$name" --arg root "$root" --arg outcome "$outcome" --arg logDir "$log_dir" \
    --argjson prepare "$prepare_json" --argjson detail "${compare_json:-null}" \
    '{name:$name,root:$root,outcome:$outcome,prepare:$prepare,comparison:$detail,logDir:$logDir}')"
  targets="$(jq -c --argjson record "$record" '. + [$record]' <<<"$targets")"
}

if jq -e '.workspace == null' "$feature_json" >/dev/null 2>&1; then
  root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null)" || exit 2
  run_target "$slug" "$root" \
    "$(jq -r '.branch' "$feature_json")" \
    "$(jq -r '.baseSha // ""' "$feature_json")" \
    "$(jq -c '.commands // {}' "$feature_json")" \
    "$(jq -c '.verificationBaseline // null' "$feature_json")"
else
  workspace_root="$(jq -r '.workspace.root // ""' "$feature_json")"
  while IFS= read -r repo; do
    name="$(jq -r '.name' <<<"$repo")"
    root="$workspace_root/$(jq -r '.path' <<<"$repo")"
    run_target "$name" "$root" "$(jq -r '.branch' <<<"$repo")" "$(jq -r '.baseSha' <<<"$repo")" \
      "$(jq -c '.commands // {}' <<<"$repo")" \
      "$(jq -c '.verificationBaseline // null' <<<"$repo")"
  done < <(jq -c '.workspace.repos[]' "$feature_json")
fi

jq -cn --arg outcome "$overall" --argjson targets "$targets" \
  '{schema:1,outcome:$outcome,targets:$targets}'
case "$overall" in
  accepted) exit 0 ;;
  regression) exit 20 ;;
  *) exit 21 ;;
esac
