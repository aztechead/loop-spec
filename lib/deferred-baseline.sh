#!/usr/bin/env bash
# Capture an opt-in validation baseline once, at a phase boundary before implementation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${1:-}" == "run" && -n "${2:-}" ]] || { echo "usage: deferred-baseline.sh run FEATURE_DIR" >&2; exit 2; }
feature_dir="$(cd "$2" && pwd -P)"; fj="$feature_dir/feature.json"
fget() { bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" -r --filter "$1"; }
[[ "$(fget '.verificationBaselineOptIn // false')" == true || "${LOOP_SPEC_STARTUP_BASELINE:-0}" == 1 ]] || exit 0
[[ "$(fget '.verificationBaselineAttempted // false')" != true ]] || exit 0
[[ "$(fget '.verificationBaseline // null')" == null ]] || exit 0
[[ "$(fget '.greenfield // false')" != true ]] || exit 0

# A baseline needs an isolated exact-base checkout.  In-place mode is an explicit
# request to avoid creating any worktrees, so leave the attempt retryable if a
# later invocation enables worktrees deliberately.
case "${LOOP_SPEC_WORKTREES:-1}" in
  1) ;;
  0)
    echo "loop-spec: deferred baseline skipped because LOOP_SPEC_WORKTREES=0 forbids exact-base worktrees; enable worktrees to capture it" >&2
    exit 0
    ;;
  *)
    echo "loop-spec: deferred baseline skipped because LOOP_SPEC_WORKTREES must be 0 or 1 (got '${LOOP_SPEC_WORKTREES}'); treating it as 0 (no worktrees) for this call. Set it to 0 or 1 explicitly." >&2
    exit 0
    ;;
esac
workspace_mode="$(fget 'if (.workspace == null or (.workspace.mode // "") == "single") then "single" else "workspace" end')"
if [[ "$workspace_mode" == "single" ]]; then root="$(git -C "$feature_dir" rev-parse --show-toplevel)"; else root="$(fget '.workspace.root')"; fi
capture() {
(
  local target="$1" base="$2" prepare="$3" test="$4" lint="$5" typecheck="$6" name="$7"
  local parent tmp
  parent="$(mktemp -d "${TMPDIR:-/tmp}/loop-spec-baseline.XXXXXX")" || {
    echo "loop-spec: baseline not captured for $name: could not create temporary directory" >&2
    printf '%s\n' null; exit 0;
  }
  tmp="$parent/repo"
  cleanup() { git -C "$target" worktree remove --force "$tmp" >/dev/null 2>&1 || true; rmdir "$parent" >/dev/null 2>&1 || true; }
  trap cleanup EXIT
  if ! git -C "$target" worktree add --quiet --detach "$tmp" "$base"; then
    echo "loop-spec: baseline not captured for $name: could not create exact-base checkout" >&2; printf '%s\n' null; return 0
  fi
  local prep_rc=0 prep key logs out rc=0
  prep="$(bash "$SCRIPT_DIR/prepare-environment.sh" run --root "$tmp" --command "$prepare")" || prep_rc=$?
  if (( prep_rc != 0 )); then echo "loop-spec: baseline not captured for $name: environment preparation failed" >&2; printf '%s\n' null; return 0; fi
  key="$(jq -r '.key // ""' <<<"$prep")"; logs="$(git -C "$target" rev-parse --git-path "loop-spec/validation/$(fget '.slug')/base/$name")"; [[ "$logs" == /* ]] || logs="$target/$logs"; mkdir -p "$logs"
  out="$(bash "$SCRIPT_DIR/verification-baseline.sh" capture --root "$tmp" --base-sha "$base" --prepare-key "$key" --log-dir "$logs" --test "$test" --lint "$lint" --typecheck "$typecheck")" || rc=$?
  (( rc == 0 )) && jq -c . <<<"$out" || { echo "loop-spec: baseline not captured for $name; verificationBaseline stays null" >&2; printf '%s\n' null; }
  # Remove the temporary checkout before returning a completed result; the EXIT trap
  # still covers early exits from preparation or checkout failure.
  cleanup
  trap - EXIT
  exit 0
)
}
if [[ "$workspace_mode" == "single" ]]; then
  baseline="$(capture "$root" "$(fget '.baseSha')" "$(fget '.commands.prepare // ""')" "$(fget '.commands.test // ""')" "$(fget '.commands.lint // ""')" "$(fget '.commands.typecheck // ""')" single)"
  # Publish the result before latching the marker.  If the process is interrupted
  # during capture, neither write runs and the next invocation retries.
  [[ "$baseline" == null ]] || bash "$SCRIPT_DIR/feature-write.sh" set "$feature_dir" verificationBaseline "$baseline" >/dev/null
  bash "$SCRIPT_DIR/feature-write.sh" set "$feature_dir" verificationBaselineAttempted true >/dev/null
else
  updated_repos="$(fget '.workspace.repos')"
  while IFS= read -r repo; do
    name="$(jq -r '.name' <<<"$repo")"; target="$root/$(jq -r '.path' <<<"$repo")"
    [[ "$(jq -r '.verificationBaseline // null' <<<"$repo")" == "null" ]] || continue
    baseline="$(capture "$target" "$(jq -r '.baseSha' <<<"$repo")" "$(jq -r '.commands.prepare // ""' <<<"$repo")" "$(jq -r '.commands.test // ""' <<<"$repo")" "$(jq -r '.commands.lint // ""' <<<"$repo")" "$(jq -r '.commands.typecheck // ""' <<<"$repo")" "$name")"
    updated_repos="$(jq -c --argjson b "$baseline" --arg n "$name" 'map(if .name == $n then .verificationBaseline = $b else . end)' <<<"$updated_repos")"
    # Persist every completed repository before starting the next one.  This keeps
    # successful captures durable when a later repository is interrupted.
    bash "$SCRIPT_DIR/feature-write.sh" set "$feature_dir" workspace.repos "$updated_repos" >/dev/null
  done < <(fget '.workspace.repos | .[]' | jq -c .)
  bash "$SCRIPT_DIR/feature-write.sh" set "$feature_dir" verificationBaselineAttempted true >/dev/null
fi
