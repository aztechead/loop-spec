#!/usr/bin/env bash
# Test suite for restrict-agent-paths.sh
# Tests the PreToolUse hook that restricts Write/Edit paths per subagent_type.
# Usage: bash hooks/restrict-agent-paths.test.sh
set -euo pipefail

HOOK="$(dirname "$0")/restrict-agent-paths.sh"
FIXTURES="$(dirname "$0")/../tests/fixtures/probe-transcripts"
PASS=0
FAIL=0

# Tests run outside an active cycle; bypass the no-feature-state fast path.
export SUPER_SPEC_PATH_GUARD_FORCE=1

check() {
  local name="$1"
  local expected_exit="$2"
  local payload="$3"
  local actual_exit=0

  echo "$payload" | bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?

  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"
    ((FAIL++)) || true
  fi
}

# Helper: build a JSON payload
payload() {
  local tool_name="$1"
  local file_path="$2"
  local transcript_path="$3"
  printf '{"tool_name":"%s","tool_input":{"file_path":"%s"},"transcript_path":"%s"}' \
    "$tool_name" "$file_path" "$transcript_path"
}

echo "=== restrict-agent-paths.sh tests ==="

# Case A: spec-writer Write to allowed features path -> ALLOW (exit 0)
check "A: spec-writer Write to docs/super-spec/features/foo/SPEC.md ALLOW" 0 \
  "$(payload "Write" "docs/super-spec/features/foo/SPEC.md" "$FIXTURES/spec-writer.jsonl")"

# Case B: spec-writer Write to disallowed path -> DENY (exit 2)
check "B: spec-writer Write to src/foo.py DENY" 2 \
  "$(payload "Write" "src/foo.py" "$FIXTURES/spec-writer.jsonl")"

# Case C: planner Edit to allowed features path -> ALLOW (exit 0)
check "C: planner Edit to docs/super-spec/features/foo/PLAN.md ALLOW" 0 \
  "$(payload "Edit" "docs/super-spec/features/foo/PLAN.md" "$FIXTURES/planner.jsonl")"

# Case D: mapper-tech Write to allowed codebase path -> ALLOW (exit 0)
check "D: mapper-tech Write to docs/super-spec/codebase/TECH.md ALLOW" 0 \
  "$(payload "Write" "docs/super-spec/codebase/TECH.md" "$FIXTURES/mapper-tech.jsonl")"

# Case E: mapper-arch Write to disallowed path -> DENY (exit 2)
check "E: mapper-arch Write to src/foo.py DENY" 2 \
  "$(payload "Write" "src/foo.py" "$FIXTURES/mapper-arch.jsonl")"

# Case F: implementer Write to any path -> ALLOW (exit 0)
check "F: implementer Write to src/foo.py ALLOW" 0 \
  "$(payload "Write" "src/foo.py" "$FIXTURES/implementer.jsonl")"

# Case G: main thread (no subagent_type) Write anywhere -> ALLOW (exit 0)
check "G: main thread Write to src/foo.py ALLOW" 0 \
  "$(payload "Write" "src/foo.py" "$FIXTURES/main-thread.jsonl")"

# Case H: non-Write/Edit tool (Bash) -> always ALLOW (exit 0)
check "H: Bash tool not restricted ALLOW" 0 \
  "$(payload "Bash" "src/foo.py" "$FIXTURES/spec-writer.jsonl")"

# Case I: spec-writer with absolute path to allowed location -> ALLOW (exit 0)
check "I: spec-writer Write to /abs/path/docs/super-spec/features/bar/SPEC.md ALLOW" 0 \
  "$(payload "Write" "/abs/path/docs/super-spec/features/bar/SPEC.md" "$FIXTURES/spec-writer.jsonl")"

# Case J: mapper-arch Edit to absolute allowed codebase path -> ALLOW (exit 0)
check "J: mapper-arch Edit to /abs/docs/super-spec/codebase/MAP.md ALLOW" 0 \
  "$(payload "Edit" "/abs/docs/super-spec/codebase/MAP.md" "$FIXTURES/mapper-arch.jsonl")"

# Case K: pattern-mapper Write to allowed features path -> ALLOW (exit 0)
check "K: pattern-mapper Write to docs/super-spec/features/foo/PATTERNS.md ALLOW" 0 \
  "$(payload "Write" "docs/super-spec/features/foo/PATTERNS.md" "$FIXTURES/pattern-mapper.jsonl")"

# Case L: pattern-mapper Write to disallowed path -> DENY (exit 2)
check "L: pattern-mapper Write to src/foo.py DENY" 2 \
  "$(payload "Write" "src/foo.py" "$FIXTURES/pattern-mapper.jsonl")"

# Case M: dispatch FINISHED (tool_result received) -> main thread, ALLOW anywhere
check "M: finished spec-writer dispatch does not restrict main thread ALLOW" 0 \
  "$(payload "Write" "src/foo.py" "$FIXTURES/finished-dispatch.jsonl")"

# Case N: malformed payload -> fail-open ALLOW (exit 0, never a hook error)
actual_exit=0
echo 'not json' | bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
if [[ "$actual_exit" -eq 0 ]]; then
  echo "PASS: N: malformed payload fail-open ALLOW"
  ((PASS++)) || true
else
  echo "FAIL: N: malformed payload fail-open ALLOW (got $actual_exit)"
  ((FAIL++)) || true
fi

# Case O: missing transcript file -> fail-open ALLOW
check "O: nonexistent transcript path ALLOW" 0 \
  "$(payload "Write" "src/foo.py" "/nonexistent/transcript.jsonl")"

# Case P: kill switch SUPER_SPEC_PATH_GUARD=0 -> ALLOW even for restricted caller
actual_exit=0
echo "$(payload "Write" "src/foo.py" "$FIXTURES/spec-writer.jsonl")" \
  | SUPER_SPEC_PATH_GUARD=0 bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
if [[ "$actual_exit" -eq 0 ]]; then
  echo "PASS: P: kill switch ALLOW"
  ((PASS++)) || true
else
  echo "FAIL: P: kill switch ALLOW (got $actual_exit)"
  ((FAIL++)) || true
fi

# Case Q: fast path — no .super-spec/features and no force flag -> ALLOW without parsing
HOOK_ABS="$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")"
actual_exit=0
echo "$(payload "Write" "src/foo.py" "$FIXTURES/spec-writer.jsonl")" \
  | env -u SUPER_SPEC_PATH_GUARD_FORCE CLAUDE_PROJECT_DIR=/nonexistent bash -c "cd /tmp && bash '$HOOK_ABS'" >/dev/null 2>&1 || actual_exit=$?
if [[ "$actual_exit" -eq 0 ]]; then
  echo "PASS: Q: no-feature-state fast path ALLOW"
  ((PASS++)) || true
else
  echo "FAIL: Q: no-feature-state fast path ALLOW (got $actual_exit)"
  ((FAIL++)) || true
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
