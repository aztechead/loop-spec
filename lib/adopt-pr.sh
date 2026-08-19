#!/usr/bin/env bash
# Resolve whether a request names an existing open PR to adopt as the execution
# branch, instead of minting feat/{slug}.
#
# Why: a merge-conflict resolution, PR sync, or re-review is work ON an open PR.
# Starting a new feat/{slug} from the default branch leaves the conflicts on the
# other checkout and DELIVER opens a second PR. This probe answers from the
# request text and gh, never from a model judgment, and fails safe to "do not
# adopt" when gh is missing, the PR is not OPEN, or the head is a fork.
#
# Usage:
#   adopt-pr.sh resolve --repo DIR --request TEXT
#
# Output: one JSON object
#   {adopt:bool, number:int|null, url:string|null, branch:string|null,
#    baseBranch:string|null, reason:string}
#
# Exit: 0 with an answer, 2 bad invocation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=bounded-run.sh
. "$SCRIPT_DIR/bounded-run.sh"
loop_spec_disable_interactive_prompts

usage() {
  echo "usage: adopt-pr.sh resolve --repo DIR --request TEXT" >&2
  exit 2
}

emit() {
  jq -cn --argjson adopt "$1" --arg reason "$2" \
    --argjson number "${3:-null}" --arg url "${4:-}" \
    --arg branch "${5:-}" --arg base "${6:-}" \
    '{adopt:$adopt,reason:$reason,
      number:$number,
      url:(if $url == "" then null else $url end),
      branch:(if $branch == "" then null else $branch end),
      baseBranch:(if $base == "" then null else $base end)}'
  exit 0
}

[[ "${1:-}" == "resolve" ]] || usage
shift
repo=""
request=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --request) request="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$repo" && -d "$repo" ]] || usage
repo="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" \
  || emit false "not a git repository"

# Extract a PR number, CURRENT (deictic "this/the PR"), or empty. Python so the
# patterns stay one place and bash 3.2 does not own the URL grammar.
ref="$(python3 - "$request" <<'PY'
import re, sys
text = sys.argv[1]
m = re.search(r"github\.com/[^/\s]+/[^/\s]+/pull/(\d+)", text, re.I)
if m:
    print(m.group(1))
    raise SystemExit(0)
m = re.search(r"(?i)(?:\bpull request\s+#?|\bprs?\s*#?\s*)(\d+)", text)
if m:
    print(m.group(1))
    raise SystemExit(0)
m = re.search(r"(?i)(?:\bpr\s*#\s*|#)(\d+)", text)
if m:
    print(m.group(1))
    raise SystemExit(0)
if re.search(r"(?i)\b(?:this|the|our)\s+(?:open\s+)?pr\b", text):
    print("CURRENT")
    raise SystemExit(0)
print("")
PY
)"

if [[ -z "$ref" ]]; then
  emit false "request does not name an existing PR"
fi

command -v gh >/dev/null 2>&1 || emit false "gh is not on PATH"
git -C "$repo" remote get-url origin >/dev/null 2>&1 || emit false "origin remote is required"

timeout_secs="$(loop_spec_resolve_timeout "${LOOP_SPEC_GH_COMMAND_TIMEOUT_SECONDS:-}" 60)" \
  || timeout_secs=60
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/loop-spec-adopt-pr-XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

view_args=(pr view --json number,url,headRefName,baseRefName,state,isCrossRepository)
if [[ "$ref" == "CURRENT" ]]; then
  # gh pr view takes a branch as a positional; it has no --head (that flag is
  # pr list). Passing HEAD's name keeps the lookup explicit even if cwd drifts.
  view_args+=("$(git -C "$repo" rev-parse --abbrev-ref HEAD)")
else
  view_args+=("$ref")
fi

rc=0
# gh reads origin from cwd. bounded-run honors LOOP_SPEC_BOUNDED_RUN_CWD so the
# probe still answers when the skill invoked us from a different checkout.
LOOP_SPEC_BOUNDED_RUN_CWD="$repo" \
  loop_spec_run_bounded "$timeout_secs" "$tmp_dir/gh.out" "$tmp_dir/gh.err" \
  gh "${view_args[@]}" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  emit false "gh pr view failed (rc=$rc)"
fi
jq -e 'type == "object"' "$tmp_dir/gh.out" >/dev/null 2>&1 \
  || emit false "gh pr view returned malformed JSON"

state="$(jq -r '.state // empty' "$tmp_dir/gh.out")"
[[ "$state" == "OPEN" ]] || emit false "PR state is ${state:-unknown}, not OPEN"
cross="$(jq -r '.isCrossRepository // false' "$tmp_dir/gh.out")"
[[ "$cross" == "true" ]] && emit false "PR head is a fork; refusing to adopt a cross-repository branch"

number="$(jq -r '.number' "$tmp_dir/gh.out")"
url="$(jq -r '.url // empty' "$tmp_dir/gh.out")"
branch="$(jq -r '.headRefName // empty' "$tmp_dir/gh.out")"
base="$(jq -r '.baseRefName // empty' "$tmp_dir/gh.out")"
[[ "$number" =~ ^[0-9]+$ && -n "$branch" && -n "$base" ]] \
  || emit false "PR snapshot missing number, head, or base"
emit true "named open PR #$number on $branch" "$number" "$url" "$branch" "$base"
