# loop-spec test matrix

## Automated suites

Run from repo root:

```bash
bash tests/run-unit.sh
bash tests/run-unit.sh --list skills/shared/human-code.md
bash tests/run-all.sh
```

`run-unit.sh` is the edit-loop gate. With no argument it maps uncommitted files to their
same-name unit suites and every registered coupling test that names them, then runs only
that set. Pass a base ref (`bash tests/run-unit.sh main`) to cover a whole branch diff.
Use `--list <path>...` to inspect the mapping without running it. Coupling discovery includes
Markdown that the plugin executes as instructions under `skills/`, `agents/`, `commands/`,
and `.claude/rules/`; ordinary prose selects the docs linter without expanding into every
suite that happens to quote it.
It also syntax-checks changed files and runs the code/document tells over lines introduced
by the diff, so an existing finding elsewhere in a touched file does not poison the edit
loop. The full
gate runs every suite concurrently; set `RUN_ALL_JOBS=1` when diagnosing order-sensitive
behavior and `RUN_ALL_VERBOSE=1` to print successful suite logs.

The full gate runs every non-interactive suite: the agent/manifest validators, the hook
tests, the `lib/` units and integration contracts, and (when a node runtime is available)
the workflow syntax checks in `tests/workflows/smoke.sh`. It needs bash, git, jq, python3,
and (for the workflow checks) node. It does NOT require the Claude CLI.

There are no scripted e2e or live-model suites: the shipped test tree is offline-only
by policy (no network, no `claude -p`, no live services). Behavioral end-to-end
coverage is the manual matrix below, run against a live Claude Code session.

## Manual end-to-end matrix

Run a subset before each tag (against a live Claude Code session with the plugin
installed). Full grid quarterly.

| # | Feature | Exec Style | Status |
|---|---------|------------|--------|
| 1 | trivial 1-task | auto | not run |
| 2 | trivial 1-task | step | not run |
| 3 | trivial 1-task | interactive | not run |
| 4 | trivial 1-task | review-only | not run |
| 5 | medium 5-task | auto | not run |
| 6 | medium 5-task | step | not run |
| 7 | medium 5-task | interactive | not run |
| 8 | medium 5-task | review-only | not run |
| 9 | complex 10-task | auto | not run |
| 10 | complex 10-task | step | not run |
| 11 | complex 10-task | interactive | not run |
| 12 | complex 10-task | review-only | not run |

Total: 12 cells (3 feature sizes x 4 execution styles; single-tier operation).

Additional scenario rows (run alongside the grid):

| # | Scenario | How | Status |
|---|----------|-----|--------|
| S1 | spec-file ingest | `/loop-spec:cycle path/to/spec.md` with a pre-authored spec (also headless: `LOOP_SPEC_SPEC_FILE=path`). Confirm: NO interview questions; SPEC.md preserves the draft's requirements verbatim; `spec-draft.md` exists in the feature dir; ambiguity gate scored on the draft. | not run |
| S2 | implicit-team harness (CC >= 2.1.178) | Any trivial cell with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` on a modern CC. Confirm: `runtime.json.teamsMode == "implicit"`; NO `TeamCreate`/`TeamDelete` calls appear; teammates spawn via `Agent({name})` and rework rides `SendMessage`. | not run |
| S3 | explicit-team harness (CC < 2.1.178) | Same as S2 on a legacy CC. Confirm `teamsMode == "explicit"` and per-phase `TeamCreate`/`TeamDelete`. | not run |
| S4 | iterate budget ship | Force a persistent gap (spec asks for X+Y, sabotage Y) with `LOOP_SPEC_PHASE_TIMEOUT_MINS` low or a shrunken maxIterations via manual feature.json edit. Confirm: confirmation runs once; gaps land in `warnings[]` and BACKLOG.md; ITERATE advances to DELIVER; no PR is opened before that; DELIVER reports the warnings in the final PR. | not run |

For each cell, drive `loop-spec:cycle` in `LOOP_SPEC_NON_INTERACTIVE=1` mode
(set `LOOP_SPEC_ANSWER_STYLE`, `LOOP_SPEC_ANSWER_TITLE`, or `LOOP_SPEC_SPEC_FILE`
for the spec-file scenario)
and confirm SPEC.md / PLAN.md / VERIFICATION.md / ITERATION.md are produced, DELIVER
runs after terminal ITERATE, `feature.json.currentPhase == "completed"`,
`delivery.status == "ready-for-review"`, and each delivered target records equal
target/remote/head SHAs plus a passed-or-none required-check status.

### Pre-tag minimum

- One trivial + auto cell.
- Plus 3 hand-picked cells from rows 5-12 covering: parallel waves, AUTO self-heal
  triggered, STEP execution.
- Plus S1 (spec-file ingest) and whichever of S2/S3 matches the local CC version.

### Quarterly

Run all 12 cells. Track failures in the CHANGELOG of the next release.

## Fixtures

`tests/fixtures/` holds inputs for the automated suites (e.g. probe transcripts,
sample agent definitions). To add a fixture for a new manual end-to-end cell,
create `tests/fixtures/{name}/` with a `Makefile` exposing `test`, `lint`, and
`typecheck` targets, plus a short `README.md` describing its purpose.

## Manual ADK-harness smoke (post-merge operational validation)

`tests/adk-extension.test.sh` exercises the bridge against the REAL `google-adk`
package (skills load, `CLAUDE_*` reaches the shell, tool surfaces are exact), and
`tests/adk-harness-coverage.test.sh` pins the cross-file couplings — but neither
calls a model. Live validation is not a merge gate while the adapter has no active
users. The first operator should record this smoke and ship follow-up fixes as
needed:

1. `python3 -m pip install 'google-adk>=2.7,<3'` and
   `bash lib/adk-install.sh install --project <dir>`
   — both agent directories written, `check` clean.
2. `adk run <dir>/adk_agents/loop_spec "list your skills" --jsonl` — the agent
   enumerates loop-spec's skills and the JSONL stream parses.
3. Load a skill and confirm its shell lines run: the model should call
   `load_skill`, then `Execute` a `bash "${CLAUDE_SKILL_DIR}/../../lib/..."`
   command that succeeds — this is the whole CLAUDE_SKILL_DIR bridge in one step.
4. A fleet tick:
   `python3 skills/loop-runner/scripts/loop.py "<task>" --agent-cli adk --adk-agent-dir <dir>/adk_agents/loop_spec --verify <cmd>`
   — `result.json` has the same shape as the claude backend, with
   `total_cost_usd: null` (ADK reports tokens, not money).
5. Confirm the read-only agent refuses to write: dispatch a judge tick
   (`--permission-mode plan`) and verify it holds only `ReadFile` plus the skill
   tools.
6. Continue the fleet with its emitted session id and confirm the next tick uses
   `--session_id`, retains context, and completes without replaying a fresh
   session.
7. Record the ADK version, model/provider, commands, sanitized output, and final
   result path in the first operational report.

`lib/adk-install.sh install` and `check` enforce `google-adk>=2.7,<3`; missing,
older, and 3.x installations fail before an agent mount is accepted. A real
oldest/latest compatibility matrix remains useful follow-up coverage, not a
merge gate.

## Manual Codex-harness smoke (post-merge operational validation)

`tests/codex-harness-coverage.test.sh` pins the cross-file couplings, and
`tests/lib/codex-install.test.sh` / `skills/loop-runner/tests/run_tests.sh`
exercise the installer and `codex exec --json` backend against `fakecodex` —
but none of those call a live Codex model. Live validation is not a merge
gate. The first operator should record this smoke and ship follow-up fixes as
needed:

1. `bash lib/codex-install.sh install --project <dir>` — adapters under
   `<dir>/.agents/skills/loop-spec-*`, custom agents under
   `<dir>/.codex/agents/loop-spec-*.toml`, and a marked
   `shell_environment_policy.set` block in `<dir>/.codex/config.toml`.
2. `LOOP_SPEC_HARNESS=codex LOOP_SPEC_NON_INTERACTIVE=1 codex exec --json --sandbox workspace-write
   '$loop-spec-auto list your skills'` — JSONL stream
   parses (`thread.started`, `turn.*`, `item.*`).
3. Load `$loop-spec-status` (or a plugin skill `$status`) and confirm a shell
   line runs `bash "${CLAUDE_SKILL_DIR}/../../lib/harness.sh" detect` printing
   `codex`.
4. A fleet tick:
   `python3 skills/loop-runner/scripts/loop.py "<task>" --agent-cli codex --verify <cmd>`
   — `result.json` has the same shape as the claude backend, with
   `cost_usd: null` (Codex reports tokens, not money).
5. Confirm a read-only judge tick (`--permission-mode plan`) passes
   `--sandbox read-only`.
6. Continue the fleet with its emitted thread id and confirm the next tick
   uses `codex exec resume <id> --json`.
7. Record the Codex CLI version, model, commands, sanitized output, and final
   result path in the first operational report.

Plugin-bundled hooks stay skipped until `/hooks` trusts them. Do not pass
`--dangerously-bypass-approvals-and-sandbox` as the default automation path.
