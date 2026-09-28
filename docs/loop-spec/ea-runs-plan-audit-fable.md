# Audit of ea-runs-plan.md (architecture)

For the plan's author. Read against `52334ce`; line numbers are at that commit. The
focus is the microkernel shape the operator asked for: minimal core, plug-ins that do
not depend on each other, one contract per plug-in kind, a registry the core consults.

Verdict: revise

Section 1's map is accurate in what it names, and D1 to D3 are real. D4's deferral
is right: publishing execute/verify state through products touches every adapter and
the route matrix, and nothing in this change needs it. The must-fixes below are the
places where the plan states a rule the tree will still break after the change, or
leaves a phase the controller cannot drive.

## Must-fix

1. **Section 1, plug-in rule.** "A plug-in never imports another plug-in" is false in
   the tree today and the plan does not list it as a deviation. Every stepped adapter
   imports its result types from `execute.py`: `verify.py:25`, `iterate.py:19`,
   `revise.py:17`, `debug.py:16`, `deliver.py:19` (`from loop_spec.execute import
   IssueStep, Product`; deliver also `Pause`). The classes are `execute.py:61-97`
   (`IssueStep`, `IssueSteps`, `Product`, `Pause`). They are the adapter-to-core
   step contract, not EXECUTE's business. Move the four classes to `steps.py` (core,
   already the step protocol) in wave 1, update the six imports, and add the move to
   the D-list as fixed. Without it, `architecture.md` states a rule and the first
   grep disproves it.

2. **Section 1, D2 ("the three tables are deleted").** Not as planned. The adapter
   registry holds stepped modules with `step`/`on_submit`/`on_step_refused`, and the
   plan keeps `run_lead_phase` for spec/plan, so `_DEFAULT_ROLE_BY_PHASE`
   (`contract.py:158`) and the deliver branch (`contract.py:244`) survive as a second
   and third dispatch. Worse, `direct` is a lead step (section 2), so the new phase
   lands in the table the plan says is gone. And `_ALL_IMPLEMENTATION_PHASES`
   (`controller.py:39`) feeds `store.state["implementations"]["phases"]`, which
   `controller.py:549` indexes with `[phase]`: `route` and `direct` raise `KeyError`
   at their first `_drive_phase` unless added, and the plan never says where. Change:
   one registry, `contract.DEFAULT_IMPLEMENTATIONS = {phase: (kind, target)}` with
   `kind` in `lead` (target = role name: spec, plan, direct), `stepped` (target =
   module: execute, verify, iterate, debug, revise, route), `pass` (deliver). Derive
   `_ALL_IMPLEMENTATION_PHASES = list(DEFAULT_IMPLEMENTATIONS)`. Name the route
   module: `route.py`, `debug.py`'s shape (step() issues the router step, on_submit
   records the product). The controller's submit and refusal owners are then the
   `stepped` entries of the same dict, not two more tables.

3. **Section 2, `_accept_route` and `_accept_direct` versus the parity rule.** The plan
   writes R1/R2 into `phase-interface-7.0.md` as postcondition ids and checks them in
   `controller._accept_route`, with `postconditions.ROUTES` "untouched". debug is the
   precedent the plan cites, and debug's B1 to B3 are in `ROUTES`
   (`postconditions.py:101-105`) and checked by `Boundary._b1`/`_b2` (`controller.py:
   706-716`). CLAUDE.md: `postconditions.py` is the one place that answers whether a
   claimed exit holds, and `ROUTES`/`POSTCONDITION_TEXT` transcribe the doc. Either
   route and direct get `ROUTES` rows (`route`: exit `routed` requires R1, R2, next
   per `routedTo`; `direct`: exit `done` requires D-schema plus the push check) with
   `Boundary._r1`/`_r2` and `POSTCONDITION_TEXT` entries, and `_accept_route` only
   transitions; or the doc does not give them ids. Take the first: it is the same
   shape as debug and keeps the controller out of judging.

4. **Section 2, revise hand-off.** `phase.current = "routed"` with no terminal result
   leaves an auto run in a phase no table knows, with no result and no question.
   `loop-spec status` and `_find_delivering_run_products` (`controller.py:238`) walk
   runs; a re-entry `auto --slug <s>` lands in `_drive_phase` on an unknown phase.
   Change: `_accept_route` writes the auto run's terminal result (`status:
   completed`, `outcome: routed`, `routedTo: {entry, slug, reason}`, `converged:
   false`, `workDelivered: false`) and then returns the revise run's `Next`. Add that
   row to "Terminal results". The same-run hand-offs (cycle/micro/debug/direct) are
   fine as written; also set `run.cycleType = "direct"` on the direct hand-off
   (`result.py:112,117` reads it for the summary; the plan sets it for the other
   three only).

## Should-fix

5. **Section 2, refusal path.** After two router refusals the question defaults to
   `cycle`. The reporting harness runs `--answer-policy default`, so a request that
   named a PR the program could not adopt (`route-refused:pr-not-adoptable`) then
   runs a full cycle on "resolve the conflicts on <PR>": run A again, 20 minutes.
   Make the default `stop` (terminal `escalated`, reason = the failed rule), with the
   routable entries as the other options. A human picks an entry; a policy never
   does.

6. **Section 2, `direct` SHA check.** `git cat-file -e <sha>` proves the object exists
   in the local repo, not that a push or PR happened, yet `workDelivered: true` rests
   on it. Check the fact the claim makes: for a `push` action, `git ls-remote <remote>
   <ref>` equals the claimed SHA (`repo.run_git` already exists); for a `pr`, the PR's
   head equals it (`repo.adopt_pr` returns `head_sha`). An action that fails the
   check makes `workDelivered: false` and a warning naming it. `commit`/`other`
   actions need no check; drop `cat-file`.

7. **Section 2, `Entry.use` duplicates the stub frontmatter.** `skills/micro/SKILL.md:3`
   already says when micro fits and names cycle and debug as the alternatives; `use`
   is a second copy of that sentence in the core, and the two will drift. The table
   belongs in the core (the router must not read stubs), so keep it and add one unit
   test beside `test_roles.py`: for each entry with a stub, the stub's `description`
   equals `ENTRIES[name].use`. One assertion, no new mechanism.

8. **Section 1, a missed deviation (D5): the stubs.** Eleven stubs of 71 lines each
   (`wc -l skills/*/SKILL.md`; cycle and micro differ by one line), and section 2 adds
   a twelfth. They are the host-side half of the runner contract copied per entry,
   which is the opposite of "cite, don't copy" and of CLAUDE.md's thin shell. Not this
   change, but record it next to D4 in `architecture.md` with the follow-up (one
   protocol file the stubs name and the host reads, or stubs generated from it) so the
   map is complete.

9. **Section 1, the table.** The runner row names a contract but no registry and no
   deviation; in code there is none: the runner is whichever process picks up
   `step.json`, and the SDK runner self-declares (`sdk_runner.py:134`). Say
   "registry: none, self-declared". The core row lists twelve modules and omits
   `probes.py`, `repo.py`, `baseline.py`, `schema.py`, `render.py`, `log.py`,
   `errors.py`, `jsonio.py`, `ids.py`, all of which adapters import. State the rule
   instead of the list: everything not a phase adapter, role, runner, or entry is
   core.

10. **Section 2, `Entry` in the core.** The shape is right for the router's need
    (`name`, `use`, `takes` are what it reads; `start` is what the CLI needs) and it
    is one table replacing three, so it is deep enough. Two nits. `routable` exists
    only to exclude `auto` from its own choices; a one-line filter on the name does
    the same with one field fewer. And `_ENTRY_ACCEPT` keyed by phase, beside
    `DEFAULT_IMPLEMENTATIONS` keyed by phase (finding 2), is a second per-phase table
    in the core; if finding 3 moves the checks into `ROUTES`, `_ENTRY_ACCEPT` reduces
    to the compaction hooks for debug and revise and can be a field on those two
    entries (`compact: Callable | None`) rather than a dict.

## Not findings

- Deferring D4 is right. The new accept handlers read products only; keep it that
  way so the follow-up list does not grow.
- `direct` as a lead step with no gate, `converged: false`, and its own terminal
  classification is sound and minimal: the requester asked for the mechanical work,
  the result says no gate ran, and the stub already knows `lead`. No stub for it is
  right.
- Router as a role step (attested, fresh worker, entries rendered from `ENTRIES`) is
  the correct side of "program checks facts, roles judge". The five ordered rules are
  fine; rule 1's "plainly implies" is judgement and belongs to the role.
- Item 5 unchanged, R6 as a doc-only how-to, and the item table in section 4 are
  consistent with the contract.

## Rev 2

Verdict: go

Every rev-1 finding is resolved as section 7 says, and I checked the ones with code
consequences: `steps.py` imports `contract`, `events`, `postconditions`, `repo`,
`schema` and not `execute` (`steps.py:13-21`), so D0's move creates no cycle;
`_reject_product` past `retry_limit()` asks a `blocked` question with default `stop`
(`controller.py:1428-1436`), so F5 needs no new mechanism; `entries.py` as data plus
`controller._ENTRY_START` with a key-equality test is the right split, since an
`Entry.start` field would make the data module import the controller. The shared
`_adopt` helper, the lazy `DEFAULT_IMPLEMENTATIONS` with the default-only check, and
`direct` as a `lead` phase through `run_lead_phase` are all consistent with the core
they land in. Nothing in rev 2 introduces a new cross-adapter import or a new core
read of adapter state, provided finding 3 below is stated.

### Must-fix

None.

### Should-fix

1. **Section 2, ROUTES row `route`.** `_accept_product` unpacks `route["next"]` as a
   `(phase, mode)` tuple and transitions on it (`controller.py:1260-1263`); the only
   product-dependent target today is `mode == "rewind"`, computed from `gaps`. The
   `routed` exit's target comes from the product (`entry`), which a static row cannot
   name, and the plan does not say what the row holds. Change: `"routed": {"requires":
   ["R1", "R2"], "next": (None, "routed"), "backward": False}` and a `mode == "routed"`
   branch beside the `rewind` one that does the hand-off (same run: `_enter_phase`;
   revise: `_ENTRY_START["revise"]` plus the `routed` result and the explicit
   return). One place, same pattern as `rewind`.

2. **Section 2, `direct` inputs.** `run_lead_phase` gives the lead `request`,
   `products`, `state`, `entry`, `answers`, `probes`, `revisions`, and `repos` only
   when `phase == "plan"` (`defaults.py:50-59`). `direct` gets the PR through
   `products.route.pr`, which is enough, but no repo map, so the prompt cannot name
   the branch or path it must push. Change: `phase in ("plan", "direct")` for the
   `repos` key, and list direct's inputs in the role section (`request`,
   `products.route`, `repos`) so the prompt author does not guess.

3. **Section 2, `state["route"]` ownership.** `probes.pr_refs` output goes to
   `store.state["route"]["facts"]` (core-written at start), `route.py` "stores the
   result" (adapter-written, presumably under the same key), and `Boundary._r2` reads
   the facts. Reading an adapter's key from the core is D4's pattern. State it in the
   plan and in `architecture.md`'s D4 sentence: `route.facts` is core-owned and
   read-only to the adapter; the adapter's own key is `route.result` (or whatever
   it picks); the Boundary reads `facts` plus the product, never `result`. One
   sentence keeps the new phase out of the D4 follow-up list.

4. **Section 1, core rule.** The rule "everything not a phase adapter, role, runner,
   or entry is core" leaves `defaults.py`, `external.py`, and `sdk_runner.py`
   unclassified by the reader's first reading: `sdk_runner.py` is a runner, and
   `defaults.py`/`external.py` are the core's side of the implementation contract
   (the `lead` and `external` kinds). Add those three to the sentence so the
   `architecture.md` section is complete at a glance.
