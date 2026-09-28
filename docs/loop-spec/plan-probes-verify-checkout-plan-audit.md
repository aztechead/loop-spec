# Audit: PLAN fact probes, security signals, VERIFY checkout key (7.1.1)

For the implementer of `plan-probes-verify-checkout-plan.md`. Every finding was checked
against branch `v7` at `a73f626`. Paths are under `skills/loop-spec/program/` unless
given in full. Findings F1-F3 in the plan are all confirmed (controller.py:430-440,
execute.py:524/531/584/602, verify.py:114-127/287/293, postconditions.py:724-741,
roles.py:160, iterate.py:56, controller.py:1548, test_postconditions.py:410-417).

## Findings

1. **should-fix** — `tests/test_iterate.py` breaks under D7 and the plan does not list it.
   Its fixture builds the cwd by name (`test_iterate.py:73`, `:188`, `:208`:
   `checkouts_dir / f"verify-{head[:12]}"`) and never sets `store.state["verify"]`.
   Fix to the plan: add to Tests: "test_iterate setUp (and the two head-moving tests)
   set `store.state["verify"] = {"checkouts": {"repo": str(checkout)}}` instead of
   mkdir-by-name". And in `iterate.py:56` read
   `(store.state.get("verify") or {}).get("checkouts", {}).get(first_repo)`, keeping
   the existing `LoopSpecError` when it is None or not a directory (iterate.py:57-61).

2. **should-fix** — `tests/test_controller.py:2361-2364` (`PhaseProbesTests`) calls
   `controller._phase_probes(state, phase)` with a bare dict; change 2 adds a `paths`
   argument. Name this test in the plan's Tests list: pass a `FeaturePaths` (any tmp
   root) and assert `named` is absent when the request names no file, so the existing
   `repoChecks` assertions keep holding with `probe.call_count == 2`.

3. **should-fix** — D4 `_relativize` must strip two prefixes, `str(root)` and
   `os.path.realpath(root)`. Several probes go through `os.path.realpath`
   (probes.py:592-605, 847-854, 873, 1061). Measured on a `/var/folders/...` checkout
   (macOS symlink to `/private/var`): today every emitted path is in the un-resolved
   form (`duplication[].file/partnerFile`, `houseStyle.sample[]`,
   `indirection.findings[].file/calledFrom`, `securitySignals[].file`), but a state home
   under a symlink only stays correct by accident of which branch each probe takes. One
   tuple of prefixes, same helper.

4. **should-fix (simpler)** — D5 relativizes security signals in `_range_style_probes`.
   The root cause is `security_signal` itself (probes.py:1013-1020): it iterates
   `_resolve_all(root, files)` and stores the resolved path. Change that one function to
   `for rel, path in zip(files, _resolve_all(root, files)): ... {"file": rel, ...}`.
   Then `plan_probes` and `_range_style_probes` both emit repo-relative files with no
   post-processing, and `_relativize` (finding 3) is only needed for the other keys.
   `tests/test_probes.py:76-96` assert `signal`, `reason` and length only; nothing breaks.

5. **should-fix** — D5 drops `securitySignals: []` from the adopted review
   (controller.py:1548) but leaves `rangeProbes: {}`, so that reviewer sees no
   `inputs.rangeProbes.securitySignals` key. Make the roles.py:160 sentence conditional
   ("when `inputs.probes.securitySignals` / `inputs.rangeProbes.securitySignals` lists
   any"); otherwise the adopted review is told to disposition a list it cannot find.

6. **should-fix** — Change 1 lists what to delete but not the docstrings that name the
   feature: probes.py:3-4 (module docstring, "dependency-doc grounding") and
   probes.py:1889-1891 (`plan_probes` docstring). Also delete `_DP_MANIFEST_ECOSYSTEM`
   (probes.py:1227) with the `_dp_*` helpers. `docs/loop-spec/migration-inventory-7.0.md:412`
   and `ROADMAP-7.0.md:911` are historical records; leave them.

7. **should-fix** — D2 says "no path character on either side" without defining it.
   Fix the sentence: a path character is `[A-Za-z0-9_./-]`; anything else (space,
   backtick, quote, bracket, comma, colon, end of text) is a boundary. Say the cap
   applies after sorting (first 20 of the sorted set) so the test is deterministic.

8. **note** — D6 wording. `diff_probes` covers `feature_head..task_head`
   (execute.py:1339), but a re-opened task that owns integrated commits keeps
   `reviewFrom` (execute.py:865-867), so its review diff is wider than the probes'
   diff. "a task whose reviewed diff touches a file with a security signal" overstates;
   "a task whose probed diff touches ..." is what E11 can check. Adjust the E11 text in
   both `external.py:58` and phase-interface row 169 (the plan's "E11 row").

9. **note** — D6 must read `task_state.get("probes")`: an adopted task's state entry
   (execute.py:1137-1150) is built without the key. The plan already says "missing key:
   none"; this just confirms the case exists. E11 runs only on `integrated`
   (postconditions.py:77), so a blocked task with probes and `review: None`
   (execute.py:1360-1364) never reaches it.

10. **note** — D7's "left alone" claims hold: `_run_verify_reruns` creates and removes
    `verify-<criterion>-<head12>` inside one `try/finally` (controller.py:1128-1135);
    `_base_layers` likewise (verify.py:132-138); `clean_checkout` refuses an existing
    destination (repo.py:308-313). `verify` state is assigned only at verify.py:214
    and re-initialised on input change (verify.py:500-506), so ITERATE reads the
    checkouts of the VERIFY that passed at the current heads (same `_heads` /
    `_touched_repos`, verify.py:32-41 vs iterate.py:26-35).

11. **note** — Version lockstep is 10 files: `.claude-plugin/plugin.json`,
    `.claude-plugin/marketplace.json`, README line 7, and seven `skills/*/manifest.toml`
    (cycle, debug, deliver, execute, iterate, loop-spec, micro), all at 7.1.0 now.
    CHANGELOG.md exists at the repo root.

12. **note** — `context.json` declares `probes` as a bare `{"type": "object"}`
    (schemas/context.json:77), so `named` needs no schema change. The reviewer schema's
    `securityDispositions[].signal` is a free string (roles/code-reviewer/schema.json:80-88),
    so "signal = file path" needs no schema change either.

## Answers to the plan's questions

- **Does `build_envelope` run more than once per PLAN attempt?** No. It is called once,
  inside the `attemptId is None` branch (controller.py:508-516). It runs again only when
  a new attempt starts: every rejection, critic remediation or disapproval resets
  `attemptId` (controller.py:90, 983, 1292, 1402, 1444). So the checkout + probes cost is
  once per attempt, not per step. At one `git worktree add --detach` plus probes over at
  most 20 files, no caching; a cache keyed on (repo, sha, files) would outlive the
  request text it was derived from and is not worth the state.
- **Is `task_state["probes"]` at E11 time the probes of the accepted review?** Yes.
  Probes are written in one place, `_on_implement_submit` (execute.py:1339), and the
  three resets all precede a fresh implement whose submit rewrites them (`_refork`
  execute.py:852; `_reopen` reused-branch execute.py:885) or a no-change close-out
  reviewed over the empty range with probes `None` (execute.py:1314-1318). The product's
  `review` (execute.py:1125) is `task_state["review"]`, set only on the accepted review
  submit (execute.py:1370-1374). Review retries (`retry_status="probing"`,
  execute.py:792, 1535) re-issue the review with the same probes. A wave review is
  applied per task (execute.py:1348) and touches no sibling's probes.
- **Any consumer of `plan_probes()["docs"]` or `docs_probe` outside probes.py and
  tests?** No. A grep over `skills/`, `examples/` and `docs/` finds only
  probes.py:1247/1899 and tests/test_probes.py:13, 119, 129, 184 (the last asserts the
  `docs` key in `plan_probes`, which the plan's test change removes).

VERDICT: go
