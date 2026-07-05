---
name: debug
description: Spec-driven debugging loop for a specific error (message/stack/failing test) OR a non-specific symptom ("something's wrong", flaky, slow). TRIAGE converges vague symptoms to one reproducible signal; REPRODUCE writes the failing oracle before any fix; a bounded FIX loop (max 5 hypotheses, 3 attempts each) closes it; a mandatory SIBLING SWEEP fixes same-mechanism occurrences in the same branch; VERIFY runs the full suite + test-tamper scan and keeps the repro as a regression test. Writes docs/loop-spec/debug/{slug}/BUG.md.
argument-hint: "<error text | stack trace | failing test | vague symptom description>"
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion
---

# Debug Loop

Invoked as `/loop-spec:debug <input>`. The cycle's archetypes, scaled down to a bug:
the SPEC analog is BUG.md, the acceptance oracle is a failing reproduction, and the
loop is bounded. No teams, no phases DAG — a bug is narrow; main thread plus at most
one-shot subagents (ponytail: the cheapest orchestration that works).

Honors autonomous mode (`skills/shared/autonomous-mode.md`): with the `autonomous`
token or `LOOP_SPEC_AUTONOMOUS=1`, strategy questions self-answer with the
recommended option and are recorded in BUG.md's `## Decisions` section. Styles: `auto`
(default) runs end-to-end; `step` pauses after TRIAGE and after each hypothesis verdict.

## The one hard gate

**No fix before a red reproduction.** A fix scored against the symptom that produced
it, not against the fixer's opinion — the same maker≠checker principle as the cycle.
Until a command exists that fails BECAUSE of the bug, you are guessing, and the loop
does not advance to FIX. The only exception is the recorded observation plan for
genuinely unreproducible bugs (REPRODUCE step 3), and that exception must be written
into BUG.md before any change is made.

## Step 0 - Classify and initialize

1. **Initialize deterministically** — one call does the mechanics (token stripping,
   slug, BUG.md dir, branch discipline, branch-point SHA capture, test-cmd detection):
   ```bash
   dbg="$(bash "${CLAUDE_SKILL_DIR}/../../lib/debug-init.sh" init -- "$ARGUMENTS")"
   # {slug, bug_dir, branch, branch_action: created|switched|kept, default_branch,
   #  dirty, sha_before, test_cmd, autonomous, style}
   ```
   `.sha_before` is the test-tamper baseline VERIFY needs (Step 4) — it is captured
   before ANY change, which is exactly why it is script-side. `.test_cmd` honors
   `LOOP_SPEC_CMD_TEST` over detection; `feature.commands.test` (when a feature
   context exists) overrides both.
2. Start `BUG.md` in `.bug_dir` (format below) with the verbatim input under
   `## Symptom (verbatim)`.
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
4. **The graph + hotspots.** `graphify query "<symptom area>"` to find what implements
   the behavior (skip if no graph); `bash "${CLAUDE_SKILL_DIR}/../../lib/fragility-scan.sh" . --top 10`
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

## Step 3 - FIX loop (bounded)

Budgets: **max 5 hypotheses; max 3 fix attempts per hypothesis.** The counter is a
FILE, not model memory — a long session's compaction cannot drift a file. Before
opening a hypothesis and before each fix attempt, tick the budget and obey the exit
code (`0` = proceed, `3` = that budget is spent):

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/debug-budget.sh" hypothesis "{bug_dir}"   # opens Hn, resets attempts
bash "${CLAUDE_SKILL_DIR}/../../lib/debug-budget.sh" attempt "{bug_dir}"      # ticks attempt on Hn
```

Narrative (mechanism, evidence, verdicts) still goes in BUG.md `## Hypothesis log`;
`budget.json` is the arithmetic. On exit 3 from `attempt`: revert, refine or move to
the next hypothesis. On exit 3 from `hypothesis`: stop and escalate with the full
log — a spent budget with recorded verdicts is progress; unbounded thrashing is not.

For each hypothesis, in ranked order:

1. **State the mechanism, not the location:** "X returns a stale value when Y because
   Z" — falsifiable, not "something in X". Ground it: read the implicated code, walk
   `graphify path` between symptom site and suspect, check `git log -p` on the suspect
   for the introducing change.
2. **Confirm before changing:** find the cheapest observation that would falsify the
   hypothesis (a log line in the repro run, an inspected intermediate value, a
   narrower assertion). If falsified — record the verdict `REFUTED: <evidence>` and
   move to the next hypothesis WITHOUT changing code. This is what keeps the loop from
   shotgun-patching.
3. **Fix minimally** (simplicity mode applies): the smallest change that corrects the
   mechanism. Not the refactor the area deserves — note that in `## Deferred` for the
   backlog instead.
4. **Verify:** repro goes green AND the full test suite passes AND nothing else changed
   behavior (`git diff` review — the diff should read as exactly the mechanism fix).
   Record `CONFIRMED` with the green output. If the repro stays red: attempt counter
   +1, revert the attempt (`git checkout -- <files>` or revert commit), refine or
   re-rank hypotheses.
5. **Scope tripwire:** the moment a correct fix demonstrably requires feature-scale
   work (schema change, cross-cutting redesign, new dependency), stop fixing. BUG.md
   becomes the spec draft: `Skill(loop-spec:cycle)` with
   `docs/loop-spec/debug/{slug}/BUG.md` as the spec-file argument (interactive: confirm
   first; autonomous: hand off and record). The debug loop fixes bugs; it does not
   smuggle features.

## Step 3b - SIBLING SWEEP (mandatory after CONFIRMED)

A confirmed root cause is rarely alone: the same mechanism tends to recur in sibling
code. This step is not optional and not budget-ticked — the hypothesis is already
CONFIRMED, so the sweep extends the fix, it does not open new hypotheses.

1. **Sweep for the same mechanism** (canonical reference
   `skills/shared/design-for-change.md`): grep every caller of the fixed function,
   grep for copy-pasted instances of the flawed pattern, and walk `graphify query` /
   `graphify path` from the fixed site to parallel code paths that share the mechanism.
2. **Same mechanism found elsewhere → fix it in the same branch.** A sibling is covered
   by the already-confirmed hypothesis; apply the same minimal fix, extend the
   regression coverage where the sibling is independently reachable, and re-run the
   verify battery from Step 3.4. The scope tripwire (Step 3.5) still applies: siblings
   that push the fix to feature scale escalate to the cycle instead.
3. **Different mechanism found during the sweep → it is a new bug, not a sibling.**
   Record it under `## Deferred` (offer `lib/backlog.sh add`); do not fix it in this
   branch — mixing mechanisms makes the diff unreviewable.
4. **Record the sweep in BUG.md `## Sibling sweep`:** the commands run, every site
   examined, and the verdict per site (`FIXED-SIBLING: <file:line>`,
   `CLEAN: <file:line>`, or `DEFERRED-NEW-BUG: <file:line>`). An empty sweep section is
   a defect: "no siblings" is a claim the commands must back. The loop does not
   advance to VERIFY without this section populated.

## Step 4 - VERIFY and land

1. **Keep the repro as a regression test** — it lands in the test suite, named after
   the bug, asserting the fixed behavior. A fix without its regression test is half a
   fix. (Command-style repros get distilled into a test where feasible; where not,
   record the manual verification command in BUG.md.)
2. Run: full test suite, lint + typecheck when configured, and the anti-reward-hacking
   scan on the diff — `bash "${CLAUDE_SKILL_DIR}/../../lib/test-tamper-scan.sh" "{sha_before}"`
   (the fix must not delete/skip tests or swallow exit codes to go green; `sha_before`
   is in debug-init's Step 0 output, captured before any change). Exception: the
   regression test ADDED here is expected new test content, not tampering.
3. Complete BUG.md (`## Fix` — root cause, mechanism, why this change is sufficient)
   and commit: BUG.md + fix + regression test on `fix/{slug}`, message
   `fix: {symptom summary}` with body naming the root cause.
4. Report: root cause, the fix diffstat, the regression test, and anything in
   `## Deferred` (offer `bash "${CLAUDE_SKILL_DIR}/../../lib/backlog.sh" add` for deferred findings). PR opening is the
   user's call (interactive offer; autonomous: push + PR only when the repo already has
   an origin and prior loop-spec PRs — otherwise leave the branch and say so).

## BUG.md format

```markdown
# BUG: {symptom summary}

## Symptom (verbatim)
## Decisions            <- autonomous self-answers land here
## Triage evidence      <- non-specific inputs only
## Converged signal     <- non-specific inputs only
## Reproduction         <- command, red output verbatim, exit code
## Hypothesis log       <- H1..H5: mechanism, evidence, verdict (REFUTED/CONFIRMED), attempts
## Fix                  <- root cause, change, why sufficient
## Sibling sweep        <- commands run, sites examined, verdict per site (FIXED-SIBLING/CLEAN/DEFERRED-NEW-BUG)
## Deferred             <- findings out of scope for this fix (backlog candidates)
```

BUG.md is committed with the fix — it is the audit trail (the SPEC.md analog), and the
spec draft if the bug escalates to a full cycle.

## Bounds recap

| Bound | Value |
|---|---|
| Hypotheses | 5 |
| Fix attempts per hypothesis | 3 |
| Triage sources before instrumented-stop | 5 |
| Flaky-oracle battery | N-run, matched pre/post |
| Sibling sweep after CONFIRMED fix | mandatory; same mechanism = same branch, new mechanism = deferred |

The loop always terminates in one of: fixed-and-verified, instrumented-and-waiting,
escalated-to-cycle, or budget-spent-with-evidence. Never in silent thrash.
