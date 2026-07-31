#!/usr/bin/env bash
# worktree-base.sh - Resolve WHERE loop-spec may create a git worktree, and why.
#
# loop-spec creates three kinds of worktree (feature at cycle Step 5, per-task in
# EXECUTE, revise), all historically at a fixed path INSIDE the repository:
# `.claude/worktrees/<slug>` and `.loop-spec/worktrees/<slug>/task-<id>`. A fixed
# in-repo location is not always usable: an agent harness may sandbox the Bash tool
# and deny writes to harness-config paths (`.claude/commands/**` and friends) at any
# depth inside the active repository. `git worktree add` checks out every tracked
# file, so a repo that TRACKS such a path cannot be checked out into an in-repo
# worktree at all — the checkout dies mid-way with a bare EPERM from git and leaves a
# partial worktree behind.
#
# This probe is the seam. It answers one question — which base directory can actually
# hold a worktree for this root — by TESTING the candidate rather than by guessing at
# the sandbox's rules: it writes, at each candidate, the same relative directories the
# checkout will have to write, and takes the first candidate that accepts them.
#
# Usage:
#   worktree-base.sh resolve <root> <kind> [name]
#       Print one JSON object:
#         {kind, root, base, path, relocated, writable, reason, probed}
#       `path` is `base/name` (or `base` when no name is given) and is the value to
#       hand to `git worktree add`. `reason` always states WHY that base was chosen.
#       `writable: false` means no candidate accepted the probe; `base` is then the
#       default and the caller should refuse with a diagnostic rather than let git
#       fail obscurely. Always exits 0 with an answer.
#
#   worktree-base.sh bases <root> <kind>
#       Print every candidate base directory, one absolute path per line, most
#       preferred first. No probing, no filesystem writes. Discovery (`git-ops.sh
#       list-feature-worktrees`) matches against ALL of them, so a worktree stays
#       findable no matter which candidate was chosen when it was created.
#
# Kinds:
#   feature   the cycle's one worktree per feature       (default <root>/.claude/worktrees)
#   task      EXECUTE's per-task and revise worktrees    (default <root>/.loop-spec/worktrees)
#
# Candidates, in order (first that accepts the probe wins):
#   1. $LOOP_SPEC_WORKTREE_DIR/<features|tasks>   operator override; absolute, or
#      relative to <root>. Outranks every probe and is used verbatim, unprobed.
#   2. <root>/<kind default>                      the historical in-repo location.
#   3. <root>-worktrees/<features|tasks>          sibling of the repo, outside it.
#   4. $HOME/.loop-spec/worktrees/<name>-<sum>/<features|tasks>
#
# <root> is the repository (or, for task worktrees, the feature worktree) the new
# worktree belongs to. Exit codes: 0 with the answer on stdout; 2 bad invocation.
set -euo pipefail

# Cap the probe: repos with a huge .claude/ tree do not need every directory tested
# to learn whether the base accepts harness-config paths.
MAX_PROBE_DIRS=25

usage() {
  echo "usage: worktree-base.sh {resolve <root> <kind> [name]|bases <root> <kind>}" >&2
  echo "       <kind> is 'feature' or 'task'" >&2
  exit 2
}

cmd="${1:-}"
root="${2:-}"
kind="${3:-}"
name="${4:-}"

case "$cmd" in
  resolve|bases) ;;
  *) usage ;;
esac
[[ -n "$root" && -d "$root" ]] || {
  echo "worktree-base: no such directory: ${root:-<missing>}" >&2
  exit 2
}
case "$kind" in
  feature) default_subdir=".claude/worktrees" ;;
  task)    default_subdir=".loop-spec/worktrees" ;;
  *) usage ;;
esac
relocated_subdir="${kind}s"   # features | tasks

root_abs="$(cd "$root" && pwd -P)"

# Candidate list (raw; normalized in one pass below).
override="${LOOP_SPEC_WORKTREE_DIR:-}"
raw=()
if [[ -n "$override" ]]; then
  raw+=("${override%/}/${relocated_subdir}")
else
  raw+=("${root_abs}/${default_subdir}")
  raw+=("${root_abs}-worktrees/${relocated_subdir}")
  if [[ -n "${HOME:-}" ]]; then
    # Distinguish same-named repos from different parents; cksum is POSIX and
    # deterministic, and this is a directory name, not a security boundary.
    sum="$(printf '%s' "$root_abs" | cksum | cut -d' ' -f1)"
    raw+=("${HOME%/}/.loop-spec/worktrees/$(basename "$root_abs")-${sum}/${relocated_subdir}")
  fi
fi

# `..` in an operator-supplied relative path must collapse, and macOS reports
# /var and /private/var for the same directory — git prints the resolved form in
# `worktree list`, so discovery only matches if we resolve too.
# Portable read loop instead of mapfile so this runs on stock macOS bash 3.2.
candidates=()
while IFS= read -r line; do
  [[ -n "$line" ]] && candidates+=("$line")
done < <(python3 - "$root_abs" "${raw[@]}" <<'PY'
import os
import sys

root = sys.argv[1]
for raw in sys.argv[2:]:
    print(os.path.realpath(os.path.join(root, raw)))
PY
)

if [[ "$cmd" == "bases" ]]; then
  printf '%s\n' "${candidates[@]}"
  exit 0
fi

emit() {
  local base="$1" relocated="$2" writable="$3" reason="$4" probed="$5"
  local path="$base"
  [[ -n "$name" ]] && path="${base}/${name}"
  jq -cn \
    --arg kind "$kind" --arg root "$root_abs" --arg base "$base" --arg path "$path" \
    --argjson relocated "$relocated" --argjson writable "$writable" \
    --arg reason "$reason" --argjson probed "$probed" \
    '{kind: $kind, root: $root, base: $base, path: $path,
      relocated: $relocated, writable: $writable, reason: $reason, probed: $probed}'
}

if [[ -n "$override" ]]; then
  emit "${candidates[0]}" true true \
    "operator override LOOP_SPEC_WORKTREE_DIR=${override}" 0
  exit 0
fi

# Which relative directories will the checkout have to write under a harness-config
# path? Only tracked files are checked out, so only tracked paths can be denied.
probe_dirs=()
while IFS= read -r d; do
  [[ -n "$d" ]] && probe_dirs+=("$d")
done < <(
  git -C "$root_abs" ls-files -z 2>/dev/null \
    | tr '\0' '\n' \
    | grep -E '(^|/)\.claude/' \
    | sed 's#/[^/]*$##' \
    | sort -u \
    | head -"$MAX_PROBE_DIRS" \
    || true
)

if [[ "${#probe_dirs[@]}" -eq 0 ]]; then
  emit "${candidates[0]}" false true \
    "in-repo default; repo tracks no .claude/ path that a checkout must write" 0
  exit 0
fi

deepest_existing() {
  local p="$1"
  while [[ ! -d "$p" && "$p" != "/" && "$p" != "." ]]; do
    p="$(dirname "$p")"
  done
  printf '%s' "$p"
}

# Remove only the directories this probe created, innermost first. rmdir refuses a
# non-empty directory, so anything that was already in use survives untouched.
prune_created() {
  local cur="$1" keep="$2"
  while [[ "$cur" != "$keep" && "$cur" != "/" && -d "$cur" ]]; do
    rmdir "$cur" 2>/dev/null || break
    cur="$(dirname "$cur")"
  done
}

# Write the checkout's own harness-config directories at the candidate. This is the
# exact operation `git worktree add` performs, at the exact location it performs it.
probe_base() {
  local base="$1"
  local keep probe d ok=1
  keep="$(deepest_existing "$base")"
  probe="${base}/.loop-spec-write-probe.$$"
  for d in "${probe_dirs[@]}"; do
    if ! mkdir -p "${probe}/${d}" 2>/dev/null; then ok=0; break; fi
    if ! : > "${probe}/${d}/.probe" 2>/dev/null; then ok=0; break; fi
  done
  rm -rf "$probe" 2>/dev/null || true
  prune_created "$base" "$keep"
  [[ "$ok" -eq 1 ]]
}

n="${#probe_dirs[@]}"
for i in "${!candidates[@]}"; do
  base="${candidates[$i]}"
  if probe_base "$base"; then
    if [[ "$i" -eq 0 ]]; then
      emit "$base" false true \
        "in-repo default; verified writable for ${n} tracked .claude/ path(s)" 1
    else
      emit "$base" true true \
        "in-repo base ${candidates[0]} is not writable for ${n} tracked .claude/ path(s); relocated outside the repository" 1
    fi
    exit 0
  fi
done

# Fail safe: report the default and say plainly that nothing accepted the probe.
# The caller refuses with an actionable message instead of letting git die on EPERM.
emit "${candidates[0]}" false false \
  "no candidate base is writable for ${n} tracked .claude/ path(s); checked ${#candidates[@]} candidate(s)" 1
