#!/usr/bin/env bash
# Tests for lib/watch.sh (bounded post-merge watch, ROADMAP-3.0 C2).
# Digest-append semantics + the clean/dirty verdict table, all fixture-driven
# (a real throwaway git repo stands in for the merged default branch).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/watch.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}/watch-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/digests" "$WORK/repo"
export LOOP_SPEC_BACKLOG_FILE="$WORK/BACKLOG.md"

# ── Fixture repo: a "merged" commit, then one fixup touching the feature file ─
GIT="git -C $WORK/repo"
$GIT init -q -b main .
$GIT config user.email watch@test && $GIT config user.name watch
echo a > "$WORK/repo/app.txt"; echo o > "$WORK/repo/other.txt"
$GIT add -A && $GIT commit -qm "merge: feature x"
MERGE_OID="$($GIT rev-parse HEAD)"
echo fix >> "$WORK/repo/app.txt"
$GIT add -A && $GIT commit -qm "fix: post-merge regression"
echo unrelated >> "$WORK/repo/other.txt"
$GIT add -A && $GIT commit -qm "chore: unrelated"

DIG="$WORK/digests"
mk_digest() {
  jq -n '{schema:2, slug:"feat-x", branch:"feat/feat-x", status:"completed",
          converged:true, iterations:{used:1,max:10}}' > "$DIG/feat-x.json"
}
mk_pr() { # mk_pr <files-json-array>
  jq -n --arg oid "$MERGE_OID" --argjson files "$1" \
    '{number:7, url:"https://github.com/t/r/pull/7", mergedAt:"2026-07-10T00:00:00Z",
      mergeCommit:$oid, files:$files}' > "$WORK/pr.json"
}
GREEN='[{"status":"completed","conclusion":"success","createdAt":"2026-07-10T01:00:00Z"}]'
RED='[{"status":"completed","conclusion":"success","createdAt":"2026-07-10T01:00:00Z"},
      {"status":"completed","conclusion":"failure","createdAt":"2026-07-10T02:00:00Z"}]'
NOW="$(jq -rn '"2026-07-11T01:00:00Z" | fromdateiso8601')"

run_watch() { # run_watch <runs-json> [extra flags...]
  local runs="$1"; shift
  printf '%s' "$runs" > "$WORK/runs.json"
  bash "$SCRIPT" run --slug feat-x --digests "$DIG" --repo-dir "$WORK/repo" \
    --default-branch main --fixture-pr "$WORK/pr.json" --fixture-runs "$WORK/runs.json" \
    --now "$NOW" "$@"
}

# ── Verdict table ─────────────────────────────────────────────────────────────
# dirty: red CI + fixup commit
mk_digest; mk_pr '["app.txt"]'
run_watch "$RED" >/dev/null
w="$(jq -c '.watch' "$DIG/feat-x.json")"
check "dirty: branchGreen false" "false" "$(jq '.branchGreen' <<<"$w")"
check "dirty: fixup counted" "1" "$(jq '.humanFixCommits' <<<"$w")"
check "dirty: clean false" "false" "$(jq '.clean' <<<"$w")"
check "dirty: watch schema stamped" "1" "$(jq '.schema' <<<"$w")"
check "dirty: pr number recorded" "7" "$(jq '.prNumber' <<<"$w")"
check "dirty: backlog entry queued as watch-regression" "1" \
  "$(grep -c 'watch-regression' "$LOOP_SPEC_BACKLOG_FILE")"

# green CI but a fixup commit is still dirty
mk_digest; run_watch "$GREEN" >/dev/null
w="$(jq -c '.watch' "$DIG/feat-x.json")"
check "fixup-only: clean false" "false" "$(jq '.clean' <<<"$w")"
# re-run idempotent on the backlog (exact-text match)
check "re-run does not duplicate backlog entry" "1" \
  "$(grep -c 'watch-regression' "$LOOP_SPEC_BACKLOG_FILE")"

# fixups only count when they touch the feature's files
mk_digest; mk_pr '["never-touched.txt"]'
run_watch "$GREEN" >/dev/null
w="$(jq -c '.watch' "$DIG/feat-x.json")"
check "untouched files: no fixups counted" "0" "$(jq '.humanFixCommits' <<<"$w")"
check "untouched files + green CI: clean" "true" "$(jq '.clean' <<<"$w")"

# no CI runs in the window: green is unknowable -> null, clean null (fail-closed)
mk_digest
run_watch '[]' >/dev/null
w="$(jq -c '.watch' "$DIG/feat-x.json")"
check "no CI: branchGreen null" "null" "$(jq '.branchGreen' <<<"$w")"
check "no CI: clean null" "null" "$(jq '.clean' <<<"$w")"

# CI runs outside the window are ignored
mk_digest; mk_pr '["app.txt"]'
run_watch '[{"status":"completed","conclusion":"failure","createdAt":"2026-07-13T01:00:00Z"}]' >/dev/null
check "failure outside window ignored" "null" "$(jq '.watch.branchGreen' "$DIG/feat-x.json")"

# window bound on fixups: commits after the window do not count
mk_digest
EARLY_NOW="$(jq -rn '"2026-07-10T00:30:00Z" | fromdateiso8601')"
printf '%s' "$GREEN" > "$WORK/runs.json"
bash "$SCRIPT" run --slug feat-x --digests "$DIG" --repo-dir "$WORK/repo" \
  --default-branch main --fixture-pr "$WORK/pr.json" --fixture-runs "$WORK/runs.json" \
  --now "$EARLY_NOW" --window-hours 0 >/dev/null
check "zero-hour window counts no fixups" "0" "$(jq '.watch.humanFixCommits' "$DIG/feat-x.json")"

# ── Not merged yet: exit 0, digest untouched ──────────────────────────────────
mk_digest
jq -n '{number:8, url:null, mergedAt:null, mergeCommit:null, files:[]}' > "$WORK/pr-open.json"
ec=0
out="$(bash "$SCRIPT" run --slug feat-x --digests "$DIG" --repo-dir "$WORK/repo" \
  --default-branch main --fixture-pr "$WORK/pr-open.json" --fixture-runs "$WORK/runs.json" \
  --now "$NOW")" || ec=$?
check "unmerged: exit 0" "0" "$ec"
check "unmerged: says nothing to watch" "1" "$(grep -c 'nothing to watch' <<<"$out")"
check "unmerged: digest untouched" "null" "$(jq '.watch // null' "$DIG/feat-x.json")"

# ── Unresolvable merge commit: fixups unknowable -> null ──────────────────────
mk_digest
jq -n '{number:7, url:"u", mergedAt:"2026-07-10T00:00:00Z",
        mergeCommit:"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", files:["app.txt"]}' > "$WORK/pr.json"
run_watch "$GREEN" >/dev/null
w="$(jq -c '.watch' "$DIG/feat-x.json")"
check "unknown oid: fixups null" "null" "$(jq '.humanFixCommits' <<<"$w")"
check "unknown oid: clean not true (fail-closed)" "null" "$(jq '.clean' <<<"$w")"

# ── Branch resolution: digest branch wins, feat/<slug> is the fallback ────────
mk_pr '["app.txt"]'
jq -n '{schema:2, slug:"feat-x", status:"completed", converged:true}' > "$DIG/feat-x.json"
ec=0
run_watch "$GREEN" >/dev/null 2>&1 || ec=$?
check "no branch field: falls back to feat/<slug> and still runs" "0" "$ec"

# ── Bad invocations ───────────────────────────────────────────────────────────
ec=0; bash "$SCRIPT" run --digests "$DIG" >/dev/null 2>&1 || ec=$?
check "missing --slug exits 2" "2" "$ec"
ec=0; bash "$SCRIPT" run --slug no-such --digests "$DIG" --fixture-pr "$WORK/pr.json" >/dev/null 2>&1 || ec=$?
check "missing digest exits 2" "2" "$ec"
ec=0; bash "$SCRIPT" verify >/dev/null 2>&1 || ec=$?
check "unknown subcommand exits 2" "2" "$ec"
ec=0; bash "$SCRIPT" run --slug feat-x --digests "$DIG" --window-hours nope >/dev/null 2>&1 || ec=$?
check "bad window exits 2" "2" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
