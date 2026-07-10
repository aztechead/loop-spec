#!/usr/bin/env bash
# Tests for lib/sentinel-sources.sh (sentinel work-source adapters, ROADMAP-3.0 A1).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/sentinel-sources.sh"
BACKLOG="$REPO_ROOT/lib/backlog.sh"
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

WORK="${TMPDIR:-/tmp}/sentinel-sources-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

# ── list: the seam is enumerable ──────────────────────────────────────────────
out="$(bash "$SCRIPT" list)"
check "list names all four adapters" "gh-issues ci-failures backlog assessment" "$(tr '\n' ' ' <<<"$out" | sed 's/ $//')"

# ── unknown subcommand ────────────────────────────────────────────────────────
ec=0; bash "$SCRIPT" jira >/dev/null 2>&1 || ec=$?
check "unknown adapter exits 2" "2" "$ec"

# ── gh-issues (fixture) ───────────────────────────────────────────────────────
cat > "$WORK/issues.json" << 'EOF'
[
  {"number": 12, "title": "Crash on empty spec", "body": "steps...", "url": "https://github.com/o/r/issues/12",
   "updatedAt": "2026-07-08T12:00:00Z", "labels": [{"name": "loop-spec"}, {"name": "bug"}]},
  {"number": 13, "title": "Add CSV export", "body": "", "url": "https://github.com/o/r/issues/13",
   "updatedAt": "2026-07-01T12:00:00Z", "labels": [{"name": "loop-spec"}, {"name": "enhancement"}]},
  {"number": 14, "title": "Already claimed", "body": "", "url": "https://github.com/o/r/issues/14",
   "updatedAt": "2026-07-08T12:00:00Z", "labels": [{"name": "loop-spec"}, {"name": "loop-spec:in-progress"}]},
  {"number": 15, "title": "Unlabeled kind", "body": "", "url": "https://github.com/o/r/issues/15",
   "updatedAt": "2026-07-08T12:00:00Z", "labels": [{"name": "loop-spec"}]}
]
EOF
out="$(bash "$SCRIPT" gh-issues --fixture "$WORK/issues.json")"
check "gh-issues: lifecycle-labeled skipped" "3" "$(jq 'length' <<<"$out")"
check "gh-issues: id shape" "gh-12" "$(jq -r '.[0].id' <<<"$out")"
check "gh-issues: bug label -> bug" "bug" "$(jq -r '.[] | select(.id=="gh-12") | .kind' <<<"$out")"
check "gh-issues: enhancement -> gap" "gap" "$(jq -r '.[] | select(.id=="gh-13") | .kind' <<<"$out")"
check "gh-issues: no class label -> unknown" "unknown" "$(jq -r '.[] | select(.id=="gh-15") | .kind' <<<"$out")"
check "gh-issues: source stamped" "gh-issues" "$(jq -r '.[0].source' <<<"$out")"
check "gh-issues: url carried" "https://github.com/o/r/issues/12" "$(jq -r '.[] | select(.id=="gh-12") | .url' <<<"$out")"
ec=0; bash "$SCRIPT" gh-issues --fixture "$WORK/missing.json" >/dev/null 2>&1 || ec=$?
check "gh-issues: missing fixture exits 2" "2" "$ec"

# ── ci-failures (fixture) ─────────────────────────────────────────────────────
cat > "$WORK/runs.json" << 'EOF'
[
  {"databaseId": 1, "workflowName": "CI", "displayTitle": "older failure", "url": "https://github.com/o/r/actions/runs/1",
   "updatedAt": "2026-07-01T10:00:00Z", "headBranch": "main"},
  {"databaseId": 2, "workflowName": "CI", "displayTitle": "newest failure", "url": "https://github.com/o/r/actions/runs/2",
   "updatedAt": "2026-07-08T10:00:00Z", "headBranch": "main"},
  {"databaseId": 3, "workflowName": "Release", "displayTitle": "release broke", "url": "https://github.com/o/r/actions/runs/3",
   "updatedAt": "2026-07-07T10:00:00Z", "headBranch": "main"},
  {"databaseId": 4, "workflowName": "CI", "displayTitle": "feature branch failure", "url": "https://github.com/o/r/actions/runs/4",
   "updatedAt": "2026-07-08T11:00:00Z", "headBranch": "feat/x"}
]
EOF
out="$(bash "$SCRIPT" ci-failures --branch main --fixture "$WORK/runs.json")"
check "ci-failures: one item per workflow" "2" "$(jq 'length' <<<"$out")"
check "ci-failures: most recent run wins" "1" "$(jq '[.[] | select(.title | contains("newest failure"))] | length' <<<"$out")"
check "ci-failures: off-branch runs excluded" "0" "$(jq '[.[] | select(.title | contains("feature branch"))] | length' <<<"$out")"
check "ci-failures: kind is always bug" "bug bug" "$(jq -r 'map(.kind) | join(" ")' <<<"$out")"
check "ci-failures: id from workflow name" "1" "$(jq '[.[] | select(.id=="ci-ci")] | length' <<<"$out")"

# ── backlog ───────────────────────────────────────────────────────────────────
export LOOP_SPEC_BACKLOG_FILE="$WORK/BACKLOG.md"
bash "$BACKLOG" add feat-a iterate-gap "close the csv gap" --id "$(bash "$BACKLOG" gap-id "close the csv gap")" >/dev/null
bash "$BACKLOG" add feat-b manual "tidy the docs" >/dev/null
out="$(bash "$SCRIPT" backlog)"
check "backlog: both entries" "2" "$(jq 'length' <<<"$out")"
check "backlog: iterate-gap -> gap" "gap" "$(jq -r '.[0].kind' <<<"$out")"
check "backlog: manual -> chore" "chore" "$(jq -r '.[1].kind' <<<"$out")"
check "backlog: title is entry text" "close the csv gap" "$(jq -r '.[0].title' <<<"$out")"
check "backlog: id prefixed" "backlog-" "$(jq -r '.[0].id' <<<"$out" | cut -c1-8)"
check "backlog: date becomes updatedAt" "true" "$(jq '.[0].updatedAt | test("T00:00:00Z$")' <<<"$out")"
rm -f "$LOOP_SPEC_BACKLOG_FILE"
check "backlog: empty file -> []" "[]" "$(bash "$SCRIPT" backlog)"
unset LOOP_SPEC_BACKLOG_FILE

# ── assessment ────────────────────────────────────────────────────────────────
ASSESS="$WORK/ASSESSMENT.md"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$ASSESS" << EOF
# Codebase Assessment

Generated: $NOW_ISO
Mode: single

## Cross-repo ranked findings

| Rank | Repo | File | Line | Severity | Finding |
|------|------|------|------|----------|---------|
| 1 | repo | src/a.sh | 10 | CRITICAL | unquoted expansion eats args |
| 2 | repo | src/b.sh | 22 | HIGH | exit code swallowed |
| 3 | repo | src/c.sh | 5 | MEDIUM | duplicated parser |
| 4 | repo | src/d.sh | 7 | LOW | stale comment |

## Prioritized fix recommendations
EOF
out="$(bash "$SCRIPT" assessment --file "$ASSESS" --top 3)"
check "assessment: top-N respected" "3" "$(jq 'length' <<<"$out")"
check "assessment: CRITICAL -> bug" "bug" "$(jq -r '.[0].kind' <<<"$out")"
check "assessment: HIGH -> bug" "bug" "$(jq -r '.[1].kind' <<<"$out")"
check "assessment: MEDIUM -> gap" "gap" "$(jq -r '.[2].kind' <<<"$out")"
check "assessment: id stable hash" "assess-" "$(jq -r '.[0].id' <<<"$out" | cut -c1-7)"
check "assessment: title carries location" "true" "$(jq '.[0].title | contains("src/a.sh:10")' <<<"$out")"
# stable id across re-parse
id1="$(jq -r '.[0].id' <<<"$out")"
id2="$(bash "$SCRIPT" assessment --file "$ASSESS" --top 1 | jq -r '.[0].id')"
check "assessment: id deterministic" "$id1" "$id2"

# stale report -> []
sed -i.bak "s/^Generated: .*/Generated: 2020-01-01T00:00:00Z/" "$ASSESS"
check "assessment: stale -> []" "[]" "$(bash "$SCRIPT" assessment --file "$ASSESS")"
check "assessment: stale but wide bound -> items" "4" "$(bash "$SCRIPT" assessment --file "$ASSESS" --max-age-days 99999 | jq 'length')"
check "assessment: missing file -> []" "[]" "$(bash "$SCRIPT" assessment --file "$WORK/nope.md")"

# every adapter emits the same normalized keys
for src_out in "$(bash "$SCRIPT" gh-issues --fixture "$WORK/issues.json")" \
               "$(bash "$SCRIPT" ci-failures --branch main --fixture "$WORK/runs.json")" \
               "$(bash "$SCRIPT" assessment --file "$ASSESS" --max-age-days 99999)"; do
  check "normalized key set" "body id kind source title updatedAt url" \
    "$(jq -r '.[0] | keys | sort | join(" ")' <<<"$src_out")"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
