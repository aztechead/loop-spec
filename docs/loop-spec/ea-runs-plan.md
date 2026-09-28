# Plan: the 2026-09-23 EA-runs report on v7 (7.3.0), rev 5

For the two critics of this change (Fable: architecture, Opus: correctness) and the
implementer after a `go`. Source: the upstream report "three autonomous runs,
2026-09-23" (6.11.1, runs A/B/C, items 1-11 and a reviewer seam), at
`/Users/aztechead/Downloads/loop-spec-upstream-2026-09-23-ea-runs.md`. Paths are under
`skills/loop-spec/program/loop_spec/` unless given in full. Line numbers are at `52334ce`.

Operator direction (2026-09-24): v7 gets a request router again (reversing the
2026-09-22 removal of `auto`, `migration-inventory-7.0.md:53`), and the whole plugin,
not just the router, is shaped as a microkernel. The reviewer seam is documented role
binding with no new command. The changelog fix is a planner task plus a safe repair text.

Rev 2 folds in `ea-runs-plan-audit-fable.md` (F1-F10) and
`ea-runs-plan-audit-opus.md` (O-M1..M6, O-S1..S9); every finding is accepted. Section 7
maps each one to where it landed.

## 1. The plugin as a microkernel

The terms: a **core** holds the minimum needed to run. **Plug-ins** add behaviour,
never import each other, and talk to the core only through a **contract**. A
**registry** is how the core finds a plug-in by name. The rule this plan applies:
everything that is not a phase adapter, a role, a runner, or an entry is core
(`controller`, `postconditions`, `contract`, `state`, `steps`, `attest`, `questions`,
`result`, `events`, `ledger`, `paths`, and the shared services `repo`, `baseline`,
`probes`, `schema`, `render`, `jsonio`, `ids`, `errors`, `log`, and `defaults`/`external`,
the core side of the `lead` and `external` implementation kinds). `sdk_runner` is a
runner plug-in.

| Plug-in kind | Contract | Registry today |
|---|---|---|
| Phase implementation | `context.json` in, `product.json` out, ROUTES postconditions | `contract.resolve_implementation` (`phases.<p>`, `LOOP_SPEC_PHASE_<P>`) picks `default`/`external`/skill; the `default` adapters sit in three tables (D2) |
| Role | `roles/<name>/SKILL.md` + `schema.json` | `contract.resolve_role` (`roles.<r>`, `LOOP_SPEC_ROLE_<R>`); names repeated in `ROLE_NAMES` (D3) |
| Runner | `step.json` in, `submit` out | none, self-declared: whichever process picks up `step.json` (`sdk_runner.py:134`) |
| Entry | an entry name plus its argument | none: hard-coded (D1) |

Deviations:

- **D0. Plug-ins import each other.** `verify.py:25`, `iterate.py:19`, `revise.py:17`,
  `debug.py:16`, and `deliver.py:19` import `IssueStep`/`IssueSteps`/`Product`/`Pause`
  from `execute.py:61-97`. Those classes are the adapter-to-core step contract.
- **D1. Entries have no registry.** Entries are hard-coded in five places:
  - the `run_entry` if-chain (`controller.py:61-95`), whose error text at `:95` lists them;
  - `cli._CONTROLLER_ENTRIES` (`cli.py:24`);
  - the per-entry `add_argument` branches (`cli.py:43-49`);
  - `cli._REPAIR_COMMAND` (`cli.py:196-197`).
- **D2. The default adapters are listed in three tables:**
  - `contract.py:158-159`, plus the lazy-import dict at `:228-236` and the deliver
    branch at `:238-242`;
  - `controller._SUBMIT_ROLE_MODULES` (`:1591-1596`);
  - `controller._REFUSAL_OWNERS` (`:1618`).

  `_ALL_IMPLEMENTATION_PHASES` (`controller.py:39`) is a fourth hand-kept list that
  `store.state["implementations"]["phases"]` is built from, and `controller.py:549`
  indexes it.
- **D3.** `roles.ROLE_NAMES` (`roles.py:23`) repeats `roles/` and lacks `reviser`.
- **D4. The core reads plug-in state:** `store.state.get("verify")`
  (`controller.py:1386`); the shared keys `executeRuns` (`:1079`) and `verifyRuns`
  (`:1123`, `:1405`); `debug_module.compact_products`/`record_base_runs` and
  `revise_module.gaps_from_pr` at entry. The final list comes from a grep at
  implementation time.
- **D5. Stubs copy the runner protocol.** There are eleven 71-line stubs, nearly
  identical, and this change adds a twelfth.

This change fixes D0-D3. D4 and D5 are follow-ups, recorded in `architecture.md` with
their sites. D4 needs each phase to publish through its product. D5 needs one protocol
file that the stubs cite, or stubs generated from it.

### D0: step contract into the core

Move `IssueStep`, `IssueSteps`, `Product`, and `Pause` from `execute.py` to `steps.py`.
Move `Wait` with them (O2-S1). `steps.py` does not import `execute`
(checked). The edge to watch is `contract` and `steps`, so `contract` keeps its lazy
adapter imports. The six modules change their imports, and so do the 8 test files that
import these types from `execute` (list them by grep). `execute.py` keeps no re-export.

### D2: one implementation registry

In `contract.py`:

```python
# phase -> (kind, target). kind: "lead" (target = role name, run_lead_phase),
# "stepped" (target = module name exposing step/on_submit[/on_step_refused]),
# "run" (target = module name exposing run(), deliver).
DEFAULT_IMPLEMENTATIONS = {
    "spec": ("lead", "spec-writer"), "plan": ("lead", "planner"), "direct": ("lead", "direct"),
    "execute": ("stepped", "execute"), "verify": ("stepped", "verify"), "iterate": ("stepped", "iterate"),
    "debug": ("stepped", "debug"), "revise": ("stepped", "revise"), "route": ("stepped", "route"),
    "deliver": ("run", "deliver"),
}
def default_adapter(phase):  # importlib.import_module(f"loop_spec.{target}"); lazy, no import cycle
```

- `contract.invoke`'s default branch dispatches on `kind` from this one table.
  `_DEFAULT_ROLE_BY_PHASE`, `_DEFAULT_STEPPED_MODULE_BY_PHASE`, and the dict at
  `:235` are deleted.
- `controller._ALL_IMPLEMENTATION_PHASES = list(contract.DEFAULT_IMPLEMENTATIONS)`.
- The controller's submit and refusal routing replaces `_SUBMIT_ROLE_MODULES` and
  `_REFUSAL_OWNERS` with one lookup:
  - It sends a step to `default_adapter(phase)` only when
    `state.implementations.phases[phase] == "default"` and its kind is `stepped`, and
    the step's role is not null. An external step (`role: None`, `external.py:115`)
    stays a no-op, as today.
  - A refusal goes to `getattr(adapter, "on_step_refused", None)`.
  - The current table keys on (phase, role). The check keeps today's pairs, so it
    must reproduce that behaviour for every pair, including the adopted review.
    Confirm at implementation against `controller.py:1591-1616`, and keep any pair
    that routes differently as an explicit exception.
- The `lead` kind needs `external.PHASE_POSTCONDITIONS["direct"]` (`defaults.py:71`)
  and `schemas/direct.json`. `run_lead_phase` validates against `load_schema(phase)`.

The full suite is the behaviour check for D0-D3.

### D3

`ROLE_NAMES` becomes the sorted `roles/` directories that hold a `schema.json`.
`test_roles.py:27-36` then covers `reviser`, `router`, and `direct`; each needs an
`## Example` that validates.

### architecture.md

The "Core and plug-ins" section replaces "The program, by responsibility". It carries:
the core rule, the table above, the three registries (implementations, roles, and
entries after this change), the plug-in rule (no plug-in imports another; the core
reads only products), and D4/D5 as named follow-ups with their sites.

## 2. The request router (items 1, 5; run A)

### Entry registry

A new core module `entries.py`, data only, is read by `cli`, `controller`, `route`, and
`postconditions`, and imports nothing from them:

```python
@dataclass(frozen=True)
class Entry:
    name: str
    use: str      # when this entry fits; equals its stub's description (test)
    takes: str    # "request" or "pr"

ENTRIES = {e.name: e for e in (cycle, micro, debug, revise, direct, auto)}
ROUTABLE = [n for n in ENTRIES if n != "auto"]
```

- `controller._ENTRY_START = {name: fn}`. A test asserts that its keys equal
  `ENTRIES`. `run_entry` does `_ENTRY_START[entry](...)`. The resume entries keep their
  branch. The error text at `:95` renders from the registry.
- `cli.py` builds subparsers and `_REPAIR_COMMAND` from `ENTRIES`. A `takes ==
  "request"` entry gets `--request` and `--request-file`. `debug` gains
  `--request-file`, a stated behaviour change in the CHANGELOG.
- `_phase_probes` (`controller.py:436`) stays a named set, because it describes the
  phases that write a PLAN, not entries.
- Test: for each entry with a stub, the stub's frontmatter `description` equals
  `ENTRIES[name].use` (F7).

### One adoption helper (item 1b's root and item 9)

`cycle`/`micro` already adopt a PR their request names (`_resolve_repos`,
`controller.py:287-311`), and `revise` adopts one too (`:205-235`). Both are broken
in the same ways:
- `merge-base` runs on an unfetched head SHA;
- `lastKnownHead` stays at the merge-base while the feature branch is the PR branch,
  so `execute._init` (`:357`) creates it at `baseSha`, which reads as drift;
- `_resolve_repos`' adoption dict has no `repo` key, so `_issue_adopted_review`
  (`controller.py:1554`) raises `KeyError` at EXECUTE.

One helper, `controller._adopt(repo_name, repo_path, candidate) -> (repo_entry,
adoption_dict)`, used by both sites:

1. `repo.fetch_pr_head(repo_path, head_ref, base_ref, head_sha)`:
   - `git fetch --no-tags [--unshallow] origin +refs/heads/<base>:refs/remotes/origin/<base>
     +refs/heads/<head>:refs/remotes/origin/<head>`, with `--unshallow` only when
     `rev-parse --is-shallow-repository` prints `true` (`# ponytail: full unshallow;
     --deepen loop if a huge repo makes it slow`).
   - `origin/<head>` must equal `head_sha`, else a LoopSpecError "PR moved during
     adoption; re-run".
   - If `git worktree list --porcelain` shows `branch refs/heads/<head>`, it refuses
     and names the worktree that holds the branch. The repair is `git -C <that
     worktree> checkout --detach`, or `git worktree remove <path>` when the worktree
     is under the state home (a stale run's, O2-S8). (This includes a clone
     of the PR branch itself; `worktree add` would fail later at EXECUTE.)
   - Local `<head>`: if absent, create it at `head_sha`; if equal, nothing; if an
     ancestor of `head_sha`, refuse with the repair `git -C <repo> branch -f <head>
     origin/<head>`; otherwise refuse with "local <head> has commits the PR lacks;
     push or rename it".
2. `base_sha = merge-base origin/<base> <head_sha>`.
3. Return the repo entry `{path, baseSha, featureBranch: head, defaultBranch: base,
   lastKnownHead: head_sha}` and the adoption `{repo, number, url, headRef,
   baseBranch, baseSha, headSha, reason}`: one shape for both sites.

Tests:
- The two revise tests (`test_controller.py:1145`, `:1255`) and any cycle-adoption
  test get a bare origin with `main` and the PR branch pushed (a new helper beside
  `_init_repo`).
- New `test_repo.py`: a bare origin and a `git clone --depth=1 --single-branch
  file://...` clone. A local-path clone ignores `--depth` (O-M2). After
  `fetch_pr_head`, the clone is not shallow, the local branch is at head, and
  `merge-base` resolves.
- One refusal test: the PR branch checked out in the clone.
- `test_controller.py`: a cycle whose request names an open PR reaches EXECUTE's
  adopted review with no `KeyError` and no drift pause (`gh` stubbed the way the revise
  tests stub it).

### `auto` and the `route` phase

- **CLI:** `loop-spec auto --request | --request-file`. The stub is
  `skills/auto/SKILL.md` (the micro stub with the entry name changed; D5 stays a
  follow-up) plus `skills/auto/manifest.toml`.
- **Start:** creates the run like `_run_request_entry`, but with no adoption. It calls
  `_resolve_repos` with `pr_ref=None` (the signature gains `pr_ref`; `cycle`/`micro`
  pass `find_pr_reference(request)` as today). Then `run.cycleType = "auto"`,
  `phase.current = "route"`, and the answer policy recorded as in every entry.
- **Facts** (`probes.pr_refs(workspace, text)`): every PR URL (any host),
  `PR #<n>`, and `#<n>` in the request, each resolved by `repo.adopt_pr` per workspace
  repo into `{ref, number, url, repo, adoptable, reason}`. A `#<n>` that resolves nowhere
  is dropped. A `gh` failure gives `adoptable: false` with the reason. Stored in
  `store.state["route"]["facts"]`.
- **`route.py`** (a stepped adapter, `debug.py`'s shape):
  - `step` issues the `router` role step. Its inputs are the request verbatim,
    `prRefs`, and `entries: [{name, use, takes}]` for `ROUTABLE`; the prompt never
    lists entries itself.
  - `on_submit` stores `{attempt, result}` under `store.state["route"]["result"]`.
  - The next `step` returns the product only when the stored attempt is the current
    attempt. Otherwise (a retry after a rejection) it issues a fresh router step
    carrying `retryOf` and the rejection's reason, so the router sees the rule it broke
    (O2-M2). `debug.py` has the same replay today; that is recorded as a follow-up,
    not fixed here.
  - The product is `{exit: "routed", entry, pr, reason, inputsDigest, boundTo:
    {requirements: null, plan: null}}`, the shape `_record_accepted_product` reads
    (`controller.py:1367`, O2-M1).
- **Role `router`:** `roles/router/SKILL.md` + `schema.json` (`{entry, pr: int|null,
  reason}`), attested (add it to `steps.ATTESTATION_REQUIRED_ROLES`, `steps.py:27`),
  with its model from `roles.router.model`. Its rules, in order:
  1. The request asks for a mechanical git or PR operation, and says or plainly implies
     that it needs no design or verification (resolve conflicts, rebase, sync with base,
     re-run CI, retitle or relabel, push): `direct`.
  2. It asks to address review, findings, or comments on an adoptable PR: `revise`.
  3. It is a defect report with a reproduction or error: `debug`.
  4. It is a small, well-defined change: `micro` (with `pr` when it names a PR to work on).
  5. Otherwise: `cycle` (with `pr` likewise).
- **ROUTES row `route`** (`postconditions.py`, `Boundary._a1`/`_a2`,
  `external.POSTCONDITION_TEXT`, and the doc in the same diff):
  - A1: `entry` is in `ROUTABLE` (reason `route-refused:unknown-entry`).
  - A2: when `takes == "pr"`, `pr` is a `prRefs` number with `adoptable: true`
    (`route-refused:pr-not-adoptable`). When `takes == "request"`, `pr` is null or a
    `prRefs` number with `adoptable: true` (`route-refused:pr-not-named`). A number that
    matches adoptable entries in more than one workspace repo is refused as
    `route-refused:pr-ambiguous` (O3-S1).
  - Exit `routed` requires A1 and A2 (ids A, not R: R-numbers are taken by this plan's items and by code comments, O2-S7). `ROUTES["route"]["routed"]["next"] = (None,
    "routed")`. `_accept_product` unpacks `(phase, mode)` (`controller.py:1260`). The
    `mode == "routed"` branch in `_finalize` sits after the phase-end marker, does the
    hand-off below, and returns (F-r2-1, O3-M2).
  - Ownership: the core writes `store.state["route"]["facts"]` at start. `route.py`
    owns only `store.state["route"]["result"]`. `Boundary._a1`/`_a2` read the facts
    plus the product, never the adapter's key, so the new phase adds no D4 site
    (F-r2-3).
  - A failing check is the generic product rejection (`controller.py:1415-1438`): a
    retry with the named rule as reason. Past `retry_limit()` comes the existing
    blocked question, whose default is `stop`, so `--answer-policy default` ends
    terminal `escalated` with the failed rule, never a guessed cycle (F5). No new
    question mechanism.
- **Hand-off** (the controller, on an accepted `routed` exit):
  - A shared `_enter_phase(store, phase)` sets `attemptId` to None (`_drive_phase`
    writes `context.json` only when it is None, `controller.py:531-540`, O3-M1),
    `entry: fresh`,
    `entryPayload`, `pending`, `provisional`, `retries`, the way `_begin_compaction`
    does (`:752-760`). `_begin_compaction` also calls it, then sets its own new
    `attemptId` right after: the compacted SPEC's approval is asked and looked up
    under that id (`controller.py:419-423`, O4-M1). Only the router's hand-offs keep
    `attemptId` None.
  - The hand-off runs in `_finalize`'s `mode == "routed"` branch (O2-M3). That branch
    comes after the phase-end marker, does the hand-off, and returns. It never falls
    through to `controller.py:1317-1321`, which would set `phase.current = None` and
    `entry = "routed"` over it (O3-M2).
  - The PR passed on, to every hand-off including revise, is the matching `prRefs`
    entry's `url`, never the bare number (O2-S2, O3-S1).
  - `cycle`/`micro`/`debug`: same run. `_resolve_repos(..., pr_ref=<that URL>)`
    re-resolves repos, adopting through `_adopt` when `pr` is set. `run.cycleType`
    becomes `full`, `micro`, or `debug`; `run.routedTo = {entry, pr, reason}`;
    `_enter_phase(spec | debug)`.
  - `revise`: `_ENTRY_START["revise"](pr=<that URL>, answer_policy=<this run's
    questions.policy>)` creates or resumes `revise-<n>`. The auto run holds no adoption
    (start skipped it), so `_find_run_by_adoption_number` cannot match it. The auto
    run then gets its own `result.json` with classification `routed`
    (`status: completed`, `outcome: routed`, `routedTo: {entry, slug, reason}`,
    `converged: false`, `workDelivered: false`). It is written through a
    `_finish_run(..., handoff=True)` path that writes neither the per-repo
    `last-result.json` pointer nor the `LOOP_SPEC_RESULT` marker, so nothing reports
    the request as finished before revise starts (O2-M5). `continue_run` checks for
    the hand-off before it returns anything and returns the revise run's `Next`.
  - `_find_run_by_adoption_number` (`controller.py:138-149`) matches only runs with
    `cycleType == "revise"`. With cycle/micro adoption working, a later `revise --pr
    n` would otherwise resume a cycle run (O2-M4).
  - `direct`: same run, `run.cycleType = "direct"`, `_enter_phase("direct")`.

### `direct` (run A's "just do the thing")

- It is reachable through the router, and as `loop-spec direct --request` for a
  harness that already knows. It has no stub.
- **Phase `direct`,** kind `lead`, role `direct` (`roles/direct/SKILL.md` +
  `schema.json`, product schema `schemas/direct.json`):
  - The prompt: do the request now, with no SPEC or PLAN. Change and push only what
    the request names. Never open a PR it did not ask for. Report every action that
    changed a repository or a remote.
  - Inputs: `request`, `products.route` (the router's reason), and `repos`.
    `run_lead_phase` gives a `repos` map only to `plan` (`defaults.py:50-59`); extend
    that to `direct` (F-r2-2).
  - The product: `{exit: "done" | "incomplete", summary, actions: [{kind: commit | push
    | pr | other, repo, ref, sha, url}], blocker}`.
- **ROUTES row `direct`:**
  - X1: product validates.
  - X2: every `push` action's `sha` equals `repo.remote_head(<repo path>, "origin",
    ref)`, and every `pr` action's `sha` equals `gh pr view <url> --json headRefOid`
    (not `adopt_pr`, which refuses merged, closed, and fork PRs, O2-S4). `commit` and `other` actions are not checked. `git cat-file` is
    not used (F6, O-S7).
  - `done` requires X1 and X2. `incomplete` requires X1. `schemas/direct.json`
    has two `oneOf` branches: `done` with `blocker` null, and `incomplete` with
    `blocker` a non-empty string. The in-house validator ignores `if`/`then`, so X1
    covers the rule only this way (O2-S5, O3-S3).
  - `schemas/direct.json` requires `inputsDigest` and `boundTo`, which the lead
    writes the way spec/plan leads do. `run_lead_phase` adds neither, and no fallback
    is added: for plan it would overwrite the planner's `boundTo` (O3-S2).
  - `schemas/route.json` is new, because `load_schema("route")` raises without it.
    `external.PHASE_EXITS` and `PHASE_POSTCONDITIONS` get `route` and `direct` entries
    (O3-S4).
  - A failed X2 is the generic rejection: a retry naming the action.
- **Terminal results** (`result.py`, `schemas/result.json`):
  - `_write_terminal_result` gets a `direct` branch ahead of its
    `products["execute"]` read (`controller.py:1529`, O2-M3).
  - `done`: classification `direct` (`status: completed`, `outcome: direct`,
    `converged: false`, a warning "no gate ran"). `workDelivered` is true iff any
    action is a checked `push` or `pr`.
  - `incomplete`: classification `escalated` with `blocker` as `reason`.
  - `result.write` gains keyword arguments for `workDelivered` and extra `warnings`,
    because today it derives both from delivery targets and the ledger
    (`result.py:92-100`).
  - `schemas/result.json`:
    - `cycleType` enum: add `auto`, `direct`;
    - `result` enum: add `direct`, `routed`;
    - `_STATUS`/`_OUTCOME` entries.

    An auto run that escalates before the hand-off writes `cycleType: auto`.
- **`phase-interface-7.0.md`:** add `auto` and `direct` to "Entry points and the
  order"; add `route` and `direct` sections with A1-A2 and X1-X2; add terminal-result
  rows for `direct` and `routed`.

### Item 5 (SPEC oracle question)

Not changed. S2 is a core invariant. `--answer-policy default` answers the approval
with no human, and a mechanical request now routes to `direct`, which has no SPEC.

### Router tests (deterministic parts, O-M6)

- `test_controller.py`:
  - `_a1`/`_a2` for each refusal reason (including `pr-ambiguous`), and acceptance.
  - The state after each hand-off: cycle, micro with `pr` (adoption present, with
    `repo`), debug, revise (a `routed` result on the auto run and a separate
    `revise-<n>` run with the inherited policy), and direct.
  - A second refusal under the default policy ends `escalated`.
- `test_probes.py`: `pr_refs` over a URL on a non-github host, `PR #n`, and a bare
  `#n` that does not resolve (dropped), with `gh` stubbed.
- `test_result.py`: `direct` and `routed` results validate; `workDelivered` for a
  checked push.
- `test_postconditions.py`: X2, with a push whose SHA matches the remote and one whose
  SHA does not.

## 3. Report items fixed in v7 terms

**R2 (item 3, checks after review).** Move `_check_regressed(...)` from
`_on_review_submit` (`execute.py:1422-1426`) to the end of `_on_implement_submit`,
after the commit checks and before `status = "probing"`, in the task worktree at
`task_head`.
- If the tree is dirty after the checks: the checks wrote it, because it was clean at
  entry (`:1340`). Restore it with `git restore --staged --worktree . && git clean -fd`
  in the task worktree, and emit an event naming the check. This is safe because
  `is_clean` held just before, and ignored files are untouched.
- Update the comments at `:1422-1424`.
- Replace `test_a_repo_check_regression_at_integration_sends_the_task_back_with_the_diagnostic`
  (`test_execute.py:582-607`) with the implement-time version. After the implement
  submit, the next step is an implement retry carrying the check's reason, and no
  review step was issued. Add one assertion that a check which writes a file leaves
  the worktree clean.

**R3 (item 6, security signal on whole files).**
- Refactor `_sec_scan_file` into `_sec_scan_lines(numbered_lines, only=None)`. The
  file variant opens the file and calls it. With `only`, a term counts only on a line
  in it, while headings are tracked on every line.
- A new `_diff_lines(path, base, head, file) -> (added: set[int], removed: [(n,
  text)])` runs `git diff -U0 --no-renames base..head -- <file>` per file (the list
  `_diff_touched_files` already builds) and parses only `@@` lines: an omitted count
  is 1, `+c,0` adds nothing, and binary files have no hunk. It never parses file names
  (O-S3).
- Removed lines are scanned with `_sec_scan_lines` and no heading context. A hit
  reports `removed line <n>`, so deleting a permission check still signals.
- `_range_style_probes` uses both. For removed lines it takes every touched file,
  including deleted ones, which the current `is_file` filter drops (`probes.py:1848`).
  It reads the `-` lines that follow the first `@@`, never the `---` header (O2-S3).
  `plan_probes` stays whole-file.
- `verify.py:206` passes the verify checkout at head (`checkouts[name]`) to
  `range_probes`, not the operator's checkout (O-M3).
- Tests (`test_probes.py`):
  - An old `credential` line plus an unrelated added line gives no signal.
  - An added `credential` line gives a signal at its line.
  - A removed `permission` line gives a signal.
  - A hunk parse over `@@ -4,0 +4 @@` and `@@ -2 +1,0 @@`.

**R4 (item 4, serial revise tasks).** EXECUTE already runs a wave in parallel with one
wave review, and revise hands off through the reviser's product (4c has no v7 analog).
`roles/reviser/SKILL.md` step 3 gets the planner's rules copied as they are (planner
SKILL.md:39 and LF-71): give each file one owning task, fold small gaps on the same
file into that task, and add `dependsOn` only when a task needs another's result
(O-S5). No test (a prompt).

**R5 (item 2, post-gate CHANGELOG commit, then a reset).**
- `roles/planner/SKILL.md`: when the repository keeps a root changelog and its own
  instructions (`CLAUDE.md`, `CONTRIBUTING*`) ask for an entry per change, the last
  task edits it. The entry is then in the gated diff.
- `deliver.py:201-205`, the moved-branch row. The caveat names the commits in
  `verified..local` and a recovery that keeps them. It never contains `--hard`.
  - When `local_sha` is present: `git -C <repo> branch loop-spec-rescue-<local8>
    <local>`, then `git -C <feature worktree> reset --keep <verified>`, then re-enter
    DELIVER. After the PR opens: `git -C <repo> push origin
    loop-spec-rescue-<local8>:<featureBranch>`, then `loop-spec revise --pr <n>`, which
    gates the new head (O-S4a).
  - When the exit ends up `partially delivered` (terminal; the worktree has been
    removed), the text names only the rescue-branch command. The row is written before
    the exit is known, so the text gives both paths conditionally: "if DELIVER is still
    paused ..., otherwise ...".
  - When `local_sha is None`, the text says the branch is missing and has nothing to
    rescue.
- Test (`test_deliver.py`): the moved-branch caveat contains the rescue-branch command
  and not `--hard`.

**R6 (reviewer seam).** In README Configuration, under the `roles.<role>` row, a short
how-to: bind `code-reviewer` to a project skill that runs the external reviewer when
its inputs carry `rangeProbes` (VERIFY's review, `verify.py:293-298`; the
prompt carries no phase, O-S8). The adopted-range review also sends `full: true`, so
`full` alone is not a VERIFY signal. At implementation, check whether the adopted review
also gets `rangeProbes`: it does (`rangeProbes: {}`, `controller.py:1575`). So the
how-to says the bound reviewer runs in VERIFY's review and in the adopted-range review,
and that a skill wanting VERIFY only checks for a non-empty `rangeProbes` (O2-S6,
O3-S5). The skill then merges the findings into
the role's `schema.json` shape. No program change.

## 4. Items with no v7 counterpart

| Item | Why |
|---|---|
| 1a classification mismatch | no classifier; A1/A2 name the failed rule |
| 7 artifact-only PR | D6: a `no change` head opens no PR; LF-49 records an empty task as already satisfied; nothing is committed by default |
| 8 phase commits to the checked-out branch | products live in the state home; EXECUTE uses its own worktrees; LF-15 pauses on a moved default branch; `fetch_pr_head` refuses a checked-out PR branch |
| 10 BACKLOG.md committed | no backlog file in v7 |
| 11 phase-begin, SKILL_DIR, tasks.extract.err | the scripts do not exist in v7 |
| 11 prTitle | revise's `feature_title` is the request line |

## 5. Docs, version, live runs

- Docs in the same diff:
  - `phase-interface-7.0.md` (section 2);
  - `architecture.md` (section 1);
  - `migration-inventory-7.0.md:53`: `auto` reinstated in 7.3.0 as a router over the
    entry registry. `route-judge` stays removed: the router is a role, not a
    SPEC-entry judge.
  - `migrating-6-to-7.md:61`;
  - README: the `auto` example, the R6 how-to;
  - CHANGELOG, including debug's `--request-file`.
- Version 7.3.0 in all four places, including the new `skills/auto/manifest.toml`.
- Live runs, recorded in `live-runs-7.0.md`:
  - Every live PR used is fresh: revise resumes a finished run for the same PR and
    returns its old result, a pre-existing behaviour recorded as a follow-up (O3-S7).
  - L1: revise from `git clone --depth=1 --single-branch <consumer remote>` against an
    open live-7 PR with one review comment. It converges and updates that PR.
  - L2: `auto` with four requests on the consumer fixture:
    - "resolve the conflicts on <PR url> and push" (a PR made to conflict) goes to
      `direct`, and X2 checks the push;
    - "address the review comments on <PR url>" goes to `revise` (a `routed` result
      plus the revise run);
    - "add a clamp helper with tests" goes to `micro` or `cycle`;
    - "add a docstring to lerp on <PR url>" goes to `micro` with `pr` (the adoption
      path, previously a `KeyError`).
  - L3: the planner changelog task on a fixture with a `CHANGELOG.md` and a
    `CLAUDE.md` rule.
  - R2 and R3 are covered by module tests only.

## 6. Order

1. D0, D2, D3, and the entry registry with the existing entries. Suite green. Commit.
2. The adoption helper, R2-R5, and their tests. Commit.
3. `entries` gains `auto`/`direct`, `route.py`, the roles, schemas, ROUTES rows,
   result enums, the stub, and the docs, with the tests. Commit.
4. Version and CHANGELOG. Commit. Then live runs L1-L3, a docs commit, a push to PR
   #109, and a PR body update.

## 7. Audit findings, where each landed

| Finding | Landed in |
|---|---|
| F1 | D0 |
| F2 | D2 registry, `route.py`, `_ALL_IMPLEMENTATION_PHASES` derived |
| F3 | ROUTES rows `route` and `direct` |
| F4 | `routed` terminal result; `cycleType = "direct"` |
| F5 | generic rejection, default `stop` |
| F6 | X2 |
| F7 | stub-description test |
| F8 | D5 |
| F9 | table and core rule |
| F10 | `routable` dropped (`ROUTABLE` filter); `_ENTRY_ACCEPT` dropped (ROUTES rows) |
| O-M1 | auto start without adoption; shared `_adopt` |
| O-M2 | R1 tests |
| O-M3 | `verify.py:206` |
| O-M4 | D2 lazy registry with a default-only check |
| O-M5 | schemas, enums, `result.write` args, `route.py`, `_enter_phase`, explicit `routed` branch, inherited policy, attestation, generic rejection |
| O-M6 | router tests |
| O-S1 | `fetch_pr_head` refusals |
| O-S2 | R2 restore and replaced test |
| O-S3 | per-file `@@` parse, removed lines |
| O-S4 | R5 conditional text |
| O-S5 | R4 |
| O-S6 | D1 lists; `_phase_probes` kept; `--request-file` stated |
| O-S7 | X2 |
| O-S8 | R6 via `full` |
| O-S9 | D4 sites from grep |
| F-r2-1..4 | routed `next`, direct `repos`, facts ownership, core rule |
| O2-M1 | `inputsDigest`/`boundTo` on route and direct products |
| O2-M2 | route result tied to its attempt |
| O2-M3 | `_finalize` routed branch; `_write_terminal_result` direct branch |
| O2-M4 | `_find_run_by_adoption_number` matches revise runs only |
| O2-M5 | `_finish_run(handoff=True)` |
| O2-S1 | D0 `Wait`, contract lazy imports, test imports |
| O2-S2 | PR passed by URL |
| O2-S3 | deleted files and `-` lines |
| O2-S4 | X2 via `headRefOid` |
| O2-S5 | `blocker` in the schema |
| O2-S6 | R6 `rangeProbes` |
| O2-S7 | ids A1/A2 |
| O2-S8 | refusal names the worktree |
| O3-M1 | `_enter_phase` sets `attemptId` None |
| O3-M2 | routed branch returns after the hand-off |
| O3-S1 | `url` in the facts, `pr-ambiguous` |
| O3-S2 | `direct.json` requires `inputsDigest`/`boundTo`; no fallback |
| O3-S3 | `oneOf` for `blocker` |
| O3-S4 | `route.json`, `PHASE_EXITS`/`PHASE_POSTCONDITIONS` |
| O3-S5 | R6 both reviews |
| O3-S6 | test names |
| O3-S7 | fresh live PRs; revise-resume follow-up |
| O4-M1 | `_begin_compaction` sets its own `attemptId` after `_enter_phase` |
| O4-S1 | revise gets the URL; routed-branch wording |
