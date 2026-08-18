# loop-spec configuration and command reference

This is the exhaustive configuration contract for loop-spec 3.1.0. A setting not
listed as a supported input below is not a supported operator control. Variables in
the final “injected and internal variables” table are published so wrappers and
implementers do not mistake them for controls, but callers must not set them unless
the table explicitly says otherwise.

The release’s source-to-contract utilization review is recorded in
[`configuration-audit.md`](configuration-audit.md).

## Value and precedence rules

- Boolean environment variables accept only `0` or `1` when the consuming command
  validates them. `1` means enabled and `0` means disabled. Do not use
  `true`/`false`. Safety-critical controls (`LOOP_SPEC_WORKTREES` and
  `LOOP_SPEC_PHASE_HANDOFF`) reject any other non-empty value.
- An explicit command token or CLI flag wins over an environment variable for the
  same invocation. An explicit environment variable wins over persisted project or feature state.
  Persisted state wins over the built-in default.
- The one exception is a host fact: a headless `CLAUDE_CODE_ENTRYPOINT` overrides
  `LOOP_SPEC_EXECUTION_PROFILE=interactive`. An explicit
  `LOOP_SPEC_LOOP_RUNTIME=1` is required to assert that a headless wrapper can keep a
  foreground loop alive.
- Empty is not generally the same as `0`. The documented exception is
  `LOOP_SPEC_CMD_PREPARE=""`, which explicitly disables preparation.
- `phase:fresh` and `phase:continuous` are persisted in `feature.json`. On a later
  bare resume, that stored policy remains active unless another inline phase token
  or `LOOP_SPEC_PHASE_HANDOFF` overrides it.
- `LOOP_SPEC_WORKTREES=0` is not advisory. It selects the in-place feature branch,
  forces serial implementation, makes loop-runner imply `--no-worktree`, and blocks
  worktree creation or entry at the tool boundary.
- Model routing precedence is defined once in
  `skills/shared/model-matrix.md`; `lib/feature-init.sh` implements it. Phase
  activation occurs before every phase skill invocation.

## Supported environment variables

### Cycle and phase control

| Variable | Accepted values / default | Exact effect |
|---|---|---|
| `LOOP_SPEC_AUTONOMOUS` | `0`/`1`; unset | `1` self-answers cycle questions, forces `style:auto`, and records assumptions. Equivalent to the `autonomous` cycle token. |
| `LOOP_SPEC_NON_INTERACTIVE` | `0`/`1`; unset | `1` forbids interactive questions and reads the `LOOP_SPEC_ANSWER_*` inputs below. It also implies a headless execution profile. |
| `LOOP_SPEC_SPEC_FILE` | path; unset | Uses the specified pre-authored Markdown spec instead of collecting a new one. |
| `LOOP_SPEC_MAX_FEATURES` | positive integer; `1` | Maximum backlog features selected per invocation. Sentinel batch requests above one are still restricted by the trust level. |
| `LOOP_SPEC_PHASE_TIMEOUT_MINS` | positive integer; `60` | Wall-clock watchdog ceiling for a phase. A non-integer or non-positive value is a configuration error, not a fallback. |
| `LOOP_SPEC_PHASE_HANDOFF` | `0`/`1`; unset | `1` permits one phase per main-agent invocation, persists the next phase, and returns `status=paused`, `reason=phase-handoff`. `0` runs phase routing continuously. The environment overrides persisted state; inline `phase:fresh`/`phase:continuous` overrides the environment. A tool-boundary guard enforces the boundary. |
| `LOOP_SPEC_ITERATE_FRESH` | `0`/`1`; unset | `1` makes an ITERATE rewind persist state and relaunch instead of continuing in the current main-agent context. |
| `LOOP_SPEC_ITERATE_MAX_ITERATIONS` | integer `1..100`; `10` | Sets the full cycle's persisted ITERATE convergence ceiling. This is independent of `LOOP_SPEC_LOOP_MAX_ITERATIONS`, which bounds each loop-fleet task. |
| `LOOP_SPEC_CHECKPOINT_EACH_PHASE` | `0`/`1`; autonomous runs default to `1`, other runs to `0` | Pushes or reuses a draft checkpoint PR after every non-DELIVER phase. |
| `LOOP_SPEC_CHECKPOINT_PR` | `0`/`1`; `1` | Controls the draft checkpoint PR written on pause, escalation, or terminal stop. |
| `LOOP_SPEC_SQUASH_STATE_COMMITS` | `0`/`1`; `0` | `1` defers pure feature.json/PROGRESS phase-state commits and writes one final state commit during DELIVER. It also disables per-phase remote checkpoints because pushed intermediate state would require a later history rewrite. |
| `LOOP_SPEC_CYCLE_PROFILE` | `maintenance`/`standard`/`auto`; `auto` | Selects the cycle's gate ladder through `lib/cycle-profile.sh`. `auto` resolves it from the validated task classification and answers `standard` whenever there is no classification to read. `maintenance` lightens SPEC (synthesize instead of interview) and, when there is no security signal, takes the graph short path: skip DISCUSS, spec-critique, and code review (`skills/shared/tier-matrix.md`). PLAN critique is still decided by `plan-critique.sh` / the skill fast-path. The ambiguity gate, the feasibility check, and the deterministic VERIFY gates stay. The inline `profile:maintenance` / `profile:standard` cycle token outranks this variable. An invalid value fails safe to `standard`. |
| `LOOP_SPEC_SKIP_HEALTHCHECK` | `0`/`1`; unset | `1` skips the startup model probe. A successful probe is cached for 24 hours only while the exact sorted effective selector set is unchanged. |
| `LOOP_SPEC_PREPARE_TIMEOUT_SECS` | non-negative integer; `1800` | Wall-clock timeout for dependency/environment preparation. `0` disables the wall-clock deadline. |
| `LOOP_SPEC_PREPARE_IDLE_TIMEOUT_SECS` | non-negative integer; `300` | No-output timeout for preparation. `0` disables the idle deadline. |
| `LOOP_SPEC_STARTUP_BASELINE` | `0`/`1`; `0` | `1` captures the exact-base test/lint/typecheck baseline during cycle startup, before the feature exists. Default `0` skips that fresh-checkout suite run entirely: `verificationBaseline` stays `null` and every repository-wide failure observed later in the cycle blocks. Enable it only where the base commit is already red and the known-failure oracle is what keeps EXECUTE and VERIFY from chasing failures the feature did not cause. Greenfield never captures a baseline regardless. |
| `LOOP_SPEC_BASELINE_TIMEOUT_SECS` | non-negative integer; `1800` | Wall-clock timeout for each baseline/candidate validation command. `0` disables the wall-clock deadline. |
| `LOOP_SPEC_BASELINE_IDLE_TIMEOUT_SECS` | non-negative integer; `300` | No-output timeout for each baseline/candidate validation command. `0` disables the idle deadline. |
| `LOOP_SPEC_COMMAND_TIMEOUT_SECS` | non-negative integer; `1800` | Default wall-clock timeout used by generic managed command execution. A more specific timeout wins; `0` disables the wall-clock deadline. |
| `LOOP_SPEC_COMMAND_IDLE_TIMEOUT_SECS` | non-negative integer; `300` | Default no-output timeout used by generic managed command execution. A more specific idle timeout wins; `0` disables the idle deadline. |

### Worktrees, dispatch, and runtime capability

| Variable | Accepted values / default | Exact effect |
|---|---|---|
| `LOOP_SPEC_WORKTREES` | `0`/`1`; `1` | `0` prohibits all feature/task/revise worktree creation and entry. Cycle creates `feat/<slug>` in the current clean checkout, EXECUTE is serial, revise checks out the PR branch in place, supervisor implies `--no-worktree`, and a PreToolUse guard denies `git worktree add`, `create-feature-worktree`, `EnterWorktree`, and `Agent({isolation: "worktree"})` — the three tool-reachable worktree entry points. `claude --worktree` is an operator launch decision and is not gated; agent-frontmatter `isolation` is not visible in `tool_input`, so `tests/validate-agents.sh` forbids the key instead. `1` enables normal isolated worktrees. |
| `LOOP_SPEC_WORKTREE_DIR` | absolute path, or a path relative to the repository; unset | Base directory for every worktree loop-spec creates. Feature worktrees go to `<dir>/features/<slug>`, task and revise worktrees to `<dir>/tasks/…`. Used verbatim and unprobed — it outranks the automatic resolution in `lib/worktree-base.sh`. Point it outside the repository when the harness sandbox denies writing harness-config paths (`.claude/commands/**`) into an in-repo worktree. Unset means: keep the in-repo default (`.claude/worktrees/<slug>`, `.loop-spec/worktrees/<slug>/task-<id>`) when it can hold the checkout, otherwise relocate automatically to `<repo>-worktrees/` and then `$HOME/.loop-spec/worktrees/<repo>-<sum>/`. |
| `LOOP_SPEC_SHARE_DEPENDENCIES` | `0`/`1`; `1` | With worktrees enabled, links a matching, successfully prepared `node_modules` into task worktrees. `0` prepares each worktree independently. No effect when worktrees are disabled. |
| `LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS` | positive integer, clamped to `3`; `3` | Caps simultaneous implementers. `LOOP_SPEC_WORKTREES=0` forces the effective value to `1`. |
| `LOOP_SPEC_MAX_PARALLEL_SUBAGENTS` | positive integer; unset | Deployment-wide cap on simultaneous one-shot agents. When set, teams, Workflow fan-out, and loop fleets are replaced by bounded waves. `1` retains role agents but runs them serially. |
| `LOOP_SPEC_EXECUTE_LOOPS` | `0`/`1`; automatic | `1` requests loop-fleet regardless of DAG width, subject to agent-CLI and persistent-runtime capability. `0` forbids loop-fleet. |
| `LOOP_SPEC_EXECUTE_WORKFLOW` | `0`/`1`; `0` | `1` opts sufficiently wide EXECUTE DAGs into the Workflow rung when the Workflow tool is available. |
| `LOOP_SPEC_PLAN_MULTI_ANGLE` | `0`/`1`; `0` | `1` enables PLAN multi-angle authoring through Workflow when available. |
| `LOOP_SPEC_EXECUTION_PROFILE` | `interactive`/`headless`; probed | Declares whether the invocation can retain a foreground fleet call. `headless` disables loop-fleet. A headless host entrypoint overrides `interactive`. |
| `LOOP_SPEC_LOOP_RUNTIME` | `0`/`1`; probed | Explicit capability assertion for a persistent foreground loop. `0` disables it. `1` is the only loop-spec setting that can override a headless entrypoint stamp. |
| `LOOP_SPEC_LOOP_MAX_ITERATIONS` | positive integer; `10` | Iteration cap for each loop-fleet task. |
| `LOOP_SPEC_LOOP_MAX_BUDGET_USD` | positive decimal; unlimited | Cumulative model-cost cap for each loop-fleet task. A fleet’s worst-case cap is this value times its task count. |
| `LOOP_SPEC_TEAMS_MODE` | `none`/`explicit`/`implicit`; probed | Overrides agent-team capability detection. |
| `LOOP_SPEC_WORKFLOWS_AVAILABLE` | `0`/`1`; probed | Overrides Workflow-tool capability detection. |
| `LOOP_SPEC_HARNESS` | `claude`/`opencode`/`adk`; detected | Forces the host adapter. The OpenCode plugin and ADK bridge normally set this themselves. An unknown value falls through to detection, which defaults to `claude`. |
| `LOOP_SPEC_FOREIGN_CLAIMANTS` | `0`/`1`; `0` | `1` opts EXECUTE into the `foreign` rung when a handoff port adapter is reachable (`LOOP_SPEC_PORT` or the bundled `lib/graph/port-local.sh`). Width still selects the rung and never removes a graph node. |
| `LOOP_SPEC_PORT` | executable path; unset | Handoff-port adapter invoked by `lib/graph/port.sh`. Unset uses `lib/graph/port-local.sh`. |
| `LOOP_SPEC_PORT_ROOT` | directory path; platform temp | Store root for the reference `port-local` adapter. Unset defaults under the process temp directory. |
| `LOOP_SPEC_EFFORT` | `system1`/`system2`; unset | Global operator override for `lib/effort-probe.sh`. Invalid values fail safe to `system2`. Outranked by the more-specific overrides below. |
| `LOOP_SPEC_EFFORT_PHASE` | `system1`/`system2`; unset | Per-phase effort override. Outranks `LOOP_SPEC_EFFORT`; outranked by `LOOP_SPEC_EFFORT_NODE`. |
| `LOOP_SPEC_EFFORT_NODE` | `system1`/`system2`; unset | Per-node effort override. Most specific form; outranks phase and global. |
| `LOOP_SPEC_FEATURE_WRITE` | executable path; `lib/feature-write.sh` | Test/seam override for the feature-state writer. Production unset uses the bundled `lib/feature-write.sh`. |
| `LOOP_SPEC_EVENTS` | executable path; `lib/events.sh` | Test/seam override for the event emitter used by `lib/graph/trace.sh`. Production unset uses the bundled `lib/events.sh`. |

### Host and installer environment

These are not loop-spec-owned controls, but they are read by the plugin or its
installers and therefore are part of the integration contract.

| Variable | Owner / default | Exact effect in loop-spec |
|---|---|---|
| `CLAUDE_CODE_ENTRYPOINT` | Claude Code | Read-only host fact. `sdk-cli`, `sdk-py`, and `sdk-ts` prove a one-shot invocation and suppress loop-fleet unless `LOOP_SPEC_LOOP_RUNTIME=1`. |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | Claude Code; unset | `1` permits loop-spec’s version probe to select explicit or implicit teams. Any other value selects the no-teams route. |
| `CLAUDE_CODE_DISABLE_WORKFLOWS` | Claude Code; unset | `1` forces Workflow fallbacks. |
| `CLAUDE_CODE_RETRY_WATCHDOG` | Claude Code; inherited | Native unattended retry watchdog. Loop-runner inherits it unless `--retry-watchdog` supplies a child-specific value. |
| `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` | Claude Code; `8` | Maximum consecutive Stop-hook blocks before Claude Code force-completes the turn with a warning. This is what bounds `LOOP_SPEC_DEFERRAL_GUARD` and `LOOP_SPEC_MICRO_GUARD`, which deliberately do not treat `stop_hook_active` as an override. loop-spec never sets it. |
| `CLAUDE_CODE_MAX_RETRIES` | Claude Code legacy control; inherited | Not configured by loop-spec. Prefer `CLAUDE_CODE_RETRY_WATCHDOG`; Claude Code caps the legacy value at 15. |
| `CLAUDECODE` | Claude Code | `1` is a fallback harness-detection signal when `LOOP_SPEC_HARNESS` is unset. |
| `CLAUDE_PLUGIN_ROOT` | host adapter | Absolute installed plugin root used to resolve hooks and bundled assets. The OpenCode plugin and ADK bridge set it. Operator override is unsupported. |
| `CLAUDE_PROJECT_DIR` | host adapter; current directory | Project root used for `.loop-spec` discovery. The OpenCode plugin and ADK bridge set it from the session/project directory. |
| `CLAUDE_SKILL_DIR` | host adapter | Directory of the active skill, used for bundled relative paths. The OpenCode plugin and ADK bridge update it as skills are loaded. |
| `CLAUDE_CODE_SESSION_ID`, `CLAUDE_SESSION_ID` | host adapter; process ID fallback | Session identity used to scope learnings and hook failure counters. |
| `OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS` | OpenCode; unset | OpenCode-native opt-in for background subagents. loop-spec does not set it and does not depend on it; the OpenCode adapter’s bounded dispatch rules still apply. |
| `OPENCODE_CONFIG_DIR` | operator/installer; unset | Explicit OpenCode install target. |
| `LOOP_SPEC_ADK_AGENT_DIR` | operator/installer; unset | Mounted ADK agent directory (written by `lib/adk-install.sh`). Required by the `adk` fleet backend and `lib/issue-intake.sh`, which dispatch at a directory rather than a bare prompt. |
| `LOOP_SPEC_ADK_MODEL` | operator; `gemini-2.5-pro` | Default ADK model for a mounted agent. `lib/adk-install.sh --model` writes it into the generated shim. |
| `XDG_CONFIG_HOME` | operating system/user; `~/.config` | Base for the default OpenCode install target when `OPENCODE_CONFIG_DIR` is unset. |
| `GH_HOST` | GitHub CLI; `github.com` | GitHub host used for credential refresh context and PR API calls. |
| `GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN`, `GITHUB_ENTERPRISE_TOKEN` | GitHub CLI | Authentication inherited by GitHub operations. They are also the only keys a credential-refresh command may return in its private JSON output. |
| `ANTHROPIC_API_KEY` | Claude/Agent SDK | Model authentication for headless examples. loop-spec passes the process environment through and never logs this value. |
| `HOME` | operating system | Locates global rules, runtime-manager shims, and default user config. |
| `TMPDIR` | operating system; platform temp directory | Base for transient private files where a helper uses the platform temp directory. |

### Cloud Agent SDK recipe environment

The reference controller in
[`cloud-run-autonomous.md`](cloud-run-autonomous.md) consumes these wrapper-owned
variables. They configure that published recipe, not plugin internals:

| Variable | Accepted values / default | Exact effect |
|---|---|---|
| `REPO_ROOT` | absolute/relative path; required | Repository used as the Agent SDK `cwd` and reconciliation root. |
| `LOOP_SPEC_PLUGIN` | plugin directory path; required | Local plugin path passed to `ClaudeAgentOptions.plugins`. |
| `TASK_PROMPT` | text; required | Appended to `/loop-spec:cycle autonomous` for each phase invocation. |
| `CYCLE_TIMEOUT_SECONDS` | positive integer; `10800` | Outer asyncio timeout for each fresh Agent SDK query. |
| `MAX_PHASE_INVOCATIONS` | positive integer; `12` | Maximum fresh phase queries made by the reference controller. |
| `CLAUDE_MAX_TURNS` | positive integer; SDK default | Passed as `ClaudeAgentOptions.max_turns` for each query. |
| `CLAUDE_MAX_BUDGET_USD` | positive decimal; SDK default | Passed as the per-query `max_budget_usd`; the controller must separately enforce a whole-job spend limit. |
| `CLAUDE_EFFORT` | SDK-supported effort; SDK default | Passed as `ClaudeAgentOptions.effort`. |
| `CLAUDE_MODEL` | model/alias; SDK default | Default primary Agent SDK model, applied by whatever launches the SDK. The published phase-handoff controller does not read it: it asks `feature-init.sh phase-model` and overrides the query model only for a phase whose selector resolves to something other than `inherit`. |
| `CLAUDE_FALLBACK_MODEL` | model/alias; SDK default | Passed as the Agent SDK fallback model. |
| `CLAUDE_PERMISSION_MODE` | SDK permission mode; `acceptEdits` | Passed as `ClaudeAgentOptions.permission_mode`. |
| `CLAUDE_MAX_BUFFER_BYTES` | positive integer; `8388608` | Maximum buffered SDK subprocess stdout bytes. |

### Project commands, GitHub, and credentials

| Variable | Accepted values / default | Exact effect |
|---|---|---|
| `LOOP_SPEC_CMD_PREPARE` | shell command; detected | Pins dependency/environment preparation. It runs on the untouched base, in isolated task roots, on resume, and before VERIFY comparisons. An explicitly empty value disables preparation. |
| `LOOP_SPEC_CMD_TEST` | shell command; detected | Pins the project test command and wins over auto-detection in every mode. An explicitly empty value disables the test slot. |
| `LOOP_SPEC_CMD_LINT` | shell command; detected | Pins the project lint command and wins over auto-detection in every mode. An explicitly empty value disables the lint slot. |
| `LOOP_SPEC_CMD_TYPECHECK` | shell command; detected | Pins the project typecheck command and wins over auto-detection in every mode. An explicitly empty value disables the typecheck slot. |
| `LOOP_SPEC_CMD_*` | shell command; detected | Reserved command-family namespace. Only command names consumed by the installed release have an effect; unknown suffixes are ignored. |
| `LOOP_SPEC_REGRESSION_SCAN` | `0`/`1`; `0` | `1` adds VERIFY’s advisory prior-feature regression scan. |
| `LOOP_SPEC_RALPH_THRESHOLD` | positive integer; `3` | Consecutive no-progress VERIFY remediation rounds before escalation. |
| `LOOP_SPEC_VGAP_MAX_FILES` | positive integer; `2000` | Caps how many test files `lib/verification-gap-scan.sh` reads when answering whether a changed definition is named by any test. When the corpus is truncated, a symbol with no hit is reported `covered=unknown` rather than `covered=no` — a partial search cannot establish absence. |
| `LOOP_SPEC_EXTENSIONS` | path; `.loop-spec/extensions.json` | Project extension declarations read by `lib/extension-points.sh`: additional review layers, per-phase prepend/append instructions, and standing facts. Extensions add only — a declared layer can never disable, reorder, or shadow a built-in gate, and no authority script reads this file. Read paths fail open; `extension-points.sh validate` fails closed. |
| `LOOP_SPEC_MAP_MAX_LINES` | positive integer; `1000` | Ceiling for the total size of the codebase map, measured by `lib/map-audit.sh budget` (~20k tokens across the five domains). Exceeding it is a finding to cut against, never a reason to raise the ceiling. |
| `LOOP_SPEC_MAP_MAX_AGE_DAYS` | positive integer; `90` | Age at which `lib/map-audit.sh staleness` reports a map domain as stale, matching the existing refresh advisory. |
| `LOOP_SPEC_MAP_DIR` | path; `docs/loop-spec/codebase` | Codebase-map location read by `lib/map-audit.sh` and `lib/map-trust.sh`. |
| `LOOP_SPEC_MAP_INDEX` | path; `.loop-spec/codebase/index.json` | Map index location read by `lib/map-audit.sh orphans` and `staleness`, and pruned by `lib/map-index-prune.sh`. |
| `LOOP_SPEC_MAP_BOOTSTRAP` | `0`/`1`; `1` | `0` skips first-run GSD codebase-map ingestion and mapper dispatch. Existing maps are left untouched. |
| `LOOP_SPEC_MAP_REFRESH` | `0`/`1`; `1` | `0` skips VERIFY's automatic incremental or greenfield codebase-map refresh. |
| `LOOP_SPEC_ARTIFACTS_IN_PR` | `0`/`1`; `1` | `0` copies `docs/loop-spec/features/<slug>/` and feature state to the artifact store during candidate finalization, then restores that document directory to its base image so run documents do not enter the PR diff. |
| `LOOP_SPEC_ARTIFACT_DIR` | directory outside the working tree; Git private storage | Store root used when `LOOP_SPEC_ARTIFACTS_IN_PR=0`. The default is the repository's private Git path under `loop-spec/artifacts`; set an external mounted directory for ephemeral jobs. A working-tree path is rejected because it would reintroduce the audit payload into the candidate. |
| `LOOP_SPEC_PR_BODY_VERBOSE` | `0`/`1`; `0` | `0` keeps reviewer-facing summary and verification sections expanded while putting spec scores, convergence prose, and artifact metadata in a collapsed Run details block. `1` expands those sections. |
| `LOOP_SPEC_CHECKS_TIMEOUT_SECONDS` | integer `0..86400`; `900` | Total DELIVER wait for required PR checks. `0` performs no extended wait. |
| `LOOP_SPEC_CHECKS_INTERVAL_SECONDS` | integer `0..3600`; `10` | Required-check polling interval. `0` polls again without sleeping. |
| `LOOP_SPEC_CHECKS_REGISTRATION_GRACE_SECONDS` | non-negative integer; `30` | Grace period after push during which a missing check is treated as not-yet-registered rather than absent. |
| `LOOP_SPEC_GH_COMMAND_TIMEOUT_SECONDS` | positive integer; `60` | Timeout for each GitHub CLI/API subprocess. |
| `LOOP_SPEC_CREDENTIAL_REFRESH_TIMEOUT_SECONDS` | integer `1..3600`; `60` | Deadline for the credential-refresh hook itself. A token mint that stalls rather than failing fast would otherwise block every gh/git stage. |
| `LOOP_SPEC_REGRESSION_CMD_TIMEOUT_SECONDS` | integer `1..3600`; `300` | Per-command deadline for the prior-feature regression scan's replayed test commands. |
| `LOOP_SPEC_LIVE_READY_PROBE_TIMEOUT_SECONDS` | integer `1..3600`; `10` | Per-attempt deadline for live-verify's readiness probe. `readyTimeoutSec` counts attempts, so an unbounded probe would make the bounded wait infinite. |
| `LOOP_SPEC_LIVE_PROBE_TIMEOUT_SECONDS` | integer `1..3600`; `120` | Per-probe deadline for live-verify's acceptance probes. |
| `LOOP_SPEC_CONSOLE_EVENTS` | `0`/`1`; `1` | `0` silences the greppable `[PHASE] …` console lines. The JSONL event ledger is unaffected. |
| `LOOP_SPEC_CONSOLE_STREAM` | `stderr`/`stdout`; probed | Which stream the console lines use. When unset, a deterministic probe decides: Cloud Run's own stamps (`CLOUD_RUN_JOB` for jobs, `K_SERVICE` for services) select `stdout`, because Cloud Run assigns stderr output ERROR severity; everywhere else `stderr`, because stdout carries the marker JSON that callers parse. An explicit value outranks the probe. In `stdout` mode two lines share the stream, so a consumer must prefix-select its record (`grep '^LOOP_SPEC_PHASE_'`) rather than pipe all of stdout to `jq`. `lib/pr-delivery.sh`'s heartbeat always stays on stderr — its stdout is a single JSON document. Unknown values fall back to the probe's answer. |
| `LOOP_SPEC_CREDENTIAL_REFRESH_CMD` | trusted shell command; unset | Runs before push/API stages and once after a 401/403 before one retry. It receives the four `LOOP_SPEC_CREDENTIAL_REFRESH_*` variables documented below. Stdout must be empty or an allow-listed token JSON object and is never logged. |
| `LOOP_SPEC_PR_FEEDBACK_MODE` | `local`/`external`; `local` | `local` runs loop-spec’s terminal PR-feedback observation. `external` delegates polling without claiming a clean result. There is deliberately no off mode. |
| `LOOP_SPEC_PR_FEEDBACK_OWNER` | text; `external-orchestrator` | Attribution persisted when PR feedback mode is `external`. |
| `LOOP_SPEC_ISSUE_INTAKE_CLAUDE_FLAGS` | CLI fragment; unset | Extra flags passed only to `claude -p` subprocesses started by `lib/issue-intake.sh`. |

### Models and non-interactive answers

| Variable | Accepted values / default | Exact effect |
|---|---|---|
| `LOOP_SPEC_PHASE_MODEL_<PHASE>` | `inherit` or a harness-native model selector; unset | Sets an optional phase default. Claude aliases apply to the main context and role Agents. A Claude full ID applies only to a fresh CLI/SDK main context (`LOOP_SPEC_PHASE_HANDOFF=1` or an equivalent fresh controller); role Agents omit their model key and inherit it. Pi and OpenCode consume an explicit value only on loop-fleet subprocesses. Unset inherits. Supported phases are `SPEC`, `DISCUSS`, `PLAN`, `EXECUTE`, `VERIFY`, `ITERATE`, and `DELIVER`. OpenCode native task agents use generated-agent routes instead. |
| `LOOP_SPEC_MODEL_<ROLE>` | `inherit` or a consumed harness-native selector; `inherit` | Wins over the phase default. Claude role overrides accept only Agent aliases; full IDs fail early because Agent rejects them. OpenCode and ADK accept a native ID only for `IMPLEMENTER` on the loop-fleet rung (OpenCode `provider/model`, ADK `gemini-*` or `provider/model`); configure other OpenCode roles through generated agents and ADK roles through the mounted agent. Supported roles are `SPEC_WRITER`, `PLANNER`, `ADVOCATE`, `CHALLENGER`, `SPEC_COMPLIANCE_REVIEWER`, `ITERATE_JUDGE`, `CODE_REVIEWER`, `IMPLEMENTER`, `VERIFIER`, `MAPPER`, and `PATTERN_MAPPER`. |
| `LOOP_SPEC_ANSWER_STYLE` | `auto`/`step`/`interactive`/`review-only`; `auto` | Supplies the cycle style when questions are disabled. |
| `LOOP_SPEC_ANSWER_TITLE` | text; unset | Supplies the feature description. Required in non-interactive mode unless the spec file supplies one. |
| `LOOP_SPEC_ANSWER_REPOS` | comma-separated repo names; all | Supplies workspace repo selection. |
| `LOOP_SPEC_ANSWER_SPEC_CONFIRM` | `yes`/`no`; `yes` | After a passing synthesized gate, `yes` writes SPEC.md; `no` leaves the phase at SPEC and returns a durable `spec-confirmation-declined` pause. |
| `LOOP_SPEC_ANSWER_SPEC_OVERRIDE` | `yes`/`no`; `yes` | After a failing synthesized gate, `yes` writes SPEC.md with failing dimensions recorded; `no` leaves the phase at SPEC and returns a durable `spec-override-declined` pause. |
| `LOOP_SPEC_ANSWER_ITERATE_SPEC` | `reopen`/`ship`; `reopen` | On a non-interactive SPEC-level iteration gap, `reopen` returns to DISCUSS refinement; `ship` advances to DELIVER and records the accepted gap. |
| `LOOP_SPEC_ANSWER_TIER` | ignored | Removed compatibility input. A notice is emitted; it cannot change behavior. |
| `LOOP_SPEC_ANSWER_PRESET` | ignored | Removed compatibility input. A notice is emitted; it cannot change behavior. |
| `LOOP_SPEC_ANSWER_*` | family | Namespace used by non-interactive answers. Unknown suffixes are ignored. |

Concrete variables such as `LOOP_SPEC_MODEL_PLANNER` and
`LOOP_SPEC_MODEL_ITERATE_JUDGE` follow the `LOOP_SPEC_MODEL_<ROLE>` contract; the
family form is canonical for every supported role. Likewise,
`LOOP_SPEC_PHASE_MODEL_SPEC`, `LOOP_SPEC_PHASE_MODEL_DISCUSS`,
`LOOP_SPEC_PHASE_MODEL_PLAN`, `LOOP_SPEC_PHASE_MODEL_EXECUTE`,
`LOOP_SPEC_PHASE_MODEL_VERIFY`, `LOOP_SPEC_PHASE_MODEL_ITERATE`, and
`LOOP_SPEC_PHASE_MODEL_DELIVER` follow the phase-family contract.
`lib/feature-init.sh phase-model <phase>` exposes the validated value to Claude
CLI/Agent SDK supervisors, and
`feature.phaseModels.<phase>` persists it in durable state.

### Learning, paths, quality, and modes

| Variable | Accepted values / default | Exact effect |
|---|---|---|
| `LOOP_SPEC_RETRO_AUTO_APPLY` | `0`/`1`; autonomous=`1`, interactive=`0` | Applies retro rule candidates automatically when enabled; otherwise produces a report only. |
| `LOOP_SPEC_RETRO_DIGEST_DIR` | path; `docs/loop-spec/telemetry/runs` | Overrides the run-digest corpus. |
| `LOOP_SPEC_COMMIT_TELEMETRY` | `0`/`1`; `0` | Commits run digests with the feature branch. Already tracked digest directories continue to be committed. |
| `LOOP_SPEC_TUNING` | `0`/`1`; `1` | Master switch for parameter tuning. |
| `LOOP_SPEC_TUNING_AUTO_APPLY` | `0`/`1`; autonomous=`1`, interactive=`0` | Applies tuning adjustments when enabled; otherwise counts candidates only. |
| `LOOP_SPEC_RULES` | `0`/`1`; `1` | Controls RULES.md injection at session start. |
| `LOOP_SPEC_RULES_FILE` | path; `.loop-spec/RULES.md` | Overrides the project rules file. |
| `LOOP_SPEC_GLOBAL_RULES_FILE` | path; `~/.loop-spec/RULES.md` | Overrides the cross-project rules layer. |
| `LOOP_SPEC_ADHOC_LEDGER` | path; `.loop-spec/adhoc-ledger.md` | Overrides the micro-cycle ledger. |
| `LOOP_SPEC_LEARNINGS_FILE` | path; `.loop-spec/learnings.jsonl` | Overrides the session-learnings log that `lib/retro.sh` mines for recurring non-success session outcomes. Distinct from `LOOP_SPEC_LEARNINGS`, which enables or disables the SessionEnd writer. |
| `LOOP_SPEC_BACKLOG_FILE` | path; `.loop-spec/BACKLOG.md` | Overrides the backlog. |
| `LOOP_SPEC_WORKFLOW_CONFIG` | path; `.loop-spec/workflow.json` | Overrides workflow configuration. |
| `LOOP_SPEC_ASSESS_TOP_N` | positive integer; `5` | Fragility hotspots per repository sent to assess reviewers. |
| `LOOP_SPEC_ASSESS_SINCE` | git `--since` value; all history | Limits the assess fragility scan history. |
| `LOOP_SPEC_QUALITY_LOOP_MAX_ROUNDS` | positive integer; `3` | Review rounds before quality-loop escalates. |
| `LOOP_SPEC_INDIRECTION_MAX_BODY` | integer >= 1; `5` | Body size, in significant lines, below which a private single-caller definition counts as a pass-through wrapper for `lib/indirection-scan.sh`. Raise it to catch larger wrappers, at the cost of reporting legitimate decomposition; an unreadable value falls back to the default. |
| `LOOP_SPEC_DUP_MIN_LINES` | integer >= 3; `6` | Verbatim window `lib/duplication-scan.sh` matches on, in significant lines (blank lines, comments, and lone block terminators are not counted). The shape window — same lines with identifiers and literals replaced — is always this plus two. Lower finds shorter clones and reports more; an unreadable value falls back to the default rather than scanning with a window of one. |
| `LOOP_SPEC_QL_STATE` | path; `.loop-spec/quality-loop.json` | Overrides quality-loop state. |
| `LOOP_SPEC_ROLLBACK_CONFIRMED` | `1`; unset | Safety interlock: `lib/checkpoint.sh rollback` refuses to restore files unless this is exactly `1`. |

### Session directives and guards

Unless stated otherwise, these are `0`/`1` switches. Guards only act in projects
with loop-spec state, and task guards only act on loop-spec-owned tasks.

| Variable | Default | Exact effect |
|---|---|---|
| `LOOP_SPEC_GRILL` | `1` | Asks 2–4 clarifying questions immediately after an opening prompt. |
| `LOOP_SPEC_SIMPLICITY` | `1` | Injects the minimum-diff/deletion/reuse/stdlib directive, including the DRY rung and the `lib/duplication-scan.sh` probe that measures it. Suppresses the SessionStart injection only; dispatch-rung copies travel in the prompt and are unaffected. |
| `LOOP_SPEC_HUMAN_CODE` | `1` | Injects the house-style directive: match the neighbors' conventions, comments carry why not what, comment density follows the file. The same switch carries the docs directive: name the document's reader, one job per document, cite rather than copy, and fix a document the change makes false in the same diff. Suppresses the SessionStart injection only; dispatch-rung copies travel in the prompt and are unaffected. |
| `LOOP_SPEC_MICRO` | `1` | Enables the micro-mode SessionStart directive. |
| `LOOP_SPEC_MICRO_GUARD` | `1` | Blocks stopping after code edits without a verification run; stands down for active feature cycles and docs/config-only edits. |
| `LOOP_SPEC_DEFERRAL_GUARD` | `1` | Blocks completion with self-authored omitted/deferred scope. After denial, rewording alone remains blocked; repository work, a later verification action, and `Resolved scope: <item> — <evidence>` are required. |
| `LOOP_SPEC_DEFERRAL_LINT` | `1` | DELIVER gate for explicit deferred-scope declarations in a PR body (`Deferred scope:`, `Follow-ups:`, etc.). Runtime warnings, negations, template defaults, quoted reports, and ordinary mentions are not scope declarations. `0` is the explicit override for a feature whose subject is deferral detection. |
| `LOOP_SPEC_DISCIPLINE` | `0` | Enables brainstorm, verification, investigation, decision, and intent gates. |
| `LOOP_SPEC_TASK_GUARD` | `1` | Enforces task metadata and required lint/typecheck completion. |
| `LOOP_SPEC_PATH_GUARD` | `1` | Enforces role-specific write paths. |
| `LOOP_SPEC_PATH_GUARD_FORCE` | `0` | Applies path restrictions to otherwise open dispatches. |
| `LOOP_SPEC_BLOCKEDBY_GUARD` | `1` | Refuses completion or claim of tasks with unfinished `blockedBy` dependencies. |
| `LOOP_SPEC_USERGATE_GUARD` | `1` | Enforces user-gate evidence at task completion. |
| `LOOP_SPEC_USERGATE_STOP_GUARD` | `1` | Enforces user-gate evidence at Stop. |
| `LOOP_SPEC_STRATEGY_ROTATION` | `1` | Injects a strategy-change directive after repeated failures. |
| `LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD` | `2` | Consecutive failures before strategy rotation. |
| `LOOP_SPEC_DONE_CRITERIA` | `1` | Injects done-criteria reminders when tasks are created. |
| `LOOP_SPEC_ROUTE_GUARD` | `1` | Blocks stopping an autonomous session whose routed run never published `.loop-spec/last-result.json`. Stands down for interactive runs and for armed records past the stand-down age. |
| `LOOP_SPEC_ROUTE_GUARD_MAX_AGE_MIN` | `720` | Minutes after which an armed run is treated as a dead record rather than this session's contract. |
| `LOOP_SPEC_DEFLECTION_GUARD` | `1` | Blocks premature “out of context” stops below the configured usage threshold. |
| `LOOP_SPEC_DEFLECTION_THRESHOLD_PCT` | `50` | Percent of context that must be consumed before a context-exhaustion stop is accepted. |
| `LOOP_SPEC_CONTEXT_LIMIT` | `200000` | Token context size used to compute the deflection threshold. |
| `LOOP_SPEC_LEARNINGS` | `1` | Writes session-end learnings to `.loop-spec/learnings.jsonl`. |
| `LOOP_SPEC_PAUSE` | `1` | Controls pause snapshot writing. |

### Guard diagnostics

These optional paths cause the named guard to append decision diagnostics. They do
not enable the guard; its switch above must also be enabled.

| Variable | Built-in path when applicable |
|---|---|
| `LOOP_SPEC_BLOCKEDBY_TRACE_LOG` | no file unless set |
| `LOOP_SPEC_USERGATE_TRACE_LOG` | `/tmp/claude-hooks/loop-spec-user-gate-trace.log` |
| `LOOP_SPEC_DEFLECTION_TRACE_LOG` | `/tmp/claude-hooks/loop-spec-deflection-trace.log` |
| `LOOP_SPEC_MICRO_GUARD_TRACE_LOG` | `/tmp/claude-hooks/loop-spec-micro-guard-trace.log` |
| `LOOP_SPEC_DEFERRAL_TRACE_LOG` | `/tmp/claude-hooks/loop-spec-deferral-trace.log` |
| `LOOP_SPEC_ROUTE_GUARD_TRACE_LOG` | `/tmp/claude-hooks/loop-spec-route-guard-trace.log` |
| `LOOP_SPEC_DEFERRAL_STATE_DIR` | `/tmp/claude-hooks/loop-spec-deferral-state`; transcript-scoped pending-obligation records |

## Skill command arguments

Tokens below are arguments after `/loop-spec:<skill>`. Brackets mean optional;
angle brackets mean required. Inline words are tokens, not GNU flags.

| Command | Arguments | Exact behavior |
|---|---|---|
| `auto` | `<task description>` | Chooses micro or full-cycle routing from task scope. |
| `cycle` | `[new] [description \| path/to/spec.md \| backlog] [style:auto\|step\|interactive\|review-only] [autonomous] [phase:fresh\|phase:continuous]` | Starts or resumes a cycle. `new` prevents automatic resume. `backlog` selects queued work. `phase:fresh` persists one-phase-per-invocation; `phase:continuous` persists same-session routing. |
| `debug` | `<error text \| stack trace \| failing test \| symptom>` | Starts evidence-first debugging. |
| `discipline` | `[on\|off\|status]` | Changes or reports the session discipline directive. |
| `forensics` | `[feature slug \| failed-workflow description]` | Reconstructs a stuck/failed run. |
| `grill` | `[on\|off\|status]` | Changes or reports grill mode. |
| `intake` | `<file path \| pasted text> [autonomous] [new] [style:…] [--no-run]` | Normalizes intake into a draft spec and normally forwards tokens to cycle. `--no-run` stops after writing the draft. |
| `map-codebase` | `[--full] [--domain tech,arch,…]` | Refreshes codebase maps. `--full` ignores incremental scope; `--domain` limits map domains. |
| `micro` | `[autonomous] [task \| on \| off \| status]` | Runs a small-task workflow or changes/reports micro mode. |
| `onboard` | none | Installs project-local loop-spec state/config. |
| `pause` | `[path/to/feature.json]` | Writes a resumable pause snapshot for the explicit or active feature. |
| `quality-loop` | `[file paths]` | Reviews supplied paths, or modified files when omitted. |
| `retro` | `[report\|apply] [--min-repeats N]` | Reports or applies recurring-rule candidates; the flag sets the minimum observation count. |
| `revise` | `<PR number \| PR URL> [autonomous]` | Applies actionable PR feedback. `autonomous` removes interactive confirmations but not safety gates. |
| `rollback` | `[checkpoint tag \| checkpoint type]` | Selects a checkpoint; file restoration still requires `LOOP_SPEC_ROLLBACK_CONFIRMED=1`. |
| `rules` | `add "<rule>" [--check "<cmd>"] \| list \| render \| path` | Manages project rules. `--check` associates a verification command with a rule. |
| `sentinel` | `scan\|run` | `scan` reports candidates; `run` selects authorized backlog work. |
| `simplicity` | `[on\|off\|status\|lite\|full\|ultra]` | Changes, reports, or selects simplicity intensity. |
| `human-code` | `[on\|off\|status\|probe]` | Changes or reports code-for-humans mode, which covers the code and the documents that ship with it; `probe` reports the conventions `lib/house-style.sh` measures for the given paths, plus `lib/doc-tells.sh` findings for any markdown among them, without changing state. |
| `status` | `[status [slug]\|stats\|trust] [--json]` | Reports active state, metrics, or trust; `--json` emits machine-readable output. |
| `walkthrough` | `[<slug> \| <base-ref>] [--write \| --walk]` | Builds the reviewer's guide for a change. `--write` (default inside a cycle) produces and lints `REVIEW-ORDER.md` and stops; `--walk` presents the trail one concern at a time for a human reviewer. |
| `watch` | `<slug> [--window-hours N]` | Evaluates post-merge stability over the requested window (default 24 hours). |

`spec`, `discuss`, `plan`, `execute`, `verify`, `iterate`, and `deliver` are cycle
phase skills. They have no public arguments and are normally invoked only by
`cycle`; directly chaining them bypasses lifecycle setup and is unsupported.

## Loop-runner CLI flags

These scripts are an advanced standalone interface under
`skills/loop-runner/scripts/`.

### `loop.py`

Usage: `loop.py [task] [flags]`. Supply either the positional task or
`--prompt-file`.

| Flag | Meaning |
|---|---|
| `--prompt-file PATH` | Read the task prompt from a file. |
| `--config PATH` | Load JSON `LoopConfig` fields; explicit CLI flags override the file. |
| `--task-id ID` | Stable task/state identifier (default derived from the prompt). |
| `--verify CMD` | Verification command run between agent iterations. |
| `--protected PATH` | Protect a path from edits; repeatable. |
| `--max-iterations N` | Maximum agent iterations (default `10`). |
| `--max-turns N` | Maximum turns per agent invocation (default `0`, host default/unlimited). |
| `--timeout SECONDS` | Wall-clock timeout per agent invocation (default `3600`). |
| `--no-progress N` | Consecutive no-progress iterations before watchdog termination (default `3`). |
| `--verify-timeout SECONDS` | Timeout for the verification command (default `600`). |
| `--mode fresh\|continue` | Start each iteration fresh or continue the agent session (default `fresh`). |
| `--permission-mode MODE` | Permission mode passed to Claude (default `acceptEdits`; validated against the supported Claude modes). |
| `--max-budget-usd AMOUNT` | Non-negative cumulative task cost cap; `0`/unset is unlimited. |
| `--allowed-tools LIST` | Allowed-tools value passed to Claude. |
| `--model MODEL` | Primary model or alias. |
| `--effort low\|medium\|high\|xhigh\|max` | Reasoning effort. |
| `--fallback-model MODEL` | Model used after a retryable primary-model failure. |
| `--retry-watchdog CMD` | Command used to decide whether a failed iteration may retry. |
| `--judge` | Enable the completion-judge pass. |
| `--judge-model MODEL` | Optional completion-judge model; omitted inherits the selected harness model. |
| `--state-dir PATH` | Override persisted runner state (default `.loop/<task-id>`). |
| `--commit` | Commit a successful task result. |
| `--claude-bin PATH` | Agent executable (default `claude`; changes to the selected adapter binary when appropriate). |
| `--agent-cli claude\|opencode\|adk` | Agent CLI adapter (default inferred from the executable name, then Claude). |
| `--adk-agent-dir <dir>` | Mounted ADK agent directory for `--agent-cli adk` (default `$LOOP_SPEC_ADK_AGENT_DIR`). |
| `--reset` | Discard prior state for this task ID and start again. |

After `--`, additional arguments are forwarded verbatim to the selected agent CLI on
each work tick. These are backend-native options rather than loop-spec flags; use them
only when the chosen `--agent-cli` supports them. The JSON `extra_args` array is the
equivalent config-file field.

### `supervisor.py`

| Flag | Meaning |
|---|---|
| `--plan PATH` | Compiled task plan (default `plan/tasks.json`). |
| `--parallel N` | Worker count (default `1`). Must be `1` with `--no-worktree` or `LOOP_SPEC_WORKTREES=0`. |
| `--retries N` | Retry count per failed task (default `1`; timeouts do not retry). |
| `--task-timeout SECONDS` | Wall-clock timeout per task (default `3600`). |
| `--max-turns N` | Maximum turns per agent invocation (default `0`, host default/unlimited). |
| `--model MODEL` | Primary worker model. |
| `--effort low\|medium\|high\|xhigh\|max` | Worker reasoning effort. |
| `--fallback-model MODEL` | Worker fallback model. |
| `--retry-watchdog CMD` | Retry authorization command. |
| `--max-budget-usd AMOUNT` | Non-negative cost cap per task (default `0`, unlimited). |
| `--claude-bin PATH` | Agent executable (default `claude`). |
| `--agent-cli claude\|opencode\|adk` | Agent CLI adapter (default inferred from the executable). |
| `--prepare-command CMD` | Persisted preparation command; an empty value disables detection. |
| `--no-worktree` | Run serially in the supplied repository instead of creating task worktrees. `LOOP_SPEC_WORKTREES=0` implies this flag. |
| `--cleanup-worktrees` | Remove successful task worktrees and branches after integration. |
| `--dry-run` | Validate and print the schedule without executing tasks. |
| `--tasks-json PATH` | Optional cycle `tasks.json` sidecar. Ids already `status=done` are skipped; each successful merge is marked done. Omit for standalone loop-runner. |

### `compile_spec.py`

Usage: `compile_spec.py <spec> [flags]`.

| Flag | Meaning |
|---|---|
| `--out PATH` | Compiled plan destination (default `plan/tasks.json`). |
| `--model MODEL` | Compiler-pass model. |
| `--claude-bin PATH` | Agent executable (default `claude`). |
| `--agent-cli claude\|opencode\|adk` | Agent CLI adapter (default inferred from the executable). |

All three scripts also accept argparse’s `-h` / `--help`. Flags on scripts under
`lib/` and `hooks/` are implementation interfaces used by skills and tests; they are
not public plugin CLI and carry no compatibility promise.

## Names found only in historical design artifacts

Committed feature records preserve old proposals and examples. They are not runtime
configuration. In particular, `LOOP_SPEC_BUDGET_GUARD`,
`LOOP_SPEC_CURRENT_COST_USD`, `LOOP_SPEC_MAX_COST_USD`, `LOOP_SPEC_COMPRESSOR`, and
`LOOP_SPEC_ANSWER_MIGRATE_SCHEMA` are unshipped historical proposals.
`LOOP_SPEC_FOO` and `LOOP_SPEC_SOME_GUARD` are documentation placeholders. Setting
any of these names has no effect in 2.29.1.

## Injected and internal variables

These names exist in shipped code but are not general operator configuration.
They are listed to remove ambiguity in wrappers and integrations.

| Variable | Owner and meaning |
|---|---|
| `LOOP_SPEC_CREDENTIAL_REFRESH_STAGE`, `LOOP_SPEC_CREDENTIAL_REFRESH_REASON`, `LOOP_SPEC_CREDENTIAL_REFRESH_HOST`, `LOOP_SPEC_CREDENTIAL_REFRESH_REPO` | Injected into `LOOP_SPEC_CREDENTIAL_REFRESH_CMD`; safe for that command to read. |
| `LOOP_SPEC_AUTH_ERROR_CODE`, `LOOP_SPEC_AUTH_ERROR_MESSAGE`, `LOOP_SPEC_CREDENTIAL_PREPARED_STAGES` | Mutable credential-library status; do not set. |
| `LOOP_SPEC_INTEGRATION_CANDIDATE` | Injected candidate commit for prepare/verify integration commands; safe for those commands to read. |
| `LOOP_SPEC_RESULT` | Machine-output marker printed to stdout, not an input variable. |
| `LOOP_SPEC_PHASE_START`, `LOOP_SPEC_PHASE_END` | Event marker names printed to output, not input variables. |
| `LOOP_SPEC_ACTIVE_CYCLE_BIN`, `LOOP_SPEC_CYCLE_RESULT_BIN`, `LOOP_SPEC_DEFERRAL_LINT_BIN`, `LOOP_SPEC_FINALIZE_CANDIDATE_BIN`, `LOOP_SPEC_PR_COMMENTS_BIN`, `LOOP_SPEC_PR_DELIVERY_BIN` | Test seams that replace internal executables. Unsupported in production wrappers. |
| `LOOP_SPEC_FEATURE_DIR` | Hook-scoped feature-directory override used by team hooks/tests. Normal runs discover the active feature. |
| `LOOP_SPEC_RESULT_ROOT` | Reconciliation-only destination override for cycle result state. |
| `LOOP_SPEC_PR_DELIVERY_CWD` | Internal subprocess transport for PR delivery’s working directory. |
| `LOOP_SPEC_BOUNDED_RUN_CWD`, `LOOP_SPEC_BOUNDED_RUN_STDIN` | Internal subprocess transport used by `lib/bounded-run.sh`; callers set these only while spawning the bounded child. |
| `LOOP_SPEC_PROJECT_DIR`, `LOOP_SPEC_PWD`, `LOOP_SPEC_PROJ_VERIFY_CMD`, `LOOP_SPEC_LAST_RESULT_FILE` | Internal values passed into embedded hook parsers. |
| `LOOP_SPEC_GROUNDING_SPEC` | Internal transport for the verification-grounding linter. |
| `LOOP_SPEC_BASE_CURSOR`, `LOOP_SPEC_STATE_CURSOR`, `LOOP_SPEC_STATE_FINGERPRINT`, `LOOP_SPEC_STATE_FLAGS`, `LOOP_SPEC_STATE_REPORT` | Internal deferral-guard state serialization. |
| `LOOP_SPEC_DIR` | Internal session-learnings path variable. |
| `LOOP_SPEC_VERSION` | Packaging/test override for plugin-version detection. Production reads the installed manifest. |
| `LOOP_SPEC_PLUGIN` | Deployment-wrapper path used by the documented cloud recipe; plugin runtime itself does not read it. |

When integrating loop-spec, depend only on the supported inputs and documented
machine-result files/lines. Internal variables may change without compatibility
guarantees.
