#!/usr/bin/env bash
# Tests for lib/opencode-install.sh — install into a temp config dir and
# assert every native opencode discovery surface is populated correctly:
# skills/commands/plugin placed on the documented glob paths, agents converted
# to opencode frontmatter, manifest-driven uninstall removes exactly its own.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO/lib/opencode-install.sh"
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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/opencode"

# --- install (global-style, via OPENCODE_CONFIG_DIR override) ---
OPENCODE_CONFIG_DIR="$CFG" bash "$LIB" install >/dev/null
check "manifest written" "yes" "$([[ -f "$CFG/loop-spec-install.json" ]] && echo yes || echo no)"

# Skills land on the documented {skill,skills}/**/SKILL.md glob, as symlinks
# into the repo (so ${CLAUDE_SKILL_DIR}/../../lib resolves after realpath).
check "cycle skill linked" "yes" "$([[ -L "$CFG/skills/cycle" && -f "$CFG/skills/cycle/SKILL.md" ]] && echo yes || echo no)"
check "cycle link resolves into repo" "$REPO/skills/cycle" "$(readlink "$CFG/skills/cycle")"
check "shared/ (no SKILL.md) not linked" "no" "$([[ -e "$CFG/skills/shared" ]] && echo yes || echo no)"
skill_count="$(ls "$CFG/skills" | wc -l | tr -d ' ')"
repo_skill_count="$(ls -d "$REPO"/skills/*/SKILL.md | wc -l | tr -d ' ')"
check "every SKILL.md dir installed" "$repo_skill_count" "$skill_count"

# Command + plugin on their documented globs.
check "loop-debug command placed" "yes" "$([[ -f "$CFG/commands/loop-debug.md" ]] && echo yes || echo no)"
check "bridge plugin placed" "yes" "$([[ -f "$CFG/plugins/loop-spec.ts" ]] && echo yes || echo no)"

# Skill command wrappers: opencode's TUI hides skill-sourced entries from the
# "/" popup (packages/tui .. autocomplete skips source === "skill"), so every
# skill also gets a real command at commands/loop-spec/<name>.md, loading as
# /loop-spec/<name>. Namespaced to never shadow opencode built-ins (/debug,
# /status, /skills are TUI palette slashes).
check "cycle wrapper generated" "yes" "$([[ -f "$CFG/commands/loop-spec/cycle.md" ]] && echo yes || echo no)"
check "wrapper is a real file (not link)" "no" "$([[ -L "$CFG/commands/loop-spec/cycle.md" ]] && echo yes || echo no)"
check "wrapper has description frontmatter" "1" "$(grep -c '^description:' "$CFG/commands/loop-spec/cycle.md")"
check "wrapper invokes the skill tool" "yes" "$(grep -q 'skill({ name: "cycle" })' "$CFG/commands/loop-spec/cycle.md" && echo yes || echo no)"
check "wrapper passes \$ARGUMENTS" "yes" "$(grep -qF '$ARGUMENTS' "$CFG/commands/loop-spec/cycle.md" && echo yes || echo no)"
wrapper_count="$(ls "$CFG/commands/loop-spec" | wc -l | tr -d ' ')"
check "every skill has a wrapper" "$repo_skill_count" "$wrapper_count"
# loop-runner's description is a YAML folded scalar (>-) — must not be dropped.
check "folded description survives" "yes" "$(grep -q '^description: "Compile specs' "$CFG/commands/loop-spec/loop-runner.md" && echo yes || echo no)"
# argument-hint carries over as prose so the wrapper documents its input.
check "argument-hint carried into body" "yes" "$(grep -q 'Argument shape:' "$CFG/commands/loop-spec/cycle.md" && echo yes || echo no)"

# Agents are converted (never linked): opencode frontmatter dialect.
check "verifier agent generated" "yes" "$([[ -f "$CFG/agents/loop-spec-verifier.md" ]] && echo yes || echo no)"
check "agent is a real file (not link)" "no" "$([[ -L "$CFG/agents/loop-spec-verifier.md" ]] && echo yes || echo no)"
check "agent mode is subagent" "1" "$(grep -c '^mode: subagent$' "$CFG/agents/loop-spec-verifier.md")"
check "agent has description" "1" "$(grep -c '^description:' "$CFG/agents/loop-spec-verifier.md")"
# verifier's CC allow-list has no Agent/WebFetch -> task/webfetch disabled.
check "allow-list maps to denials" "1" "$(grep -c '  task: false' "$CFG/agents/loop-spec-verifier.md")"
check "allowed tools not denied" "0" "$(grep -c '  read: false' "$CFG/agents/loop-spec-verifier.md" || true)"
# implementer allow-lists {Read,Write,Edit,Bash,Grep,Glob} (its
# disallowedTools are already outside that list) -> the other 6 builtins
# are denied, including webfetch/websearch.
check "implementer denials" "6" "$(grep -c ': false' "$CFG/agents/loop-spec-implementer.md")"
check "implementer webfetch denied" "1" "$(grep -c '  webfetch: false' "$CFG/agents/loop-spec-implementer.md")"
# CC-only frontmatter must not leak into the opencode dialect.
check "no CC model alias leaks" "0" "$(grep -c '^model: sonnet\|^model: opus' "$CFG/agents/"loop-spec-*.md | awk -F: '{s+=$NF} END {print s}')"
check "no CC effort key leaks" "0" "$(grep -c '^effort:' "$CFG/agents/"loop-spec-*.md | awk -F: '{s+=$NF} END {print s}')"

# --- idempotent re-install ---
OPENCODE_CONFIG_DIR="$CFG" bash "$LIB" install >/dev/null
check "re-install exits 0" "0" "$?"

# --- collisions are refused, not clobbered ---
CFG2="$TMP/opencode2"
mkdir -p "$CFG2/skills/cycle"
echo "user content" > "$CFG2/skills/cycle/SKILL.md"
rc=0; OPENCODE_CONFIG_DIR="$CFG2" bash "$LIB" install >/dev/null 2>&1 || rc=$?
check "collision -> exit 1" "1" "$rc"
check "user file untouched" "user content" "$(cat "$CFG2/skills/cycle/SKILL.md")"

# --- status ---
out="$(OPENCODE_CONFIG_DIR="$CFG" bash "$LIB" status)"
check "status reports installed" "yes" "$(grep -q '^installed:' <<<"$out" && echo yes || echo no)"

# --- uninstall removes exactly its manifest paths ---
echo "keep me" > "$CFG/skills/user-skill-marker"
OPENCODE_CONFIG_DIR="$CFG" bash "$LIB" uninstall >/dev/null
check "cycle skill removed" "no" "$([[ -e "$CFG/skills/cycle" || -L "$CFG/skills/cycle" ]] && echo yes || echo no)"
check "agents removed" "0" "$(ls "$CFG/agents" 2>/dev/null | wc -l | tr -d ' ')"
check "skill wrappers removed" "0" "$(ls "$CFG/commands/loop-spec" 2>/dev/null | wc -l | tr -d ' ')"
check "manifest removed" "no" "$([[ -f "$CFG/loop-spec-install.json" ]] && echo yes || echo no)"
check "unrelated user file kept" "keep me" "$(cat "$CFG/skills/user-skill-marker")"

# --- project-mode targets <dir>/.opencode ---
PROJ="$TMP/proj"; mkdir -p "$PROJ"
bash "$LIB" install --project "$PROJ" >/dev/null
check "project install under .opencode" "yes" "$([[ -f "$PROJ/.opencode/loop-spec-install.json" ]] && echo yes || echo no)"

# --- copy mode makes real files ---
CFG3="$TMP/opencode3"
OPENCODE_CONFIG_DIR="$CFG3" bash "$LIB" install --copy >/dev/null
check "copy mode: skill is a real dir" "no" "$([[ -L "$CFG3/skills/cycle" ]] && echo yes || echo no)"
check "copy mode: SKILL.md present" "yes" "$([[ -f "$CFG3/skills/cycle/SKILL.md" ]] && echo yes || echo no)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
