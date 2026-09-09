#!/usr/bin/env bash
# Tests for lib/feature-read.sh, the one typed reader of feature.json.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
READ="$ROOT/lib/feature-read.sh"
PASS=0; FAIL=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then echo "PASS: $name"; PASS=$((PASS+1))
  else echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL+1)); fi
}
WORK="$(mktemp -d "${TMPDIR:-/tmp}/feature-read-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FD="$WORK/feature"; mkdir -p "$FD"
cat > "$FD/feature.json" <<'JSON'
{"slug":"my-feature","artifacts":{"spec":"docs/SPEC.md","plan":null},
 "iterate":{"used":2,"feedback":{"type":"verify"},"history":[{"round":1},{"round":2}]},
 "workspace":{"repos":[{"name":"api","path":"api"}]},"warnings":[],"greenfield":false}
JSON

check "a string key reads as JSON" '"my-feature"' "$(bash "$READ" "$FD" slug)"
check "-r prints a string bare" "my-feature" "$(bash "$READ" "$FD" slug -r)"
check "a dotted path descends" "docs/SPEC.md" "$(bash "$READ" "$FD" artifacts.spec -r)"
check "an absent path is null" "null" "$(bash "$READ" "$FD" artifacts.tasks)"
check "a null value is null" "null" "$(bash "$READ" "$FD" artifacts.plan)"
check "-r prints null as nothing" "" "$(bash "$READ" "$FD" artifacts.plan -r)"
check "--default fills an absent path" '""' "$(bash "$READ" "$FD" artifacts.tasks --default '""')"
check "--default fills a null value under -r" "docs/PLAN.md" "$(bash "$READ" "$FD" artifacts.plan -r --default '"docs/PLAN.md"')"
check "a number reads as JSON" "2" "$(bash "$READ" "$FD" iterate.used)"
check "a boolean under -r is JSON" "false" "$(bash "$READ" "$FD" greenfield -r)"
check "an object reads compact" '{"type":"verify"}' "$(bash "$READ" "$FD" iterate.feedback)"
check "an array index descends" '{"round":2}' "$(bash "$READ" "$FD" 'iterate.history[1]')"
check "an index past the end is null" "null" "$(bash "$READ" "$FD" 'iterate.history[5]')"
check "a path through an array to a field" "api" "$(bash "$READ" "$FD" 'workspace.repos[0].name' -r)"
check "an empty array reads as []" "[]" "$(bash "$READ" "$FD" warnings)"
check "a path crossing a scalar is null" "null" "$(bash "$READ" "$FD" slug.nope)"
check "the feature.json path itself is accepted" "my-feature" "$(bash "$READ" "$FD/feature.json" slug -r)"

check "--jq shapes the value" "api" "$(bash "$READ" "$FD" workspace --jq '.repos[].path' -r)"
check "--jq sees null for an absent key" "none" "$(bash "$READ" "$FD" delivery --jq '.status // "none"' -r)"
check "--jq without -r prints compact JSON" '["api"]' "$(bash "$READ" "$FD" workspace --jq '[.repos[].name]')"
check "--jq and --default compose" "main" "$(bash "$READ" "$FD" baseBranch --default '"main"' --jq '. ' -r)"
ec=0; bash "$READ" "$FD" workspace --jq '.repos[' >/dev/null 2>&1 || ec=$?
check "a bad --jq filter is exit 1" "1" "$ec"
# --filter: the old readers' whole-document filters, typed at the root.
check "--filter reads a root key" "my-feature" "$(bash "$READ" "$FD" -r --filter '.slug')"
check "--filter with a default" "" "$(bash "$READ" "$FD" -r --filter '.artifacts.plan // empty')"
check "--filter reads two roots" "my-feature docs/SPEC.md" "$(bash "$READ" "$FD" -r --filter '.slug + " " + .artifacts.spec')"
check "--filter with a conditional over a root" "null" "$(bash "$READ" "$FD" -r --filter 'if (.workspace != null and (.workspace.mode // "") != "single") then .workspace.root else "none" end')"
check "--filter -c prints compact JSON" '[{"name":"api","path":"api"}]' "$(bash "$READ" "$FD" -c --filter '[.workspace.repos[]]')"
check "--filter: a field after a pipe is not a root" "2" "$(bash "$READ" "$FD" -r --filter '[.iterate.history[] | select(.round > 0)] | length')"
check "--filter with --arg after --" "verify" "$(bash "$READ" "$FD" -r --filter '.iterate.feedback[$k]' -- --arg k type)"
ec=0; bash "$READ" "$FD" -e --filter '.artifacts.plan' >/dev/null 2>&1 || ec=$?
check "--filter -e relays jq's exit 1 on null" "1" "$ec"
ec=0; bash "$READ" "$FD" -e --filter '.slug' >/dev/null 2>&1 || ec=$?
check "--filter -e is 0 on a value" "0" "$ec"
ec=0; out="$(bash "$READ" "$FD" -r --filter '.nope // "x"' 2>&1)" || ec=$?
check "--filter: a root outside the enum is exit 1" "1" "$ec"
check "--filter: the message names the key and the filter" "1" "$(grep -c "'nope' in filter '.nope // \"x\"' is not a feature.json state key" <<<"$out")"
ec=0; bash "$READ" "$FD" -r --filter 'has("slug")' >/dev/null 2>&1 || ec=$?
check "--filter naming no key is exit 1" "1" "$ec"
check "--filter never sees keys it did not name" "false" "$(bash "$READ" "$FD" -r --filter '.slug | length > 0 | not')" 
ec=0; bash "$READ" "$WORK/none" -r --filter '.slug' >/dev/null 2>&1 || ec=$?
check "--filter on a missing feature.json is exit 2" "2" "$ec"
ec=0; out="$(bash "$READ" "$FD" -r --filter '.slug | ' 2>&1)" || ec=$?
check "--filter relays a jq compile error as non-zero" "1" "$([[ $ec -ne 0 ]] && echo 1 || echo 0)"
ec=0; out="$(bash "$READ" "$FD" nope 2>&1)" || ec=$?
check "a key outside the enum is exit 1" "1" "$ec"
check "the message names the enum" "1" "$(grep -c "not a feature.json state key (graph/schema.json stateKey: schemaVersion, slug" <<<"$out")"
ec=0; bash "$READ" "$FD" 'slug;rm' >/dev/null 2>&1 || ec=$?
check "a malformed path is exit 1" "1" "$ec"
ec=0; bash "$READ" "$WORK/none" slug >/dev/null 2>&1 || ec=$?
check "a missing feature.json is exit 2" "2" "$ec"
printf 'not json' > "$WORK/bad.json"; mkdir -p "$WORK/badfd"; cp "$WORK/bad.json" "$WORK/badfd/feature.json"
ec=0; bash "$READ" "$WORK/badfd" slug >/dev/null 2>&1 || ec=$?
check "an unparseable feature.json is exit 2" "2" "$ec"
ec=0; bash "$READ" "$FD" >/dev/null 2>&1 || ec=$?
check "a missing key argument is exit 1" "1" "$ec"
ec=0; bash "$READ" "$FD" slug --default '{' >/dev/null 2>&1 || ec=$?
check "a non-JSON default is exit 1" "1" "$ec"

printf '{"slug":"s","stray":1,"warnings":[]}' > "$WORK/badfd/feature.json"
check "--all projects the document onto the enum" '{"slug":"s","warnings":[]}' "$(bash "$READ" "$WORK/badfd" --all)"
check "--strays is the complement" '{"stray":1}' "$(bash "$READ" "$WORK/badfd" --strays)"
ec=0; bash "$READ" "$WORK/none" --all >/dev/null 2>&1 || ec=$?
check "--all on a missing feature.json is exit 2" "2" "$ec"

# The key space is the schema's, read at call time, and it covers everything the
# skeleton seeds and the documented v7 key space.
keys="$(bash "$READ" --keys)"
check "--keys lists the enum" "$(jq -r '.definitions.stateKey.enum | length' "$ROOT/graph/schema.json")" "$(wc -l <<<"$keys" | tr -d ' ')"
skeleton="$(bash "$ROOT/lib/feature-init.sh" skeleton --mode single --slug s --now 1970-01-01T00:00:00Z --style auto \
  --title s --branch b --base-sha 0000000000000000000000000000000000000000 --base-branch main \
  --worktree "" --prepare "" --test "" --lint "" --typecheck "" 2>/dev/null | jq -r 'keys[]')"
missing=""
while IFS= read -r k; do grep -qx "$k" <<<"$keys" || missing="$missing $k"; done <<<"$skeleton"
check "every skeleton key is a state key" "" "$missing"
doc_keys="$(python3 - "$ROOT/skills/shared/feature-state-schema.md" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
start = next(i for i, l in enumerate(lines) if l.startswith("```json"))
end = next(i for i, l in enumerate(lines) if i > start and l.startswith("```"))
for l in lines[start + 1:end]:
    m = re.match(r'^  "([A-Za-z_][A-Za-z0-9_]*)":', l)
    if m: print(m.group(1))
PY
)"
missing=""
while IFS= read -r k; do grep -qx "$k" <<<"$keys" || missing="$missing $k"; done <<<"$doc_keys"
check "every documented v7 key is a state key" "" "$missing"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
