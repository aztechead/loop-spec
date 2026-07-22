---
name: micro
description: Micro-cycle for small, ad-hoc tasks — the cycle's five invariants (stated done-criteria, grounded claims, test-first, evidence-before-done, mistakes-become-rules) enforced inline on the main thread with zero agent ceremony. Give it a small task and it runs the protocol directly, ending like every cycle type — work delivered as a PR that is then checked for reviews/comments/requested changes; or toggle micro mode (on/off/status), which controls the micro-inject SessionStart directive and the adhoc-verify-guard Stop hook. Honors inline autonomous mode and escalates to /loop-spec:intake when the task outgrows ad-hoc scale.
argument-hint: "[autonomous] [small task description | on | off | status]"
allowed-tools: Bash Read Write Edit Glob Grep Skill AskUserQuestion
model: sonnet
---

# loop-spec:micro

The full cycle is enforcement machinery for feature-scale work. At ad-hoc scale the
same ideology survives as five invariants you apply inline — no teams, no subagents,
no worktrees, no phase artifacts. This skill is the protocol definition; the hooks
(`hooks/team/micro-inject.sh` SessionStart directive, `hooks/team/adhoc-verify-guard.sh`
Stop gate) are the enforcement.

## Invocation

- `/loop-spec:micro <small task description>` — run the micro-cycle protocol on the task.
- `/loop-spec:micro autonomous <small task description>` — run question-free; strip
  `autonomous` from the task text before deriving its title and criteria.
- `/loop-spec:micro on|off|status` — toggle micro mode for the project (see Mode toggle).
- Bare `/loop-spec:micro` — ask one free-text question for the task, then run the protocol.

## When this skill applies

Small, ad-hoc work: a bug fix, a rename, a config change, a small function, a doc
tweak — anything you would not run `/loop-spec:cycle` for. If any of the following
hold, the task is NOT micro-scale; escalate (see Escalation):

- More than ~5 files need edits, or a new seam/dependency/interface is being introduced.
- The done-criteria cannot be stated in 3 bullets.
- Ambiguity survives one clarifying question.

## The protocol

First, before any jq-backed hook or helper can fail mid-run:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" clear --result-root "$(git rev-parse --show-toplevel)"
bash "${CLAUDE_SKILL_DIR}/../../lib/runtime-preflight.sh" check-jq
```

Execute directly on the main thread with base tools. Do not dispatch subagents.

**1. Done-criteria first.** Before touching any file, state 1–3 bullets of what "done"
means, each verifiable. Show them to the user as part of your normal narration. If the
task is compound (multiple asks), enumerate criteria per ask.

**2. One question, not zero, not five.** If the highest-leverage unknown would change
what you build, ask exactly one sharp question (grill mode's single-shot form). In
autonomous runs (inline `autonomous` token or `LOOP_SPEC_AUTONOMOUS=1`), self-answer with the recommended option and
say so — never block.

**3. Ground claims.** Any premise about external systems or unfamiliar code gets a
read-only probe (run the command, read the file) before you rely on it. Do not assert
from memory what one command can verify. (Full protocol: `skills/shared/grounding-protocol.md`;
at micro scale the probe result goes in your narration, not an EVIDENCE.md.)

**4. Test-first where a test fits.** If the change has testable behavior, write or
extend the failing test before the fix (red → green). If it genuinely has no test
surface (docs, config), say so explicitly instead of silently skipping.

**5. VERIFY phase: ground, then validate.** Apply
`skills/shared/verification-grounding.md` after the final edit. This is one explicit
phase with two hard gates:

- **Grounding gate:** inspect the final diff; re-read every changed file in its final
  state and the nearest affected caller, test, configuration, interface, or documented
  contract. For each done-criterion, capture concrete repository evidence as
  `file:line` references for both implementation and integration (or state why there is
  no separate integration site). Re-probe affected external premises. An unsupported
  assumption or stale pre-edit read fails the gate; correct or escalate, then repeat it.
- **Validation gate:** only after grounding passes, run the project's real verification
  command (test suite, lint, build — `lib/detect-test-cmd.sh` can find it) and show the
  output. With no behavioral runner, use the strongest static check available, at
  minimum `git diff --check`, and state the limitation.

A green command cannot substitute for repository grounding, and repository reads cannot
substitute for an executed command. "Should work" is not a result. Simplicity mode still
applies: ship the shortest grounded diff that passes.

**6. Deliver as a PR, then check it for feedback.** Micro work ends the same way every
cycle type ends: on a branch, behind a PR, with the PR checked for reviews/comments/
requested changes (`skills/shared/pr-feedback-check.md`). Still zero ceremony — no
worktree, no DELIVER controller:

- On the default branch? Move the work to a branch first: `git checkout -b micro/<slug>`
  (uncommitted changes travel). Already on a topic branch: stay on it.
- Commit (project commit conventions apply), `git push -u origin <branch>`, then reuse
  the branch's existing PR if one exists (`gh pr view --json number,url`) or open one
  (`gh pr create`). Keep the body to the micro scale: title, the done-criteria bullets,
  the verification command + result. GitHub-flavored markdown, no phase-artifact dumps.
- Run the terminal feedback check on the PR (`lib/pr-feedback.sh check <number>`) and
  route the result per the shared contract: requested changes at micro scale get fixed
  now. Every feedback-driven edit returns to Step 5: repeat the post-change grounding
  gate and validation gate against the new final diff before creating the new commit,
  pushing, and re-checking feedback. Evidence from before that edit is stale. Larger asks hand off to `/loop-spec:revise` or
  `/loop-spec:intake` — say which.
- No origin remote, or `gh` missing/unauthenticated? Degrade loudly: state exactly what
  blocked the PR, leave the branch in place, and record the gap in the ledger `--notes`.
  Never silently skip the PR step.

**7. Record the ledger entry.** Append one entry to `.loop-spec/adhoc-ledger.md`:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/adhoc-ledger.sh" add \
  --title "<task title>" \
  --criteria "<criterion 1>" [--criteria "<criterion 2>" ...] \
  --grounding "<criterion 1> | repo: <file:line> | integration: <file:line or reason>" \
  [--grounding "<criterion 2> | repo: ..." ...] \
  --verify "<the verification command you actually ran>" \
  --result pass|fail|partial \
  [--pr "<PR url from step 6>"] \
  [--notes "<deferred work, caveats, unaddressed PR feedback>"]
```

`--result` reflects both VERIFY gates. A `fail` entry is a valid ending when you are
handing the failure back to the user — never record `pass` without post-change grounding
and command output to back it. `--pr` binds the entry to its delivery PR; when step 6
could not open one, the `--notes` say why instead.

**8. Repeated mistake → rule.** If this task exposed a mistake you (or the loop) have
made before, make it permanent: `bash "${CLAUDE_SKILL_DIR}/../../lib/rules.sh" add "<rule>" [--check "<cmd>"]`.

**9. Emit the terminal result.** Every terminal path writes the shared compatibility
record after ledger/PR/feedback side effects finish. Resolve `result_root` with
`git rev-parse --show-toplevel`, the current `branch`, detected `base_branch`, task
slug/title, actual verification command, and PR URL. Then call:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" write-terminal \
  --result-root "$result_root" --cycle-type micro \
  --status "<completed|failed|escalated>" --outcome "<verified|verification-failed|delivery-blocked|promoted-to-full>" \
  --slug "$slug" --title "$title" --branch "$branch" --base-branch "$base_branch" \
  --pr-url "$pr_url" --converged "<true|false>" \
  --verification-status "<passed|failed|not-run>" --verification-command "$verify_command" \
  --autonomous "<true|false>"
```

`verification-status=passed` requires both VERIFY gates. `converged=true` additionally
requires a PR URL. The writer emits one
`LOOP_SPEC_RESULT {...}` line and atomically updates `.loop-spec/last-result.json`.
Do not claim success if result emission warns; report the observability failure.

## Escalation

When a "When this skill applies" bound is crossed mid-task, stop expanding scope and
promote losslessly: write what you have (the stated done-criteria, probe results,
open questions) into a short prose brief and invoke `Skill(loop-spec:intake)` with it —
the intake skill converts it into a cycle-ready spec draft and starts `/loop-spec:cycle`.
When this micro run is autonomous (inline token or environment), pass `autonomous` before
the brief so intake and the resulting full cycle remain question-free.
Record a `partial` ledger entry with `--notes "escalated to cycle"` before handing off.
Emit the Step 9 `escalated/promoted-to-full` result before delegation; the full cycle
will replace the stable pointer with its final terminal result.

## Mode toggle

Micro mode controls the two hooks. State persists in `.loop-spec/micro.conf`
(project root = `CLAUDE_PROJECT_DIR` or CWD). **Default is ON** when the project has a
`.loop-spec/` directory and no conf file exists (same polarity as grill and simplicity).

- `on` — write `ENABLED=1` to `.loop-spec/micro.conf` (create `.loop-spec/` if needed). Confirm: "micro mode enabled".
- `off` — write `ENABLED=0`. Confirm: "micro mode disabled".
- `status` — print `on` if the conf file is absent or contains `ENABLED=1`, else `off`.

Session-level kill switches (hook env vars, no conf change): `LOOP_SPEC_MICRO=0`
disables the SessionStart directive; `LOOP_SPEC_MICRO_GUARD=0` disables the Stop gate.

One more conf key: `VERIFY_CMD=<command>` declares the project's real verification
command when its runner is not in the guard's built-in pattern (e.g.
`VERIFY_CMD=rake spec`). A Bash command containing that string counts as evidence.
Set it when the guard blocks a stop even though you ran the project's actual
checks — declaring the command is always better than disabling the guard.

## Boundary with the cycle

Inside a running cycle none of this applies — the phases own these invariants at
feature scale (SPEC states criteria, EXECUTE is test-first, VERIFY gathers evidence,
DELIVER owns the PR and its terminal feedback check).
The adhoc-verify-guard stands down automatically while a feature is in flight, and you
should not write ledger entries for cycle work (the feature tree is its audit trail).
Step 6's PR delivery likewise stands down there — never open a side PR from inside a
feature worktree.
