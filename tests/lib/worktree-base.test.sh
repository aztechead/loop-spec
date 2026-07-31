#!/usr/bin/env bash
# Tests for lib/worktree-base.sh — the worktree-location probe.
set -uo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/worktree-base.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/loop-spec-worktree-base.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
cleanup() { chmod -R u+rwX "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

new_repo() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" config user.email t@t
  git -C "$path" config user.name t
  echo x > "$path/a"
  git -C "$path" add a
  git -C "$path" commit -q -m init
}

# --- A/B: default in-repo bases when the repo tracks nothing under .claude/ ---
PLAIN="$WORK/plain"
new_repo "$PLAIN"

out="$(bash "$LIB" resolve "$PLAIN" feature demo)"
check "A: feature default base is in-repo .claude/worktrees" \
  "$PLAIN/.claude/worktrees/demo" "$(jq -r '.path' <<<"$out")"
check "A2: default is not flagged relocated" "false" "$(jq -r '.relocated' <<<"$out")"
check "A3: default is writable" "true" "$(jq -r '.writable' <<<"$out")"
[[ -n "$(jq -r '.reason' <<<"$out")" ]] && r=ok || r=empty
check "A4: resolve always reports a reason" "ok" "$r"

out="$(bash "$LIB" resolve "$PLAIN" task "demo/task-001")"
check "B: task default base is in-repo .loop-spec/worktrees" \
  "$PLAIN/.loop-spec/worktrees/demo/task-001" "$(jq -r '.path' <<<"$out")"

# A repo with no tracked harness-config paths must not pay for a write probe.
[[ -e "$PLAIN/.claude" ]] && r=created || r=untouched
check "B2: no probe residue when there is nothing to check out" "untouched" "$r"

# --- C/D: operator override outranks every probe ---
out="$(LOOP_SPEC_WORKTREE_DIR="$WORK/elsewhere" bash "$LIB" resolve "$PLAIN" feature demo)"
check "C: absolute LOOP_SPEC_WORKTREE_DIR wins" \
  "$WORK/elsewhere/features/demo" "$(jq -r '.path' <<<"$out")"
check "C2: override is flagged relocated" "true" "$(jq -r '.relocated' <<<"$out")"
grep -q "LOOP_SPEC_WORKTREE_DIR" <<<"$(jq -r '.reason' <<<"$out")" && r=ok || r=missing
check "C3: override reason names the operator control" "ok" "$r"

out="$(LOOP_SPEC_WORKTREE_DIR="../rel-wt" bash "$LIB" resolve "$PLAIN" task "demo/task-002")"
check "D: relative LOOP_SPEC_WORKTREE_DIR resolves against the root" \
  "$WORK/rel-wt/tasks/demo/task-002" "$(jq -r '.path' <<<"$out")"

# --- E/F: repos that DO track harness-config paths get probed ---
TRACKED="$WORK/tracked"
new_repo "$TRACKED"
mkdir -p "$TRACKED/.claude/commands"
echo "# setup" > "$TRACKED/.claude/commands/setup.md"
git -C "$TRACKED" add .claude/commands/setup.md
git -C "$TRACKED" commit -q -m "add command"

out="$(bash "$LIB" resolve "$TRACKED" feature demo)"
check "F: writable in-repo base is kept (no needless relocation)" \
  "$TRACKED/.claude/worktrees/demo" "$(jq -r '.path' <<<"$out")"
check "F2: kept in-repo base is not relocated" "false" "$(jq -r '.relocated' <<<"$out")"
probe_left="$(find "$TRACKED" -name '.loop-spec-write-probe*' 2>/dev/null | wc -l | tr -d ' ')"
check "F3: the write probe leaves no residue" "0" "$probe_left"

if [[ "$(id -u)" == "0" ]]; then
  echo "SKIP: E/I permission cases (running as root)"
else
  # The sandbox denies the checkout of .claude/commands/** inside the repo. A
  # read-only .claude/ reproduces exactly that failure mode for the probe.
  chmod 500 "$TRACKED/.claude"
  out="$(bash "$LIB" resolve "$TRACKED" feature demo)"
  check "E: denied in-repo base falls back to the out-of-repo sibling" \
    "$WORK/tracked-worktrees/features/demo" "$(jq -r '.path' <<<"$out")"
  check "E2: fallback is flagged relocated" "true" "$(jq -r '.relocated' <<<"$out")"
  check "E3: fallback is writable" "true" "$(jq -r '.writable' <<<"$out")"
  grep -q "not writable" <<<"$(jq -r '.reason' <<<"$out")" && r=ok || r=missing
  check "E4: fallback reason states the in-repo base was rejected" "ok" "$r"

  # I: every candidate denied -> report unwritable instead of guessing.
  RO="$WORK/ro"
  mkdir -p "$RO"
  BOXED="$RO/boxed"
  new_repo "$BOXED"
  mkdir -p "$BOXED/.claude/commands"
  echo "# setup" > "$BOXED/.claude/commands/setup.md"
  git -C "$BOXED" add .claude/commands/setup.md
  git -C "$BOXED" commit -q -m "add command"
  chmod 500 "$BOXED/.claude"
  chmod 500 "$RO"
  out="$(HOME="$RO" bash "$LIB" resolve "$BOXED" feature demo)"
  check "I: exhausted candidates report writable=false" "false" "$(jq -r '.writable' <<<"$out")"
  check "I2: exhausted resolve still exits 0 with the default answer" \
    "$BOXED/.claude/worktrees/demo" "$(jq -r '.path' <<<"$out")"
  chmod 700 "$RO"
fi

# --- H: candidate enumeration for discovery ---
bases=()
while IFS= read -r line; do bases+=("$line"); done < <(bash "$LIB" bases "$PLAIN" feature)
check "H: first candidate is the in-repo default" "$PLAIN/.claude/worktrees" "${bases[0]}"
[[ "${#bases[@]}" -ge 2 ]] && r=ok || r="${#bases[@]}"
check "H2: out-of-repo candidates are enumerated too" "ok" "$r"
printf '%s\n' "${bases[@]}" | grep -qx "$WORK/plain-worktrees/features" && r=ok || r=missing
check "H3: the sibling candidate is enumerated" "ok" "$r"

obases=()
while IFS= read -r line; do obases+=("$line"); done \
  < <(LOOP_SPEC_WORKTREE_DIR="$WORK/elsewhere" bash "$LIB" bases "$PLAIN" feature)
check "H4: an override collapses the candidate list to itself" "1" "${#obases[@]}"
check "H5: the single candidate is the override" "$WORK/elsewhere/features" "${obases[0]}"

# --- Bad invocation ---
rc=0; bash "$LIB" resolve "$PLAIN" bogus x >/dev/null 2>&1 || rc=$?
check "J: unknown kind exits 2" "2" "$rc"
rc=0; bash "$LIB" bogus "$PLAIN" feature >/dev/null 2>&1 || rc=$?
check "J2: unknown verb exits 2" "2" "$rc"
rc=0; bash "$LIB" resolve "$WORK/does-not-exist" feature x >/dev/null 2>&1 || rc=$?
check "J3: missing root exits 2" "2" "$rc"

echo ""
echo "worktree-base: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
