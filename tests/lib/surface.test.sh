#!/usr/bin/env bash
# Tests for lib/surface.sh -- the derived index over bundled scripts and contracts.
#
# Two jobs. The query cases check the tool. The coverage cases check the TREE: every
# bundled script and shared contract must carry a header purpose line the index can
# read, because a file whose header says nothing is a file the next agent finds only by
# opening it. That is the convention CLAUDE.md already names ("file-header purpose
# blocks") with nothing enforcing it until now.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/surface.sh"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

# --- invocation contract ---
rc=0; bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
check "no subcommand is a bad invocation" "2" "$rc"
rc=0; bash "$SCRIPT" bogus >/dev/null 2>&1 || rc=$?
check "an unknown subcommand is a bad invocation" "2" "$rc"
rc=0; bash "$SCRIPT" list nonsense >/dev/null 2>&1 || rc=$?
check "an unknown list scope is a bad invocation" "2" "$rc"
rc=0; bash "$SCRIPT" find >/dev/null 2>&1 || rc=$?
check "find with no term is a bad invocation" "2" "$rc"

# --- list ---
lib_rows="$(bash "$SCRIPT" list lib)"
shared_rows="$(bash "$SCRIPT" list shared)"
agent_rows="$(bash "$SCRIPT" list agent)"
all_rows="$(bash "$SCRIPT" list all)"
check "list all is every kind" \
  "$(( $(wc -l <<<"$lib_rows") + $(wc -l <<<"$shared_rows") + $(wc -l <<<"$agent_rows") ))" \
  "$(wc -l <<<"$all_rows")"
check "list defaults to all" "$(wc -l <<<"$all_rows")" "$(bash "$SCRIPT" list | wc -l)"
check "every row is kind<TAB>path<TAB>purpose" "0" \
  "$(awk -F'\t' 'NF != 3 {n++} END {print n+0}' <<<"$all_rows")"
check "lib rows are all script paths" "0" \
  "$(awk -F'\t' '$2 !~ /^(lib|hooks)\// {n++} END {print n+0}' <<<"$lib_rows")"
check "shared rows are all shared contracts" "0" \
  "$(awk -F'\t' '$2 !~ /^skills\/shared\/.*\.md$/ {n++} END {print n+0}' <<<"$shared_rows")"
check "agent rows are all role charters" "0" \
  "$(awk -F'\t' '$2 !~ /^agents\/.*\.md$/ {n++} END {print n+0}' <<<"$agent_rows")"
check "the agents directory README is not a role" "0" \
  "$(grep -c 'agents/README.md' <<<"$agent_rows" || true)"
# An agent's purpose is its frontmatter description -- the same text the harness routes on.
check "an agent purpose comes from its frontmatter description" "1" \
  "$(bash "$SCRIPT" find code-reviewer | grep -c 'Quality + security review')"

# The index is derived, never stored: nothing is written and no artifact is left behind.
before="$(git -C "$ROOT" status --porcelain | sort)"
bash "$SCRIPT" list >/dev/null
bash "$SCRIPT" find worktree >/dev/null || true
check "querying the index writes nothing" "$before" "$(git -C "$ROOT" status --porcelain | sort)"

# --- coverage: the tool sees the whole surface ---
# Swept from the TREE, not from the directories the index happens to walk: a sweep
# tuned to the indexed set cannot catch a directory the index omits, which is how
# lib/graph/probes/ and hooks/ were missing from a tool documented as covering "any
# bundled script".
missing=0
while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  grep -qF "$rel" <<<"$lib_rows" || { echo "  uncovered: $rel"; missing=$((missing + 1)); }
done < <(find "$ROOT/lib" "$ROOT/hooks" -name '*.sh' -not -name '*.test.sh' | sort)
check "every non-test lib and hook script is indexed" "0" "$missing"

missing=0
while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  grep -qF "$rel" <<<"$shared_rows" || { echo "  uncovered: $rel"; missing=$((missing + 1)); }
done < <(find "$ROOT/skills/shared" -maxdepth 1 -name '*.md' | sort)
check "every shared contract is indexed" "0" "$missing"

# Named explicitly because both were absent from a tool documented as covering "any
# bundled script", and neither is in the directory a reader would check first.
check "graph route probes are part of the surface" "1" \
  "$(bash "$SCRIPT" find human-gate | grep -c 'lib/graph/probes/human-gate.sh')"
check "hooks are part of the surface" "1" \
  "$(bash "$SCRIPT" find restrict-agent-paths | grep -c 'hooks/restrict-agent-paths.sh')"

missing=0
while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  [[ "$rel" == "agents/README.md" ]] && continue
  grep -qF "$rel" <<<"$agent_rows" || { echo "  uncovered: $rel"; missing=$((missing + 1)); }
done < <(find "$ROOT/agents" -maxdepth 1 -name '*.md' | sort)
check "every agent charter is indexed" "0" "$missing"

check "a test file is not part of the callable surface" "0" \
  "$(grep -c '\.test\.sh' <<<"$all_rows" || true)"

# --- coverage: every header actually SAYS something ---
# A purpose that is empty, that only repeats the filename, or that is a bare usage line
# leaves the reader exactly where they started.
short=0
while IFS=$'\t' read -r _kind path text; do
  base="$(basename "$path")"
  stem="$(tr '[:upper:]' '[:lower:]' <<<"${base%.*}")"
  words="$(wc -w <<<"$text" | tr -d ' ')"
  if [[ "$words" -lt 4 ]] || [[ "$(tr '[:upper:]' '[:lower:]' <<<"$text")" == "$stem" ]]; then
    echo "  thin purpose: $path -> '$text'"
    short=$((short + 1))
  fi
done <<<"$all_rows"
check "every indexed file carries a real purpose line" "0" "$short"

# --- find ---
# The probe wrapper's purpose names security-signal.sh too, so the term legitimately
# matches both -- assert the hit is present, not that it is alone.
found="$(bash "$SCRIPT" find security-signal | cut -f2)"
check "find narrows to matching entries" "1" "$(grep -cx 'lib/security-signal.sh' <<<"$found")"
check "find does not return the whole index" "1" \
  "$([[ "$(wc -l <<<"$found")" -lt "$(wc -l <<<"$all_rows")" ]] && echo 1 || echo 0)"
# `worktree` and `security` each match entries; nothing matches both, so requiring
# every term is the difference between one hit and an honest miss.
rc=0; bash "$SCRIPT" find worktree security >/dev/null 2>&1 || rc=$?
check "find requires EVERY term, not any" "1" "$rc"
rc=0; bash "$SCRIPT" find zzz-no-such-thing >/dev/null 2>&1 || rc=$?
check "an unmatched query exits 1, not 0" "1" "$rc"
check "find is case-insensitive" "$found" "$(bash "$SCRIPT" find SECURITY-SIGNAL | cut -f2)"
# `destructive-change` appears in a purpose line, never in a path.
check "find matches purpose text, not only paths" "1" \
  "$(bash "$SCRIPT" find 'destructive-change' | cut -f2 | grep -cx 'lib/security-signal.sh')"

# --- show: the header block, so exit codes are one call away ---
shown="$(bash "$SCRIPT" show ralph-remediation)"
check "show resolves a bare name" "lib/ralph-remediation.sh" "$(head -1 <<<"$shown")"
check "show prints the exit-code contract" "1" "$(grep -c 'Exit codes' <<<"$shown")"
check "show resolves a full path" "lib/ralph-remediation.sh" \
  "$(bash "$SCRIPT" show lib/ralph-remediation.sh | head -1)"
check "show resolves a shared contract" "skills/shared/dispatch-events.md" \
  "$(bash "$SCRIPT" show dispatch-events | head -1)"
rc=0; bash "$SCRIPT" show no-such-script >/dev/null 2>&1 || rc=$?
check "show of an unknown name exits 1" "1" "$rc"
rc=0; bash "$SCRIPT" show a b >/dev/null 2>&1 || rc=$?
check "show takes exactly one name" "2" "$rc"

# show stops at the header: it is a summary, never the whole file.
check "show stops at the end of the header block" "0" \
  "$(grep -c '^  set -euo' <<<"$(bash "$SCRIPT" show security-signal)" || true)"
check "show of an agent prints its frontmatter, including the tool allow-list" "1" \
  "$(bash "$SCRIPT" show code-reviewer | grep -c 'tools:')"

# --- covers: which registered suites pin this path ---
rc=0; bash "$SCRIPT" covers >/dev/null 2>&1 || rc=$?
check "covers with no path is a bad invocation" "2" "$rc"
check "covers names the file's own unit suite" "1" \
  "$(bash "$SCRIPT" covers lib/security-signal.sh | grep -c 'tests/lib/security-signal.test.sh')"
check "covers names a coupling pin in another suite" "1" \
  "$(bash "$SCRIPT" covers lib/security-signal.sh | grep -c 'tests/lib/graph-probes.test.sh')"
check "covers resolves a bare name through the index" \
  "$(bash "$SCRIPT" covers lib/security-signal.sh)" "$(bash "$SCRIPT" covers security-signal)"
# A basename under a DIFFERENT directory is a different file: `core/engine.py` in a
# fixture is not coverage of `lib/graph/engine.py`.
check "covers does not match a basename under another directory" "0" \
  "$(bash "$SCRIPT" covers lib/graph/engine.py | grep -c 'quality-loop-state')"
# The COVERING suite (column 3) is never the target itself; the target naturally
# appears in column 2 of every row.
check "a suite never covers itself" "0" \
  "$(bash "$SCRIPT" covers tests/lib/surface.test.sh 2>/dev/null \
     | awk -F'\t' '$3 == "tests/lib/surface.test.sh"' | wc -l | tr -d ' ')"
# A path no suite names is an honest miss, not an empty success. The probe path is
# built at runtime so this file does not itself become the thing that names it.
unpinned="lib/$(printf 'zz-unpinned-%s.sh' "$$")"
rc=0; bash "$SCRIPT" covers "$unpinned" >/dev/null 2>&1 || rc=$?
check "covers of an unpinned path exits 1" "1" "$rc"

# --- review findings, pinned so they cannot come back ---

# `covers` must read the suites run-all.sh REGISTERS, not the files under tests/:
# a quarter of them live elsewhere, and the ones that do were reported as unpinned.
check "covers finds a registered suite outside tests/" "1" \
  "$(bash "$SCRIPT" covers lib/pause-snapshot.sh | grep -c 'lib/pause-snapshot.test.sh')"
check "covers finds a hooks suite" "1" \
  "$(bash "$SCRIPT" covers hooks/team/no-worktrees-guard.sh | grep -c 'hooks/team/no-worktrees-guard.test.sh')"

# A file's own sibling unit suite must never be displaced by an incidental mention.
check "covers names the sibling unit suite" "1" \
  "$(bash "$SCRIPT" covers lib/ralph-remediation.sh | grep -c 'lib/ralph-remediation.test.sh')"

# One unanswered target is a miss even when another target matched: a silent 0 would
# tell the caller every path they asked about is pinned.
rc=0; bash "$SCRIPT" covers lib/security-signal.sh "lib/zz-unpinned-$$.sh" >/dev/null 2>&1 || rc=$?
check "a partly unanswered covers query exits 1" "1" "$rc"

# A basename two files share must not silently answer for one of them.
rc=0; bash "$SCRIPT" covers checkpoint >/dev/null 2>&1 || rc=$?
check "an ambiguous bare name is a bad invocation, not a guess" "2" "$rc"
check "the ambiguous answer names every candidate" "1" \
  "$(bash "$SCRIPT" covers checkpoint 2>&1 >/dev/null | grep -c 'lib/graph/checkpoint.sh')"
rc=0; bash "$SCRIPT" show checkpoint >/dev/null 2>&1 || rc=$?
check "show refuses an ambiguous bare name too" "2" "$rc"

# A script with no header block has NO purpose. Taking some later column-0 comment
# instead would let the header enforcement above pass on exactly what it must catch.
HEADERLESS="$ROOT/lib/zz-surface-headerless-$$.sh"
trap 'rm -f "$HEADERLESS"' EXIT
printf '#!/usr/bin/env bash\nset -euo pipefail\n# a later comment that is not a header\necho hi\n' \
  > "$HEADERLESS"
check "a headerless script reports no purpose" "" \
  "$(bash "$SCRIPT" list lib | awk -F'\t' -v p="lib/$(basename "$HEADERLESS")" '$2 == p {print $3}')"
rm -f "$HEADERLESS"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
