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
check "lib rows are all lib paths" "0" \
  "$(awk -F'\t' '$2 !~ /^lib\// {n++} END {print n+0}' <<<"$lib_rows")"
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
missing=0
while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  grep -qF "$rel" <<<"$lib_rows" || { echo "  uncovered: $rel"; missing=$((missing + 1)); }
done < <(find "$ROOT/lib" -maxdepth 2 -name '*.sh' -not -name '*.test.sh' | sort)
check "every non-test lib script is indexed" "0" "$missing"

missing=0
while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  grep -qF "$rel" <<<"$shared_rows" || { echo "  uncovered: $rel"; missing=$((missing + 1)); }
done < <(find "$ROOT/skills/shared" -maxdepth 1 -name '*.md' | sort)
check "every shared contract is indexed" "0" "$missing"

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
  stem="${base%.*}"
  words="$(wc -w <<<"$text" | tr -d ' ')"
  if [[ "$words" -lt 4 ]] || [[ "${text,,}" == "${stem,,}" ]]; then
    echo "  thin purpose: $path -> '$text'"
    short=$((short + 1))
  fi
done <<<"$all_rows"
check "every indexed file carries a real purpose line" "0" "$short"

# --- find ---
check "find narrows to matching entries" "lib/security-signal.sh" \
  "$(bash "$SCRIPT" find security-signal | cut -f2)"
# `worktree` and `security` each match entries; nothing matches both, so requiring
# every term is the difference between one hit and an honest miss.
rc=0; bash "$SCRIPT" find worktree security >/dev/null 2>&1 || rc=$?
check "find requires EVERY term, not any" "1" "$rc"
rc=0; bash "$SCRIPT" find zzz-no-such-thing >/dev/null 2>&1 || rc=$?
check "an unmatched query exits 1, not 0" "1" "$rc"
check "find is case-insensitive" "lib/security-signal.sh" \
  "$(bash "$SCRIPT" find SECURITY-SIGNAL | cut -f2)"
check "find matches purpose text, not only paths" "1" \
  "$(bash "$SCRIPT" find 'destructive-change' | grep -c 'security-signal')"

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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
