#!/usr/bin/env bash
# dispatch-read-set.test.sh - The bytes a fresh dispatch reads before it can act stay
# under a ceiling, like the test wall clock in run-all.sh.
#
# Why: every implementer and reviewer dispatch starts from zero and reads its agent
# file plus every contract it cites, on every task and every rework attempt. The
# 6.5.0 cycle here paid that for 12 tasks, twice each. The ceilings sit within 5% of
# the 6.9.0 measurement; a red run is a finding to fix (cut, cite a section, or move
# a rule into the brief), never a number to raise.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
check() {
  local name="$1" ceiling="$2" actual="$3"
  if (( actual <= ceiling )); then echo "PASS: $name ($actual <= $ceiling bytes)"; ((PASS++)) || true
  else echo "FAIL: $name ($actual > $ceiling bytes)"; ((FAIL++)) || true; fi
}
# The shared docs a document names, by basename, summed with the document itself.
read_set() {
  local doc="$1" total; total=$(wc -c < "$doc")
  for name in $(grep -oE 'shared/[a-z0-9-]+\.md' "$doc" | sed 's#shared/##' | sort -u); do
    [[ -f "$ROOT/skills/shared/$name" ]] && total=$((total + $(wc -c < "$ROOT/skills/shared/$name")))
  done
  echo "$total"
}
# The subagent rung's implementer reads the brief plus ONE rendered contracts file
# (`lib/dispatch-files.sh brief`), selected by the task's file types. The stanza that
# opens every prompt must name only that file: the 6.5.0 stanza listed eight
# `skills/shared/` paths and the agent opened each one on every dispatch.
stanza="$(awk '/^## Implementer contract stanza/{f=1} /^## Implementer Agent prompt/{f=0} f' "$ROOT/skills/shared/execute-subagent.md")"
if grep -qF '${LOOP_SPEC_SKILL_DIR}/../../skills/shared/' <<<"$stanza"; then
  echo "FAIL: the stanza orders a read of a skills/shared source; name only the rendered file"; ((FAIL++)) || true
else
  echo "PASS: the stanza orders no read of a skills/shared source"; ((PASS++)) || true
fi
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/f"
cat > "$WORK/f/tasks.json" <<'EOF'
[{"id":"code","subject":"code and tests","files":["lib/x.sh","tests/lib/x.test.sh"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["a"]},
 {"id":"docs","subject":"docs only","files":["README.md"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["b"]}]
EOF
rendered() {
  local id="$1" brief
  brief="$(bash "$ROOT/lib/dispatch-files.sh" brief --feature-dir "$WORK/f" --task-id "$id")"
  echo $(( $(wc -c < "$brief") + $(wc -c < "$WORK/f/dispatch/$id-contracts.md") ))
}
check "subagent-rung read set: code task with tests" 45056 "$(rendered code)"
check "subagent-rung read set: docs-only task" 31232 "$(rendered docs)"
check "agents/implementer.md + cites" 77824 "$(read_set "$ROOT/agents/implementer.md")"
check "agents/code-reviewer.md + cites" 79872 "$(read_set "$ROOT/agents/code-reviewer.md")"
check "agents/spec-writer.md + cites" 53248 "$(read_set "$ROOT/agents/spec-writer.md")"
check "agents/planner.md + cites" 49152 "$(read_set "$ROOT/agents/planner.md")"
echo "Results: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
