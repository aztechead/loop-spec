#!/usr/bin/env bash
# Contract test: every shipped environment name and public CLI surface is present
# in the canonical configuration reference.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/docs/loop-spec/configuration.md"
PASS=0
FAIL=0

# Every sweep below enumerates the tree with `rg`. Without it each `rg -o | sort -u`
# feeds an EMPTY list into the while loops and all of them report ✓ having checked
# nothing -- a green suite that verified nothing is worse than a red one.
if ! command -v rg >/dev/null 2>&1; then
  echo "configuration-coverage: ripgrep (rg) is required; see tests/README.md" >&2
  exit 1
fi

ok() {
  PASS=$((PASS + 1))
  printf '  ✓ %s\n' "$1"
}

bad() {
  FAIL=$((FAIL + 1))
  printf '  ✗ %s\n' "$1"
}

contains_literal() {
  grep -Fq "\`$1\`" "$DOC"
}

contains_text() {
  grep -Fq -- "$1" "$DOC"
}

# The model routes are the one family whose variable names are CONSTRUCTED rather
# than written out: feature-init.sh builds `LOOP_SPEC_PHASE_MODEL_${suffix}` from a
# phase, so grepping the shipped tree for the concrete name finds nothing. The
# suffixes it actually supports are derived from that same executable source -- a
# bare prefix match would accept a documented LOOP_SPEC_PHASE_MODEL_REVIEW for a
# phase that does not exist, which is the defect this whole check exists to catch.
phase_suffixes() {
  grep -oE '^[[:space:]]+[a-z]+\) echo [A-Z_]+ ;;' "$ROOT/lib/feature-init.sh" | grep -oE '[A-Z_]+'
}

role_suffixes() {
  grep -oE 'resolve_role_model [A-Z_]+' "$ROOT/lib/feature-init.sh" | grep -oE '[A-Z_]+$'
}

has_consumer() {
  local name="$1"
  if rg -Fq "$name" \
    "$ROOT/agents" "$ROOT/commands" "$ROOT/extensions" "$ROOT/hooks" "$ROOT/lib" "$ROOT/skills" \
    "$ROOT/docs/loop-spec/cloud-run-autonomous.md" \
    --glob '!*.test.sh' --glob '!**/tests/**'; then
    return 0
  fi

  case "$name" in
    # The family headers themselves (`LOOP_SPEC_PHASE_MODEL_<PHASE>` reduces to
    # this once the placeholder is stripped): the construction site is the consumer.
    LOOP_SPEC_PHASE_MODEL_)
      rg -Fq 'var="LOOP_SPEC_PHASE_MODEL_${suffix}"' "$ROOT/lib/feature-init.sh"
      ;;
    LOOP_SPEC_MODEL_)
      rg -Fq 'local var="LOOP_SPEC_MODEL_${env_suffix}"' "$ROOT/lib/feature-init.sh"
      ;;
    LOOP_SPEC_PHASE_MODEL_*)
      phase_suffixes | grep -qx -- "${name#LOOP_SPEC_PHASE_MODEL_}"
      ;;
    LOOP_SPEC_MODEL_*)
      role_suffixes | grep -qx -- "${name#LOOP_SPEC_MODEL_}"
      ;;
    *)
      return 1
      ;;
  esac
}

echo "configuration reference coverage"

if [[ -s "$DOC" ]]; then
  ok "canonical reference exists"
else
  bad "canonical reference is missing"
fi

missing_env=()
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  contains_text "$name" || missing_env+=("$name")
done < <(
  rg -o --no-filename 'LOOP_SPEC_[A-Z0-9_]+' \
    "$ROOT/agents" "$ROOT/commands" "$ROOT/extensions" "$ROOT/hooks" "$ROOT/lib" "$ROOT/skills" \
    --glob '!*.test.sh' --glob '!**/tests/**' | sort -u
)

if [[ ${#missing_env[@]} -eq 0 ]]; then
  ok "every shipped LOOP_SPEC_* name is classified"
else
  bad "undocumented environment names: ${missing_env[*]}"
fi

missing_consumers=()
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  if ! has_consumer "$name"; then
    missing_consumers+=("$name")
  fi
done < <(
  sed -n '/^## Supported environment variables/,/^## Skill command arguments/p' "$DOC" \
    | rg -o 'LOOP_SPEC_[A-Z0-9_]+' | sort -u
)

if [[ ${#missing_consumers[@]} -eq 0 ]]; then
  ok "every documented LOOP_SPEC_* input has a shipped consumer"
else
  bad "documented inputs without consumers: ${missing_consumers[*]}"
fi

# The constructed-name fallback must still REJECT a suffix the router does not
# support, or it silently licenses the whole family.
if has_consumer LOOP_SPEC_PHASE_MODEL_REVIEW || has_consumer LOOP_SPEC_MODEL_ARCHITECT; then
  bad "constructed-name fallback accepts an unsupported phase/role suffix"
else
  ok "constructed-name fallback rejects an unsupported phase/role suffix"
fi

missing_host_env=()
for name in \
  CLAUDE_CODE_DISABLE_WORKFLOWS \
  CLAUDE_CODE_ENTRYPOINT \
  CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS \
  CLAUDE_CODE_MAX_RETRIES \
  CLAUDE_CODE_RETRY_WATCHDOG \
  CLAUDE_CODE_STOP_HOOK_BLOCK_CAP \
  CLAUDE_CODE_SESSION_ID \
  CLAUDE_EFFORT \
  CLAUDE_FALLBACK_MODEL \
  CLAUDE_MAX_BUDGET_USD \
  CLAUDE_MAX_BUFFER_BYTES \
  CLAUDE_MAX_TURNS \
  CLAUDE_MODEL \
  CLAUDE_PERMISSION_MODE \
  CLAUDE_SESSION_ID \
  CLAUDECODE \
  CLAUDE_PLUGIN_ROOT \
  CLAUDE_PROJECT_DIR \
  CLAUDE_SKILL_DIR \
  GH_HOST \
  GH_TOKEN \
  GITHUB_TOKEN \
  GH_ENTERPRISE_TOKEN \
  GITHUB_ENTERPRISE_TOKEN \
  HOME \
  OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS \
  OPENCODE_CONFIG_DIR \
  TMPDIR \
  XDG_CONFIG_HOME \
  ANTHROPIC_API_KEY \
  CYCLE_TIMEOUT_SECONDS \
  MAX_PHASE_INVOCATIONS \
  REPO_ROOT \
  TASK_PROMPT; do
  contains_text "$name" || missing_host_env+=("$name")
done

if [[ ${#missing_host_env[@]} -eq 0 ]]; then
  ok "every host/installer environment input is classified"
else
  bad "undocumented host environment inputs: ${missing_host_env[*]}"
fi

missing_cli=()
while IFS= read -r flag; do
  [[ -n "$flag" ]] || continue
  contains_text "$flag" || missing_cli+=("$flag")
done < <(
  {
    rg '^argument-hint:' "$ROOT"/skills/*/SKILL.md \
      | rg -o -- '--[a-z][a-z0-9-]*' || true
    rg -o 'add_argument\("--[a-z][a-z0-9-]*' \
      "$ROOT"/skills/loop-runner/scripts/loop.py \
      "$ROOT"/skills/loop-runner/scripts/supervisor.py \
      "$ROOT"/skills/loop-runner/scripts/compile_spec.py \
      | sed 's/.*add_argument("//'
  } | sort -u
)

if [[ ${#missing_cli[@]} -eq 0 ]]; then
  ok "every public GNU-style flag is documented"
else
  bad "undocumented CLI flags: ${missing_cli[*]}"
fi

missing_skills=()
for skill_file in "$ROOT"/skills/*/SKILL.md; do
  rg -q '^argument-hint:' "$skill_file" || continue
  skill_name="$(basename "$(dirname "$skill_file")")"
  contains_literal "$skill_name" || missing_skills+=("$skill_name")
done

if [[ ${#missing_skills[@]} -eq 0 ]]; then
  ok "every skill with public arguments has a command row"
else
  bad "skills with undocumented arguments: ${missing_skills[*]}"
fi

for required in \
  'environment variable wins over persisted project or feature state' \
  'LOOP_SPEC_WORKTREES=0' \
  'phase:fresh' \
  'phase:continuous' \
  'Injected and internal variables'; do
  if grep -Fq "$required" "$DOC"; then
    ok "contract states: $required"
  else
    bad "contract omits: $required"
  fi
done

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
