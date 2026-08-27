---
name: micro
description: Use when the user has a small ad-hoc task ("add a flag", "rename this helper", "fix this typo") and wants the five cycle invariants without agent ceremony. Give it the task, or toggle on/off/status. Ends in a PR. Do not use for a new feature that needs a spec (that's /loop-spec:cycle) or a pasted stack trace (that's /loop-spec:debug).
argument-hint: "[autonomous] [small task description | on | off | status]"
allowed-tools: Bash Read Write Edit Glob Grep Skill AskUserQuestion
model: inherit
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
# Observability: micro is a favorite target of the autonomous router, and it used to
# emit NOTHING -- an unattended run routed here was silent end to end. Events go to
# the adhoc dir (no feature dir exists at micro scale); the console line follows.
mkdir -p .loop-spec/adhoc
bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit .loop-spec/adhoc phase_start --phase micro || true
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

**6. Deliver as a PR, then check it for feedback.** Changed micro work ends on a branch,
behind a PR, with the PR checked for reviews/comments/requested changes
(`skills/shared/pr-feedback-check.md`). If the grounding and validation gates instead
prove every criterion was already satisfied before this run, make no empty commit and
open no PR: select `no-change-needed` with reason code `already-satisfied`. A clean diff
alone is not enough; unsupported or blocked work is a failure, not intentional no-change.
Still zero ceremony — no worktree, no DELIVER controller:

- If the request names an open PR, adopt it instead of minting `micro/<slug>`:
  ```bash
  adopt_json="$(bash "${CLAUDE_SKILL_DIR}/../../lib/adopt-pr.sh" resolve \
    --repo "$(git rev-parse --show-toplevel)" --request "$task")"
  ```
  When `.adopt == true`, check out `.branch` (fetch first) and stay on it. That is
  the PR DELIVER-equivalent will update. Dirt on that branch is the work.
- Otherwise: on the default branch? Move the work to a branch first: `git checkout -b micro/<slug>`
  (uncommitted changes travel). Already on a topic branch: stay on it.
- Commit (project commit conventions apply), `git push -u origin <branch>`, then reuse
  the branch's existing PR if one exists (`gh pr view --json number,url`) or open one
  (`gh pr create`). Keep the body to the micro scale: title, the done-criteria bullets,
  the verification command + result. GitHub-flavored markdown, no phase-artifact dumps.
  Write the body to a file and gate it before creating/updating the PR — micro PRs get
  the same no-deferral guarantee as full-cycle DELIVER (`skills/shared/no-deferral.md`):
  ```bash
  bash "${CLAUDE_SKILL_DIR}/../../lib/deferral-lint.sh" text "$body_file"
  ```
  A flag means the task is not done: do the flagged work or promote to a full cycle;
  never reword past the probe. Then `gh pr create --body-file "$body_file"`.
- Run the terminal feedback check on the PR (`lib/pr-feedback.sh check <number>`) and
  route the result per the shared contract: requested changes at micro scale get fixed
  now. Every feedback-driven edit returns to Step 5: repeat the post-change grounding
  gate and validation gate against the new final diff before creating the new commit,
  pushing, and re-checking feedback. Evidence from before that edit is stale. Larger asks hand off to `/loop-spec:revise` or
  `/loop-spec:intake` — say which.
- No origin remote, or `gh` missing/unauthenticated? Degrade loudly: state exactly what
  blocked the PR, leave the branch in place, and record the gap in the ledger `--notes`.
  Never silently skip the PR step.

**7. Record the ledger entry and close the run out.** After the ledger entry below,
emit the matching end event — `bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit
.loop-spec/adhoc phase_end --phase micro --data '{"next":"completed"}' || true`
(on escalation to intake, use `'{"next":"escalated"}'`). A `[MICRO] start` with no
`[MICRO] done` is what a stall looks like to a log watcher. Append one entry to
`.loop-spec/adhoc-ledger.md`:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/adhoc-ledger.sh" add \
  --title "<task title>" \
  --criteria "<exact criterion 1 text>" \
  --grounding "<exact criterion 1 text> | repo: <file>:<positive line> | integration: <file>:<positive line>" \
  [--criteria "<exact criterion 2 text>" \
   --grounding "<exact criterion 2 text> | repo: <file>:<positive line> | integration: <file>:<positive line>"] \
  --verify "<the verification command you actually ran>" \
  --result pass|fail|partial \
  [--pr "<PR url from step 6>"] \
  [--notes "<deferred work, caveats, unaddressed PR feedback>"]
```

For a passed result, copy each `--criteria` value byte-for-byte as the prefix of
exactly one `--grounding` value. Use a single positive line number, not a line range.
When no separate integration site exists, the only accepted alternative is
`integration: none - <reason of at least 10 characters>`.

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
result_args=(
  --result-root "$result_root" --cycle-type micro
  --status "$status" --outcome "$outcome"
  --slug "$slug" --title "$title" --branch "$branch" --base-branch "$base_branch"
  --pr-url "$pr_url" --converged "$converged"
  --verification-status "$verification_status" --verification-command "$verify_command"
  --autonomous "$autonomous" --summary "$summary"
)
[[ -n "$no_change_reason" ]] && result_args+=(--no-change-reason "$no_change_reason")
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" write-terminal "${result_args[@]}"
```

`summary` is a non-empty, concise synthesis of the actual change and verification result,
or the already-satisfied finding. `verification-status=passed` requires both VERIFY gates.
`converged=true` requires a PR URL except for validated `no-change-needed`, which requires
no PR and `no_change_reason=already-satisfied`. The writer emits one
`LOOP_SPEC_RESULT {...}` line and atomically updates `.loop-spec/last-result.json`.
Do not claim success if result emission warns; report the observability failure.

The final report you print contains **no self-authored deferrals** — no "follow-ups",
"deferred items", or "future work" you chose on your own (`skills/shared/no-deferral.md`).
Probe the draft before printing: `printf '%s' "$report" |
bash "${CLAUDE_SKILL_DIR}/../../lib/deferral-lint.sh" text -`. A flag means the task
is not done — do the flagged work (or promote to a full cycle), never reword past it.

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

## Protocol mismatch

Escalation is for work that outgrew this protocol. A mismatch is the other direction:
the request is not repository work at all (a pure question, or a different product).
A merge-conflict resolution, PR sync/rebase, re-review, or one-command chore is
micro-scale work when the bounds still hold — execute it; if a bound is crossed,
promote (Escalation above), do not decline. Both endings publish a result, never with
the protocol abandoned and the task finished by hand
(**`skills/shared/route-exit-contract.md`**). Before touching the repository, emit the
Step 9 record with `--status escalated --outcome protocol-mismatch --converged false`
and a `--reason` naming why this is not repository work, then stop so the caller can
re-route.

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

What the guard mechanically requires after the final edit is narrower than the
invariant above: one content review (`git diff`, or `git show HEAD` for committed
work — summaries like `--stat`/`-s` show no content), a re-read of any edited path
that review's pathspec does not cover, then the verification command. Paths deleted
before the stop are exempt, since neither evidence form can reach them.

## Boundary with the cycle

Inside a running cycle none of this applies — the phases own these invariants at
feature scale (SPEC states criteria, EXECUTE is test-first, VERIFY gathers evidence,
DELIVER owns the PR and its terminal feedback check).
The adhoc-verify-guard stands down automatically while a feature is in flight, and you
should not write ledger entries for cycle work (the feature tree is its audit trail).
Step 6's PR delivery likewise stands down there — never open a side PR from inside a
feature worktree.
