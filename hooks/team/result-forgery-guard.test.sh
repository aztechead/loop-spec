#!/usr/bin/env bash
# Test suite for hooks/team/result-forgery-guard.sh
# PreToolUse hook (Bash): contract files are written only by their own writers.
# Usage: bash hooks/team/result-forgery-guard.test.sh
set -uo pipefail
HOOK="$(cd "$(dirname "$0")" && pwd)/result-forgery-guard.sh"
WORK="${TMPDIR:-/tmp}/result-forgery-guard-test-$$"
mkdir -p "$WORK/proj/.loop-spec" "$WORK/plain"
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0
check() {
  local name="$1" expected="$2" cmd="$3" dir="${4:-$WORK/proj}" ec=0
  # From the fixture: the hook also reads the working directory, and the plugin's own
  # checkout carries a .loop-spec/ of its own.
  (cd "$dir" && CLAUDE_PROJECT_DIR="$dir" bash "$HOOK" >/dev/null 2>&1 <<<"$(jq -cn --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')") || ec=$?
  if [[ "$ec" -eq "$expected" ]]; then echo "PASS: $name"; ((PASS++)) || true
  else echo "FAIL: $name (expected exit $expected, got $ec)"; ((FAIL++)) || true; fi
}
check "heredoc into last-result.json is denied" 2 $'cat > .loop-spec/last-result.json << \'EOF\'\n{"status":"completed"}\nEOF'
check "jq redirected into feature.json is denied" 2 'jq ".currentPhase=\"deliver\"" f.json > .loop-spec/features/x/feature.json'
check "append to result.json is denied" 2 'echo "{}" >> /abs/path/.loop-spec/features/x/result.json'
check "tee into active-run.json is denied" 2 'printf "{}" | tee .loop-spec/active-run.json'
check "cp over delivery.json is denied" 2 'cp /tmp/d.json .loop-spec/features/x/delivery.json'
check "sed -i on feature.json is denied" 2 'sed -i "s/execute/deliver/" .loop-spec/features/x/feature.json'
check "python open for write is denied" 2 'python3 -c "import json; json.dump({}, open(\".loop-spec/last-result.json\", \"w\"))"'
check "reading the result is allowed" 0 'cat .loop-spec/last-result.json | jq .status'
check "the writer itself is allowed" 0 'bash /plugin/lib/cycle-result.sh write .loop-spec/features/x --status failed --reason "runner died" --summary s'
check "feature-write is allowed" 0 'bash /plugin/lib/feature-write.sh set .loop-spec/features/x currentPhase "\"verify\""'
check "an unrelated redirect is allowed" 0 'python3 -m unittest > /tmp/out.log 2>&1'
check "a project without .loop-spec is untouched" 0 'cat > .loop-spec/last-result.json <<< "{}"' "$WORK/plain"
LOOP_SPEC_FORGERY_GUARD=0 check "kill switch allows" 0 'cat > .loop-spec/last-result.json <<< "{}"'

# The driver-owned artifacts of a feature on the oneshot route: a shell write into
# SPEC.md or VERIFICATION.md is denied, a read or a full-route feature is not
# (port audit 4, N1's remaining writers).
ONE="$WORK/one"; mkdir -p "$ONE/.loop-spec/features/one" "$ONE/docs/loop-spec/features/one" "$ONE/.loop-spec/features/big" "$ONE/docs/loop-spec/features/big"
git -C "$ONE" init -q >/dev/null 2>&1
printf '{"slug":"one","schemaVersion":7}\n' > "$ONE/.loop-spec/features/one/feature.json"
printf '{"slug":"big","schemaVersion":7}\n' > "$ONE/.loop-spec/features/big/feature.json"
printf -- '---\nunresolved_questions: []\nfootprint:\n  - a.py\n---\n# one\n\n## Intent\n\nx\n<!-- /intent -->\n\n## Implementation notes\n\n- a.py: x\n' > "$ONE/docs/loop-spec/features/one/SPEC.md"
printf -- '---\nfootprint: [a.py, b.py, c.py, d.py]\n---\n# big\n\n## Problem\n\nx\n' > "$ONE/docs/loop-spec/features/big/SPEC.md"
check "a redirect into a oneshot feature's SPEC.md is denied" 2 'cat > docs/loop-spec/features/one/SPEC.md <<EOF2
# x
EOF2' "$ONE"
check "sed -i on a oneshot feature's VERIFICATION.md is denied" 2 'sed -i "s/PASS/FAIL/" docs/loop-spec/features/one/VERIFICATION.md' "$ONE"
check "a python open for writing on the artifact is denied" 2 'python3 -c "open(\"docs/loop-spec/features/one/VERIFICATION.md\", \"w\").write(\"x\")"' "$ONE"
check "reading the artifact is allowed" 0 'cat docs/loop-spec/features/one/SPEC.md' "$ONE"
check "a full-route feature's spec is the lead's" 0 'cat > docs/loop-spec/features/big/SPEC.md <<< "# big"' "$ONE"
check "a feature the project does not hold is not this guard's" 0 'cat > docs/loop-spec/features/none/SPEC.md <<< "# x"' "$ONE"
# The same rule as the path hook: an unreadable spec keeps both files the driver's
# (port audit 5, R7 closed the inversion where the shell path opened here).
printf -- '---\nfootprint:\n  - a.py\n# no closing marker\n' > "$ONE/docs/loop-spec/features/one/SPEC.md"
check "an unreadable spec denies the shell write too (fail closed)" 2 'cat > docs/loop-spec/features/one/VERIFICATION.md <<< "# v"' "$ONE"
ec=0; CLAUDE_PROJECT_DIR="$WORK/proj" bash "$HOOK" >/dev/null 2>&1 <<<"not json" || ec=$?
check_m() { [[ "$ec" -eq 0 ]] && { echo "PASS: malformed payload allows"; ((PASS++)) || true; } || { echo "FAIL: malformed payload allows"; ((FAIL++)) || true; }; }; check_m

# task-009: the same driver-owned publication set as hooks/restrict-agent-paths.sh,
# reached by shell instead of the Write tool (feature.json[.bak], tasks.json,
# observations/**, publication-generations/**, migration-generations/** are always
# protected; publication-staging/** stays a maker's; PLAN.md/PATTERNS.md join
# SPEC.md/VERIFICATION.md as driver-owned on the oneshot route).
mkdir -p "$ONE/.loop-spec/features/one/observations/final/deadbeef" \
  "$ONE/.loop-spec/features/one/migration-generations/t1" \
  "$ONE/.loop-spec/features/one/publication-generations" \
  "$ONE/.loop-spec/features/one/publication-staging"
check "a redirect into feature.json.bak is denied" 2 \
  'cat > .loop-spec/features/one/feature.json.bak <<< "{}"' "$ONE"
check "rm of tasks.json is denied" 2 \
  'rm .loop-spec/features/one/tasks.json' "$ONE"
check "tee into an observation record is denied" 2 \
  'printf "{}" | tee .loop-spec/features/one/observations/exec-1.json' "$ONE"
check "cp over a final observation projection is denied" 2 \
  'cp /tmp/v.md .loop-spec/features/one/observations/final/deadbeef/VERIFICATION.md' "$ONE"
check "sed -i on the migration journal is denied" 2 \
  'sed -i "s/x/y/" .loop-spec/features/one/migration-generations/t1/backup.json' "$ONE"
check "patch onto the publication generation journal is denied" 2 \
  'patch .loop-spec/features/one/publication-generations/active.json < x.diff' "$ONE"
check "git apply onto the publication generation journal is denied" 2 \
  'git apply --include=.loop-spec/features/one/publication-generations/active.json x.diff' "$ONE"
check "a redirect into staged publication content is allowed" 0 \
  'cat > .loop-spec/features/one/publication-staging/spec-abc.md <<< "# x"' "$ONE"
check "a redirect into a oneshot feature's PLAN.md is denied" 2 \
  'cat > docs/loop-spec/features/one/PLAN.md <<< "# x"' "$ONE"
check "a redirect into a oneshot feature's PATTERNS.md is denied" 2 \
  'cat > docs/loop-spec/features/one/PATTERNS.md <<< "# x"' "$ONE"
check "a full-route feature's PLAN.md stays the lead's" 0 \
  'cat > docs/loop-spec/features/big/PLAN.md <<< "# big"' "$ONE"

# Security hardening: a shell write through a symlink whose LITERAL name is
# nothing protected (the redirection target text a regex could ever match) but
# that RESOLVES into a protected artifact must still be denied -- the second
# "candidate" trigger resolves every match under a feature's tree with realpath
# before handing it to lib/harness.sh protected-path, so the resolved location
# is judged, not the literal staged-looking name.
ln -s "$ONE/docs/loop-spec/features/one/SPEC.md" "$ONE/.loop-spec/features/one/publication-staging/sneaky.md"
check "a shell write through a staging symlink resolving to the protected SPEC.md is denied" 2 \
  'cat > .loop-spec/features/one/publication-staging/sneaky.md <<< "# x"' "$ONE"
check "a plain (non-symlink) staging file stays allowed" 0 \
  'cat > .loop-spec/features/one/publication-staging/plain.md <<< "# x"' "$ONE"
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
