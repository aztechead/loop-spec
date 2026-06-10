# Resilience + operations layer

**Slug:** `resilience-ops`
**Created:** 2026-05-28
**Tier:** quick
**Execution style:** auto

## Problem

super-spec has no crash-recovery artifact a human can read mid-session, no diagnostic command when a feature gets stuck, no gate that verifies prior-cycle work has not regressed, and no rollback path beyond raw `git reset`. The EXECUTE remediation path spins up a full reviewer-gate team even for trivial one-task fix lists. SPEC.md lacks anti-goal and tiered success sections. There is no SessionStart discipline enforcement, no output compression for verbose tool results, no detection of compound task prompts that blur completion criteria, no accumulation of session-end learnings, and agent frontmatter is missing modern fields (`disallowedTools`, `effort`, `isolation`).

<decisions>
- Decision: HANDOFF.json + .continue-here.md dual artifact (machine + human). Rationale: feature.json is JSON-only and hard to parse during a mid-context-loss recovery. Alternatives considered: extending feature.json with a human-readable summary field (rejected: still requires JSON literacy to open); single markdown-only artifact (rejected: orchestrators need machine-parseable schema).
- Decision: /super-spec:forensics is read-only diagnostic. Rationale: destructive ops during stuck-feature triage add risk when the state is already unknown. Alternatives considered: auto-remediation as part of forensics (rejected: too risky in unknown state); interactive repair prompts (rejected: scope creep for diagnostic command).
- Decision: Regression gate is advisory-then-escalation, not a hard block. Rationale: prior phase test suites may have environmental drift unrelated to the current feature; a hard block would stall otherwise-valid work. Alternatives considered: hard block on any prior-phase failure (rejected: brittle across environments).
- Decision: Checkpoint rollback uses `git checkout TAG -- .` not `git reset --hard`. Rationale: history-safe; the rollback itself becomes a new commit, preserving the record. Alternatives considered: `git reset --hard` (rejected: destroys intervening history).
- Decision: Ralph remediation executor activates only when pendingRemediationTasks.length <= 3. Rationale: small lists benefit from inline fix loops; large lists still need full reviewer-gate parallelism. Alternatives considered: always use Ralph loop (rejected: does not scale to large fix lists); threshold configurable via env var (accepted: SUPER_SPEC_RALPH_THRESHOLD).
- Decision: Intent contract integrates into existing DISCUSS spec-writer (SPEC.md gains Boundaries + 2-tier success sections); no new agent. Rationale: minimal schema disruption; avoids a new agent lifecycle for what is a template and prompt change. Alternatives considered: new spec-intent agent (rejected: overhead exceeds benefit for a template addition).
- Decision: Discipline-mode toggle persists in `.super-spec/discipline.conf`. Rationale: per-project state prevents global side effects; survives shell session restarts. Alternatives considered: env-var-only toggle (rejected: does not persist across sessions); global ~/.config location (rejected: not per-project).
- Decision: Output compressor threshold = 3000 chars. Rationale: empirically validated in claude-octopus as the inflection point where verbosity exceeds actionable information. Alternatives considered: 1000 chars (rejected: too aggressive, truncates useful partial outputs); 5000 chars (rejected: misses frequent verbose Bash outputs).
- Decision: Session-end learnings cap at 50 entries (FIFO oldest dropped). Rationale: prevent unbounded growth of learnings.jsonl in long-running projects. Alternatives considered: no cap (rejected: file grows without bound); cap at 100 (accepted as alternative but 50 matches octopus default).
- Decision: Agent frontmatter changes are additive only; no existing field is made required. Rationale: existing agents not yet migrated must not break. Alternatives considered: require all three new fields immediately (rejected: breaks agents not yet updated).
</decisions>

## Goals

- Provide a human-readable crash-recovery artifact (`.continue-here.md`) alongside the machine-readable `HANDOFF.json` when the `/super-spec:pause` command is invoked.
- Provide a read-only `/super-spec:forensics` diagnostic that detects 7 anomaly patterns and writes a structured report without modifying project state.
- Add a regression gate to the VERIFY phase that runs prior completed features' test suites and logs advisory warnings on failure.
- Add checkpoint tagging at each phase boundary and a rollback skill that restores any checkpoint using history-safe `git checkout TAG -- .`.
- Route EXECUTE remediation to a bash-loop Ralph executor when the pending remediation task count is at or below the configured threshold (default 3).
- Extend SPEC.md with explicit `## Boundaries` and `## Success criteria` (two-tier: Good Enough / Exceptional) sections, enforced by the spec-writer agent and template.
- Add a `discipline-inject.sh` SessionStart hook that injects 5 behavioral gates when `.super-spec/discipline.conf` has `ENABLED=1`, toggled via `/super-spec:discipline on|off|status`.
- Add an `output-compressor.sh` PostToolUse hook that compresses tool outputs exceeding 3000 chars using shape-aware strategies (JSON array, JSON object, HTML, log).
- Add a `done-criteria.sh` UserPromptSubmit hook that detects compound task prompts and injects an explicit completion-criteria enumeration directive.
- Accumulate session learnings in `.super-spec/learnings.jsonl` (capped at 50 FIFO entries) via a `session-end-learnings.sh` SessionEnd hook.
- Add `disallowedTools`, `effort`, and `isolation` fields to relevant agent frontmatter, with documentation in `agents/README.md`.

## Non-goals

- Any Cycle 5 feature or spec-phase work.
- Making any of the 11 new features mandatory at the system level (all remain opt-in via kill switches or conf files).
- Adding Node.js, npm, pip, or brew dependencies to any runtime path.
- Removing or modifying existing functionality from Cycles 1 through 3.
- Auto-remediation within the forensics command (forensics is strictly read-only).
- Hard-blocking the regression gate on prior-phase test failures (advisory only).

## Constraints

- Runtime: `bash`, `git`, `jq`, `python3` stdlib only.
- All new hooks expose a kill-switch environment variable and are fail-open (any parse error, missing file, or unset env causes exit 0).
- All commits must use the format `<type>: NO_JIRA <message>`.
- References used for behavioral design:
  - `/Users/cbobrowitz/Projects/_reference/gsd-redux/` (pause snapshot, regression gate patterns)
  - `/Users/cbobrowitz/Projects/_reference/ralph/` (remediation loop pattern)
  - `/Users/cbobrowitz/Projects/_reference/claude-octopus/` (output compressor, done-criteria, session-end learnings patterns)

## User-facing behavior

**Pause and crash recovery.** Invoking `/super-spec:pause` triggers `lib/pause-snapshot.sh`, which writes two artifacts into `.super-spec/features/{slug}/`:

`HANDOFF.json` (machine schema) contains: `currentPhase`, `completedTasks[]`, `pendingTasks[]`, `blockers[]`, `decisions[]`, `uncommittedFiles[]`, `contextNotes`.

`.continue-here.md` (human-readable) contains: a BLOCKING CONSTRAINTS checklist, severity-tagged anti-patterns (`blocking` or `advisory`), and a Required Reading ordered list. The cycle/SKILL.md resume detection parses severity tags from this file to determine restart posture.

**Forensics diagnostic.** Invoking `/super-spec:forensics` runs `skills/forensics/SKILL.md` in read-only mode. It probes 7 anomaly patterns: stuck loop (same file modified in 3 or more consecutive commits), missing artifact (currentPhase does not match committed artifacts), partial plan drift (PLAN.md task count does not match completed plus remaining), abandoned work (commits on feature branch with no recent activity), crash or interruption (feature.json `updatedAt` exceeds stale threshold but `currentPhase` is not `completed`), scope drift (commits touch files outside PLAN.md `files[]`), and test regression (prior phase test suites failing). The command writes a structured report to `.super-spec/forensics/report-{ISO-8601}.md` and makes no changes to any other file.

**Regression gate.** Before the current feature's VERIFY step runs, `skills/verify/SKILL.md` calls `lib/regression-scan.sh <project-root>`. The script reads each `docs/super-spec/features/*/VERIFICATION.md` for prior completed features, extracts test commands, runs them, and returns JSON `{prior_features: [...], failed_tests: [...]}`. On failure, an advisory warning is logged in the VERIFICATION.md output; VERIFY is not blocked.

**Checkpoint rollback.** Phase skills (discuss, plan, execute, verify) call `lib/checkpoint.sh tag <type>` at phase completion, creating a git tag with format `super-spec-checkpoint-{type}-YYYYMMDD-HHMMSS`. Six checkpoint types exist: `post-discuss`, `post-plan`, `post-execute`, `post-verify` (auto at phase completion), `pre-rollback` (auto immediately before rollback executes), and `manual` (user-invoked via `/super-spec:checkpoint <name>`). Rollback via `skills/rollback/SKILL.md` uses `git checkout <TAG> -- .`, requires the user to type "ROLLBACK" to confirm, and creates a new commit (history-safe).

**Ralph remediation executor.** When `skills/verify/SKILL.md` encounters a HARD-GATE failure, it checks `pendingRemediationTasks.length` against `SUPER_SPEC_RALPH_THRESHOLD` (default 3). At or below threshold, `lib/ralph-remediation.sh <feature-dir>` runs a bash loop (max 5 iterations): each iteration dispatches a fresh implementer Agent with a single remediation task and checks the agent stdout for `<promise>COMPLETE</promise>`. The loop exits when all remediations resolve or the ceiling is reached. Above threshold, the existing full EXECUTE team behavior applies.

**Intent contract (SPEC.md sections).** `agents/super-spec-spec-writer.md` is updated to require two new sections in every SPEC.md: `## Boundaries (what NOT to do)` listing explicit anti-goals with concrete examples, and `## Success criteria` split into `### Good Enough` (minimum shippable) and `### Exceptional` (ideal) tiers. `skills/shared/artifact-templates/SPEC.md.template` is updated to show both sections.

**Discipline-mode.** `hooks/team/discipline-inject.sh` fires on SessionStart. If `.super-spec/discipline.conf` exists and contains `ENABLED=1`, the hook injects a directive listing 5 behavioral gates: brainstorm-before-coding, verification-before-claims, investigation-before-fixes, decision-gate, and intent-gate. Setting `SUPER_SPEC_DISCIPLINE=0` disables injection. `skills/discipline/SKILL.md` provides the `/super-spec:discipline on|off|status` slash command, which writes or updates `.super-spec/discipline.conf`.

**Output compressor.** `hooks/team/output-compressor.sh` fires on PostToolUse for Bash, Read, and Grep tools. Outputs exceeding 3000 chars are compressed using shape detection: JSON arrays compress to first 2 + last 2 elements plus count; JSON objects compress to first 15 keys plus count; HTML strips tags and retains the first 30 lines; log output retains head 15 + tail 15 lines. The hook fires on every 3rd call (debounce), injects the compressed summary as `additionalContext`, and exits 0 on any error (fail-open). Kill switch: `SUPER_SPEC_COMPRESSOR=0`.

**Done-criteria detector.** `hooks/team/done-criteria.sh` fires on UserPromptSubmit. It detects compound tasks via three heuristics: numbered lists (`1. 2. 3.`), multi-verb prompts containing "and" or "then", and bullet lists with 2 or more items containing action verbs. On detection it injects the instruction: "Enumerate completion criteria explicitly before starting. Verify each before declaring done." Kill switch: `SUPER_SPEC_DONE_CRITERIA=0`. Fail-open.

**Session-end learnings.** `hooks/team/session-end-learnings.sh` fires on SessionEnd (or Stop). It appends a JSONL line to `.super-spec/learnings.jsonl` with schema `{timestamp, sessionId, taskType, approach, outcome, lesson}`. Heuristic lesson generation: more than 3 agents dispatched logs "parallel dispatch effective"; any errors logged produces "partial outcome". The file is trimmed to 50 lines (oldest dropped). Kill switch: `SUPER_SPEC_LEARNINGS=0`.

**Agent frontmatter.** `agents/super-spec-implementer.md` gains `isolation: worktree`. At least 3 agents gain an `effort:` field (low/medium/high/xhigh/max). At least 1 agent gains a `disallowedTools:` field. `agents/README.md` (created if absent) documents all three fields and their semantics. All additions are additive; no existing required field changes.

## Boundaries (what NOT to do)

- Do NOT make any of the 11 new features mandatory (all must remain opt-in via kill switches or conf file).
- Do NOT add Node.js, npm, pip, or brew dependencies to any hook, lib script, or skill.
- Do NOT remove, modify, or degrade existing functionality from Cycles 1 through 3.
- Do NOT allow `skills/forensics` to write to project state beyond its structured report file.
- Do NOT hard-block VERIFY on prior-phase regression failures.
- Do NOT use `git reset --hard` in the rollback path.
- Do NOT let `learnings.jsonl` grow without bound; cap at 50 FIFO entries.
- Do NOT write an em-dash character anywhere in new or modified files.

## Success criteria

### Good Enough

- [ ] `skills/pause/SKILL.md` exists and documents generation of HANDOFF.json and .continue-here.md.
  Verify: `test -f skills/pause/SKILL.md && echo PASS`.

- [ ] `lib/pause-snapshot.sh` exists, is executable, and outputs valid JSON.
  Verify: `test -x lib/pause-snapshot.sh && bash lib/pause-snapshot.sh --dry-run 2>/dev/null | jq . > /dev/null && echo PASS`.

- [ ] `skills/forensics/SKILL.md` exists and documents all 7 anomaly patterns as read-only checks.
  Verify: `grep -c "stuck loop\|missing artifact\|plan drift\|abandoned\|crash\|scope drift\|regression" skills/forensics/SKILL.md` returns 7 or more.

- [ ] `lib/regression-scan.sh` exists, is executable, and outputs JSON with `prior_features` and `failed_tests` keys.
  Verify: `bash lib/regression-scan.sh . | jq 'has("prior_features") and has("failed_tests")'` returns `true`.

- [ ] `skills/verify/SKILL.md` references `lib/regression-scan.sh` and describes advisory (non-blocking) failure logging.
  Verify: `grep -c "regression-scan.sh" skills/verify/SKILL.md` returns 1 or more.

- [ ] `skills/rollback/SKILL.md` exists and documents all 6 checkpoint types and the typed "ROLLBACK" confirmation requirement.
  Verify: `grep -c "post-discuss\|post-plan\|post-execute\|post-verify\|pre-rollback\|manual" skills/rollback/SKILL.md` returns 6 or more.

- [ ] `lib/checkpoint.sh` exists, is executable, and supports `tag <type>` and `rollback <tag>` subcommands.
  Verify: `bash lib/checkpoint.sh 2>&1 | grep -c "tag\|rollback"` returns 1 or more.

- [ ] `lib/checkpoint.sh tag` is wired into all 4 phase SKILL.md files at phase completion.
  Verify: `grep -l "checkpoint.sh" skills/discuss/SKILL.md skills/plan/SKILL.md skills/execute/SKILL.md skills/verify/SKILL.md | wc -l | tr -d ' '` returns `4`.

- [ ] `lib/ralph-remediation.sh` exists, is executable, runs a bash loop with max 5 iterations, and checks for `<promise>COMPLETE</promise>` in agent stdout.
  Verify: `grep -c "COMPLETE\|max.*5\|5.*iter" lib/ralph-remediation.sh` returns 1 or more; `test -x lib/ralph-remediation.sh && echo PASS`.

- [ ] `skills/verify/SKILL.md` routes to Ralph when `pendingRemediationTasks.length <= SUPER_SPEC_RALPH_THRESHOLD` and documents the default threshold of 3.
  Verify: `grep -c "ralph-remediation.sh\|RALPH_THRESHOLD" skills/verify/SKILL.md` returns 1 or more.

- [ ] `agents/super-spec-spec-writer.md` requires `## Boundaries` and `## Success criteria` with `### Good Enough` and `### Exceptional` subsections.
  Verify: `grep -c "Boundaries\|Good Enough\|Exceptional" agents/super-spec-spec-writer.md` returns 3 or more.

- [ ] `skills/shared/artifact-templates/SPEC.md.template` contains `## Boundaries` and both `### Good Enough` and `### Exceptional` sections.
  Verify: `grep -c "Boundaries\|Good Enough\|Exceptional" skills/shared/artifact-templates/SPEC.md.template` returns 3 or more.

- [ ] `hooks/team/discipline-inject.sh` exists, is executable, fires on SessionStart, injects 5 gates when `ENABLED=1`, and exits 0 when `SUPER_SPEC_DISCIPLINE=0`.
  Verify: `bash hooks/team/discipline-inject.test.sh` passes "enabled inject", "kill switch", and "file absent" cases.

- [ ] `skills/discipline/SKILL.md` exists and documents `on`, `off`, and `status` subcommands writing to `.super-spec/discipline.conf`.
  Verify: `grep -c "on\|off\|status" skills/discipline/SKILL.md` returns 3 or more.

- [ ] `hooks/team/output-compressor.sh` exists, is executable, and compresses outputs above 3000 chars using shape detection.
  Verify: `bash hooks/team/output-compressor.test.sh` passes "threshold trigger", "JSON array", "kill switch", and "fail-open" cases.

- [ ] `hooks/team/done-criteria.sh` exists, is executable, detects compound task heuristics, and injects the completion-criteria directive.
  Verify: `bash hooks/team/done-criteria.test.sh` passes "numbered list", "multi-verb and", "bullet list", "kill switch", and "fail-open" cases.

- [ ] `hooks/team/session-end-learnings.sh` exists, is executable, appends valid JSONL, and caps file at 50 entries.
  Verify: `bash hooks/team/session-end-learnings.test.sh` passes "append", "cap at 50", and "kill switch" cases.

- [ ] `agents/super-spec-implementer.md` contains `isolation: worktree` in frontmatter.
  Verify: `grep -c "isolation: worktree" agents/super-spec-implementer.md` returns 1 or more.

- [ ] At least 3 agent files contain an `effort:` field and at least 1 contains `disallowedTools:`.
  Verify: `grep -rl "effort:" agents/ | wc -l | tr -d ' '` returns 3 or more; `grep -rl "disallowedTools:" agents/ | wc -l | tr -d ' '` returns 1 or more.

- [ ] `hooks/hooks.json` wires discipline-inject (SessionStart), output-compressor (PostToolUse), done-criteria (UserPromptSubmit), and session-end-learnings (SessionEnd or Stop).
  Verify: `jq '[.hooks | to_entries[] | .value[] | .command] | map(select(test("discipline-inject|output-compressor|done-criteria|session-end-learnings"))) | length' hooks/hooks.json` returns 4 or more.

- [ ] Each new hook has a companion `.test.sh` covering kill switch, fail-open, and main behavior.
  Verify: `for f in discipline-inject output-compressor done-criteria session-end-learnings; do test -f hooks/team/${f}.test.sh || echo "MISSING: $f"; done` prints nothing.

- [ ] `bash tests/run-all.sh` exits 0 with all suites passing.
  Verify: `bash tests/run-all.sh`.

- [ ] `bash tests/validate-agents.sh` exits 0 with 12 agents validated (agent count does not change).
  Verify: `bash tests/validate-agents.sh | grep "12 agents"`.

- [ ] `CHANGELOG.md` contains entries for all 11 items: pause, forensics, regression gate, checkpoint rollback, Ralph executor, intent contract, discipline hook, output compressor, done-criteria hook, session learnings, agent frontmatter.
  Verify: `grep -c "pause\|forensics\|regression.*gate\|rollback\|ralph\|intent.*contract\|discipline\|compressor\|done-criteria\|learnings\|frontmatter" CHANGELOG.md` returns 11 or more.

- [ ] No em-dash character (U+2014) appears in any new or modified file.
  Verify: `grep -rP "—" skills/pause skills/forensics skills/rollback skills/discipline lib/pause-snapshot.sh lib/regression-scan.sh lib/checkpoint.sh lib/ralph-remediation.sh hooks/team/discipline-inject.sh hooks/team/output-compressor.sh hooks/team/done-criteria.sh hooks/team/session-end-learnings.sh agents/super-spec-spec-writer.md agents/super-spec-implementer.md agents/README.md skills/shared/artifact-templates/SPEC.md.template hooks/hooks.json CHANGELOG.md` returns no matches.

### Exceptional

- [ ] `lib/pause-snapshot.sh` detects uncommitted files via `git diff --name-only` and includes them in `uncommittedFiles[]` in HANDOFF.json.
  Verify: create an uncommitted file, run `lib/pause-snapshot.sh --dry-run`, and confirm the file appears in `uncommittedFiles`.

- [ ] `.continue-here.md` severity tags (`blocking`, `advisory`) are parsed by `skills/cycle/SKILL.md` to adjust resume posture (blocking constraints prevent immediate auto-resume).
  Verify: `grep -c "blocking\|advisory" skills/cycle/SKILL.md` returns 1 or more.

- [ ] `skills/forensics/SKILL.md` documents the report path format `report-{ISO-8601}.md` and writes only to `.super-spec/forensics/`.
  Verify: `grep -c "forensics/report-" skills/forensics/SKILL.md` returns 1 or more.

- [ ] `lib/ralph-remediation.sh` logs each iteration outcome (task, resolution status, iteration number) to a temp file for post-loop inspection.
  Verify: `grep -c "iter\|iteration\|log" lib/ralph-remediation.sh` returns 1 or more.

- [ ] `hooks/team/output-compressor.sh` debounces correctly by only firing on every 3rd qualifying call (state persisted in a temp file keyed by session).
  Verify: `bash hooks/team/output-compressor.test.sh` passes the "debounce every 3rd call" case.

- [ ] `hooks/team/session-end-learnings.sh` applies heuristic lesson generation: more than 3 agents dispatched produces "parallel dispatch effective"; presence of errors produces "partial outcome".
  Verify: `bash hooks/team/session-end-learnings.test.sh` passes the "heuristic lessons" case.

## Out of scope

- Cycle 5 spec-phase work. All 11 items are bounded to the resilience and operations layer; no C5 features are started here.
- Auto-remediation inside forensics. The forensics command was considered as an interactive repair tool; it is strictly read-only by explicit decision.
- Hard-blocking regression gate. Blocking VERIFY entirely on prior-phase test failures was considered and rejected; advisory logging only.
- `git reset --hard` rollback. Destructive history rewrite was considered and rejected in favor of `git checkout TAG -- .` (history-safe new commit).
- Mandatory discipline enforcement. Making discipline-mode always-on (removing the conf file toggle) was considered and rejected to keep all new features opt-in.
- Global learnings file location. A user-level `~/.config/super-spec/learnings.jsonl` was considered and rejected; per-project `.super-spec/learnings.jsonl` is the chosen path.
- Configurable compressor threshold. A per-project threshold override was considered; the 3000-char constant matches the claude-octopus default and is sufficient for the quick tier.
- New agent for intent contract. A dedicated spec-intent agent was considered and rejected; changes are applied to the existing spec-writer agent and SPEC.md template.

## Open questions

(none - resolved during DISCUSS phase)
