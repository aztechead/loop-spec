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
export LOOP_SPEC_PATH_GUARD_FORCE=1

check() {
  local name="$1"
  local expected_exit="$2"
  local payload="$3"
  local actual_exit=0

  bash "$HOOK" >/dev/null 2>&1 <<<"$payload" || actual_exit=$?

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
check "A: spec-writer Write to docs/loop-spec/features/foo/SPEC.md ALLOW" 0 \
  "$(payload "Write" "docs/loop-spec/features/foo/SPEC.md" "$FIXTURES/spec-writer.jsonl")"

# Case B: spec-writer Write to disallowed path -> DENY (exit 2)
check "B: spec-writer Write to src/foo.py DENY" 2 \
  "$(payload "Write" "src/foo.py" "$FIXTURES/spec-writer.jsonl")"

# Case C: planner Edit to allowed features path -> ALLOW (exit 0)
check "C: planner Edit to docs/loop-spec/features/foo/PLAN.md ALLOW" 0 \
  "$(payload "Edit" "docs/loop-spec/features/foo/PLAN.md" "$FIXTURES/planner.jsonl")"

# Case F: implementer Write to any path -> ALLOW (exit 0)
check "F: implementer Write to src/foo.py ALLOW" 0 \
  "$(payload "Write" "src/foo.py" "$FIXTURES/implementer.jsonl")"

# Case G: main thread (no subagent_type) Write anywhere -> ALLOW (exit 0)
check "G: main thread Write to src/foo.py ALLOW" 0 \
  "$(payload "Write" "src/foo.py" "$FIXTURES/main-thread.jsonl")"

# Case H: non-Write/Edit tool (Bash) -> always ALLOW (exit 0)
check "H: Bash tool not restricted ALLOW" 0 \
  "$(payload "Bash" "src/foo.py" "$FIXTURES/spec-writer.jsonl")"

# Cases P: the installed plugin tree is never a write target, for any caller; a
# worktree under the project and a plugin root inside the project stay unaffected.
PLUG="$(mktemp -d)"; PROJ="$(mktemp -d)"; mkdir -p "$PLUG/lib" "$PROJ/.claude/worktrees/feat/lib"
export CLAUDE_PLUGIN_ROOT="$PLUG" CLAUDE_PROJECT_DIR="$PROJ"
check "P1: main thread Edit inside the installed plugin DENY" 2 \
  "$(payload "Edit" "$PLUG/lib/runtime-ignore.sh" "$FIXTURES/main-thread.jsonl")"
check "P2: implementer Write inside the installed plugin DENY" 2 \
  "$(payload "Write" "$PLUG/lib/new.sh" "$FIXTURES/implementer.jsonl")"
check "P3: main thread Edit in the project's feature worktree ALLOW" 0 \
  "$(payload "Edit" "$PROJ/.claude/worktrees/feat/lib/x.sh" "$FIXTURES/main-thread.jsonl")"
check "P4: relative project path ALLOW" 0 \
  "$(payload "Write" "lib/x.sh" "$FIXTURES/main-thread.jsonl")"
export CLAUDE_PLUGIN_ROOT="$PROJ/.claude/worktrees/feat"
check "P5: a plugin root inside the project is not guarded (self-development) ALLOW" 0 \
  "$(payload "Edit" "$PROJ/.claude/worktrees/feat/lib/x.sh" "$FIXTURES/main-thread.jsonl")"
unset CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR; rm -rf "$PLUG" "$PROJ"

# Cases R: the contract files only the bundled writers may publish are never Write or
# Edit targets, for any caller; reading and other .loop-spec files stay free.
check "R1: main thread Write to .loop-spec/last-result.json DENY" 2 \
  "$(payload "Write" ".loop-spec/last-result.json" "$FIXTURES/main-thread.jsonl")"
check "R2: implementer Edit to an absolute feature.json DENY" 2 \
  "$(payload "Edit" "/abs/proj/.loop-spec/features/x/feature.json" "$FIXTURES/implementer.jsonl")"
check "R3: main thread Write to .loop-spec/features/x/delivery.json DENY" 2 \
  "$(payload "Write" ".loop-spec/features/x/delivery.json" "$FIXTURES/main-thread.jsonl")"
check "R4: main thread Write to .loop-spec/profile.json ALLOW" 0 \
  "$(payload "Write" ".loop-spec/profile.json" "$FIXTURES/main-thread.jsonl")"
check "R5: a feature.json outside .loop-spec is not a contract file ALLOW" 0 \
  "$(payload "Write" "src/feature.json" "$FIXTURES/main-thread.jsonl")"

# Case I: spec-writer with absolute path to allowed location -> ALLOW (exit 0)
check "I: spec-writer Write to /abs/path/docs/loop-spec/features/bar/SPEC.md ALLOW" 0 \
  "$(payload "Write" "/abs/path/docs/loop-spec/features/bar/SPEC.md" "$FIXTURES/spec-writer.jsonl")"

# Case K: pattern-mapper Write to allowed features path -> ALLOW (exit 0)
check "K: pattern-mapper Write to docs/loop-spec/features/foo/PATTERNS.md ALLOW" 0 \
  "$(payload "Write" "docs/loop-spec/features/foo/PATTERNS.md" "$FIXTURES/pattern-mapper.jsonl")"

# Case L: pattern-mapper Write to disallowed path -> DENY (exit 2)
check "L: pattern-mapper Write to src/foo.py DENY" 2 \
  "$(payload "Write" "src/foo.py" "$FIXTURES/pattern-mapper.jsonl")"

# Case M: dispatch FINISHED (tool_result received) -> main thread, ALLOW anywhere
check "M: finished spec-writer dispatch does not restrict main thread ALLOW" 0 \
  "$(payload "Write" "src/foo.py" "$FIXTURES/finished-dispatch.jsonl")"

# Case N: malformed payload -> fail-open ALLOW (exit 0, never a hook error)
actual_exit=0
bash "$HOOK" >/dev/null 2>&1 <<<'not json' || actual_exit=$?
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

# Case P: kill switch LOOP_SPEC_PATH_GUARD=0 -> ALLOW even for restricted caller
# Here-string, not a pipe: the hook returns immediately and a pipe would SIGPIPE (141).
actual_exit=0
LOOP_SPEC_PATH_GUARD=0 bash "$HOOK" >/dev/null 2>&1 \
  <<< "$(payload "Write" "src/foo.py" "$FIXTURES/spec-writer.jsonl")" || actual_exit=$?
if [[ "$actual_exit" -eq 0 ]]; then
  echo "PASS: P: kill switch ALLOW"
  ((PASS++)) || true
else
  echo "FAIL: P: kill switch ALLOW (got $actual_exit)"
  ((FAIL++)) || true
fi

# Case R: spec-writer Write to absolute path under a workspace root -> features path ALLOW (exit 0)
check "R: spec-writer Write to /tmp/ws-test/workspace/docs/loop-spec/features/x/SPEC.md ALLOW" 0 \
  "$(payload "Write" "/tmp/ws-test/workspace/docs/loop-spec/features/x/SPEC.md" "$FIXTURES/spec-writer.jsonl")"

# Case S: spec-writer Write to workspace repo source path -> DENY (exit 2)
check "S: spec-writer Write to /tmp/ws-test/workspace/frontend/src/app.py DENY" 2 \
  "$(payload "Write" "/tmp/ws-test/workspace/frontend/src/app.py" "$FIXTURES/spec-writer.jsonl")"

# Case Q: fast path — no .loop-spec/features and no force flag -> ALLOW without parsing
# Here-string, not a pipe: the hook returns immediately and a pipe would SIGPIPE (141).
HOOK_ABS="$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")"
actual_exit=0
env -u LOOP_SPEC_PATH_GUARD_FORCE CLAUDE_PROJECT_DIR=/nonexistent \
  bash -c "cd /tmp && bash '$HOOK_ABS'" >/dev/null 2>&1 \
  <<< "$(payload "Write" "src/foo.py" "$FIXTURES/spec-writer.jsonl")" || actual_exit=$?
if [[ "$actual_exit" -eq 0 ]]; then
  echo "PASS: Q: no-feature-state fast path ALLOW"
  ((PASS++)) || true
else
  echo "FAIL: Q: no-feature-state fast path ALLOW (got $actual_exit)"
  ((FAIL++)) || true
fi

# Case T: code-reviewer (memory-enabled, read-only for code) Write to source path -> DENY (exit 2)
check "T: code-reviewer Write to src/foo.py DENY" 2 \
  "$(payload "Write" "src/foo.py" "$FIXTURES/code-reviewer.jsonl")"

# Case U: code-reviewer Write to its agent-memory dir -> ALLOW (exit 0)
check "U: code-reviewer Write to .claude/agent-memory/code-reviewer/MEMORY.md ALLOW" 0 \
  "$(payload "Write" ".claude/agent-memory/code-reviewer/MEMORY.md" "$FIXTURES/code-reviewer.jsonl")"

# Case V: pattern-mapper Write to its agent-memory dir -> ALLOW (exit 0)
check "V: pattern-mapper Write to .claude/agent-memory/pattern-mapper/notes.md ALLOW" 0 \
  "$(payload "Write" ".claude/agent-memory/pattern-mapper/notes.md" "$FIXTURES/pattern-mapper.jsonl")"

# Case W: code-reviewer Edit to absolute agent-memory path -> ALLOW (exit 0)
check "W: code-reviewer Edit to /abs/proj/.claude/agent-memory/code-reviewer/MEMORY.md ALLOW" 0 \
  "$(payload "Edit" "/abs/proj/.claude/agent-memory/code-reviewer/MEMORY.md" "$FIXTURES/code-reviewer.jsonl")"

# Cases W: a feature artifact must land in the checkout that holds the feature's
# feature.json. The lead's cwd is the main checkout; the feature lives in a worktree.
WREPO="$(mktemp -d)"
git -C "$WREPO" init -q && git -C "$WREPO" commit -q --allow-empty -m seed
git -C "$WREPO" worktree add -q "$WREPO/.claude/worktrees/foo" -b feat/foo
mkdir -p "$WREPO/.claude/worktrees/foo/docs/loop-spec/features/foo"
printf '{"slug":"foo"}\n' > "$WREPO/.claude/worktrees/foo/docs/loop-spec/features/foo/feature.json"
export CLAUDE_PROJECT_DIR="$WREPO"
check "W1: spec-writer Write of SPEC.md relative to the main checkout DENY (feature lives in the worktree)" 2 \
  "$(payload "Write" "docs/loop-spec/features/foo/SPEC.md" "$FIXTURES/spec-writer.jsonl")"
check "W2: spec-writer Write of SPEC.md under the feature worktree ALLOW" 0 \
  "$(payload "Write" "$WREPO/.claude/worktrees/foo/docs/loop-spec/features/foo/SPEC.md" "$FIXTURES/spec-writer.jsonl")"
check "W3: planner Edit of PLAN.md in the main checkout DENY" 2 \
  "$(payload "Edit" "$WREPO/docs/loop-spec/features/foo/PLAN.md" "$FIXTURES/planner.jsonl")"
check "W4: a slug with no feature.json anywhere stays ALLOW" 0 \
  "$(payload "Write" "docs/loop-spec/features/bar/SPEC.md" "$FIXTURES/spec-writer.jsonl")"
# The lead writes the spec itself on the short route (the dda2cca run wrote it to the
# main checkout again): the rule holds for the main thread and for every other caller.
check "W4b: main-thread Write of SPEC.md relative to the main checkout DENY" 2 \
  "$(payload "Write" "docs/loop-spec/features/foo/SPEC.md" "$FIXTURES/main-thread.jsonl")"
check "W4c: main-thread Edit of the stale parent copy DENY" 2 \
  "$(payload "Edit" "$WREPO/docs/loop-spec/features/foo/SPEC.md" "$FIXTURES/main-thread.jsonl")"
check "W4d: main-thread Write under the feature worktree ALLOW" 0 \
  "$(payload "Write" "$WREPO/.claude/worktrees/foo/docs/loop-spec/features/foo/VERIFICATION.md" "$FIXTURES/main-thread.jsonl")"
check "W4e: implementer Write of a feature artifact in the main checkout DENY" 2 \
  "$(payload "Write" "docs/loop-spec/features/foo/VERIFICATION.md" "$FIXTURES/implementer.jsonl")"
check "W4f: main-thread Write outside the feature docs stays ALLOW" 0 \
  "$(payload "Write" "src/x.py" "$FIXTURES/main-thread.jsonl")"
msg="$(bash "$HOOK" 2>&1 >/dev/null <<<"$(payload "Write" "docs/loop-spec/features/foo/SPEC.md" "$FIXTURES/spec-writer.jsonl")" || true)"
if [[ "$msg" == *"Write $WREPO/.claude/worktrees/foo/docs/loop-spec/features/foo/SPEC.md instead"* ]]; then
  echo "PASS: W5: the denial names the path to write"; ((PASS++)) || true
else
  echo "FAIL: W5: the denial names the path to write ($msg)"; ((FAIL++)) || true
fi
unset CLAUDE_PROJECT_DIR; rm -rf "$WREPO"

# Cases X: on the oneshot route the driver is the only writer of SPEC.md and
# VERIFICATION.md (followup-3, N1); the full route and a spec not yet written stay open.
XREPO="$(mktemp -d)"
git -C "$XREPO" init -q && git -C "$XREPO" commit -q --allow-empty -m seed
mkdir -p "$XREPO/.loop-spec/features/one" "$XREPO/docs/loop-spec/features/one" "$XREPO/.loop-spec/features/big" "$XREPO/docs/loop-spec/features/big"
printf '{"slug":"one","schemaVersion":7}\n' > "$XREPO/.loop-spec/features/one/feature.json"
printf '{"slug":"big","schemaVersion":7}\n' > "$XREPO/.loop-spec/features/big/feature.json"
printf -- '---\nambiguity_scores:\n  gate_passed: true\n  unresolved_dimensions: []\nfootprint:\n  - a.py\n---\n# one\n\n## Intent\n\nx\n<!-- /intent -->\n\n## Implementation notes\n\n- a.py: x\n' > "$XREPO/docs/loop-spec/features/one/SPEC.md"
printf -- '---\nambiguity_scores:\n  gate_passed: true\n  unresolved_dimensions: []\nfootprint: [a.py, b.py, c.py, d.py]\n---\n# big\n\n## Problem\n\nx\n' > "$XREPO/docs/loop-spec/features/big/SPEC.md"
export CLAUDE_PROJECT_DIR="$XREPO"
check "X1: main-thread Edit of a oneshot-route SPEC.md DENY (the driver fills it)" 2 \
  "$(payload "Edit" "$XREPO/docs/loop-spec/features/one/SPEC.md" "$FIXTURES/main-thread.jsonl")"
check "X2: main-thread Write of a oneshot-route VERIFICATION.md DENY" 2 \
  "$(payload "Write" "$XREPO/docs/loop-spec/features/one/VERIFICATION.md" "$FIXTURES/main-thread.jsonl")"
check "X3: the same paths relative to the project DENY" 2 \
  "$(payload "Edit" "docs/loop-spec/features/one/SPEC.md" "$FIXTURES/main-thread.jsonl")"
check "X4: a full-route SPEC.md (four files) stays ALLOW" 0 \
  "$(payload "Edit" "$XREPO/docs/loop-spec/features/big/SPEC.md" "$FIXTURES/main-thread.jsonl")"
check "X5: a SPEC.md not yet written (the full shape's first Write) stays ALLOW" 0 \
  "$(payload "Write" "$XREPO/docs/loop-spec/features/new/SPEC.md" "$FIXTURES/main-thread.jsonl")"
check "X6: another artifact of the oneshot feature stays ALLOW" 0 \
  "$(payload "Write" "$XREPO/docs/loop-spec/features/one/EVIDENCE.md" "$FIXTURES/main-thread.jsonl")"
printf 'route: full\n' >> "$XREPO/docs/loop-spec/features/one/SPEC.md"
sed -i 's/^footprint:$/route: full\nfootprint:/' "$XREPO/docs/loop-spec/features/one/SPEC.md"
check "X7: an escalated spec (route: full) is the lead's again ALLOW" 0 \
  "$(payload "Edit" "$XREPO/docs/loop-spec/features/one/SPEC.md" "$FIXTURES/main-thread.jsonl")"
msg="$(bash "$HOOK" 2>&1 >/dev/null <<<"$(payload "Write" "$XREPO/docs/loop-spec/features/one/VERIFICATION.md" "$FIXTURES/main-thread.jsonl")" || true)"
sed -i '/^route: full$/d' "$XREPO/docs/loop-spec/features/one/SPEC.md"
msg="$(bash "$HOOK" 2>&1 >/dev/null <<<"$(payload "Write" "$XREPO/docs/loop-spec/features/one/VERIFICATION.md" "$FIXTURES/main-thread.jsonl")" || true)"
if [[ "$msg" == *"verification fill --feature-dir $XREPO/.loop-spec/features/one"* ]]; then
  echo "PASS: X8: the denial names the fill command with the feature dir"; ((PASS++)) || true
else
  echo "FAIL: X8: the denial names the fill command with the feature dir ($msg)"; ((FAIL++)) || true
fi
unset CLAUDE_PROJECT_DIR; rm -rf "$XREPO"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
