# Choosing an approach from evidence

Reader: the lead or agent turning a requested method into a design, implementation,
or review. Preserve the user's outcome; treat a suggested method as a candidate to
test against the code. DISCUSS owns the initial comparison, PLAN validates it against
actual patterns, and EXECUTE revisits it only when new evidence changes the choice.
This is a judgment contract, not another phase or gate.

## Separate intent from method

Record the outcome, acceptance criteria, explicit constraints, and suggested method
separately. Explicit constraints remain binding: a required library, architecture,
compatibility promise, budget, or a method the user insists on is not optional.
Do not turn a suggestion into a binding decision merely by copying it into a spec.
If the distinction would change the design and is unclear, ask one focused question
in the existing interview. Without a human, preserve the restrictive reading and
record the uncertainty; autonomy does not grant permission to weaken a constraint.

## Compare only plausible choices

Compare the requested method with the strongest relevant alternative the code or
documentation supports. Read the real call path and existing helper or pattern;
cite file:line evidence. For a dependency claim, consult documentation for the pinned
version and cite the evidence ledger, following `skills/shared/grounding-protocol.md`.
Best practice alone is not evidence: name the concrete benefit and its cost here.
An existing pattern is a candidate, not proof it is sound.

Judge both choices against the same acceptance criteria and constraints, including
behavior, compatibility, complexity, maintenance, operational risk, and relevant
scale. Never lower acceptance criteria to make an alternative win. Do not invent
alternatives for a trivial change; retaining the requested method with a short reason
is a valid result. Do not expand scope to modernize unrelated code.

Choose a better-supported method within the constraints and existing authority;
explain a material departure to the user with the evidence and tradeoff. There is no
extra approval gate for an internal choice already delegated to the agent. Existing
phase interviews still apply. Changing an explicit constraint or settled design
requires the existing decision/escalation path; never silently relabel it optional.

## Carry the reasoning through the phases

| Phase | Action and durable record |
|---|---|
| SPEC | Put outcomes in Goals/Good Enough and binding constraints in Boundaries or the existing decisions block. Keep the suggested method labeled as a candidate in the spec body, with its rationale. Ingest preserves pre-authored requirements. |
| DISCUSS | Before locking the design, compare the candidates using the scout evidence. Record the chosen approach, rejected alternative, evidence, tradeoff, and preserved requirements in the existing SPEC decisions block and transcript. A skipped interview still records the comparison without inventing a user answer. |
| PLAN | Check that choice against PATTERNS.md and actual task files. Keep user decisions verbatim. Record the comparison in PLAN's opening approach summary and turn the chosen method into tasks that cover the original criteria. If new evidence contradicts a settled design, return the evidence to the lead for the existing decision path before emitting conflicting tasks. |
| EXECUTE | Read the selected approach and its reason before coding. A local implementation detail inside the task's files, contracts, dependencies, and verify command may improve without replanning; report the evidence and preserved criteria in the task completion. A change to task boundaries, dependencies, public contracts, or settled design goes to the lead before implementation. Update PLAN.md and tasks.json together through the existing PLAN path and rerun its gates before redispatch; executors do not rewrite their own assignment. |
| VERIFY / ITERATE | Check that any departure is justified by evidence, preserves the original outcome and binding constraints, and has the required plan/decision updates. Judge equivalent implementations by their results, while still enforcing binding choices. A green test suite does not justify lost scope or a weaker criterion. |

No new evidence means no reopening. A preference for another architecture is not a
reason to churn a settled decision. Use existing decision records and phase routing;
do not add a parallel approval log or silently edit acceptance tests to fit the code.

Task-only dispatches must still receive the reason for the approach: PLAN puts the
relevant decision and evidence reference in each affected task's steps or read_first
list. Do not assume an executor sees the whole plan or the design conversation.

For example, if the user suggests a new cache to reduce repeated lookups and an
existing batch API demonstrably meets the same latency and freshness requirements,
reuse may win without adding cache state. If the cache itself is required for offline
use, batching alone fails the constraint and cannot replace it.
