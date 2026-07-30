#!/usr/bin/env bash
# Capture and compare test/lint/typecheck results against an exact base commit.
# Exit: 0 accepted; 2 invocation; 20 regression; 21 infrastructure error.
set -uo pipefail

die2() { echo "verification-baseline: $*" >&2; exit 2; }
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
infra() {
  echo "verification-baseline: $1" >&2
  jq -cn --arg reason "$1" '{outcome: "infra_error", reason: $reason}'
  exit 21
}

action="${1:-}"
shift || true
root=""
base_sha=""
prepare_key=""
log_dir=""
baseline_file=""
test_cmd=""
lint_cmd=""
typecheck_cmd=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="${2:-}"; shift 2 ;;
    --base-sha) base_sha="${2:-}"; shift 2 ;;
    --prepare-key) prepare_key="${2:-}"; shift 2 ;;
    --log-dir) log_dir="${2:-}"; shift 2 ;;
    --baseline) baseline_file="${2:-}"; shift 2 ;;
    --test) test_cmd="${2:-}"; shift 2 ;;
    --lint) lint_cmd="${2:-}"; shift 2 ;;
    --typecheck) typecheck_cmd="${2:-}"; shift 2 ;;
    *) die2 "unknown argument '$1'" ;;
  esac
done

[[ "$action" == "capture" || "$action" == "compare" ]] \
  || die2 "usage: verification-baseline.sh {capture|compare} --root ROOT --base-sha SHA --prepare-key KEY --log-dir DIR [--baseline FILE] --test CMD --lint CMD --typecheck CMD"
[[ -n "$root" && -d "$root" ]] || die2 "--root must name a directory"
[[ -n "$base_sha" ]] || die2 "--base-sha is required"
[[ -n "$log_dir" ]] || die2 "--log-dir is required"
[[ "$action" != "compare" || -n "$baseline_file" ]] || die2 "compare requires --baseline"

root="$(cd "$root" && pwd -P)"
git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || infra "not a git worktree: $root"
top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)"
[[ -n "$top" ]] || infra "cannot read repository root"
top="$(cd "$top" && pwd -P)" || infra "cannot resolve repository root"
[[ "$top" == "$root" ]] || infra "--root must be the repository root: $top"
resolved_base="$(git -C "$root" rev-parse --verify "${base_sha}^{commit}" 2>/dev/null)" \
  || infra "base SHA is not a commit: $base_sha"
[[ "$resolved_base" == "$base_sha" ]] || infra "base SHA must be the exact full commit ID"

mkdir -p "$log_dir"

fingerprints() {
  local log="$1"
  FINGERPRINT_ROOT="$root" python3 - "$log" <<'PY'
import hashlib
import json
import os
import re
import sys

path = sys.argv[1]
root = os.environ["FINGERPRINT_ROOT"]
with open(path, "r", errors="replace") as f:
    lines = f.read().splitlines()
ansi = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
marker = re.compile(r"(?:\bfail(?:ed|ure)?\b|\berror\b|\bexception\b|\bpanic\b|\bfatal\b|\bassert(?:ion)?\b|\bnot ok\b)", re.I)

def normalize(line):
    line = ansi.sub("", line).replace(root, "<ROOT>")
    line = re.sub(r"\b0x[0-9a-f]+\b", "<HEX>", line, flags=re.I)
    line = re.sub(r"(?<=:)[0-9]+(?::[0-9]+)?\b", "<LINE>", line)
    line = re.sub(r"\b[0-9]+(?:\.[0-9]+)?(?:ms|s)\b", "<TIME>", line)
    return " ".join(line.split())

candidates = [normalize(line) for line in lines if marker.search(line)]
candidates = [line for line in candidates if line]
if not candidates:
    nonempty = [normalize(line) for line in lines if line.strip()]
    candidates = nonempty[-1:] or ["<no failure output>"]
print(json.dumps(sorted({hashlib.sha256(line.encode()).hexdigest()[:16] for line in candidates})))
PY
}

read_head() {
  git -C "$root" rev-parse --verify HEAD 2>/dev/null
}

read_worktree_status() {
  git -C "$root" status --porcelain --untracked-files=all 2>/dev/null
}

assert_repo_state() {
  local expected_head="$1"
  local context="$2"
  local observed_head observed_status
  if ! observed_head="$(read_head)"; then
    echo "verification-baseline: cannot read HEAD $context" >&2
    return 21
  fi
  if [[ "$observed_head" != "$expected_head" ]]; then
    echo "verification-baseline: HEAD changed $context (expected $expected_head, found $observed_head)" >&2
    return 21
  fi
  if ! observed_status="$(read_worktree_status)"; then
    echo "verification-baseline: cannot read Git worktree status $context" >&2
    return 21
  fi
  if [[ -n "$observed_status" ]]; then
    echo "verification-baseline: worktree is not clean $context; no cleanup was attempted" >&2
    return 21
  fi
}

run_command() {
  local name="$1"
  local command="$2"
  local expected_head="$3"
  local log="$log_dir/$name.log"
  local rc status fps failure_kind
  if [[ -z "$command" ]]; then
    : > "$log"
    jq -cn --arg command "$command" '{command: $command, status: "skipped", exitCode: null, fingerprints: []}'
    return
  fi
  assert_repo_state "$expected_head" "before $name command" || return 21
  bash "$script_dir/run-with-watchdog.sh" --root "$root" --command "$command" --log "$log" \
    --timeout-secs "${LOOP_SPEC_BASELINE_TIMEOUT_SECS:-1800}" \
    --idle-timeout-secs "${LOOP_SPEC_BASELINE_IDLE_TIMEOUT_SECS:-300}"
  rc=$?
  failure_kind="$(jq -r '.status // "command_failed"' "$log.watchdog.json" 2>/dev/null \
    || printf 'command_failed')"
  assert_repo_state "$expected_head" "after $name command" || return 21
  if [[ "$rc" -eq 0 ]]; then
    status="pass"
    fps="[]"
  elif [[ "$failure_kind" == "timeout" || "$failure_kind" == "idle_timeout" \
          || "$failure_kind" == "signal" || "$failure_kind" == "spawn_failed" \
          || "$rc" -eq 126 || "$rc" -eq 127 || "$rc" -ge 128 ]]; then
    status="infra_error"
    fps="$(fingerprints "$log")"
  else
    status="fail"
    fps="$(fingerprints "$log")"
  fi
  jq -cn --arg command "$command" --arg status "$status" --arg failureKind "$failure_kind" \
    --argjson exitCode "$rc" --argjson fps "$fps" \
    '{command: $command, status: $status, exitCode: $exitCode,
      failureKind: $failureKind, fingerprints: $fps}'
}

run_all() {
  local expected_head="$1"
  local test_result lint_result typecheck_result
  assert_repo_state "$expected_head" "before verification commands" || return 21
  test_result="$(run_command test "$test_cmd" "$expected_head")" || return 21
  lint_result="$(run_command lint "$lint_cmd" "$expected_head")" || return 21
  typecheck_result="$(run_command typecheck "$typecheck_cmd" "$expected_head")" || return 21
  assert_repo_state "$expected_head" "after verification commands" || return 21
  jq -cn --argjson test "$test_result" --argjson lint "$lint_result" --argjson typecheck "$typecheck_result" \
    '{test: $test, lint: $lint, typecheck: $typecheck}'
}

if [[ "$action" == "capture" ]]; then
  head_sha="$(read_head)" || infra "cannot read HEAD before baseline capture"
  [[ "$head_sha" == "$base_sha" ]] || infra "baseline capture requires HEAD == baseSha"
  assert_repo_state "$base_sha" "before baseline capture" \
    || infra "baseline capture requires readable, clean state at baseSha"
  commands="$(run_all "$base_sha")" \
    || infra "repository state changed or became unreadable during baseline capture"
  result="$(jq -cn --arg baseSha "$base_sha" --arg prepareKey "$prepare_key" --argjson commands "$commands" \
    '{schemaVersion: 1, baseSha: $baseSha, prepareKey: $prepareKey, commands: $commands}'
  )"
  printf '%s\n' "$result"
  if jq -e '[.[] | select(.status == "infra_error")] | length > 0' >/dev/null <<<"$commands"; then
    exit 21
  fi
  exit 0
fi

missing=false
baseline=""
if [[ ! -f "$baseline_file" ]]; then
  missing=true
else
  baseline="$(jq -c . "$baseline_file" 2>/dev/null)" || infra "baseline JSON is invalid"
  [[ "$(jq -r '.schemaVersion // 0' <<<"$baseline")" == "1" ]] || infra "unsupported baseline schema"
  [[ "$(jq -r '.baseSha // ""' <<<"$baseline")" == "$base_sha" ]] || infra "baseline baseSha does not match"
  [[ "$(jq -r '.prepareKey // ""' <<<"$baseline")" == "$prepare_key" ]] || infra "baseline prepareKey does not match"
  jq -e --arg test "$test_cmd" --arg lint "$lint_cmd" --arg typecheck "$typecheck_cmd" \
    '.commands.test.command == $test and .commands.lint.command == $lint and .commands.typecheck.command == $typecheck' \
    >/dev/null 2>&1 <<<"$baseline" || infra "baseline command binding does not match"
fi

candidate_head="$(read_head)" || infra "cannot read candidate HEAD before comparison"
git -C "$root" merge-base --is-ancestor "$base_sha" "$candidate_head" >/dev/null 2>&1 \
  || infra "base SHA is not an ancestor of candidate HEAD"
assert_repo_state "$candidate_head" "before baseline comparison" \
  || infra "baseline comparison requires readable, clean candidate state"
current="$(run_all "$candidate_head")" \
  || infra "candidate repository state changed or became unreadable during baseline comparison"
if jq -e '[.[] | select(.status == "infra_error")] | length > 0' >/dev/null <<<"$current"; then
  jq -cn --argjson baselineMissing "$missing" --argjson commands "$current" \
    '{outcome: "infra_error", baselineMissing: $baselineMissing, commands: $commands}'
  exit 21
fi

if [[ "$missing" == "true" ]]; then
  if jq -e '[.[] | select(.status == "fail")] | length > 0' >/dev/null <<<"$current"; then
    outcome="regression"
    rc=20
  else
    outcome="accepted"
    rc=0
  fi
  jq -cn --arg outcome "$outcome" --argjson commands "$current" \
    '{outcome: $outcome, baselineMissing: true, commands: $commands}'
  exit "$rc"
fi

if jq -e '[.commands[] | select(.status == "infra_error")] | length > 0' >/dev/null <<<"$baseline"; then
  infra "captured baseline contains an infrastructure error"
fi

comparison="{}"
regression=false
for name in test lint typecheck; do
  old="$(jq -c --arg name "$name" '.commands[$name]' <<<"$baseline")"
  now="$(jq -c --arg name "$name" '.[$name]' <<<"$current")"
  old_status="$(jq -r '.status' <<<"$old")"
  now_status="$(jq -r '.status' <<<"$now")"
  added="$(jq -cn --argjson old "$old" --argjson now "$now" \
    '[($now.fingerprints // [])[] | select(. as $fp | (($old.fingerprints // []) | index($fp) | not))]')"
  command_regression=false
  if [[ "$old_status" == "pass" && "$now_status" == "fail" ]]; then
    command_regression=true
  elif [[ "$old_status" == "fail" && "$now_status" == "fail" && "$(jq 'length' <<<"$added")" -gt 0 ]]; then
    command_regression=true
  fi
  [[ "$command_regression" == "false" ]] || regression=true
  comparison="$(jq -cn --argjson all "$comparison" --arg name "$name" \
    --arg baselineStatus "$old_status" --arg currentStatus "$now_status" \
    --argjson added "$added" --argjson regression "$command_regression" \
    '$all + {($name): {baselineStatus: $baselineStatus, currentStatus: $currentStatus, addedFingerprints: $added, regression: $regression}}')"
done

if [[ "$regression" == "true" ]]; then
  outcome="regression"
  rc=20
else
  outcome="accepted"
  rc=0
fi
jq -cn --arg outcome "$outcome" --argjson comparison "$comparison" \
  '{outcome: $outcome, baselineMissing: false, commands: $comparison}'
exit "$rc"
