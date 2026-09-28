For the author of `docs/loop-spec/ea-runs-plan.md`: the Opus critic's correctness audit against the code at `52334ce`.

Verdict: revise

Paths are under `skills/loop-spec/program/loop_spec/` unless given in full. The experiments ran in the session scratchpad against a bare origin with `main` plus a `feat/pr` branch.

## Must-fix

1. **Section 2, `auto` start: it inherits `_resolve_repos`' PR adoption, which breaks all three hand-offs.** The plan says `start` "creates a run exactly as `_run_request_entry` does". That path calls `_resolve_repos` (controller.py:287-311). When the request names a PR, `_resolve_repos` adopts it. This causes three failures:
   - (a) It runs `merge-base` on the unfetched `candidate.head_sha` (controller.py:301). In a fresh clone that raises, so the router never runs. This is R1's defect at a second call site, and R1 does not cover it.
   - (b) It writes `state.adoption.number`. `ENTRIES["revise"].start` then calls `_find_run_by_adoption_number` (controller.py:138-149), which matches the auto run itself. The slug becomes the auto slug, `paths.state_json` exists, and `continue_run` reopens the auto run instead of creating `revise-<n>`.
   - (c) A micro or cycle hand-off keeps an adoption dict that has no `repo` key, so `_issue_adopted_review` raises KeyError at EXECUTE entry (controller.py:526, 1554-1555). That adoption also sets `featureBranch` to the PR branch with `lastKnownHead` at the merge-base (controller.py:302-305), which execute's drift check reads as a moved branch.

   Correction: the auto start resolves repos with no adoption. Split `_resolve_repos` into repo resolution plus an optional adoption, and have auto skip the adoption. `prRefs` then become the only PR facts. Put `fetch_pr_head` in the shared adoption helper so both adoption sites use it, not only `_run_revise_entry`.

2. **R1 breaks the existing revise tests, and the planned R1 test would not be shallow.** `test_revise_entry_adopts_pr_and_reaches_execute` (test_controller.py:1145) and the prior-products revise test (test_controller.py:1255) build their repo with `_init_repo` (test_controller.py:42-51), which has no `origin`. As a result, `git fetch origin ...` fails and `origin/<base>` does not exist. The plan must say what those tests get: a bare origin with `main` and `pr-branch` pushed, or a patched `fetch_pr_head`. For the new `test_repo.py` test, cloning from a local path ignores the depth. My experiment printed "warning: --depth is ignored in local clones; use file:// instead" and `--is-shallow-repository` returned `false`. Clone with a `file://` URL, or the `--unshallow` branch is never exercised. Using `file://`, the proposed fetch works as planned: `--unshallow` with both explicit refspecs gave rc 0, `.git/shallow` was removed, `origin/feat/pr` equalled the gh head, `merge-base origin/main <head>` resolved, and `git branch feat/pr <head>` succeeded.

3. **R3 in VERIFY reads the wrong tree.** verify.py:206 passes `repo_path`, the operator's checkout, to `range_probes`. `_range_style_probes` reads each file from `path / f` (probes.py:1848, 1862), while the planned added-line set comes from `base..head`. Line numbers taken at head would then filter a different version of the file. This bug predates the plan, but R3 cannot be correct in VERIFY without fixing it. Correction: pass `checkouts[name]`, the verify checkout at head created one line earlier (verify.py:203).

4. **D2 as written is not behaviour-preserving, and the registry as described is a circular import.**
   - **Routing change.** `_SUBMIT_ROLE_MODULES` is keyed by `(phase, role)` and silently skips every other pair (controller.py:1591-1610). An external phase's step has `role: None` (external.py:115). Today that submission is a no-op. With the owner looked up by `step["phase"]` alone, an external EXECUTE step's submit reaches `execute.on_submit`, which raises "execute has no task with worktree" (execute.py:1503-1504). The same applies to VERIFY and ITERATE. Correction: route to the adapter only when `state.implementations.phases[phase] == "default"`, or keep the role check.
   - **Circular import.** `contract.DEFAULT_ADAPTERS = {phase: module}` cannot be built when `contract.py` is imported, because execute, verify, iterate, debug and revise all import from `loop_spec.contract` (for example execute.py:23 and revise.py:15). That is why contract.py:228-235 imports them locally. Store module names and import them lazily, or put the registry in `controller.py`, which already imports all five at top level.
   - **Remaining special cases.** DELIVER (`run()`, not `step()`, contract.py:199) and spec/plan (`run_lead_phase`) still need their own branches, so "the three tables are deleted" should say what remains.

5. **Section 2 needs plumbing the plan does not name. Each item below fails at runtime without it.**
   - **Result schema and writer.** The `result.json` schema's `cycleType` enum is `[full, micro, debug, revise, diagnostic]`, and the `result` enum has no `direct`. `result.write` calls `validate_or_raise` (result.py:158). An auto run that fails or escalates before its hand-off crashes when it writes its result. So does a direct run, whose `cycleType` the plan never changes from `auto`. Add `auto` (or set `cycleType` to `direct`) and `direct` to the enums, and add `_STATUS`/`_OUTCOME` entries. `result.write` derives `workDelivered` from delivery targets (result.py:92-94) and `warnings` from the ledger (result.py:100), so `_accept_direct` needs parameters for both. Also say what `outcome` a not-done direct run gets: the `escalated` classification maps to outcome `escalated`, not `direct`.
   - **Product schemas.** Every product is validated by phase name (contract.py:110; defaults.py:31 and 69 use `load_schema(phase)`). Add `loop_spec/schemas/route.json` and `schemas/direct.json`. Add `roles/router/schema.json` and `roles/direct/schema.json`, each role with an `## Example` JSON block that validates, because `test_roles.py:27-36` iterates over `ROLE_NAMES`, which D3 extends to these roles.
   - **Phase implementation.** `route` and `direct` must be in `_ALL_IMPLEMENTATION_PHASES`, or controller.py:548 raises KeyError. `contract.invoke` also needs an adapter for each; the default implementation raises "no default implementation" (contract.py:247). `route` needs a new stepped module: `step` issues the router role step, `on_submit` records it, and the next `step` returns the product. `direct` can go through `_DEFAULT_ROLE_BY_PHASE`, but then `external.PHASE_POSTCONDITIONS` needs a `"direct"` key (defaults.py:71).
   - **The "routed" run.** After `_accept_route` returns, `continue_run` loops back into `_drive_phase` for phase `routed` (controller.py:426). It needs an explicit branch that returns the revise run's `Next`. The revise start must also inherit `questions.policy` from the auto run. Without that, an autonomous auto → revise run stops at the compacted SPEC's approval question.
   - **Hand-off resets.** The hand-off must reset `attemptId`, `entry`, `entryPayload`, `pending` and `retries`, and end the route phase, the way `_begin_compaction` does (controller.py:752-760). Otherwise the router's refusal count carries into SPEC.
   - **Second-refusal question.** This mechanism does not exist yet. `_reject_product` asks a `blocked` stop/fix-and-re-enter question with default `stop` once retries exceed `retry_limit()` (controller.py:1424-1438). A choice question over the entries with default `cycle` needs a `routeQuestionId` handler in `continue_run`, like `criticQuestionId` (controller.py:390-406). The plan should also say how it interacts with the generic limit.
   - **Attestation.** "Attested" requires adding `router` to `ATTESTATION_REQUIRED_ROLES` (steps.py:27).

6. **Section 2 has no unit tests.** CLAUDE.md puts routing, state and schemas under unit tests, but the plan tests the router only through the live run L2, which shows model behaviour. The following are deterministic and need tests: `_accept_route`'s three refusal rules, `probes.pr_refs` parsing (URL on any host, `PR #n`, bare `#n` dropped when it does not resolve), the state after each hand-off (cycleType, routedTo, phase, reset fields), `_accept_direct`'s status, `workDelivered` and warnings, and schema validation of a result with cycleType `auto` or `direct`. They belong in `test_controller.py`, `test_probes.py` and `test_result.py`.

## Should-fix

1. **R1: when the local PR branch exists, or when the clone is the PR branch itself.** I cloned `--depth=1 --single-branch --branch feat/pr` and ran the planned fetch (rc 0). Two results:
   - Merge-base on the local base failed ("Not a valid object name main"). The plan's switch to `origin/<base>` fixes this.
   - The local head branch is checked out in the main worktree, and `git worktree add ../wt feat/pr` fails ("'feat/pr' is already used by worktree"). That is exactly what `execute._init` does at execute.py:359-360, so the run fails at EXECUTE. `fetch_pr_head` should refuse at entry when `git worktree list --porcelain` shows `branch refs/heads/<head>`, with the repair `git -C <repo> checkout --detach`.

   The planned repair `git branch -f <head> origin/<head>` also fails on a checked-out branch ("cannot force update the branch 'feat/pr' used by worktree"). When the local branch is ahead of origin, it discards the operator's unpushed commits. Offer `branch -f` only when the local branch is an ancestor of `origin/<head>`. Otherwise tell the operator to push or rename the branch. Fork PRs are already refused by `adopt_pr` (repo.py:430-431). Workspace mode works, since the fetch runs on the adopting repo's path.

2. **R2: the existing test breaks, and a check can dirty the implementer's worktree.**
   - **The move itself works.** From implement submit, `_route_verify_comparison` → `_retry_or_block` sets `pending` with the reason, and the worktree is reused. The wave's review waits, because a `pending` sibling counts as implementing (execute.py:1292). A `baseline-error` still goes to `planGap`. Close-outs match today's behaviour: a no-change close-out returns before the check both then and now. Paths that re-review without a new implement step (the LF-60 refusal re-review, `_refresh_stale_close_outs`) review a candidate that was already checked, so no coverage is lost. `executeCheckRuns` has no reader other than its writer.
   - **The existing test breaks.** `test_a_repo_check_regression_at_integration_sends_the_task_back_with_the_diagnostic` (test_execute.py:582-607) submits a review result after the implement step. Under R2, the step after implement submit is a new implement step, so the test fails. The planned test is that test rewritten, so say "replace", and update the comments at execute.py:1422-1424 and in the test.
   - **Dirty worktree.** R2 runs the checks in the implementer's own worktree, before any review. A check that writes files (a tool cache, a formatter run without `--check`) leaves the tree dirty. The retried implementer then sees those files, and the next implement submit fails `is_clean` (execute.py:1340) and blames the implementer. VERIFY runs its checks in a fresh checkout (repo_checks.py:53-66). Either do the same at `task_head`, or re-check `is_clean` after the checks and name the check that wrote files.

3. **R3: hunk parsing and deletions.** `-U0` header shapes seen in the experiment:
   - `@@ -2 +1,0 @@`: a deletion only, no added line.
   - `@@ -4,0 +4 @@`: an omitted count means 1.
   - A new file shows `+1,2`.
   - A binary file shows "Binary files ... differ" with no hunk.
   - A path with a space prints `+++ b/sp ace é.txt` followed by a tab. Non-ASCII paths are octal-quoted unless `core.quotePath=false`.
   - A user's `diff.noprefix=true` drops the `b/` prefix (`+++ f.txt`).

   Run `git diff -U0 --no-renames base..head -- <file>` for each file `_diff_touched_files` already lists, and parse only the `@@` lines. That avoids parsing file names at all.

   A deletion-only change, such as removing a permission check, now gets no signal. Either scan the removed lines too (their text is in the diff) or state the gap. E11 does not depend on whole-file scanning: it compares the set of flagged files with the dispositions (postconditions.py:751-752). Neither does the code-reviewer prompt, which asks for one disposition per entry naming its file (roles.py:161-162).

4. **R5: the rescue text leaves the rescued commits stranded, and it fails on a terminal run.**
   - (a) `revise --pr <n>` turns PR comments into gaps (revise.py:23-47) and never reads a local branch. The text should say: after DELIVER opens the PR, push the rescue branch to the PR branch with `git -C <repo> push origin loop-spec-rescue-<local8>:<featureBranch>` (a fast-forward when local descends from the verified SHA). Then `loop-spec revise --pr <n>` gates the new head, because its adopted review and VERIFY cover `base..head`.
   - (b) The `<worktree>` command works only while the run is paused (`delivery blocked`). If another repo was delivered, the exit is `partially delivered` (deliver.py:265-267). That is terminal: `_finish_run` removes the feature worktree (controller.py:1491-1499), and DELIVER cannot be re-entered. Make the text depend on the exit.
   - (c) When `local_sha is None` (deliver.py:202-204), there is nothing to rescue. The `reset --keep` itself is correct. The feature branch is checked out in `worktrees/feature/<repo>` under the state home (execute.py:359-360), and that path is `deliver.run`'s `worktree`.

5. **R4: the reviser rule contradicts the planner rule it cites.** `dag_waves` orders tasks only by `dependsOn` (execute.py:104-124). Two same-wave tasks that edit one file therefore conflict at integration and re-fork (execute.py:1440-1459). The planner avoids this with "Give each file one owning task" (planner SKILL.md:39). Copy that rule instead of "group small gaps that touch the same files".

6. **D1 details.**
   - `_phase_probes` (controller.py:436) covers the phases that write a PLAN, not the entry phases. Driving it from the registry would give `route` and `direct` the repo-check probes. Keep it a named set.
   - There are two more hard-coded entry lists: `cli._REPAIR_COMMAND` (cli.py:196-197) and the `run_entry` error text (controller.py:95).
   - Building subparsers from `takes` gives `debug` a `--request-file` it lacks today (cli.py:46-47). That is harmless, but it contradicts step 1's "no behaviour change".

7. **`direct`: verifying pushes.** `git cat-file -e` proves a SHA exists locally, not that it was pushed. result.py:92 calls `workDelivered` "a delivery fact, not a label". For `push` actions, compare `repo.remote_head(repo, "origin", branch)` with the SHA. Add a `repo` field to each action so a workspace run can say which repo it touched.

8. **R6: the how-to relies on a phase the prompt does not carry.** `compose_prompt` takes `phase` but never writes it into the prompt (roles.py:201-240), so "when the prompt's phase is `verify`" names nothing a bound skill can read. Name an input that only VERIFY's reviewer receives (`range`, `full`, `rangeProbes`; verify.py:293-298), or accept a program change that adds the phase to the prompt.

9. **D4: the count of read sites.** I find one direct read of a phase module's own section, `store.state.get("verify")` at controller.py:1386, plus shared top-level keys: `executeRuns` (:1079) and `verifyRuns` (:1123, :1405). Build the list in `architecture.md` from a grep, not from the number 7.

## Checked and true

- Line citations match HEAD: controller.py:39, 61-95, 224, 436 and 649; cli.py:24 and 43-49; contract.py:158-159 and 235; controller.py:1618; roles.py:23; execute.py:357-358, 1425 and 1240-1302; deliver.py:201-205; migration-inventory-7.0.md:53; migrating-6-to-7.md:61. The one exception is `_SUBMIT_ROLE_MODULES`, which starts at controller.py:1591.
- The R1 defect is real. `merge-base` on an unfetched SHA fails ("fatal: Not a valid commit name"). Also, `execute._init` creates a missing feature branch at `baseSha` while recording `lastKnownHead` (execute.py:357-365), which is a drift pause for revise.
- D3 is safe. `ROLE_NAMES` is read only by test_roles.py:18 and 32. `reviser` loads, and its Example validates against its schema (I ran it: no errors).

## Rev 2

Verdict: revise

I checked rev 2 of `ea-runs-plan.md` against the code at `52334ce`. Every rev-1 finding is addressed where section 7 says. Rev 2 introduced five new defects that would fail at runtime; they are below.

Confirmed as correct in rev 2:
- **Cycle adoption is broken today, as the plan claims.** The KeyError is real. `_resolve_repos`' adoption dict has no `repo` key (controller.py:309-311). `_drive_phase` calls `_issue_adopted_review` at EXECUTE entry (:526), which indexes `adoption["repo"]` (:1555) before `execute._init` ever runs. The drift half of the claim needs a precise wording: drift happens only when the local PR branch already exists at the PR head. When the branch is absent, `_init` creates it at `baseSha`, which equals `lastKnownHead` (both are the merge-base), so there is no drift, only missing PR commits.
- **D2's gate matches today's routing.** It sends a step to a phase's adapter only when the implementation is `default`, the adapter kind is `stepped`, and the role is not null. Every step a default adapter issues has a role in today's table: execute.py:487/544/617, verify.py:263/305, iterate.py:85, debug.py:40, revise.py:89. External steps have `role: None`. The critic step is issued as phase `plan`, which is not stepped. The adopted review and the critic keep their step-id checks ahead of the lookup.
- **The R2 restore works.** In a task worktree I made a staged edit, an untracked nested directory, and an ignored `.cache/`. `git restore --staged --worktree . && git clean -fd` returned rc 0, `git status` came back empty, and `.cache/` was kept.
- **The generic rejection path handles route refusals.** Past the retry limit, `_reject_product` asks a `blocked` question with default `stop` (controller.py:1430-1437). An answer of `stop` ends the run `escalated`.

### Must-fix

1. **Route and direct products lack `inputsDigest` and `boundTo`.** Section 2 defines the products as `{exit, entry, pr, reason}` and `{exit, summary, actions, blocker}`. On an accepted exit, `_finalize` calls `_record_accepted_product`, which reads `product["inputsDigest"]` and `product["boundTo"]` (controller.py:1367), so both raise KeyError. Every ROUTES product schema requires `exit`, `inputsDigest` and `boundTo` (spec, plan, debug and iterate all do). Correction: `route.step` fills them from `ctx` (`boundTo: {requirements: null, plan: null}`). `schemas/direct.json` requires them too; `run_lead_phase` already passes `inputsDigest` to the lead (defaults.py:58).

2. **Copying `debug.py`'s shape means a refusal never re-asks the router.** `debug.step` returns its stored product whenever one exists (debug.py:52-56), and `revise.step` does the same (revise.py:102-104). After `_reject_product`, the next attempt calls `route.step`, gets the same stored product back, and has it rejected again. This repeats until the retry limit, then the blocked question defaults to `stop`. The router never sees the failed rule. Correction: store the router result with the attempt id that issued it. When a new attempt starts, issue a fresh router step, which `_drive_phase` then tags with `retryOf` and the reason (controller.py:557-563). Test: one refusal produces a second router step whose reason names the rule. Debug has the same replay on a B1/B2 rejection today. That bug predates this plan; list it as a follow-up.

3. **`_finalize` cannot carry the hand-off or the direct terminal results as written.** First, `route["next"]` is a fixed `(phase, mode)` pair (controller.py:1260), but the target of `routed` depends on the product's entry. Second, a terminal mode goes to `_write_terminal_result`, which falls through to `store.state["products"]["execute"]["exit"]` (controller.py:1529). For a direct run that value is `None`, so it raises TypeError. Correction: add a `routed` mode branch beside `rewind` that performs the hand-off; this is also Fable's rev-2 point 1. In `_write_terminal_result`, add a `direct` branch: `done` gives classification `direct`, and `incomplete` gives `escalated` with `blocker` as the reason. Name both sites in the plan.

4. **A later `revise --pr n` can resume a micro or cycle run instead of starting its own.** Rev 2 makes cycle and micro adoption work (L2 row 4: "micro with pr"). Their adoption records `number`. `_find_run_by_adoption_number` (controller.py:138-149) matches any run whose adoption has that number. So a later `revise --pr <n>` resumes the micro run. If that run has finished, `continue_run` returns its old result, and revise does nothing. Correction: match only runs with `run.cycleType == "revise"`. Add a controller test with a cycle run and a revise start on the same PR number.

5. **The `routed` result signals completion before revise runs, and `continue_run` returns it.**
   - `result.write` updates `last-result.json` (result.py:160-163). That file sits at `root.parent`, one per repo and shared across slugs (paths.py:83). It also prints `LOOP_SPEC_RESULT` (result.py:165). So an auto → revise hand-off publishes `status: completed` before revise has done anything. The report's harness would read that as the job being finished.
   - `continue_run` returns `Next(kind="result")` at its first check (controller.py:359), before any explicit branch runs, so `auto --slug <auto-slug>` returns the auto run's result, not the revise run's next step.

   Correction: write the routed `result.json` without updating `last-result.json` and without the marker (a `result.write` keyword argument). Put the routed branch, which opens `routedTo.slug` and continues that run, before the result check.

### Should-fix

1. **D0 checks the wrong import edge.** The real cycle risk is contract↔steps: steps.py:13 imports `contract`. `contract` must keep importing the step types inside functions, as it does today (contract.py:178, 205), or the types should move to a leaf module that imports nothing. The moved list must also include `Wait` (contract.py:192; test_execute_waves.py:22). "No re-export" also means the tests change: `test_iterate`, `test_debug`, `test_verify`, `test_execute_waves`, `test_execute`, `test_revise` and `test_deliver` import the types from `execute`, and `test_contract` patches `execute_module.IssueStep`/`IssueSteps`/`Product`/`Pause`. Name them in the plan.

2. **Workspace runs can adopt the wrong PR.** The hand-off passes `product.pr`, a bare number. `_resolve_repos` and `_run_revise_entry` both call `adopt_pr` on each repo and keep the first that adopts (controller.py:207-212, 297-300). If PR #n exists in two repos, the first repo wins. `prRefs` already records the repo. Pass the PR URL instead (`adopt_pr` accepts a URL), or pass the repo name.

3. **R3 still misses deleted files, and the diff parsing needs one more rule.**
   - `_range_style_probes` drops files that are absent at head (`(path / f).is_file()`, probes.py:1848). So deleting a whole file that holds a permission check still gives no signal. Scan the removed lines of deleted files too.
   - Scanning removed text requires the `-` body lines, so "parse only `@@` lines" is not enough. Read `+` and `-` lines only after the first `@@`: a removed line whose text is `-- x` prints as `--- x`, the same prefix as the file header. Skip `\ No newline at end of file`.

4. **X2's `pr` check fails on a merged, closed or fork PR, on every retry.** `repo.adopt_pr` returns `head_sha: None` for a PR that is not OPEN or whose head is a fork (repo.py:429-431). A PR the lead opened and then merged fails X2 each time it is checked. Read the head through `run_gh(repo, "pr", "view", url, "--json", "headRefOid")` instead.

5. **The direct lead gets no repo map, and one rule has no id.**
   - `run_lead_phase` passes `repos` only when the phase is `plan` (defaults.py:59). Actions must name a repo, so extend the condition to `phase in ("plan", "direct")`. This agrees with Fable's rev-2 point 2.
   - "`incomplete` requires a non-empty `blocker`" has no requirement id. Give it one (X3), or enforce it with `minLength` in `direct.json`.

6. **R6: VERIFY is not the only review with `full`.** The adopted-range review also gets `full: true` and `rangeProbes: {}` (controller.py:1574-1575). A bound reviewer keyed on `full` therefore also runs at EXECUTE entry for revise, and now for a cycle or micro run that adopts a PR. That is probably wanted, since it reviews the whole PR, but the how-to should say it rather than claim VERIFY only.

7. **The ids `R1`/`R2` are already used for other things.** This plan uses R1-R6 for report items, and code comments use R-numbers for hardening items (contract.py:162 "R1:", execute.py "R3:", result.py "R7:", deliver.py "R8:"). Choose another letter for the route postconditions.

8. **`fetch_pr_head`'s refusal gives the wrong repair when a state-home worktree holds the branch.** `checkout --detach` suits the operator's checkout. But the branch can also be held by a worktree an earlier terminal run left in its cleanup backlog. Name the worktree path from `git worktree list --porcelain` in the message, and give `git worktree remove <path>` when that path is under the state home.

## Rev 3

Verdict: revise

Every Rev 2 finding is folded in where section 7 says. Rev 3 still has two defects in the hand-off wiring that would fail at runtime, listed under Must-fix.

Checked and correct in rev 3:
- **Route attempt binding and retry.** Step records carry `attempt` (steps.py:145). After `_reject_product` sets `attemptId` to None, the next attempt finds a stored result from an older attempt and issues a fresh router step. `_drive_phase`'s LF-03 override then sets `retryOf` to `lastStepId` and the reason to the failed ids (controller.py:559-563). Within one attempt, `step` returns the product. A router step refused for missing evidence (LF-60) never reaches `on_submit`, so the next `step` issues a new one without needing an `on_step_refused` hook.
- **The hand-off check in `continue_run`.** `result.write` sets `state.result` (result.py:164), and `continue_run` returns on it at :359. The plan puts the hand-off check ahead of that return, which is what makes it work.
- **The revise-only filter in `_find_run_by_adoption_number`.** Revise runs get `cycleType: "revise"` when they are created (controller.py:226), and the LF-41 test asserts it.
- **Id names.** A1/A2 and X1/X2 collide with nothing in `postconditions.py` or `external.py`.

### Must-fix

1. **`_enter_phase` "resets `attemptId` (new)", which breaks every same-run hand-off.** `_drive_phase` writes `context.json`, records the attempt and prints the phase-start marker only when `attemptId` is None (controller.py:531-540). With an id already set, that block is skipped. `contract.invoke` then reads `attempts/<id>/context.json`, which does not exist: for spec and direct through `run_lead_phase`, and for debug through `_run_default_stepped` (contract.py:179). `_begin_compaction` can mint an id only because it hands a product straight to `_accept_product` and never invokes the phase. Correction: the hand-off sets `attemptId = None`, as `_finalize`'s forward transition does (controller.py:1318). Make the new id a parameter of `_enter_phase`, or leave `_begin_compaction` as it is.

2. **The `routed` branch must end `_finalize`.** If it runs "beside the existing `rewind` one" (controller.py:1261) and `_finalize` then carries on, lines 1317-1321 set `phase.current = None` and `entry = "routed"` on top of the hand-off. Put the branch after the phase-end marker and event (controller.py:1293-1294), do the hand-off there, and return, as the terminal branch does (controller.py:1313-1315).

### Should-fix

1. **The PR passed at hand-off is still a bare number, and a workspace still has an ambiguity.**
   - The revise hand-off passes `product.pr` (plan line 271), a bare number, which contradicts the URL rule four lines above it.
   - The facts shape `{ref, number, repo, adoptable, reason}` has no `url` field (`ref` can be `#12`), so there is no URL to pass.
   - The router returns only a number, so when two workspace repos both have an adoptable PR #n, A2 accepts it and the hand-off cannot tell which one is meant.

   Correction: add `url` (from `adoption.url`) to each fact. Make A2 refuse a number that matches adoptable facts in two repos, or have the router return the URL. Pass the URL to both hand-offs.

2. **`direct`'s `inputsDigest`/`boundTo`: the conditional can be settled now, and its fallback is unsafe.** `run_lead_phase` adds neither field. It validates the lead's result file and copies it (defaults.py:28-33). The lead writes both fields because the step's schema is `load_schema(phase)`, and spec and plan require them. So `schemas/direct.json` should require both, and the direct prompt should state `boundTo: {requirements: null, plan: null}`. Drop the fallback "`defaults.py` adds them for every lead kind": for plan it would overwrite the planner's own `boundTo`, which `bound_ok` checks.

3. **The in-house validator does not support `if`/`then`.** `schema.validate` handles `$ref`, `const`, `enum`, `type`, `minLength`, `pattern`, `minItems`, `items`, `required`, `properties`, `additionalProperties`, `oneOf` and `anyOf` (schema.py:32-110). An `if`/`then` block is silently ignored, so the non-empty `blocker` rule would not be enforced. Express it as a `oneOf` with two branches: `exit` const `done` with a null `blocker`, and `exit` const `incomplete` with a string `blocker` of `minLength: 1`.

4. **Files and table entries that rev 3 leaves out.**
   - `schemas/route.json`. `contract._accept_product` (contract.py:110) and `Boundary._validates` load the product schema by phase name, and `load_schema` raises FileNotFoundError when the file is missing.
   - `"route"` and `"direct"` entries in `external.PHASE_EXITS` and `external.PHASE_POSTCONDITIONS` (external.py:15-25), next to `POSTCONDITION_TEXT`.

5. **R6's open question is already answered.** The adopted-range review also gets `rangeProbes: {}` (controller.py:1575). A bound reviewer keyed on `rangeProbes` therefore runs in both the VERIFY review and the adopted review. The how-to should say so now, rather than "check at implementation".

6. **The router tests still use the old names.** Plan line 341 says `_r1`/`_r2`; make it `_a1`/`_a2`.

7. **Pre-existing follow-up, now reachable through `auto` and the live runs: revise resumes a finished run.** `_run_revise_entry` resumes any run found for the PR number, including a terminal one: state exists, so it calls `continue_run`, which returns the old result (controller.py:214-221). A second "address the review comments on <PR>" routed to revise therefore returns the first revise run's result and handles none of the new comments. Name it as a follow-up, and keep L1 and L2 from reusing a PR that already has a finished revise run.

## Rev 4

Verdict: revise

I checked only the Rev 3 fixes and what they touch. O3-M2 and O3-S1 through O3-S7 are correct. The fix for O3-M1, as rev 4 applies it, breaks the debug and revise entries.

Checked and correct:
- **O3-S3.** I ran the two-branch `oneOf` through `loop_spec.schema.validate`. It accepts `done` with a null `blocker` and `incomplete` with a non-empty `blocker`. It rejects `incomplete` with `""`, `incomplete` with null, and `done` with a string.
- **O3-S5.** VERIFY's `rangeProbes[repo]` is always a filled dict (probes.py:1851-1863), and the adopted review sends `{}` (controller.py:1575). "Non-empty `rangeProbes`" therefore picks out VERIFY's review.
- **O3-S1, O3-S2, O3-S4, O3-S6, O3-S7.** Each lands where section 7 says.

### Must-fix

1. **"`_begin_compaction` then uses `_enter_phase` too" breaks debug and revise.** `_begin_compaction` needs a minted `attemptId`: it records `phase.attemptId = spec_attempt_id` and accepts the compacted SPEC under that id (controller.py:752-761). The approval question is asked under that id. When the answer arrives, `continue_run` reads `phase.attemptId` (controller.py:419-423) to find it and accept the product. If `_enter_phase` leaves `attemptId` as None there, one of two things follows:
   - With the approval pending, the product is accepted under attempt None and the answered question is never matched.
   - With nothing pending, `_drive_phase` mints a fresh attempt and runs the spec-writer over the compacted SPEC.

   Correction: `_begin_compaction` calls `_enter_phase` and then sets `phase.attemptId` to its own new id, as `_resume_compaction` already does. Alternatively, `_enter_phase` takes the id as a parameter, with None for the hand-off.

### Should-fix

1. **Two leftover sentences contradict the fixes.** Line 271 still reads `_ENTRY_START["revise"](pr=product.pr, ...)`, while the bullet above it says every hand-off, revise included, passes the matching `prRefs` entry's `url`. Lines 250-251 still say the `routed` branch sits "beside the existing `rewind` one", while the hand-off bullet says it comes after the phase-end marker and returns. Make both sentences match the fixes, or an implementer may follow the stale one.

## Rev 5

Verdict: go

I checked only O4-M1 and O4-S1.

1. **O4-M1 is fixed.** `_begin_compaction` now calls `_enter_phase` and then sets its own new `attemptId`. The compacted SPEC's approval is therefore asked and looked up under a real id (controller.py:419-423), as it is today. Only the router hand-offs leave `attemptId` as None, which `_drive_phase` needs in order to write `context.json` (controller.py:531-540). One small change comes with it: `_enter_phase` also zeroes `retries`, which `_begin_compaction` does not do today. That is harmless. A debug product has already had its retries reset by `_record_accepted_product` (controller.py:1415), and the revise product has no rejection path.
2. **O4-S1 is fixed.** The revise hand-off now passes `pr=<that URL>`, matching the rule that every hand-off passes the URL. The `routed` branch is described in one place only: after the phase-end marker, then the hand-off, then a return.
