#!/usr/bin/env bash
# human-code-inject.sh - Inject the code-for-humans and docs-for-humans directives
# on SessionStart.
# Reads .loop-spec/human-code.conf from CLAUDE_PROJECT_DIR (or CWD).
#
# DEFAULT IS ON (like grill-inject and simplicity-inject, unlike opt-in
# discipline): the directive is injected unless explicitly disabled. The
# dispatch rungs carry their own copy for agents a SessionStart hook cannot
# reach; this covers the main thread, where most ad-hoc edits are made.
#
# Suppressed only when:
#   - .loop-spec/human-code.conf contains ENABLED=0, OR
#   - LOOP_SPEC_HUMAN_CODE=0 is set (session-level kill switch), OR
#   - the project is not a loop-spec project (no .loop-spec/ dir).
#
# Environment variables:
#   LOOP_SPEC_HUMAN_CODE  Set to "0" to disable (kill switch). Default: on.
#   CLAUDE_PROJECT_DIR    Project root to find conf file. Defaults to CWD.

set -euo pipefail

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR

# Kill switch.
if [[ "${LOOP_SPEC_HUMAN_CODE:-1}" == "0" ]]; then
  printf '{}\n'
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"

# Self-scope: only act inside loop-spec projects, matching every other loop-spec
# SessionStart hook. A default-ON directive must not inject into unrelated
# projects just because the plugin is installed.
if [[ ! -d "${PROJECT_DIR}/.loop-spec" ]]; then
  printf '{}\n'
  exit 0
fi

CONF_FILE="${PROJECT_DIR}/.loop-spec/human-code.conf"

# The directive names three scripts the model has to RUN, and the session's cwd is the
# user's project, not the plugin. Resolve them from this hook's own location -- the
# probes ship beside it -- so the paths are correct wherever the plugin is installed.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" 2>/dev/null && pwd || true)"

# Opt-out: if the conf file exists AND pins ENABLED=0, stay silent.
# Absent conf file => default ON (inject).
if [[ -f "$CONF_FILE" ]] && grep -q "ENABLED=0" "$CONF_FILE" 2>/dev/null; then
  printf '{}\n'
  exit 0
fi

DIRECTIVE="CODE FOR HUMANS MODE ACTIVE (default): write code for the next person to read, not for the compiler. Code is read far more often than it is written, and the reader arrives with a half-loaded mental model of the module.

Read the neighbors before writing a line, and match them:
1. Naming, error idiom, test structure, file layout, import order, how they log, how they fail.
2. The house convention outranks any external guide, and it outranks your own defaults even where you would have chosen differently.
3. Disagreeing with a convention is a finding to report, never a licence to deviate inside your diff.
4. Where the convention is not obvious, measure it instead of guessing: 'bash ${LIB_DIR}/house-style.sh probe <files>' reports comment density, doc-comment usage, indentation, naming case, and line length from the actual neighbors, and says unknown rather than inventing an answer. When you have finished writing, check your own work: 'bash ${LIB_DIR}/house-style.sh compare <files you touched>' holds each file out of its own baseline and names where it deviates from its same-language neighbors -- indent, naming, quotes, semicolons, module system. Use compare for that question, never probe: probe pools your file into the sample, so a file breaking every convention around it reports as the convention.

Comments carry WHY, never what. The code already says what it does; a comment restating it goes stale on the first edit and misleads from then on. Spend a comment on what the code cannot say: a constraint not visible locally, a decision and the alternative it beat, a workaround and its reason, a landmine for the next reader. Never narrate the code, restate a signature, announce the edit ('Added...', 'Updated...'), or narrate history ('previously...', 'renamed from...') -- 'bash ${LIB_DIR}/comment-tells.sh scan <files>' catches those three shapes.

Comment DENSITY matches the file, not an absolute: do not add docstrings to a module that has none, or strip them from one that documents everything. A good name deletes a comment -- reach for the name first. Early return over nested branch, one idea per function. Keep the diff readable: no drive-by reformatting, no unrelated renames, no churn that buries the real change.

Never cut: 'simplicity:' shortcut markers, file-header purpose blocks where the codebase uses them, TODO/FIXME/NOTE/HACK/SAFETY/SECURITY markers, spec- or API-required contract docs, or any comment encoding a non-obvious why.

DOCS FOR HUMANS: the markdown is a deliverable too. A person maintains and operates every document you write after this session ends, so name its reader in the first line -- someone about to CHANGE this system, or someone about to RUN it -- and hold one job per document: a how-to gets a task done, a reference states facts, an explanation says why. Blending them serves neither reader.

A procedure states its prerequisites first, then the exact copy-pasteable command, then what success looks like, then what to do when the step fails. A command whose expected output you never described cannot be checked by the person running it.

Cite, never copy: point at file:line rather than restating what the code says. Stale prose is worse than none because it is wrong with authority. If a change makes a document false -- README, help text, runbook, configuration table -- fix it in the SAME diff; a follow-up documentation task is deferred scope. Ground every claim: never write what the code probably does. Prefer one page the project will keep true over five that decay, and never invent a documentation convention this repository does not already have. Check your own writing with 'bash ${LIB_DIR}/doc-tells.sh scan <the markdown you touched>': it flags a relative link with no target, an inline-code path the tree no longer holds, and a command holding a placeholder the prose never explains. Never cut frontmatter, machine-read contract sections, required artifact headings, EVID citation lines, or license blocks. Full contract: skills/shared/human-docs.md.

Code-for-humans mode is ON by default and covers both halves -- the code and the docs that ship with it. Disable it with /loop-spec:human-code off or LOOP_SPEC_HUMAN_CODE=0."

# Emit valid JSON via jq (hard dependency) rather than a hand-rolled escaper.
jq -n --arg ctx "$DIRECTIVE" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
