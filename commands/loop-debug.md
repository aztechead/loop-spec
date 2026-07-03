---
description: One-shot fix for an issue in existing code — the debug skill's bounded loop (red repro first, 5x3 hypothesis budget, regression test, tamper scan) driven end to end in a single autonomous pass
argument-hint: "<error text | stack trace | failing test | symptom description>"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Skill, Agent
---

# /loop-spec:loop-debug — one-shot bounded fix

Issue to fix: $ARGUMENTS

This command is the one-shot entry point to the debug skill: a single invocation that
ends in **fixed-and-verified**, **instrumented-and-waiting** (genuinely
unreproducible), **escalated-to-cycle** (feature-scale root cause), or
**budget-spent-with-evidence** — never a mid-run question, never silent thrash.

Invoke the full machinery now, in autonomous end-to-end style:

```
Skill(loop-spec:debug, args: "autonomous auto $ARGUMENTS")
```

Everything else — TRIAGE convergence, the red-reproduction hard gate, the file-based
5-hypotheses x 3-attempts budget, minimal-fix discipline, the test-tamper scan, the
regression test, and BUG.md as the audit trail — is the debug skill's contract
(`skills/debug/SKILL.md`). The only thing this wrapper adds is the one-shot framing:
autonomous mode is non-negotiable here, so every strategy question self-answers with
the recommended option and lands in BUG.md `## Decisions`, and the run reports once,
at the end: root cause, fix diffstat, regression test, verification evidence, and any
deferred findings.
