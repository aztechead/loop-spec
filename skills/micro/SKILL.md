---
name: micro
description: Micro-cycle for small, ad-hoc tasks — the cycle's five invariants (stated done-criteria, grounded claims, test-first, evidence-before-done, mistakes-become-rules) enforced inline on the main thread with zero agent ceremony. Give it a small task and it runs the protocol directly; or toggle micro mode (on/off/status), which controls the micro-inject SessionStart directive and the adhoc-verify-guard Stop hook. Escalates to /loop-spec:intake when the task outgrows ad-hoc scale.
argument-hint: "[small task description | on | off | status]"
allowed-tools: Bash Read Write Edit Glob Grep Skill AskUserQuestion
---

# loop-spec:micro

The full cycle is enforcement machinery for feature-scale work. At ad-hoc scale the
same ideology survives as five invariants you apply inline — no teams, no subagents,
no worktrees, no phase artifacts. This skill is the protocol definition; the hooks
(`hooks/team/micro-inject.sh` SessionStart directive, `hooks/team/adhoc-verify-guard.sh`
Stop gate) are the enforcement.

## Invocation

- `/loop-spec:micro <small task description>` — run the micro-cycle protocol on the task.
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

Execute directly on the main thread with base tools. Do not dispatch subagents.

**1. Done-criteria first.** Before touching any file, state 1–3 bullets of what "done"
means, each verifiable. Show them to the user as part of your normal narration. If the
task is compound (multiple asks), enumerate criteria per ask.

**2. One question, not zero, not five.** If the highest-leverage unknown would change
what you build, ask exactly one sharp question (grill mode's single-shot form). In
autonomous runs (`LOOP_SPEC_AUTONOMOUS=1`), self-answer with the recommended option and
say so — never block.

**3. Ground claims.** Any premise about external systems or unfamiliar code gets a
read-only probe (run the command, read the file) before you rely on it. Do not assert
from memory what one command can verify. (Full protocol: `skills/shared/grounding-protocol.md`;
at micro scale the probe result goes in your narration, not an EVIDENCE.md.)

**4. Test-first where a test fits.** If the change has testable behavior, write or
extend the failing test before the fix (red → green). If it genuinely has no test
surface (docs, config), say so explicitly instead of silently skipping.

**5. Verify with evidence.** Before claiming done, run the project's real verification
command (test suite, lint, build — `lib/detect-test-cmd.sh` can find it) and show the
output. "Should work" is not a result. Simplicity mode still applies: ship the
shortest diff that passes.

**6. Record the ledger entry.** Append one entry to `.loop-spec/adhoc-ledger.md`:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/adhoc-ledger.sh" add \
  --title "<task title>" \
  --criteria "<criterion 1>" [--criteria "<criterion 2>" ...] \
  --verify "<the verification command you actually ran>" \
  --result pass|fail|partial \
  [--notes "<deferred work, caveats>"]
```

`--result` reflects what the verification actually showed. A `fail` entry is a valid
ending when you are handing the failure back to the user — never record `pass` without
the output to back it.

**7. Repeated mistake → rule.** If this task exposed a mistake you (or the loop) have
made before, make it permanent: `bash "${CLAUDE_SKILL_DIR}/../../lib/rules.sh" add "<rule>" [--check "<cmd>"]`.

## Escalation

When a "When this skill applies" bound is crossed mid-task, stop expanding scope and
promote losslessly: write what you have (the stated done-criteria, probe results,
open questions) into a short prose brief and invoke `Skill(loop-spec:intake)` with it —
the intake skill converts it into a cycle-ready spec draft and starts `/loop-spec:cycle`.
Record a `partial` ledger entry with `--notes "escalated to cycle"` before handing off.

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
feature scale (SPEC states criteria, EXECUTE is test-first, VERIFY gathers evidence).
The adhoc-verify-guard stands down automatically while a feature is in flight, and you
should not write ledger entries for cycle work (the feature tree is its audit trail).
