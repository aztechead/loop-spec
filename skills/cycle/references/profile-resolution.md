# Step 3 profile resolution

Use this reference when resolving the cycle profile in `skills/cycle/SKILL.md` Step 3.
The inline `profile:` token outranks `LOOP_SPEC_CYCLE_PROFILE`, just as `phase:fresh`
outranks `LOOP_SPEC_PHASE_HANDOFF`.

`/loop-spec:auto` supplies `profile:compact` only after `lib/task-route.sh` has written
the normalized decision to `.loop-spec/active-run.json`. Pipe that record through
`lib/cycle-profile.sh select -`: compact is valid only with the persisted normalized
compact classification, so a dropped token or malformed/missing record promotes to
`standard`. The Step 3 call reads the same record when the token is dropped, preserving
the selected profile on a resumed autonomous run.

`maintenance` keeps the established lightened ladder (`skills/shared/tier-matrix.md`,
"Maintenance profile"): SPEC synthesizes the spec; the graph may skip DISCUSS,
spec-critique, and code review when the security signal remains clear. PLAN critique is
still selected by `plan-critique.sh` / the skill fast path, and the ambiguity, feasibility,
and deterministic VERIFY gates remain. `standard` is the default full ladder.
