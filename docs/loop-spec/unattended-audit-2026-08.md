# Unattended-operation audit — 2026-08-02

Full-plugin audit at **v2.30.1**, scoped to how loop-spec behaves when it runs with
nobody watching: headless `claude -p` in an ephemeral container, the Claude Agent SDK,
cron, and the OpenCode SDK. Roughly half of all loop-spec invocations run this way,
for long stretches, so the governing question throughout was not "is this correct?"
but **"if this goes wrong at 3am, does anything notice?"**

Method: five parallel scoped investigations (Codex) plus an independent pass. Every
finding below was reproduced or traced to specific lines before it was acted on;
findings that did not survive that check are recorded as withdrawn rather than
quietly dropped.

## Part 1 — the v2.23.1 dogfooding backlog is closed

`LOOP_SPEC_IMPROVEMENTS.txt` recorded 12 items from three real unattended Cloud Run
runs against loop-spec v2.23.1. All 12 are resolved at v2.30.1. This is recorded so
the file can be retired rather than re-litigated.

| # | Item | Evidence at HEAD |
|---|------|------------------|
| 1 | loop-fleet rung unrunnable headless, failed silently | `lib/harness.sh:133-160` `loop-runtime` probe; loud stall escalation in `skills/shared/execute-loop-fleet.md:122,138` |
| 2 | Rung hinged on incidental DAG width | `lib/execute-rung.sh:103-109` — subagent is the safe wide-DAG fallback, with a logged reason |
| 3 | `teamsAvailable` was an LLM judgment | `lib/teams-capability.sh` — version + flag gate, fails safe on unknown version |
| 4 / 12 | Delivery-blocked indistinguishable from non-convergence | `lib/cycle-result.sh:546-562` — `delivery-blocked` outcome plus `retryable` / `retryPhase` |
| 5 | No pre-existing-failure baseline | `lib/verification-baseline.sh`, wired at `skills/cycle/SKILL.md:552` before any edit |
| 6 | Env bootstrap interleaved with VERIFY | `lib/prepare-environment.sh`, wired at `skills/cycle/SKILL.md:521` |
| 7 | DELIVER SHA binding tripped on loop-spec's own commits | Local artifacts live in untracked `info/exclude` (`lib/runtime-ignore.sh`); `finalize-delivery-candidate.sh` commits before `deliver.sh` reads `target_sha` |
| 8 | Micro guard fired inside a full cycle | `hooks/team/adhoc-verify-guard.sh:87-97` — deterministic `active-cycle.sh has-active` stand-down |
| 9 | Security-signal false positive on "authoritative" | `lib/security-signal.sh` two-tier strong/weak vocabulary |
| 10 | Phase-boundary observability | **PARTIAL — see below** |
| 11 | Dirty worktree before rebase | `lib/integrate-task.sh:159` `check_clean` precedes the only `git rebase` call site |

### Item 10 is PARTIAL, not closed

An earlier revision of this document listed item 10 as closed on the strength of
`lib/events.sh` emitting phase markers. A closer read does not support that, and the
correction is recorded here rather than quietly amended.

What **is** done, and is genuinely deterministic: `phase_start` / `phase_end` write a
greppable `LOOP_SPEC_PHASE_START` / `LOOP_SPEC_PHASE_END` line to stdout carrying the
full event JSON including `elapsedSeconds` and a verdict, from one generic call site
that covers all seven phases.

What is **not**:

- `lib/events.sh:236-241` sets no marker in its `else` branch, so **every non-phase
  event is JSONL-only**. `gate_round`, `dispatch`, `iterate_verdict`, `verify_failure`
  and `checkpoint_pr` never reach stdout — critique-gate rounds, teammate dispatches
  and verify failures are invisible in a streamed log.
- The `[PHASE] start` / `[PHASE] done (elapsed) — verdict` treatment the original
  report actually asked for — the one modelled on EXECUTE's praised rung-decision line
  — is stated as **prose** in `skills/shared/report-style.md` and instructed at
  `skills/cycle/SKILL.md:764-766`. It is not a bash echo and has no test. Actual
  bash-echoed `[TAG]` lines exist only in EXECUTE (6) and DISCUSS (1); INTAKE, SPEC,
  PLAN, VERIFY, ITERATE and DELIVER have none.
- `skills/deliver/SKILL.md` contains **zero** `events.sh emit` calls, so DELIVER is
  silent between its phase boundaries — including a CI-checks wait of up to 900s,
  which is exactly when an operator most wants to know the run is alive.

By this repo's own "probes, not judgments" rule a greppable-boundary contract that
depends on model compliance is not a mechanism.

**Converted in this change** — see "Observability is now a mechanism" below. Item 10
is closed on the second pass, for the reason it should have been closed the first
time: there is now a deterministic emitter and a test, not a document asking nicely.

## Part 2 — fixed in this change

Ordered by what they cost an unattended run.

### Session wedge: an invalid `LOOP_SPEC_WORKTREES` denied every tool call, everywhere

`hooks/team/no-worktrees-guard.sh` validated its setting **before** the `.loop-spec`
project-scope check, and is registered on `Agent|Bash|EnterWorktree`. Any value other
than `0`/`1` — `true` being the natural typo for a boolean — made it `exit 2` on every
Bash call in every repository, including ones with no `.loop-spec/` at all. Reproduced
with `true`, `yes`, `TRUE`. There was no recovery: the session could not run `echo` to
diagnose itself, and an unattended run has no operator to correct the environment.

Scope is now checked first, and an unrecognized value resolves to the restrictive mode
rather than denying the tool surface.

### Lost runs: the documented Cloud Run supervisor ignored failed phases

`docs/loop-spec/cloud-run-autonomous.md` — the supervisor loop integrators copy —
never checked `claude`'s exit status or that a result file existed. A phase that died
made the `jq` error, which took the "not a handoff" branch, which `break`s, which
exits the script cleanly. A lost run reported success. The example now checks both and
reconciles on failure.

### Hangs: six external-command sites could block forever

`lib/pr-delivery.sh` bounded its network calls correctly; five sibling scripts did not.
Unattended, a hang is indistinguishable from slow progress — the container burns to its
deadline and no terminal result is written.

`lib/bounded-run.sh` is now the single seam, carrying pr-delivery's proven runner plus
stdin and shell-fragment variants, killing the whole process group on timeout.

| Site | Why it mattered |
|------|-----------------|
| `checkpoint-pr.sh` | The crash-rescue path. `cycle-reconcile.sh:72` runs it after the agent exits, wrapped in `\|\| true` — which absorbs a failure but not a hang, stranding the last safety net. |
| `pr-comments.sh` | Several `--paginate` loops, unbounded. |
| `credential-refresh.sh` | The token-mint hook every gh/git stage runs first. A stalling broker blocked all three callers at once. |
| `regression-scan.sh` | Replays test commands recorded by *prior* features. "Advisory result" bounds the verdict, not the runtime. |
| `verify-live.sh` probes | Unbounded acceptance probes. |
| `verify-live.sh` readiness | Found independently of the Codex sweeps: `readyTimeoutSec` counts *attempts*, so one `ready` probe that never returned meant the deadline was never re-checked and the bounded wait became infinite. |

`run-with-watchdog.sh` also accepted `--timeout-secs 0`, which passed validation and
then disabled the deadline while the sidecar still advertised a bound — a watchdog that
does not watch. Zero is now refused.

### Wrong capability: positive overrides could claim absent harness surfaces

`teams-capability.sh` and `workflow-availability.sh` both checked their operator
override before the non-Claude harness gate:

```
LOOP_SPEC_HARNESS=pi       LOOP_SPEC_TEAMS_MODE=implicit   -> implicit
LOOP_SPEC_HARNESS=opencode LOOP_SPEC_WORKFLOWS_AVAILABLE=1 -> true
```

The first routes EXECUTE onto a team rung on a harness with no Agent tool, where every
spawn throws. `teams-capability.sh`'s own header comment said the gate existed to stop
exactly that; the check order defeated it. Both gates now precede their override. An
override may still turn a capability **off** anywhere — the always-safe direction — but
can no longer turn one **on** where the surface does not exist.

### Wrong grounding: every resumed feature was pointed at `resilience-ops`

`lib/pause-snapshot.sh:272` hardcoded `docs/loop-spec/features/resilience-ops/PLAN.md`
in every `.continue-here.md` "REQUIRED READING" list — the slug the script was
originally built for, never templated, and the only occurrence in `lib/`. Every other
paused feature told the resuming session — typically unattended, after a crash — to
ground itself in a different feature's plan. Now derived from `artifacts.plan`.

### False failure: DELIVER could reject a feature that shipped everything

`lib/deferral-lint.sh` matched `not implemented` and `remaining gaps` with no
awareness of negation or past-tense repair framing, and `lib/deliver.sh:71-82` treats a
flag as terminal (`exit 3`, no rewrite loop). Its only override is an env var an
unattended run has nobody to set. So a PR body saying *"0 remaining gaps; every
acceptance criterion is met"* failed the whole cycle on word choice — reported as a
scope violation. Verified before and after; the exemptions are narrow and every real
deferral still flags.

### Observability is now a mechanism

The fix for item 10. `lib/events.sh` prints one `[PHASE] ...` line to **stderr** for
every event it records, alongside its existing JSONL write:

```text
[SPEC] start
[DISCUSS] gate critique round 2 - escalated
[PLAN] dispatch planner [opus, team]
[EXECUTE] task 2/5 start - task-002: Surface Airline in the Routes table
[EXECUTE] task 2/5 done - task-002 [merged]
[VERIFY] FAILURE: code-review
[ITERATE] verdict: converged
[DELIVER] waiting on required checks (120s/900s elapsed, 3 pass, 1 pending, 0 failed of 4)
[DELIVER] done (115s) - completed -> completed
```

EXECUTE is the longest phase and used to report only `[EXECUTE] start`, so a log
watcher could not tell task 1 of 6 from task 5 of 6, nor progress from a stall. The
`task_start` / `task_end` pair closes that: `total` counts the whole DAG rather than
the current wave, so the ratio advances monotonically across waves, and a `task_start`
with no matching `task_end` is precisely what a stall looks like.

Three deliberate choices:

- **stderr, not stdout.** stdout carries the machine contract — the
  `LOOP_SPEC_PHASE_START`/`_END` markers and their JSON, which callers parse and tests
  assert on. Putting a human line there would have broken both. Both streams land in a
  streamed log, so the operator gains everything and no consumer loses anything.
- **In the emitter, not in the skills.** 26 `events.sh emit` call sites already exist
  at the right moments. Emitting the console line where the event is recorded means
  observability follows from the event, and a missing boundary line is now a missing
  *event* — a real, findable bug rather than a model that forgot to narrate.
- **`pr-delivery.sh` prints its own heartbeat.** It has no feature dir and so cannot
  use `events.sh`, but its required-checks loop is exactly where a run goes quiet for
  up to 900s. It now emits progress in the same format under the same kill switch.

`report-style.md` no longer instructs the model to print boundary lines; it documents
what the mechanism emits and what remains genuinely model-authored (EXECUTE's
rung-decision line, a domain detail with no corresponding event).
`LOOP_SPEC_CONSOLE_EVENTS=0` silences the console without touching the ledger.

### Contract: `${CLAUDE_PLUGIN_ROOT}` in agent bodies

`agents/planner.md` and `agents/pattern-mapper.md` instructed the agent to read a
template from `${CLAUDE_PLUGIN_ROOT}/...`. CLAUDE.md documents that variable as valid
in hooks/MCP configs only, and there is no per-agent equivalent of
`${CLAUDE_SKILL_DIR}`. `tests/validate-agents.sh` now rejects it.

### Crash: pi bridge could die on stdin EPIPE

`extensions/pi/loop-spec.ts` wrote to a hook's stdin with no `error` listener. A hook
that exits before reading emits an async EPIPE, which Node treats as process-fatal —
the surrounding `try/catch` cannot see it. The OpenCode bridge already guarded this
exact condition.

## Part 3 — found, verified, deliberately not fixed here

These are real and reproduced, but each is a design change rather than a defect fix,
and shipping them unreviewed alongside the above would be the wrong trade.

1. **`/loop-spec:auto`'s "risky work fails upward" is prose-enforced.** `lib/task-route.sh`
   is a sound deterministic validator, but no hook requires it to have run before
   `Skill(loop-spec:micro)`. `grep -rl "AUTONOMOUS_ROUTE\|task-route" hooks/` returns
   nothing. Enforcing it needs a transcript-scanning PreToolUse gate — a real design
   decision, not a patch.
2. **`task-route.sh` risk booleans are uncorroborated.** Only `workingTreeConflict` is
   independently computed; `securitySensitive` and friends are taken from the model's
   own JSON. `lib/security-signal.sh` already exists and is used this way by DISCUSS
   and PLAN — wiring it in is the obvious fix, but it changes routing behavior.
3. **OpenCode SDK sessions are never classified headless.** OpenCode exports no
   entrypoint stamp, so `harness.sh headless` returns `false` and `cycle-preflight`
   emits no warning. A cycle can then ask a question nobody will answer.
4. **No `permission.asked` handler for SDK-driven OpenCode.** Operations defaulting to
   `ask` leave the server waiting for a reply an unsupervised caller never sends. The
   OpenCode CLI's own non-interactive path auto-rejects; loop-spec has no equivalent.
5. **`opencode-install.sh` can publish a manifest after a partial failure**, listing
   only successfully created paths, so `status` later reports a clean install.
6. **`cycle-preflight.sh:58` clears the prior result pointer before an active record
   exists** — a Graphify abort right after leaves neither terminal nor recovery state.
7. **`cycle-result.sh` terminal writers can exit 0 without publishing a pointer.**
8. **Micro/debug direct-invocation scope bounds are prose-only** and are absent from
   `docs/determinism-audit.md`'s own ledger.
9. **No test proves a `TeamCreate`-spawned teammate receives its frontmatter tools.**
    All five call sites pass `{name, subagent_type, model, prompt}` with no explicit
    `tools`, relying entirely on `subagent_type` → agent-file resolution; only
    frontmatter *shape* is tested. If that resolution ever degrades in a harness
    version, it reproduces the original "teammates can only read" report with a
    perfectly correct agent file on disk. Needs a live smoke test, not an offline one.

Items 6 and 7 are the closest to defects and should lead the next pass; they touch the
one file every unattended run depends on for its success signal, so they deserve their
own change with focused tests.

## Withdrawn

Recorded because a plausible-looking finding that fails verification is worth as much
as one that passes.

- **"~48 documented-but-unread `LOOP_SPEC_*` variables."** A naive grep missed `$VAR`,
  `os.environ.get`, and dynamically composed prefixes. The hits are archived feature
  `PLAN.md` specs plus two variables `configuration.md:359` explicitly declares as
  documentation placeholders. No drift.
- **"Agent tool grants are insufficient for their roles."** The original run-2 report
  blamed a lost run on teammates that "only have {Read, Write}". Withdrawn **at the
  agent-file level only**: all 14 `agents/*.md` were read and none is under- or
  over-granted for what its own prompt instructs. The reported symptom matches no file
  on disk, and the mechanism that actually killed that run was the capability-override
  ordering bug fixed above. The *runtime* question is not withdrawn — it is Part 3
  item 9, because nothing proves the grant survives `TeamCreate` resolution.
