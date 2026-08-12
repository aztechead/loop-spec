#!/usr/bin/env bash
# Validates all 16 agent defs.
set -euo pipefail
EXPECTED="${EXPECTED:-16}"
ALLOWED_MODELS="inherit"
RESTRICTED_AGENTS="spec-compliance-reviewer code-reviewer advocate challenger"

count=$(ls agents/*.md 2>/dev/null | grep -v '/README\.md$' | wc -l | tr -d ' ')
[[ "$count" == "$EXPECTED" ]] || { echo "FAIL: expected $EXPECTED agent files, found $count"; exit 1; }

for f in agents/*.md; do
  [[ "$(basename "$f")" == "README.md" ]] && continue
  basename=$(basename "$f" .md)

  # Extract frontmatter block (between first two ---)
  fm=$(awk '/^---$/{c++; next} c==1{print} c==2{exit}' "$f")
  [[ -n "$fm" ]] || { echo "FAIL: $f missing frontmatter"; exit 1; }

  # name: must match filename
  fm_name=$(echo "$fm" | grep '^name:' | sed 's/^name: *//')
  [[ "$fm_name" == "$basename" ]] || { echo "FAIL: $f name '$fm_name' != filename '$basename'"; exit 1; }

  # description: must be non-empty
  echo "$fm" | grep -q '^description: .\+' || { echo "FAIL: $f missing description"; exit 1; }

  # tools: must be a YAML list
  echo "$fm" | grep -q '^tools:' || { echo "FAIL: $f missing tools"; exit 1; }

  # model: must be one of allowed
  fm_model=$(echo "$fm" | grep '^model:' | sed 's/^model: *//')
  echo "$ALLOWED_MODELS" | grep -wq "$fm_model" || { echo "FAIL: $f model '$fm_model' not in allowed set"; exit 1; }

  # Forbidden frontmatter keys: skills: and mcpServers: (plus hooks:/permissionMode:,
  # which Claude Code ignores for plugin agents -- a silently-dead field is a defect)
  if echo "$fm" | grep -qE '^(skills|mcpServers|hooks|permissionMode):'; then
    echo "FAIL: $f contains forbidden frontmatter key (skills:, mcpServers:, hooks:, or permissionMode:)"
    exit 1
  fi

  # memory: if present, must be a valid scope
  fm_memory=$(echo "$fm" | grep '^memory:' | sed 's/^memory: *//' || true)
  if [[ -n "$fm_memory" ]] && ! echo "user project local" | grep -wq "$fm_memory"; then
    echo "FAIL: $f invalid memory scope '$fm_memory' (allowed: user, project, local)"
    exit 1
  fi

  # color: if present, must be a valid display color
  fm_color=$(echo "$fm" | grep '^color:' | sed 's/^color: *//' || true)
  if [[ -n "$fm_color" ]] && ! echo "red blue green yellow purple orange pink cyan" | grep -wq "$fm_color"; then
    echo "FAIL: $f invalid color '$fm_color'"
    exit 1
  fi

  # maxTurns: forbidden — the plugin runs full bore; only iterate rounds bound work
  if echo "$fm" | grep -q '^maxTurns:'; then
    echo "FAIL: $f contains forbidden frontmatter key maxTurns (no per-dispatch turn caps)"
    exit 1
  fi

  # isolation: forbidden. Frontmatter isolation never appears in a tool call's input,
  # so hooks/team/no-worktrees-guard.sh cannot see it and LOOP_SPEC_WORKTREES=0 could
  # not be enforced for that agent. It also branches from the base commit, hiding prior
  # tasks' commits in a sequential DAG (see agents/implementer.md). Worktrees are
  # created explicitly by the dispatch contract, never by the harness.
  if echo "$fm" | grep -q '^isolation:'; then
    echo "FAIL: $f contains forbidden frontmatter key isolation (invisible to the LOOP_SPEC_WORKTREES=0 tool-boundary guard; create worktrees explicitly)"
    exit 1
  fi

  # ${CLAUDE_PLUGIN_ROOT} is a hooks/MCP variable (CLAUDE.md). It is not exported into
  # an agent's prompt context, and unlike skills there is no per-agent equivalent of
  # ${CLAUDE_SKILL_DIR}. An agent instructed to read a path built from it gets a
  # literal, non-existent path and fails outright -- or silently free-forms the
  # artifact it was supposed to template. Reference bundled files repo-relatively.
  if grep -q 'CLAUDE_PLUGIN_ROOT' "$f"; then
    echo "FAIL: $f references \${CLAUDE_PLUGIN_ROOT}, which does not expand in an agent prompt (use a repo-relative path)"
    exit 1
  fi

  # Restricted agents must have NO Write/Edit
  role="$basename"
  if echo "$RESTRICTED_AGENTS" | grep -wq "$role"; then
    if echo "$fm" | grep -qE '^  - (Write|Edit)$'; then
      echo "FAIL: $f is restricted role but has Write/Edit in tools"
      exit 1
    fi
  fi
done

echo "All $EXPECTED agents validated."
