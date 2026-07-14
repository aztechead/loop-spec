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

# Generated namespaced skill adapters avoid shadowing a user's native `cycle`,
# `plan`, `status`, etc. They read the source SKILL.md from this checkout.
check "namespaced cycle skill generated" "yes" "$([[ -f "$CFG/skills/loop-spec-cycle/SKILL.md" ]] && echo yes || echo no)"
check "namespaced skill frontmatter" "1" "$(grep -c '^name: loop-spec-cycle$' "$CFG/skills/loop-spec-cycle/SKILL.md")"
check "source skill remains unshadowed" "no" "$([[ -e "$CFG/skills/cycle" ]] && echo yes || echo no)"
check "skill adapter embeds source" "yes" "$(grep -qF '# loop-spec:cycle' "$CFG/skills/loop-spec-cycle/SKILL.md" && echo yes || echo no)"
check "skill adapter needs no external source read" "no" "$(grep -qF "$REPO/skills/cycle/SKILL.md" "$CFG/skills/loop-spec-cycle/SKILL.md" && echo yes || echo no)"
check "skill adapter loads OpenCode contract" "yes" "$(grep -q 'opencode-harness.md' "$CFG/skills/loop-spec-cycle/SKILL.md" && echo yes || echo no)"
skill_count="$(ls "$CFG/skills" | wc -l | tr -d ' ')"
repo_skill_count="$(ls -d "$REPO"/skills/*/SKILL.md | wc -l | tr -d ' ')"
check "every SKILL.md has a namespaced adapter" "$repo_skill_count" "$skill_count"

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
check "wrapper invokes namespaced skill" "yes" "$(grep -q 'skill({ name: "loop-spec-cycle" })' "$CFG/commands/loop-spec/cycle.md" && echo yes || echo no)"
check "wrapper passes \$ARGUMENTS" "yes" "$(grep -qF '$ARGUMENTS' "$CFG/commands/loop-spec/cycle.md" && echo yes || echo no)"
check "wrapper loads OpenCode adaptation" "yes" "$(grep -q 'opencode-harness.md' "$CFG/commands/loop-spec/cycle.md" && echo yes || echo no)"
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
# verifier's CC allow-list has no Agent/WebFetch. OpenCode's documented
# permission frontmatter denies everything, then allows only mapped tools.
check "allow-list does not allow task" "0" "$(grep -c '  task: allow' "$CFG/agents/loop-spec-verifier.md" || true)"
check "allowed tools not denied" "0" "$(grep -c '  read: deny' "$CFG/agents/loop-spec-verifier.md" || true)"
check "agent uses permission frontmatter" "1" "$(grep -c '^permission:$' "$CFG/agents/loop-spec-verifier.md")"
check "agent omits deprecated tools frontmatter" "0" "$(grep -c '^tools:$' "$CFG/agents/loop-spec-verifier.md" || true)"
check "allow-list denies unknown tools by default" "1" "$(grep -c '^  "\*": deny$' "$CFG/agents/loop-spec-verifier.md" || true)"
check "allow-list explicitly allows read" "1" "$(grep -c '^  read: allow$' "$CFG/agents/loop-spec-verifier.md" || true)"
# implementer allow-lists {Read,Write,Edit,Bash,Grep,Glob}; unknown, custom,
# MCP, and future tools remain denied.
check "implementer deny-by-default" "1" "$(grep -c '^  "\*": deny$' "$CFG/agents/loop-spec-implementer.md" || true)"
check "implementer explicitly allows edit" "1" "$(grep -c '^  edit: allow$' "$CFG/agents/loop-spec-implementer.md" || true)"
check "read-only primary agent generated" "yes" "$([[ -f "$CFG/agents/loop-spec-readonly.md" ]] && echo yes || echo no)"
check "read-only agent denies bash" "1" "$(grep -c '^  bash: deny$' "$CFG/agents/loop-spec-readonly.md" || true)"
# CC-only frontmatter must not leak into the opencode dialect.
check "no CC model alias leaks" "0" "$(grep -c '^model: sonnet\|^model: opus' "$CFG/agents/"loop-spec-*.md | awk -F: '{s+=$NF} END {print s}')"
check "no CC effort key leaks" "0" "$(grep -c '^effort:' "$CFG/agents/"loop-spec-*.md | awk -F: '{s+=$NF} END {print s}')"

# --- idempotent re-install ---
OPENCODE_CONFIG_DIR="$CFG" bash "$LIB" install >/dev/null
check "re-install exits 0" "0" "$?"

# --- collisions are refused, not clobbered ---
CFG2="$TMP/opencode2"
mkdir -p "$CFG2/skills/loop-spec-cycle"
echo "user content" > "$CFG2/skills/loop-spec-cycle/SKILL.md"
rc=0; OPENCODE_CONFIG_DIR="$CFG2" bash "$LIB" install >/dev/null 2>&1 || rc=$?
check "collision -> exit 1" "1" "$rc"
check "user file untouched" "user content" "$(cat "$CFG2/skills/loop-spec-cycle/SKILL.md")"

# Generated wrappers and agents must use the same collision protection as
# linked artifacts; direct Python writes must never clobber user files.
CFG4="$TMP/opencode4"
mkdir -p "$CFG4/commands/loop-spec" "$CFG4/agents"
echo "user wrapper" > "$CFG4/commands/loop-spec/cycle.md"
echo "user agent" > "$CFG4/agents/loop-spec-verifier.md"
rc=0; OPENCODE_CONFIG_DIR="$CFG4" bash "$LIB" install >/dev/null 2>&1 || rc=$?
check "generated collision -> exit 1" "1" "$rc"
check "user wrapper untouched" "user wrapper" "$(cat "$CFG4/commands/loop-spec/cycle.md")"
check "user agent untouched" "user agent" "$(cat "$CFG4/agents/loop-spec-verifier.md")"

# A manifest symlink must not let install overwrite an external file.
CFG5="$TMP/opencode5"; mkdir -p "$CFG5"
echo "external manifest target" > "$TMP/external-manifest"
ln -s "$TMP/external-manifest" "$CFG5/loop-spec-install.json"
rc=0; OPENCODE_CONFIG_DIR="$CFG5" bash "$LIB" install >/dev/null 2>&1 || rc=$?
check "manifest symlink -> nonzero" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"
check "external manifest target untouched" "external manifest target" "$(cat "$TMP/external-manifest")"

# --- status ---
out="$(OPENCODE_CONFIG_DIR="$CFG" bash "$LIB" status)"
check "status reports installed" "yes" "$(grep -q '^installed:' <<<"$out" && echo yes || echo no)"

# --- uninstall removes exactly its manifest paths ---
echo "keep me" > "$CFG/skills/user-skill-marker"
OPENCODE_CONFIG_DIR="$CFG" bash "$LIB" uninstall >/dev/null
check "cycle skill removed" "no" "$([[ -f "$CFG/skills/loop-spec-cycle/SKILL.md" ]] && echo yes || echo no)"
check "agents removed" "0" "$(ls "$CFG/agents" 2>/dev/null | wc -l | tr -d ' ')"
check "skill wrappers removed" "0" "$(ls "$CFG/commands/loop-spec" 2>/dev/null | wc -l | tr -d ' ')"
check "manifest removed" "no" "$([[ -f "$CFG/loop-spec-install.json" ]] && echo yes || echo no)"
check "unrelated user file kept" "keep me" "$(cat "$CFG/skills/user-skill-marker")"

# Corrupt or hostile manifests fail closed and remain available for recovery.
CFG6="$TMP/opencode6"; mkdir -p "$CFG6" "$TMP/victim"
echo "keep" > "$TMP/victim/data"
jq -n --arg p "$CFG6/../victim" '{version:"x",mode:"link",created:[$p]}' > "$CFG6/loop-spec-install.json"
rc=0; OPENCODE_CONFIG_DIR="$CFG6" bash "$LIB" uninstall >/dev/null 2>&1 || rc=$?
check "traversal manifest -> nonzero" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"
check "traversal target preserved" "keep" "$([[ -f "$TMP/victim/data" ]] && cat "$TMP/victim/data" || echo missing)"
check "unsafe manifest retained" "yes" "$([[ -f "$CFG6/loop-spec-install.json" ]] && echo yes || echo no)"

# If an installed artifact was replaced by user content, uninstall preserves it.
CFG7="$TMP/opencode7"
OPENCODE_CONFIG_DIR="$CFG7" bash "$LIB" install >/dev/null
rm "$CFG7/skills/loop-spec-cycle/SKILL.md"
echo "replacement" > "$CFG7/skills/loop-spec-cycle/SKILL.md"
rc=0; OPENCODE_CONFIG_DIR="$CFG7" bash "$LIB" uninstall >/dev/null 2>&1 || rc=$?
check "modified install -> nonzero" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"
check "replacement artifact preserved" "replacement" "$([[ -f "$CFG7/skills/loop-spec-cycle/SKILL.md" ]] && cat "$CFG7/skills/loop-spec-cycle/SKILL.md" || echo missing)"

# Reinstall migrates the previous generic-skill layout instead of orphaning it.
CFG8="$TMP/opencode8"; mkdir -p "$CFG8/skills"
ln -s "$REPO/skills/cycle" "$CFG8/skills/cycle"
jq -n --arg p "$CFG8/skills/cycle" '{version:"2.19.1",mode:"link",created:[$p]}' > "$CFG8/loop-spec-install.json"
OPENCODE_CONFIG_DIR="$CFG8" bash "$LIB" install >/dev/null
check "legacy generic skill removed" "no" "$([[ -e "$CFG8/skills/cycle" || -L "$CFG8/skills/cycle" ]] && echo yes || echo no)"
check "legacy path dropped from manifest" "0" "$(jq --arg p "$CFG8/skills/cycle" '[.created[] | select(. == $p)] | length' "$CFG8/loop-spec-install.json")"
check "namespaced replacement installed" "yes" "$([[ -f "$CFG8/skills/loop-spec-cycle/SKILL.md" ]] && echo yes || echo no)"
OPENCODE_CONFIG_DIR="$CFG8" bash "$LIB" uninstall >/dev/null
check "migrated install uninstalls cleanly" "no" "$([[ -f "$CFG8/skills/loop-spec-cycle/SKILL.md" ]] && echo yes || echo no)"

# --- project-mode targets <dir>/.opencode ---
PROJ="$TMP/proj"; mkdir -p "$PROJ"
bash "$LIB" install --project "$PROJ" >/dev/null
check "project install under .opencode" "yes" "$([[ -f "$PROJ/.opencode/loop-spec-install.json" ]] && echo yes || echo no)"

# --- copy mode is rejected until a self-contained package layout exists ---
CFG3="$TMP/opencode3"
rc=0; OPENCODE_CONFIG_DIR="$CFG3" bash "$LIB" install --copy >/dev/null 2>&1 || rc=$?
check "copy mode rejected" "2" "$rc"
check "copy mode writes no manifest" "no" "$([[ -e "$CFG3/loop-spec-install.json" ]] && echo yes || echo no)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
