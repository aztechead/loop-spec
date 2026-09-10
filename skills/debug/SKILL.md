---
name: debug
description: Use when the user pastes an error, stack trace, failing test, or a vague "something's wrong / flaky / slow". Writes docs/loop-spec/debug/{slug}/BUG.md (triage, red repro, fix, sibling sweep, verify). Do not use for a new feature (that's /loop-spec:cycle) or a tiny unrelated edit (that's /loop-spec:micro).
argument-hint: "<error text | stack trace | failing test | vague symptom description>"
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion
---

# Debug Loop

Run as `/loop-spec:debug <input>`.
Record the investigation in BUG.md and use a failing reproduction to verify the fix.
Work in the main thread, with one-shot subagents when needed. Do not create teams or a phase graph.

Honors autonomous mode (`skills/shared/autonomous-mode.md`): with the `autonomous`
token or `LOOP_SPEC_AUTONOMOUS=1`, strategy questions self-answer with the
recommended option and are recorded in BUG.md's `## Decisions` section. Styles: `auto`
(default) runs end-to-end; `step` pauses after TRIAGE and after each hypothesis verdict.

## The one hard gate

**No fix before a red reproduction.** The reproduction command must fail because of the reported bug before FIX begins.
For an unreproducible bug, follow REPRODUCE step 3's observation plan.
Record that plan in BUG.md before changing instrumentation.

## Step 0 - Classify and initialize

Rewrite free-prose symptom text per `skills/shared/prompt-normalize.md` before
anything derives from it; the rewritten text is what `$ARGUMENTS` means in the init
call below. Concrete artifacts (stack traces, error output, failing-test names,
commands) pass through byte-for-byte, so an input that is all artifact passes
through unchanged.

1. **Initialize deterministically** — one call does the mechanics (token stripping,
   slug, BUG.md dir, branch discipline, branch-point SHA capture, test-cmd detection):
   ```bash
   dbg="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/debug-init.sh" init -- "$ARGUMENTS")"
   # Observability: debug is an autonomous-router target and used to emit nothing.
   bash "${LOOP_SPEC_SKILL_DIR}/../../lib/events.sh" emit "$(jq -r '.bug_dir' <<<"$dbg")" phase_start --phase debug || true
   # {slug, bug_dir, branch, branch_action: created|switched|kept, default_branch,
   #  dirty, sha_before, test_cmd, autonomous, style}
   ```
   `.sha_before` is the test-tamper baseline VERIFY needs (Step 4) — it is captured
   before ANY change, which is exactly why it is script-side. `.test_cmd` honors
   `LOOP_SPEC_CMD_TEST` over detection; `feature.commands.test` (when a feature
   context exists) overrides both.
2. Start `BUG.md` in `.bug_dir` (format below) with the input - normalized prose,
   byte-for-byte artifacts - under `## Symptom (as received)`.
3. **Classify the input:**
   - **Specific** — it contains a concrete signal: an error message, a stack trace, a
     failing test name, a command that fails, a URL/endpoint that errors. Skip TRIAGE.
   - **Non-specific** — a vague symptom ("login sometimes hangs", "the build got
     slower", "something broke after Tuesday"). Run TRIAGE first.
4. **Dirty work-branch judgment** (`.branch_action == "kept"` and `.dirty == true`):
   stop and ask (autonomous: continue on the current branch only when the dirty files
   are unrelated to the symptom; record the decision) — a debug diff mixed into
   unrelated changes is unreviewable. The default-branch case never arises here:
   debug-init already created/switched to `fix/{slug}`.

## Step 1 - TRIAGE (non-specific input only)

Goal: converge the vague symptom to ONE specific, reproducible signal. Evidence
gathering, cheapest first — record every finding in BUG.md `## Triage evidence`:

1. **Run the test suite.** A failing test IS the specific signal — done, go to REPRODUCE.
2. **Interrogate the report.** What changed about observable behavior, when did it
   start, what does "sometimes" correlate with (load, input shape, environment)?
   Interactive: ask the user (2-3 sharp questions, grill style). Autonomous: extract
   what the input already states; do not invent observations.
3. **Recent history.** `git log --oneline --since=<symptom onset>` (or last 20) — a
   symptom with an onset date has a suspect commit range. If the range is small and
   the symptom is checkable by command, `git bisect` with that command is the fastest
   convergence tool there is; use it.
4. **Hotspots.** Search the symptom area to find what implements the behavior, then
   `bash "${LOOP_SPEC_SKILL_DIR}/../../lib/fragility-scan.sh" . --top 10`
   — entries overlapping that area rank where bugs historically cluster.
5. **Logs/artifacts the user named.** Read them for the first concrete error, timeout,
   or anomaly around the symptom.

Exit conditions:
- **Converged** — one concrete signal (a command, input, or sequence that exhibits the
  problem). Write it to BUG.md `## Converged signal` and continue to REPRODUCE.
- **Not converged** after the five sources — do NOT thrash. Write BUG.md with the
  evidence collected, the top 1-3 candidate hypotheses ranked with reasoning, and the
  single cheapest next observation that would discriminate between them (e.g. "add a
  timestamped log line at X and wait for recurrence"). In interactive styles offer to
  set up that observation; autonomous sets it up when it is additive-only
  (logging/assertions), commits it as `chore: instrument {slug}`, and reports. That is
  a legitimate completion: instrumented-and-waiting, not fixed. Never guess-fix an
  unconverged symptom.

## Step 2 - REPRODUCE (the oracle)

1. **Write the minimal reproduction as a failing test** in the project's test framework
   whenever the symptom is test-expressible (most are). Otherwise a script/command with
   a clear failing exit condition. Minimal: strip everything not needed to trigger it.
2. **Run it and capture the red output verbatim** into BUG.md `## Reproduction`
   (command, exact failure output, exit code). It must fail for the symptom's reason —
   a repro failing on a typo of its own is not red, it is broken.
3. **Genuinely unreproducible** (race under production load, third-party outage,
   already-vanished state): write the observation plan into BUG.md — what evidence
   would confirm the hypothesis, what additive instrumentation captures it, and what
   the confirmation threshold is. Instrument, commit, and stop there (as in TRIAGE
   non-convergence). Do not "fix" what you cannot observe.
4. **Flaky repro** (fails sometimes): make the repro deterministic first — control the
   seed/clock/ordering/timeout that drives the nondeterminism. A flaky oracle cannot
   verify a fix. If determinism is unreachable, quantify it (`N` runs, `M` failures)
   and require the fixed code to pass the same N-run battery.

## Step 3 - FIX loop (evidence-disciplined, unbounded)

There is no numeric limit on hypotheses or fix attempts.
Continue until you confirm and fix the mechanism, reach the scope limit, or cannot distinguish the remaining hypotheses.
If no useful observation remains, instrument and stop as in TRIAGE's not-converged exit.

Record each hypothesis and attempt in BUG.md's `## Hypothesis log`, with its mechanism, evidence, and verdict.
Complete that record before starting another attempt. Never reopen a REFUTED hypothesis without new evidence.

For each hypothesis, in ranked order:

1. **State a testable mechanism**, such as "X returns a stale value when Y because Z".
   Read the implicated code and call path. Check `git log -p` for the introducing change.
2. **Confirm before changing.** Find the smallest observation that could refute the hypothesis.
   Examples include a log line, intermediate value, or narrower assertion.
   If refuted, record `REFUTED: <evidence>`. Continue to the next hypothesis without changing code.
3. **Fix minimally**, following the debug stance in `skills/shared/engineering-stances.md`.
   Correct the confirmed mechanism. Do not refactor unrelated code.
   In `## Fix`, explain current behavior, the defect, its cause, the change, and covered edge cases.
   Name the test for each edge case.
   Record separate work as `new-mechanism:` in `## Deferred` and add it through `lib/backlog.sh add`.
4. **Verify.** Require the reproduction and full test suite to pass.
   Review `git diff` for unrelated behavior changes. Record `CONFIRMED` with the passing output.
   If reproduction still fails, record the failed attempt. Revert only that attempt, preserving pre-existing user changes.
   Refine or reorder the hypotheses.
5. **Scope tripwire:** the moment a correct fix demonstrably requires feature-scale
   work (schema change, cross-cutting redesign, new dependency), stop fixing. BUG.md
   becomes the spec draft. Emit the `escalated/promoted-to-full` terminal result described
   below immediately before `Skill(loop-spec:cycle)` with
   `docs/loop-spec/debug/{slug}/BUG.md` as the spec-file argument (interactive: confirm
   first; autonomous: pass the `autonomous` token with the path, hand off, and record).
   Do not emit a second debug result after delegation returns; the full cycle owns the
   stable pointer from that point.
   The debug loop fixes bugs; it does not
   smuggle features.

## Step 3b - SIBLING SWEEP (mandatory after CONFIRMED)

After confirming the root cause, check sibling code for the same mechanism.
This sweep is mandatory. Treat different mechanisms as new bugs under step 3 below.

1. **Sweep for the same mechanism** under `skills/shared/design-for-change.md`.
   Search every caller of the fixed function and copied instances of the flawed pattern.
   Follow imports to parallel code paths with the same mechanism.
2. **Fix same-mechanism siblings on this branch.** Apply the same minimal correction.
   Extend regression coverage for independently reachable siblings. Repeat Step 3.4 verification.
   If sibling fixes require feature-scale work, escalate through Step 3.5.
3. **Different mechanism found during the sweep → it is a new bug, not a sibling.**
   Record it under `## Deferred` as a `new-mechanism:` entry and backlog it
   (`lib/backlog.sh add "$slug" new-mechanism "..."` — mandatory); do not fix it in
   this branch — mixing mechanisms makes the diff unreviewable.
4. **Record the sweep in BUG.md `## Sibling sweep`:** the commands run, every site
   examined, and the verdict per site (`FIXED-SIBLING: <file:line>`,
   `CLEAN: <file:line>`, or `DEFERRED-NEW-BUG: <file:line>`). An empty sweep section is
   a defect: "no siblings" is a claim the commands must back. The loop does not
   advance to VERIFY without this section populated.

## Step 4 - VERIFY and land

Apply `skills/shared/verification-grounding.md`; the debug loop is not exempt because it
is smaller. Before running the suite, inspect the final diff, re-read every changed file
and the nearest caller/test/contract, and record `file:line` evidence in BUG.md `## Fix`
that ties the confirmed mechanism and each expected behavior to the repository. Re-probe
affected external premises. An unsupported assumption, stale pre-edit read, or mismatch
returns to the FIX loop; a green repro cannot substitute for this grounding gate.

1. **Keep the repro as a regression test** — it lands in the test suite, named after
   the bug, asserting the fixed behavior. A fix without its regression test is half a
   fix. (Command-style repros get distilled into a test where feasible; where not,
   record the manual verification command in BUG.md.)
2. Run the full test suite and configured lint and typecheck commands.
   Run `bash "${LOOP_SPEC_SKILL_DIR}/../../lib/test-tamper-scan.sh" "{sha_before}"` on the diff.
   Use `sha_before` from debug-init's Step 0 output, before any edit.
   Do not delete or skip tests, or ignore failed exit codes, to obtain a passing result.
   Adding the regression test is expected, not tampering.
3. Complete BUG.md (`## Fix` — root cause, mechanism, why this change is sufficient)
   and commit: BUG.md + fix + regression test on `fix/{slug}`, message
   `fix: {symptom summary}` with body naming the root cause.
4. Deliver as a PR, then check it for feedback: push `fix/{slug}`, open the PR
   (`gh pr create` — or reuse the branch's existing PR), and run the terminal feedback
   check per `skills/shared/pr-feedback-check.md`
    (`lib/pr-feedback.sh check <number>`). Requested changes still at bug scale get
    fixed in this loop. Every feedback-driven edit returns to Step 4: repeat repository
    grounding, the repro, the full suite, and tamper scan before the new commit/push and
    feedback re-check. Evidence from before that edit is stale. New-mechanism asks go to `## Deferred`
   / `/loop-spec:intake`. Keep the PR body short GitHub-flavored markdown: symptom,
   root cause, fix summary, regression test — link BUG.md rather than inlining it.
   Write the PR body to a file.
   Check it with `bash "${LOOP_SPEC_SKILL_DIR}/../../lib/deferral-lint.sh" text "$body_file"` before creating the PR.
   Sibling-sweep entries require their `new-mechanism:` marker. Then run `gh pr create --body-file`.
   No origin remote or no `gh`: degrade loudly — leave the branch, state exactly what
   blocked the PR. Record the PR URL and check outcome in BUG.md `## Fix`.
5. Report: root cause, the fix diffstat, the regression test, the PR URL + feedback
   check result, and anything in `## Deferred` — each line keeps its `new-mechanism:`
   marker and MUST already be backlogged
   (`bash "${LOOP_SPEC_SKILL_DIR}/../../lib/backlog.sh" add "$slug" new-mechanism "..."` —
   recording is mandatory, not offered; nothing evaporates). No other deferral
   language belongs in the report (`skills/shared/no-deferral.md`); probe the draft
   with `lib/deferral-lint.sh text -` before printing.

## Terminal result (every exit)

After the terminal BUG.md/commit/PR side effects for the selected outcome, emit the same
machine-readable compatibility record as the full and micro cycles. Promotion is the
exception described above: emit before delegation so the full cycle can replace it.

```bash
result_args=(
  --result-root "$(git rev-parse --show-toplevel)" --cycle-type debug
  --status "$status" --outcome "$outcome"
  --slug "$slug" --title "$title" --branch "$branch" --base-branch "$default_branch"
  --pr-url "$pr_url" --converged "$converged"
  --verification-status "$verification_status" --verification-command "$test_cmd"
  --autonomous "$autonomous" --summary "$summary"
)
[[ -n "$no_change_reason" ]] && result_args+=(--no-change-reason "$no_change_reason")
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-result.sh" write-terminal "${result_args[@]}"
# Close the observability pair opened at Step 0 -- a [DEBUG] start with no [DEBUG]
# done is what a stall looks like to a log watcher. $outcome is the terminal outcome.
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/events.sh" emit "$bug_dir" phase_end --phase debug --data "{\"next\":\"$outcome\"}" || true
```

`summary` is the concise root-cause/fix conclusion for every exit. `fixed` requires passed
verification and a PR URL. If the reproduction proves the reported defect is already
absent in the unmodified baseline, `no-change-needed` may converge without a PR only with
`no_change_reason=already-satisfied`; inability to reproduce without proving absence stays
`instrumented-and-waiting`. Promotion, verification failure, and delivery failure are
explicitly non-converged.
The writer emits `LOOP_SPEC_RESULT {...}` and atomically updates the stable
`.loop-spec/last-result.json` pointer.

## BUG.md format

```markdown
# BUG: {symptom summary}

## Symptom (as received)
## Decisions            <- autonomous self-answers land here
## Triage evidence      <- non-specific inputs only
## Converged signal     <- non-specific inputs only
## Reproduction         <- command, red output verbatim, exit code
## Hypothesis log       <- H1..Hn: mechanism, evidence, verdict (REFUTED/CONFIRMED), attempts
## Fix                  <- what the code does, the problem, why it fails, edge cases
                           (each with its test), the change, why sufficient
## Sibling sweep        <- commands run, sites examined, verdict per site (FIXED-SIBLING/CLEAN/DEFERRED-NEW-BUG)
## Deferred             <- sibling-sweep DEFERRED-NEW-BUG findings ONLY; every entry
                           starts with `new-mechanism:` and gets a backlog entry
                           (`lib/backlog.sh add {slug} new-mechanism "..."`). A distinct
                           root-cause mechanism is a NEW bug — that rule is the only
                           thing allowed to land here. Never self-chosen scope
                           narrowing of THIS fix (skills/shared/no-deferral.md).
```

BUG.md is committed with the fix — it is the audit trail (the SPEC.md analog), and the
spec draft if the bug escalates to a full cycle.

## Discipline recap

| Rule | Value |
|---|---|
| Hypotheses / fix attempts | unbounded (full bore); every one recorded in the Hypothesis log before the next opens |
| Triage evidence sources | the 5-source checklist, then instrumented-stop if not converged |
| Flaky-oracle battery | N-run, matched pre/post |
| Sibling sweep after CONFIRMED fix | mandatory; same mechanism = same branch, new mechanism = deferred |

The loop always terminates in one of: fixed-and-verified, instrumented-and-waiting,
or escalated-to-cycle. Never in silent thrash.

## Protocol mismatch

There is a fourth ending, and it is still a published one: the request is not repository work at all (a pure question, or a different product), so the
reproduce/hypothesize/sweep protocol does not fit it. A code change that is not a
defect — including a merge-conflict resolution, PR sync/rebase, or re-review —
promotes to the full cycle (or micro, if that skill's bounds hold); it is not a
`protocol-mismatch`. Report a genuine non-task before touching the repository —
`--status escalated --outcome protocol-mismatch --converged false` with a `--reason`
naming why this is not repository work — and stop so the caller can re-route.
Leaving the protocol and completing the task by hand publishes nothing, which every
headless caller reads as a failed run (**`skills/shared/route-exit-contract.md`**).
