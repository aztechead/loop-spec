# Trusting a 7.x result

For someone deciding whether to trust a 7.x run's result: what the program
proves about it, and what stays judgment. Full detail:
[ROADMAP-7.0.md](ROADMAP-7.0.md).

## The identities

Every run, phase attempt, and worker step has its own id; every question has
a one-time id. Every context, product, and result carries an inputs digest,
so a stale product is rejected without reading further. `state.json` has one
writer, the program, which refuses to continue over a file whose digest no
longer matches what it last wrote (section 5).

## Evidence levels

A result file on disk proves a result was published, not who produced it — a
lead recovering from a failed dispatch can write a plausible one itself. So
every worker step carries an evidence level the program sets, never the
implementation:

- `controller-observed`: the program spawned the worker and consumed its
  output. Only the SDK runner gives this.
- `host-attested`: the host's transcript for the submitted dispatch id
  postdates the step, opens with the prompt's identity, ends with the digest.
- `human-attested`: an external phase, attested by a named answer.
- `unattested`: none of the above.

Only `controller-observed` and `host-attested` are accepted for a review by
default; `unattested` blocks `integrated` unless `evidence.review.accept:
"unattested"` is set, listing the task in `weakenedAssurance` (section 5). A
review, PLAN critic, or ITERATE judge step with no accepted evidence after its
re-dispatches is refused and stops the run at a blocked question, unless
`evidence.review.accept` or `evidence.judgment.accept` opts that role in. No
level says the review was thorough — that stays judgment (section 6).

## What the program re-runs itself

A baseline runs every plan-declared command once at base, before EXECUTE
starts; a task's verify command must add no new failure identity against it
(E7). VERIFY re-runs every cited command in a clean checkout of the verified
SHA it creates, comparing exit status, failure identity, and normalized
output (V4). Neither proves a command tests the right thing, only that it
produces the claimed result (section 11; full list:
[contract.md](../../skills/loop-spec/references/contract.md#products)).

## The budget and terminal results

One shared budget bounds every backward transition, counted once per accepted
transition and never reset within a run. Spent out, a run escalates rather
than retrying forever. Terminal outcomes: `converged`, `converged-with-caveats`
(draft PR, findings listed), `escalated` (a gap open, partial draft only if
opted in), `failed` (sections 10, 15).

## Known limits

- Workers are cooperative, not sandboxed: a prompt contract does not restrict
  filesystem access; the program detects an out-of-band change, never prevents one.
- The SDK runner's `controller-observed` evidence is grounded from the
  installed package's source, not confirmed by a run in this repository.
- `unattested` reaches `integrated` only under the `evidence.review.accept`
  opt-in above; the result names every task it weakened.
