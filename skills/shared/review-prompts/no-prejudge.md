# Reviewer independence — do not pre-judge findings

Canonical prompt directive for every EXECUTE, quality-loop, and VERIFY reviewer
dispatch. Superpowers v6.0.0 caught controllers coaching "do not flag X" or
"at most Minor"; the flaw shipped. `lib/prejudge-lint.sh` scans templates for
those phrases. This file is the instruction the prompt must include.

## Contract

- Never tell a reviewer what not to flag.
- Never pre-rate severity ("at most Minor", "not Important").
- Never write "the plan chose" as a reason to skip a finding.
- A finding that conflicts with plan text is `plan-mandated`. Report it.
  The lead records a ruling (`lib/decisions.sh add ... ruling`) before acting.
  Autonomous mode records the ruling and continues; interactive mode still
  asks only for the four `lib/execute-stop.sh` stop reasons.

## Allowed labels (reviewer output)

- `plan-mandated` — the plan's text requires the thing you would otherwise flag.
- `unverified` — the requirement lives outside this diff (see the reviewer JSON).

Do not use those labels to hide a finding. Use them so the lead can adjudicate.
