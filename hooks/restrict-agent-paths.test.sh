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

# Cases PS: v1 is the default now, so the docs tree is publication_protected_deny's
# to guard; the maker's own copy is the staged draft under the feature's state dir,
# scoped to the single feature its own dispatch brief named (task item 1).
NOFEAT="$(mktemp -d)"
export CLAUDE_PROJECT_DIR="$NOFEAT"
check "PS1: planner Write to .loop-spec/features/foo/publication-staging/PLAN.md (own feature) ALLOW" 0 \
  "$(payload "Write" ".loop-spec/features/foo/publication-staging/PLAN.md" "$FIXTURES/planner.jsonl")"
check "PS2: planner Write to .loop-spec/features/bar/publication-staging/PLAN.md (another feature) DENY" 2 \
  "$(payload "Write" ".loop-spec/features/bar/publication-staging/PLAN.md" "$FIXTURES/planner.jsonl")"
check "PS3: spec-writer Write to .loop-spec/features/foo/publication-staging/SPEC.md (own feature) ALLOW" 0 \
  "$(payload "Write" ".loop-spec/features/foo/publication-staging/SPEC.md" "$FIXTURES/spec-writer.jsonl")"
check "PS4: spec-writer Write to .loop-spec/features/bar/publication-staging/SPEC.md (another feature) DENY" 2 \
  "$(payload "Write" ".loop-spec/features/bar/publication-staging/SPEC.md" "$FIXTURES/spec-writer.jsonl")"
# The plan skill names the staged PATTERNS.md as the mapper's target; a live sonnet run
# had the mapper denied there and the planner wrote PATTERNS.md itself.
check "PS5: pattern-mapper Write to .loop-spec/features/foo/publication-staging/PATTERNS.md (own feature) ALLOW" 0 \
  "$(payload "Write" ".loop-spec/features/foo/publication-staging/PATTERNS.md" "$FIXTURES/pattern-mapper.jsonl")"
check "PS6: pattern-mapper Write to .loop-spec/features/bar/publication-staging/PATTERNS.md (another feature) DENY" 2 \
  "$(payload "Write" ".loop-spec/features/bar/publication-staging/PATTERNS.md" "$FIXTURES/pattern-mapper.jsonl")"
# A planner resumed with a fix list (SendMessage to its agent id) keeps its role: the
# subagent meta file next to the transcript names the dispatch that spawned it.
check "PS7: a planner resumed by SendMessage may Edit its own staged PLAN.md ALLOW" 0 \
  "$(payload "Edit" ".loop-spec/features/foo/publication-staging/PLAN.md" "$FIXTURES/planner-resumed.jsonl")"
check "PS8: the resumed planner is still scoped (src/foo.py) DENY" 2 \
  "$(payload "Write" "src/foo.py" "$FIXTURES/planner-resumed.jsonl")"
unset CLAUDE_PROJECT_DIR; rm -rf "$NOFEAT"

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
WREPO="$(cd "$WREPO" && pwd -P)"
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

# Cases WV: a v1 feature's PLAN.md/SPEC.md are publication_protected_deny's, not the
# role case's -- the planner/spec-writer's own copy is the staged draft (task item 1).
mkdir -p "$WREPO/.loop-spec/features/v1feat"
printf '{"slug":"v1feat","requirementsContract":{"format":"v1"}}\n' > "$WREPO/.loop-spec/features/v1feat/feature.json"
check "WV1: planner Write to docs/.../v1feat/PLAN.md under a v1 feature DENY" 2 \
  "$(payload "Write" "$WREPO/docs/loop-spec/features/v1feat/PLAN.md" "$FIXTURES/planner.jsonl")"
check "WV2: spec-writer Write to docs/.../v1feat/SPEC.md under a v1 feature DENY" 2 \
  "$(payload "Write" "$WREPO/docs/loop-spec/features/v1feat/SPEC.md" "$FIXTURES/spec-writer.jsonl")"
check "WV3: planner Write to v1feat's staged draft (own feature dispatch names foo, not v1feat) DENY" 2 \
  "$(payload "Write" "$WREPO/.loop-spec/features/v1feat/publication-staging/PLAN.md" "$FIXTURES/planner.jsonl")"
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
# VERIFICATION.md (port audit 3, N1); the full route and a spec not yet written stay open.
XREPO="$(mktemp -d)"
XREPO="$(cd "$XREPO" && pwd -P)"
git -C "$XREPO" init -q && git -C "$XREPO" commit -q --allow-empty -m seed
mkdir -p "$XREPO/.loop-spec/features/one" "$XREPO/docs/loop-spec/features/one" "$XREPO/.loop-spec/features/big" "$XREPO/docs/loop-spec/features/big"
printf '{"slug":"one","schemaVersion":7}\n' > "$XREPO/.loop-spec/features/one/feature.json"
printf '{"slug":"big","schemaVersion":7}\n' > "$XREPO/.loop-spec/features/big/feature.json"
printf -- '---\nunresolved_questions: []\nfootprint:\n  - a.py\n---\n# one\n\n## Intent\n\nx\n<!-- /intent -->\n\n## Implementation notes\n\n- a.py: x\n' > "$XREPO/docs/loop-spec/features/one/SPEC.md"
printf -- '---\nunresolved_questions: []\nfootprint: [a.py, b.py, c.py, d.py]\n---\n# big\n\n## Problem\n\nx\n' > "$XREPO/docs/loop-spec/features/big/SPEC.md"
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
sed -i.bak 's/^footprint:$/route: full\
footprint:/' "$XREPO/docs/loop-spec/features/one/SPEC.md"
check "X7: an escalated spec (route: full) is the lead's again ALLOW" 0 \
  "$(payload "Edit" "$XREPO/docs/loop-spec/features/one/SPEC.md" "$FIXTURES/main-thread.jsonl")"
msg="$(bash "$HOOK" 2>&1 >/dev/null <<<"$(payload "Write" "$XREPO/docs/loop-spec/features/one/VERIFICATION.md" "$FIXTURES/main-thread.jsonl")" || true)"
sed -i.bak '/^route: full$/d' "$XREPO/docs/loop-spec/features/one/SPEC.md"
msg="$(bash "$HOOK" 2>&1 >/dev/null <<<"$(payload "Write" "$XREPO/docs/loop-spec/features/one/VERIFICATION.md" "$FIXTURES/main-thread.jsonl")" || true)"
if [[ "$msg" == *"verification fill --feature-dir $XREPO/.loop-spec/features/one"* ]]; then
  echo "PASS: X8: the denial names the fill command with the feature dir"; ((PASS++)) || true
else
  echo "FAIL: X8: the denial names the fill command with the feature dir ($msg)"; ((FAIL++)) || true
fi
# Fail closed: a spec the probe cannot read (an unterminated frontmatter, what a hand
# write leaves behind) keeps both files the driver's; only a readable full route opens them.
printf -- '---\nfootprint:\n  - a.py\n# no closing marker\n' > "$XREPO/docs/loop-spec/features/one/SPEC.md"
check "X9: an unreadable spec denies (fail closed once the feature is known)" 2 \
  "$(payload "Write" "$XREPO/docs/loop-spec/features/one/VERIFICATION.md" "$FIXTURES/main-thread.jsonl")"
check "X10: and the spec itself stays the driver's" 2 \
  "$(payload "Edit" "$XREPO/docs/loop-spec/features/one/SPEC.md" "$FIXTURES/main-thread.jsonl")"
check "X11: PLAN.md is driver-owned on the oneshot route too" 2 \
  "$(payload "Write" "$XREPO/docs/loop-spec/features/one/PLAN.md" "$FIXTURES/main-thread.jsonl")"
check "X12: PATTERNS.md is driver-owned on the oneshot route too" 2 \
  "$(payload "Write" "$XREPO/docs/loop-spec/features/one/PATTERNS.md" "$FIXTURES/main-thread.jsonl")"
check "X13: a full-route PLAN.md stays the lead's" 0 \
  "$(payload "Edit" "$XREPO/docs/loop-spec/features/big/PLAN.md" "$FIXTURES/main-thread.jsonl")"

# Case X14/X15 (security hardening): a maker allowed to write under
# publication-staging could plant a symlink there pointing at the feature's
# protected SPEC.md and write through it under a literal path this hook would
# otherwise see as plain staging. FILE_PATH_REAL resolves it first, so the
# resolved target -- not the literal staging-looking path -- is what gets judged.
mkdir -p "$XREPO/.loop-spec/features/one/publication-staging"
ln -s "$XREPO/docs/loop-spec/features/one/SPEC.md" "$XREPO/.loop-spec/features/one/publication-staging/sneaky.md"
check "X14: a staging symlink resolving to the protected SPEC.md is DENY" 2 \
  "$(payload "Write" "$XREPO/.loop-spec/features/one/publication-staging/sneaky.md" "$FIXTURES/main-thread.jsonl")"
check "X15: a plain (non-symlink) staging file stays ALLOW" 0 \
  "$(payload "Write" "$XREPO/.loop-spec/features/one/publication-staging/plain.md" "$FIXTURES/main-thread.jsonl")"
check "X16: a lead's edit of the planner's staged PLAN.md is DENY (re-dispatch with a fix list)" 2 \
  "$(payload "Edit" "$XREPO/.loop-spec/features/one/publication-staging/PLAN.md" "$FIXTURES/main-thread.jsonl")"
check "X17: a lead's write of the mapper's staged PATTERNS.md is DENY" 2 \
  "$(payload "Write" "$XREPO/.loop-spec/features/one/publication-staging/PATTERNS.md" "$FIXTURES/main-thread.jsonl")"
check "X18: the planner's own staged PLAN.md stays ALLOW" 0 \
  "$(payload "Write" "$XREPO/.loop-spec/features/foo/publication-staging/PLAN.md" "$FIXTURES/planner.jsonl")"
unset CLAUDE_PROJECT_DIR; rm -rf "$XREPO"

# Cases Y: task-009's driver-owned state -- feature.json.bak, tasks.json,
# observations/**, publication-generations/**, migration-generations/** are
# never Write/Edit targets; publication-staging/**, dispatch/**, and
# review-attempts/** are a maker's to write (SPEC "The driver owns execution
# observations" / "Migration preserves originals...").
YREPO="$(mktemp -d)"
YREPO="$(cd "$YREPO" && pwd -P)"
git -C "$YREPO" init -q && git -C "$YREPO" commit -q --allow-empty -m seed
mkdir -p "$YREPO/.loop-spec/features/y" "$YREPO/docs/loop-spec/features/y"
printf '{"slug":"y","schemaVersion":7}\n' > "$YREPO/.loop-spec/features/y/feature.json"
export CLAUDE_PROJECT_DIR="$YREPO"
check "Y1: feature.json.bak DENY" 2 \
  "$(payload "Write" "$YREPO/.loop-spec/features/y/feature.json.bak" "$FIXTURES/main-thread.jsonl")"
check "Y2: tasks.json DENY" 2 \
  "$(payload "Edit" "$YREPO/.loop-spec/features/y/tasks.json" "$FIXTURES/main-thread.jsonl")"
check "Y3: an observation record DENY" 2 \
  "$(payload "Write" "$YREPO/.loop-spec/features/y/observations/exec-1.json" "$FIXTURES/main-thread.jsonl")"
check "Y4: a final observation projection DENY" 2 \
  "$(payload "Write" "$YREPO/.loop-spec/features/y/observations/final/deadbeef/VERIFICATION.md" "$FIXTURES/main-thread.jsonl")"
check "Y5: the publication generation journal DENY" 2 \
  "$(payload "Write" "$YREPO/.loop-spec/features/y/publication-generations/active.json" "$FIXTURES/main-thread.jsonl")"
check "Y6: the migration generation journal DENY" 2 \
  "$(payload "Write" "$YREPO/.loop-spec/features/y/migration-generations/t1/backup.json" "$FIXTURES/main-thread.jsonl")"
check "Y7: a staged publication file (relative path) ALLOW" 0 \
  "$(payload "Write" ".loop-spec/features/y/publication-staging/spec-abc.md" "$FIXTURES/main-thread.jsonl")"
check "Y8: a dispatch record ALLOW" 0 \
  "$(payload "Write" "$YREPO/.loop-spec/features/y/dispatch/round-1.json" "$FIXTURES/main-thread.jsonl")"
check "Y9: a review-attempts record ALLOW" 0 \
  "$(payload "Write" "$YREPO/.loop-spec/features/y/review-attempts/1.json" "$FIXTURES/main-thread.jsonl")"
check "Y10: an implementer hits the same feature-state denial" 2 \
  "$(payload "Write" "$YREPO/.loop-spec/features/y/observations/exec-2.json" "$FIXTURES/implementer.jsonl")"
unset CLAUDE_PROJECT_DIR; rm -rf "$YREPO"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
