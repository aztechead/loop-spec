# loop-spec 7.x process contract

For someone implementing a phase bound to `external`, writing a bound role skill,
or driving loop-spec directly from a harness. It names every file, field, and exit
code the program reads or writes. Source: `skills/loop-spec/program/loop_spec/`.

## Process contract

The controller drives one phase at a time through `contract.invoke` (in `contract.py`).
An implementation is one of:

- **`default`** — the program's own code runs the phase. SPEC and PLAN dispatch a
  `lead` step running a bound role's prompt (`defaults.py`). EXECUTE, VERIFY, ITERATE,
  DEBUG, and REVISE drive a `step()`/`on_submit()` loop that issues `role` steps one
  at a time (`execute.py`, `verify.py`, `iterate.py`, `debug.py`, `revise.py`).
  DELIVER runs one pass with no worker step (`deliver.py`).
- **`external`** — a person or another tool produces the phase's whole product.
  `external.py` issues one `kind: "external"` step naming the schema and exits to
  produce; nothing else runs until that step is submitted.
- Any other value raises `LoopSpecError`: binding a phase itself to a named skill
  (as opposed to binding a *role* a default implementation dispatches to, below) is
  not implemented in this release.

Every phase writes its output at `<attempt dir>/product.json`, `step.json`, or
`question.json`, where `<attempt dir>` is
`<state home>/<repo id>/<slug>/attempts/<attempt id>/`. `contract.invoke` reads
whichever file the implementation's return value implies:

| Return | File read | Meaning |
|---|---|---|
| a product | `product.json` | the phase is done; validated against that phase's schema |
| a step request | `step.json` | the controller issues a step (`steps.issue`) for a worker to complete |
| a question request | `question.json` | the controller asks a question (`questions.ask`) |

A future out-of-process implementation can produce the same files by running
`loop-spec phase <name> --context <path> --product <path>` (registered in `cli.py`,
mapped to `contract.run_phase`) and exiting 0/2/3 the way `contract.invoke`'s
in-process dispatch does today for `external`; nothing in this release actually
spawns that command as a subprocess.

## Envelope

Every attempt gets one `context.json`, built by `controller.build_envelope` and
validated against `schemas/context.json`. Top-level fields: `run.id`, `attempt.id`,
`inputs.digest` (a `sha256:` digest of the run's own inputs), `request` (the
original text and its digest), `products` (every accepted phase's `exit`/`boundTo`/
`product`), `state` (revisions, approval, baseline, ledger, budget, and `closeOuts`: the
registry of `execute` gaps accepted from ITERATE, each `C-n` with its text, repo,
source, status and closure), `entry.mode`
(`fresh`, `remediation`, or `rewind`) and `entry.payload`, `repos`, `paths`
(`stateDir`, `writable`, `projectRoot`), `answers` (`byQuestion` plus the run's
answer `policy`), and `probes` (reserved; empty in this release).

## Products

Each phase's product is one JSON object, `<attempts dir>/<id>/product.json`,
validated against `schemas/<phase>.json`. Every product carries `exit`,
`inputsDigest`, and `boundTo` (`{requirements, plan}`, the revisions it binds to).
Exit values, from `external.PHASE_EXITS`:

| Phase | Exits |
|---|---|
| spec | `approved`, `needs answer` |
| plan | `ready`, `spec gap` |
| execute | `integrated`, `no change`, `blocked`, `plan gap` |
| verify | `passed`, `implementation gap`, `plan gap`, `intent gap`, `evidence incomplete`, `blocked` |
| iterate | `converged`, `converged with caveats`, `rewind`, `escalated` |
| deliver | `delivered`, `partially delivered`, `delivery blocked` |
| debug | `reproduced`, `blocked reproduction` |

Fields beyond the common three, per phase (see `schemas/<phase>.json` for the full
shape, including nested item schemas):

- **spec**: `goal`, `boundaries[]`, `criteria[]` (`{id: "AC-n", text}`),
  `decisions[]`, `openQuestions[]`.
- **plan**: `tasks[]` (`id: "T-n"`, `title`, `dependsOn[]`, `files[]`, `repo`,
  `verify`, `criteria[]`, `featureAdded`, `mustFlip`), `prepare`,
  `evidenceExceptions[]`, `criticResponses[]`.
- **execute**: `tasks[]` (`id`, `disposition`: `done`/`already-satisfied`/`removed`/
  `adopted`, `evidence`, `commits[]`, `review`; one entry per registered close-out
  `C-n`, `done` or `already-satisfied`), `issues[]`, `heads` (repo name to head SHA).
- **verify**: `verdicts[]` (`criterion`, `verdict`: `pass`/`fail`/`blocked`,
  `evidence` with a required `repo`, `cause`), `findings[]` (`repo` optional),
  `remediationTasks[]`, `reviewedRanges[]` (`repo`, `from`, `to`, `full`; one per
  touched repo — LF-28: a workspace run has no single reviewed range).
- **iterate**: `verdict` (`met`/`unmet`), `gaps[]` (`target`: `spec`/`plan`/
  `execute`/`verify`, `text`, optional `repo`; `findingId` on a gap the program
  adds for an open Critical finding), `caveats[]`, `boundShas` (repo name to SHA; LF-28
  replaced the single-repo `boundSha`).
- **deliver**: `repos[]` (`repo`, `pr`, `deliveredSha`, `caveats[]`, `state`:
  `delivered`/`failed`/`skipped`).
- **debug**: `reproduction` (`command`, `failureDigest`, `reason`), `original`,
  `diagnosis`, a compact `spec` and `plan` (the same shapes as SPEC's and PLAN's
  own products, folded into SPEC and PLAN once accepted).

Which exit routes where, and the postcondition ids each one requires, is
`postconditions.ROUTES` and `external.PHASE_POSTCONDITIONS`/`POSTCONDITION_TEXT`;
the full route matrix and postcondition prose live in
[phase-interface-7.0.md](../../../docs/loop-spec/phase-interface-7.0.md) and are not
repeated here.

## Steps

A step is one worker dispatch, `schemas/step.json`. Fields: `stepAttemptId`,
`kind` (`role`, `lead`, or `external`), `role` (the role name, or `null` for
`external`), `phase`, `cwd`, `prompt` (the composed prompt plus a trailer naming
the step id, inputs digest, phase, and result path), `resultPath`, `schema` (the
result's own JSON Schema), `postconditions[]`, `attempt`, `inputsDigest`,
`issuedAt`, `retryOf`, `reason`, and an optional `model` (every role dispatch sets
this from `roles.resolve_model`, env `LOOP_SPEC_MODEL_<ROLE>` or config
`roles.<role>.model`). In the composed prompt each input section's trailing
newlines are trimmed, so exactly one blank line separates sections; its interior
lines are kept exactly, and a JSON input shows a non-ASCII character as itself, never
as a `\u` escape (`jsonio.render_json`). A step composed before 7.0.3 keeps its old prompt and can
fail attestation on every dispatch; recover with a fresh run.

A worker writes its result to `resultPath` (write to a temp file in the same
directory and rename) and, for a transcript-attested dispatch, ends its final
message with `LOOP_SPEC_RESULT_DIGEST <sha256:hex of the result file bytes>`.
`resultPath` (`paths.ensure_results_dir`) is under the project's
`.loop-spec/results/<slug>/`, never under the state home, because a live model's
default permission mode refuses writes under `~/.claude` (LF-27; see "Model-written
results" below). Then run `loop-spec submit --step <id> --slug <slug> [--dispatch
<name>] [--result-file <path>]` (`cli.py`/`steps.py`); `--result-file` reads the
result from `<path>` instead of `resultPath` — same schema validation, digest, and
submission record — for a worker that wrote its result somewhere else.

`submit` (`steps.submit`) validates the result against the step's schema, then
picks one evidence level:

| Evidence level | When |
|---|---|
| `human-attested` | `kind: "external"` |
| `controller-observed` | this run's own `state["run"]["runner"] == "sdk"` (set by `sdk_runner.run_step_sdk` itself, before it launches a session) AND a `receipt.json` under `paths.steps_dir/<stepAttemptId>/` (never beside the worker-writable result) has a matching `stepAttemptId` and `resultDigest` |
| `host-attested` | `--dispatch <name>` was given and `attest.ClaudeCodeAttestor` (only constructed when `CLAUDE_CODE_SESSION_ID` is set) finds and checks exactly one native subagent transcript, whose opening record contains the step's ENTIRE composed prompt (not just its trailer lines) |
| `unattested` | none of the above, or an attestation attempt failed |

A mismatched receipt (wrong id or digest) is recorded as
`attestation: {ok: false, reason: "sdk receipt digest mismatch"}` and the level
stays `unattested`; a receipt on a run whose `runner` is not `"sdk"`, or beside a
result rather than under `paths.steps_dir`, is not even read (R2: a receipt in the
old, worker-writable location, or on a run nothing here ever launched under the
SDK, is not evidence of anything). A step is retired once submitted; resubmitting
the same digest replays the same result (idempotent); resubmitting a different one
is refused.

A `role` step whose `role` is `plan-critic`, `code-reviewer`, or `iterate-judge`
(pure judgment the program cannot re-derive) is never accepted `unattested`: an
unattested submission for one of these leaves the step open, bumps its
`attestationAttempts`, emits `step_redispatch`, and `submit` returns a `redispatch`
name (`<stepId>-<n+1>`) for a fresh worker dispatched under that exact name with
the same prompt, up to `retry_limit()` (`LOOP_SPEC_STEP_RETRIES`, default 3)
attempts; past the bound it is accepted `unattested` as usual and an entry lands in
`attestationWaivers`, surfaced in the result's `weakenedAssurance`.

## Questions

A question is `schemas/question.json`: `questionId`, `attempt`, `phase`, `text`,
`options[]` (`{value, label}`), `defaultValue`, `kind` (`approval`, `choice`,
`text`, or `blocked`), `payload`, `askedAt`. Only one question may be open per run.
Answer with `loop-spec answer --question <id> --answer <value> --slug <slug>
[--scope question|run]` (`schemas/answer.json`: `questionId`, `value`, `scope`,
`answeredAt`, `by`: `human` or `policy`). `--scope run` also sets the run's answer
policy to `default`, so `questions.resolve_policy_answer` answers every later
question that carries a `defaultValue` without asking again; the result's
`policyAnsweredQuestions` lists every question a policy, not a person, answered. A PLAN critic question asked after the second pass carries the critic's own
recommendation as its default (P7), so a policy can answer it; with no recommendation
it has no default and waits for a person.

## Markers and console lines

Every controller entry ends its stdout with one line,
`LOOP_SPEC_NEXT {"kind": "step"|"question"|"result", "path": <file>, "slug": <slug>}`
(`events.marker_next`). Open the named file and act on it; every later `submit` or
`answer` call needs `--slug` from this line, since nothing else names the run. A
wave that issues several step requests at once (`execute.py`'s `IssueSteps`) prints
one `LOOP_SPEC_NEXT` line of kind `step` per request instead of one, for the caller
to dispatch in parallel; when a wave has open steps but nothing new to issue
(`execute.py`'s `Wait`), the program prints `LOOP_SPEC_WAIT {"open": [<stepAttemptId>,
...]}` (`events.marker_wait`) instead of any `LOOP_SPEC_NEXT` line. Outside that case,
every call re-announces each step still open as a `LOOP_SPEC_NEXT` line
(`controller.continue_run`), including a step the caller already dispatched; a caller
dispatches and submits each `stepAttemptId` once.
Phase boundaries also print `LOOP_SPEC_PHASE_START {...}` and
`LOOP_SPEC_PHASE_END {...}` (`marker_phase_start`/`marker_phase_end`), and a new
question prints `LOOP_SPEC_QUESTION {"questionId": ...}`. Every marker also lands
in `events.jsonl`. Ordinary progress lines (`[PHASE] summary`) go to stderr, unless
`LOOP_SPEC_CONSOLE_STREAM` says otherwise or `CLOUD_RUN_JOB`/`K_SERVICE` is set (then
stdout, so Cloud Run does not tag routine progress as an error); `LOOP_SPEC_CONSOLE_EVENTS=0`
silences them.

## Result

The terminal result, `schemas/result.json` (schema 1, `additionalProperties: true`
so a future field never breaks an old consumer), written by `result.py` at
`<state home>/<repo id>/<slug>/result.json` and mirrored to
`<state home>/<repo id>/last-result.json` (shared across every slug in that
repository; a `paused` result is not mirrored, since the run is still resumable).
Key fields: `status` (`completed`, `paused`, `escalated`, `failed`), `outcome`,
`result` (`converged`, `converged-with-caveats`, `no-change`, `escalated`,
`failed`, `paused`), `converged`, `workDelivered`, `phaseReached`, `prUrl`,
`delivery`, `reviewed` (task id to evidence level), `unreviewed[]`,
`weakenedAssurance[]`, `rewinds`, `hostVersions`. Every `weakenedAssurance` entry is
an object carrying its own `kind`: E6's `evidence.review.accept` entries are
`{kind, value, task}`; V5's `evidence.exception` entries are `{kind, criterion,
source: "plan" | "answer", reason}`.

## State home layout

`<state home>/<repo id>/<slug>/`:

- `state.json` + `state.digest` — the run's durable state; `state.py` refuses to
  open a `state.json` whose digest does not match, so nothing but the program may
  edit it.
- `events.jsonl` — every event and marker, append-only.
- `attempts/<attempt id>/` — `context.json`, and that attempt's `product.json` /
  `step.json` / `question.json` / `answer.json`.
- `steps/<step id>/` — a non-phase step's own `step.json` and `result.json` (a
  phase's own step writes its result straight to the attempt directory instead).
- `worktrees/` — EXECUTE's per-repo feature worktree, and `steps.retire`'s
  quarantine for one a dispatch never confirmed as terminated.
- `checkouts/` — disposable clean checkouts VERIFY, EXECUTE's re-verification, and
  baseline capture create and remove per run.
- `result.json` — this run's terminal result, once written.

`repo id` is derived from the project's first root commit (`paths.repo_id`), so it
survives a remote rename; `<state home>` itself is resolved by `state_home`
(`paths.py`), see below.

## Model-written results

Program-written records (state, events, attempts, steps' own metadata) live under
the state home above. A worker's result file is different: it is model-written,
`resultPath` points at `<project root>/.loop-spec/results/<slug>/<step id>.json`
(`paths.FeaturePaths.results_dir`, created by `paths.ensure_results_dir`), and
`submit` reads and validates it from there, computing the same digest and
evidence-level record it always has. This split exists because Claude Code's
default permission mode refuses writes under `~/.claude`, where the state home
lives on that host, even with the Write tool allow-listed (LF-27). `.loop-spec/`
is kept out of `git status` via the repository's own `.git/info/exclude`
(`repo.exclude_path`), never `.gitignore`, so nothing about it is committed.

## Configuration and environment

`.loop-spec/config.json` in the project root (`contract.load_config`); every key
optional:

| Key | Effect |
|---|---|
| `phases.<phase>` | binds that phase's implementation (`"external"`, or a phase name is otherwise `"default"`) |
| `roles.<role>` | binds that role to a skill other than the bundled default (`roles.load_role`); a plain string is the binding, or an object `{"binding": ..., "model": ...}` also names a model for that role's dispatches (`roles.resolve_model`), reachable without also rebinding the skill |
| `deliver.base` | overrides the branch DELIVER's PR targets, instead of the repo's detected default branch |
| `deliver.readiness` | `"checks"` makes D3 wait on `gh pr checks`; default `"none"` skips that wait |
| `deliver.escalatedPartialDraft` | `true` routes an escalated ITERATE forward into DELIVER for a draft PR instead of terminating |
| `evidence.review.accept` | `"unattested"` lets an `unattested` review count toward EXECUTE's E6, instead of blocking the task; every task accepted this way is listed in the result's `weakenedAssurance` |

Environment variables, precedence over config where both apply:

| Variable | Effect |
|---|---|
| `LOOP_SPEC_HOME` | state home root; default `~/.loop-spec` |
| `LOOP_SPEC_PYTHON` | interpreter the `loop-spec` launcher execs; default `python3`, must resolve to >= 3.11 |
| `LOOP_SPEC_PHASE_<NAME>` | overrides `phases.<phase>`; `<NAME>` is the phase name uppercased (`EXECUTE`, `DELIVER`, ...) |
| `LOOP_SPEC_ROLE_<ROLE>` | overrides `roles.<role>`; `<ROLE>` is the role name uppercased with hyphens kept as-is (`SPEC-WRITER`, `CODE-REVIEWER`) |
| `LOOP_SPEC_MODEL_<ROLE>` | sets the model on that role's step request (`roles.resolve_model`, read by every role dispatch: execute.py, controller.py's critic and adopted review, verify.py, iterate.py, debug.py, revise.py, defaults.py); `<ROLE>` has hyphens replaced with underscores (`SPEC_WRITER`). Overrides `roles.<role>.model` when both are set |
| `LOOP_SPEC_STEP_RETRIES` | per-phase retry limit before a rejected product asks a `fix-and-re-enter`/`stop` question; default 3 |
| `LOOP_SPEC_REWIND_BUDGET` | the shared T1 budget's limit; default 2, never resets within a run |
| `LOOP_SPEC_EXECUTE_WIDTH` | EXECUTE's max tasks per wave; default 3 |
| `LOOP_SPEC_CONSOLE_EVENTS` | `0` silences the `[PHASE] summary` progress lines |
| `LOOP_SPEC_CONSOLE_STREAM` | `stdout` or `stderr`, overriding the Cloud Run auto-detect |
| `LOOP_SPEC_DUP_MIN_LINES`, `LOOP_SPEC_INDIRECTION_MAX_BODY` | floor overrides for two of `probes.py`'s bundled probes, surfaced to a role's prompt under `inputs.probes` |
| `CLAUDE_CODE_SESSION_ID` | presence (any value) turns on `host-attested` evidence for dispatched steps |

A name not listed here, in [../../../docs/loop-spec/migrating-6-to-7.md](../../../docs/loop-spec/migrating-6-to-7.md)'s
environment table, or read directly by `os.environ.get` in
`skills/loop-spec/program/loop_spec/*.py` is not a control.

## Implementations

`resolve_implementation`/`resolve_role` (`contract.py`) both check the matching
environment variable first, then `.loop-spec/config.json`, then fall back to
`"default"`. A **phase** implementation is `"default"` or `"external"` only; a
third value raises (bound phase implementations are not built in this release). A
**role** implementation is `"default"` (the bundled skill under
`skills/loop-spec/roles/<name>/`) or a bound skill name, resolved by
`roles._bound_skill_candidates` against the project's `.claude/skills/<name>/`,
the user's `~/.claude/skills/<name>/` or `~/.agents/skills/<name>/`, or (for a
`plugin:skill` binding) an installed plugin's cache. A bound role supplies its own
prompt body only; `roles.load_role` still validates the result against the
*default* role's schema, and `roles.CONTRACTS` appends the same
program-authored contract text regardless of source. The nine roles that ship
under `skills/loop-spec/roles/`: `spec-writer`, `planner`, `plan-critic`,
`implementer`, `code-reviewer`, `verifier`, `iterate-judge`, `debugger`, `reviser`.
