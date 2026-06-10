# Harness Alignment + Graphify Migration

**Slug:** `harness-alignment-graphify`
**Created:** 2026-05-28
**Tier:** quick
**Execution style:** auto

## Problem

Three independent issues are addressed together because they all touch the same harness-integration layer and would otherwise create conflicting intermediate states if shipped separately.

**Bug - worktree.baseRef default changed.** Claude Code v2.1.133 changed the default value of `worktree.baseRef` from `"head"` to `"fresh"`. The `"fresh"` setting creates implementer worktrees branching from `origin/{default}` rather than local HEAD, silently losing any unpushed commits on the feature branch. EXECUTE phase worktrees created after this CC version silently miss recent commits with no error or warning.

**Cleanup - hook event migration.** The `PostToolUse:TaskUpdate` matcher used by `task-completed.sh` predates the dedicated `TaskCompleted` and `TaskCreated` hook events added to the Claude Code harness. The current approach requires the hook to parse the `tool_input.status` field and branch on it, which is brittle against payload format changes. The dedicated events fire only for their specific transitions, provide structured payloads, and support `continueOnBlock: true` so implementers can fix and retry in the same turn rather than ending the turn on a block. Additionally, `TaskCreated` schema validation currently happens at `PostToolUse:TaskUpdate` which is too late; a dedicated `TaskCreated` hook can reject malformed tasks before they enter the harness task list.

**Capability - graphify integration.** The five-mapper codebase mapping system dispatches separate agents for ARCH and TECH domains. Graphify (PyPI: `graphifyy`; CLI: `graphify`) builds a queryable AST-based knowledge graph covering the same structural and technology information as ARCH.md and TECH.md using a single `graphify . --update` invocation. The query interface (`graphify query/path/explain`) is token-efficient and scoped, unlike reading flat markdown files. Because graphify is a third-party tool that violates the zero-dep philosophy, integration must be optional: loop-spec falls back to the five-mapper path when graphify is not installed.

## Goals

- Fix the worktree.baseRef regression so EXECUTE worktrees always branch from local HEAD.
- Replace the `PostToolUse:TaskUpdate` hook with dedicated `TaskCompleted` and `TaskCreated` event handlers, adding `continueOnBlock: true` and creation-time schema validation.
- Integrate graphify as an optional replacement for the ARCH and TECH mappers, with graceful degradation to the existing five-mapper fallback when graphify is absent.
- Update `skills/map-codebase/SKILL.md` to support both paths (graphify-present and graphify-absent) with a clear pre-flight detection step.
- Run `graphify . --update` in `skills/verify/SKILL.md` before the map-codebase invocation, keeping the graph current with the just-merged feature code.
- Update `agents/loop-spec-planner.md` and `agents/loop-spec-pattern-mapper.md` to prefer `graphify query/path/explain` for structural and architectural questions when the graph is available.
- Update the `index.json` schema definition in `skills/shared/feature-state-schema.md` to track graphify state and reflect the reduced mapper set in graphify-present mode.
- Remove `agents/loop-spec-mapper-arch.md` and `agents/loop-spec-mapper-tech.md`, which are superseded by graphify in the graphify-present path.

## Non-goals

- Checking-gate and specifying-gate skills (Cycle 2).
- User-gate hooks (Cycle 2).
- Anti-shallow planner rules (Cycle 3).
- Decision coverage gate (Cycle 3).
- Plan-adherence exit check (Cycle 3).
- Post-merge build/test gate (Cycle 3).
- Strategy-rotation hook (Cycle 3).
- Budget-gate hook (Cycle 3).
- Any Cycle 4 or Cycle 5 scope items.
- Modifying graphify itself (integration only, read-only consumer).
- Making graphify a hard dependency of loop-spec.

## Constraints

- Runtime stack is bash, git, jq, and python3 stdlib only. No new package manager or manifest file is introduced.
- Graphify (`pip install graphifyy`) is a third-party Python package and is explicitly NOT bundled. All code paths must work without it.
- All commits must use the format: `<type>: NO_JIRA <message>`.
- No em-dash anywhere in any modified or added file.
- The graphify CLI reference is at `/Users/cbobrowitz/Projects/_reference/graphify/` and is the authoritative source for command syntax.

## User-facing behavior

**Before this change:**
- A Claude Code upgrade to v2.1.133+ causes EXECUTE worktrees to branch from `origin/main` instead of local HEAD, silently dropping unpushed feature commits with no error or warning.
- `hooks/hooks.json` uses a `PostToolUse:TaskUpdate` matcher with status-parsing shell logic to detect completion; this fires on every `TaskUpdate`, not only on completion transitions.
- All five codebase mappers always run (TECH, ARCH, QUALITY, CONCERNS, DOMAIN), regardless of whether graphify is installed.
- Task schema validation fires at completion time rather than at creation time.
- Planner and pattern-mapper agents read flat ARCH.md and TECH.md files for structural questions.

**After this change:**
- `.claude/settings.json` contains `worktree.baseRef: "head"`, restoring the pre-v2.1.133 behavior. EXECUTE worktrees always branch from local HEAD and preserve unpushed commits.
- `hooks/hooks.json` uses a dedicated `TaskCompleted` event with `continueOnBlock: true` and a dedicated `TaskCreated` event. Task schema is validated at creation time (exit 2 blocks the `TaskCreate` call before the task enters the harness). Implementers that trip the `TaskCompleted` gate can fix and retry in the same turn.
- When graphify is installed: `map-codebase` runs `graphify . --update --wiki` and dispatches only the QUALITY, CONCERNS, and DOMAIN mappers (3 instead of 5). A one-line install hint is printed when graphify is absent.
- `verify/SKILL.md` runs `graphify . --update` (conditional on presence) before invoking `map-codebase`, so the graph reflects the just-merged feature code when mappers read it.
- Planner and pattern-mapper agents are instructed to prefer `graphify query/path/explain` over reading flat ARCH.md for structural questions, with QUALITY.md, CONCERNS.md, and DOMAIN.md reads unchanged.
- `skills/shared/feature-state-schema.md` defines a new `graphify` block in the index.json schema and documents the reduced `last_refreshed_at` domain set for graphify-present runs.

## Success criteria

- [ ] `cat /Users/cbobrowitz/Projects/loop-spec/.claude/settings.json | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['worktree']['baseRef'] == 'head', 'FAIL'"` exits 0. Pass: no output and exit code 0. Fail: AssertionError or file missing.
- [ ] `python3 -c "import json; d=json.load(open('/Users/cbobrowitz/Projects/loop-spec/hooks/hooks.json')); events=list(d['hooks'].keys()); assert 'TaskCompleted' in events, 'no TaskCompleted'; assert 'TaskCreated' in events, 'no TaskCreated'; tu=[h for h in d['hooks'].get('PostToolUse',[]) if h.get('matcher','')=='TaskUpdate']; assert len(tu)==0, 'PostToolUse:TaskUpdate still present'"` exits 0. Pass: exit code 0. Fail: AssertionError or key error.
- [ ] `python3 -c "import json; hooks=json.load(open('/Users/cbobrowitz/Projects/loop-spec/hooks/hooks.json')); tc=[h for ev,hl in hooks['hooks'].items() if ev=='TaskCompleted' for h in hl]; assert any(h.get('continueOnBlock') for h in tc), 'continueOnBlock missing'"` exits 0. Pass: exit code 0. Fail: AssertionError.
- [ ] `test -x /Users/cbobrowitz/Projects/loop-spec/hooks/team/task-created.sh` exits 0. Pass: file exists and is executable. Fail: non-zero exit.
- [ ] `bash /Users/cbobrowitz/Projects/loop-spec/hooks/team/task-created.sh` fed a payload with missing required metadata fields exits 2. Verify: `echo '{"tool_name":"TaskCreate","tool_input":{"metadata":{}}}' | bash hooks/team/task-created.sh; echo $?` in repo root produces `2`. Pass: exit code is 2. Fail: exit code is 0 or 1.
- [ ] `grep -n 'status.*completed\|if.*status' /Users/cbobrowitz/Projects/loop-spec/hooks/team/task-completed.sh` returns no matches. Pass: grep exits 1 (no match). Fail: grep exits 0 (status-parsing still present).
- [ ] `test ! -f /Users/cbobrowitz/Projects/loop-spec/agents/loop-spec-mapper-arch.md && test ! -f /Users/cbobrowitz/Projects/loop-spec/agents/loop-spec-mapper-tech.md` exits 0. Pass: both files absent. Fail: either file still exists.
- [ ] `grep -n 'command -v graphify' /Users/cbobrowitz/Projects/loop-spec/skills/map-codebase/SKILL.md` returns at least one match AND `grep -n 'graphify.*--update\|--update.*graphify' /Users/cbobrowitz/Projects/loop-spec/skills/map-codebase/SKILL.md` returns at least one match. Pass: both greps exit 0. Fail: either exits 1.
- [ ] `grep -n 'fallback\|5.*mapper\|five.*mapper\|mapper-tech\|mapper-arch' /Users/cbobrowitz/Projects/loop-spec/skills/map-codebase/SKILL.md` returns at least one match confirming the fallback path is documented. Pass: grep exits 0. Fail: grep exits 1.
- [ ] `grep -n 'command -v graphify\|graphify.*--update' /Users/cbobrowitz/Projects/loop-spec/skills/verify/SKILL.md` returns at least one match. Pass: grep exits 0. Fail: grep exits 1.
- [ ] `grep -n 'graphify.*query\|graphify.*path\|graphify.*explain\|graphify-out/wiki' /Users/cbobrowitz/Projects/loop-spec/agents/loop-spec-planner.md` returns at least one match. Pass: grep exits 0. Fail: grep exits 1.
- [ ] `grep -n 'graphify.*query\|graphify.*path\|graphify.*explain\|graphify-out/wiki' /Users/cbobrowitz/Projects/loop-spec/agents/loop-spec-pattern-mapper.md` returns at least one match. Pass: grep exits 0. Fail: grep exits 1.
- [ ] `grep -n 'graphify' /Users/cbobrowitz/Projects/loop-spec/skills/shared/feature-state-schema.md` returns at least one match AND the match includes `last_updated` or `graph_json_path` or `wiki_path`. Pass: grep exits 0 and content matches. Fail: grep exits 1 or content does not include the new graphify block.
- [ ] `bash /Users/cbobrowitz/Projects/loop-spec/tests/smoke.sh` exits 0 with no test failures. Pass: exit code 0. Fail: non-zero exit code or any FAIL line in output.
- [ ] `grep -n 'worktree.baseRef\|TaskCompleted\|TaskCreated\|continueOnBlock\|graphify' /Users/cbobrowitz/Projects/loop-spec/CHANGELOG.md` returns matches and the matches appear under an `[Unreleased]` heading. Pass: grep exits 0 and `[Unreleased]` heading precedes the matched lines. Fail: grep exits 1 or matches appear only under a versioned heading.
- [ ] `bash /Users/cbobrowitz/Projects/loop-spec/tests/validate-agents.sh` exits 0. The expected agent count must be updated from 14 to 12 (reflecting deletion of mapper-arch and mapper-tech). Pass: exit code 0. Fail: non-zero exit code or FAIL lines in output.

## Out of scope

The following items were explicitly considered during scope discussion and deferred to later cycles:

- **Checking-gate and specifying-gate skills** (Cycle 2): new skill definitions for gating that are unrelated to harness alignment.
- **User-gate hooks** (Cycle 2): human-in-the-loop approval hooks requiring new event types.
- **Anti-shallow planner rules** (Cycle 3): prompt-level rules to prevent underspecified tasks.
- **Decision coverage gate** (Cycle 3): a gate verifying that every SPEC decision is exercised by the plan.
- **Plan-adherence exit check** (Cycle 3): a verify-time check that EXECUTE did not drift from PLAN.
- **Post-merge build/test gate** (Cycle 3): CI-style gate running the full test suite after each task merge.
- **Strategy-rotation hook** (Cycle 3): hook that rotates implementer strategy on repeated rework.
- **Budget-gate hook** (Cycle 3): hook that halts the cycle when the global retry budget approaches exhaustion.
- **graphify QUALITY, CONCERNS, and DOMAIN mapper replacement**: research synthesis confirmed graphify cannot replace these three domains (they require test execution, pattern scanning, and semantic understanding that graphify's AST graph does not provide). Only ARCH and TECH are replaced.
- **graphify as a bundled or hard dependency**: zero-dep philosophy is preserved; graphify is never required.
- **Modifying graphify source**: loop-spec is a read-only consumer of the graphify CLI.

## Open questions

(none - resolved during DISCUSS phase)
