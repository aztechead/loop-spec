# Suggested review order

For reviewers of the audit follow-up after commit `c6f9374`.

**Queued remediation reaches execution**

- recovery routing before ordinary verification successors
  `lib/graph/probes/review-route.sh:2`
- bounded return to execution
  `graph/cycle.graph.json:985`
- intake errors distinguished from invalid sidecars
  `lib/execute-prepare.sh:73`
- validated publication and replay identity
  `lib/execute_remediation.py:16`
- acknowledgment command interface
  `lib/feature-write.sh:5`
- locked acknowledgment preserving concurrent appends
  `lib/feature_write.py:56`
- pending work and invalid evidence block exit
  `lib/execute-exit-gate.sh:26`

**Early result mode remains accurate**

- explicit and stored booleans before environment fallback
  `lib/cycle-result.sh:124`

**Local runtime files stay local**

- plugin checkout runtime policy
  `.gitignore:1`
- consumer project runtime policy
  `lib/runtime-ignore.sh:38`

**Peripherals**

- real queue intake, failures, replay, and recurrence
  `tests/lib/execute-prepare.test.sh:62`
- exact graph route and retry-bound assertions
  `tests/graph-conformance.test.sh:125`
- actual saved phase transitions and exhaustion
  `tests/lib/graph-run.test.sh:167`
- acknowledgment and unchanged approval checks
  `tests/lib/feature-write.test.sh:110`
- invalid queue and sidecar exit checks
  `tests/lib/phase-exit.test.sh:260`
- result mode precedence matrix
  `tests/lib/cycle-result.test.sh:495`
- independently isolated ignore policies
  `tests/lib/runtime-ignore.test.sh:22`
- negative marker input retained as test data
  `tests/fixtures/remediation-marker.py.txt:1`
- handoff fixtures isolated from this active cycle
  `hooks/team/phase-handoff-guard.test.sh:5`
- intake recovery without rebuilding registered work
  `skills/execute/SKILL.md:46`
- actual remediation handoff guidance
  `skills/verify/SKILL.md:125`
- outcomes separated from implementation choices before approval
  `skills/spec/SKILL.md:155`
- approved intent remains immutable
  `skills/shared/autonomous-mode.md:113`
