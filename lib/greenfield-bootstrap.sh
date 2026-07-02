#!/usr/bin/env bash
# greenfield-bootstrap.sh - Deterministic mechanics for greenfield mode.
#
# Two pieces of the greenfield feature (cycle Step 0 branch; execute Step 2.5) are
# pure state checks that must never be re-derived from prose:
#
#   bootstrap: the git-init-in-place path, with its refusal cases. The refusals are
#   the safety edge — `new` inside an existing repo must NOT init a nested repo, and
#   workspace mode has no greenfield variant.
#
#   backfill-check: "an empty test command in a greenfield feature past task-001 is a
#   bug, not a degraded mode" (skills/execute/SKILL.md). A sentence enforces nothing;
#   this check does.
#
# Usage:
#   greenfield-bootstrap.sh bootstrap [dir]
#       Resolve the workspace mode of <dir> (default $PWD) and:
#         mode none      -> git init -b <default> + empty root commit; prints
#                           {"bootstrapped": true, "root": ...}
#         mode single    -> exit 4: already a git repo (greenfield is for empty dirs)
#         mode workspace -> exit 5: no multi-repo greenfield (out of scope; deferred)
#       Pre-existing untracked files are left untouched (never bulk-added): the root
#       commit is --allow-empty.
#
#   greenfield-bootstrap.sh backfill-check <feature_dir>
#       Exit 0 when the feature is not greenfield, or is greenfield with a non-empty
#       commands.test. Exit 3 (with a loud message) when greenfield && commands.test
#       is empty — callers run this after task-001 merges and before dispatching any
#       later task, the resume re-grounding test run, or VERIFY's acceptance gate.
#
# Exit codes: 0 ok, 1 bad invocation, 3 backfill missing, 4 refused (existing repo),
#             5 refused (workspace mode).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  bootstrap)
    dir="${2:-$PWD}"
    [[ -d "$dir" ]] || { echo "greenfield-bootstrap: no such directory: $dir" >&2; exit 1; }
    ws_json="$(bash "$SCRIPT_DIR/workspace.sh" detect "$dir")"
    mode="$(jq -r '.mode' <<<"$ws_json")"
    case "$mode" in
      single)
        echo "already a git repo — greenfield is for empty directories. Run the normal cycle, or cd into an empty directory for a new app." >&2
        exit 4
        ;;
      workspace)
        echo "workspace detected — greenfield has no multi-repo variant (out of scope; deferred). cd into an empty directory for a new app." >&2
        exit 5
        ;;
      none)
        default_branch="$(git config --global init.defaultBranch 2>/dev/null || true)"
        default_branch="${default_branch:-main}"
        git -C "$dir" init -q -b "$default_branch"
        # Identity fallback: a fresh environment (CI, container) may have no git
        # user configured; the root commit must not fail on that.
        id_args=()
        git -C "$dir" config user.email >/dev/null 2>&1 || id_args=(-c user.name="loop-spec" -c user.email="loop-spec@localhost")
        git -C "$dir" ${id_args[@]+"${id_args[@]}"} commit -q --allow-empty -m "chore: init repo (loop-spec greenfield)"
        jq -cn --arg root "$dir" --arg branch "$default_branch" \
          '{bootstrapped: true, root: $root, branch: $branch}'
        ;;
      *)
        echo "greenfield-bootstrap: unexpected workspace mode '$mode'" >&2
        exit 1
        ;;
    esac
    ;;
  backfill-check)
    feature_dir="${2:-}"
    [[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] || {
      echo "usage: greenfield-bootstrap.sh backfill-check <feature_dir>" >&2
      exit 1
    }
    fj="$feature_dir/feature.json"
    jq -e . "$fj" >/dev/null 2>&1 || {
      echo "greenfield-bootstrap: feature.json is not valid JSON: $fj" >&2
      exit 1
    }
    greenfield="$(jq -r '.greenfield // false' "$fj")"
    [[ "$greenfield" == "true" ]] || { echo "ok: not greenfield"; exit 0; }
    test_cmd="$(jq -r '.commands.test // ""' "$fj")"
    if [[ -z "$test_cmd" ]]; then
      echo "greenfield backfill MISSING: commands.test is empty past task-001 — this is a bug, not a degraded mode. Re-run detection (lib/detect-test-cmd.sh) and persist via feature-write.sh before dispatching further tasks." >&2
      exit 3
    fi
    echo "ok: greenfield backfilled (test: $test_cmd)"
    ;;
  *)
    echo "usage: greenfield-bootstrap.sh bootstrap [dir] | backfill-check <feature_dir>" >&2
    exit 1
    ;;
esac
