# Plan: PLAN fact probes, security signals, VERIFY checkout key (7.1.1)

For the auditor of this change and the implementer after a `go`. Two follow-ups from the
7.1.0 handoff, fixed on PR #109 (branch `v7`). Paths below are under
`skills/loop-spec/program/loop_spec/` unless given in full.

## Findings this plan acts on

F1. `probes.plan_probes` has no production caller. `controller._phase_probes` gives
PLAN only `repoChecks`, yet `roles/planner/SKILL.md` step 1 tells the planner to read
house style, duplication, indirection, security signals and dependency docs, and
`docs/loop-spec/phase-interface-7.0.md` (row `probes`, line 29; PLAN "Inputs", line 128)
says PLAN gets probes on the files the request names.

F2. Security signals are dead end to end, same root cause (the only producer was meant
to be the PLAN probes):
- `execute.py:524,584` and `verify.py:287` read `ctx["probes"]["securitySignals"]`;
  `_phase_probes` returns `{}` for execute and verify, so it is always empty.
- `postconditions._e11` reads `state["probes"]["securitySignals"]`, which nothing
  writes. Its body does `files & set(signals)` where signals were meant to be dicts
  (`security_signal` returns `{"file", "signal", "reason"}`), which would raise
  TypeError; the test (`test_postconditions.py:410`) feeds a list of path strings.
- `security_signal` returns `file` as an absolute path (`_resolve_all`), while execute
  filters with `s["file"] in plan_task["files"]` (repo-relative). Never matches.
- `roles.py:160` tells the code reviewer to disposition each signal in
  `inputs.probes.securitySignals`; execute passes them as top-level
  `inputs.securitySignals`, verify as `inputs.securitySignals` beside `rangeProbes`.

F3. `verify._verify_checkout` names the checkout `verify-<head12><suffix>` and returns an
existing directory unchecked: two workspace repos at one SHA share a checkout; a changed
`prepare` at an unchanged head reuses the old prepared tree; and a prepare that fails
leaves the directory behind, so the next `_init` returns it unprepared.
`iterate.py:56` rebuilds the same name to find its cwd.

## Decisions

D1. Wire the PLAN probes (not drop them). Scope: phase `plan` only. DEBUG and REVISE
keep `repoChecks` only; their role prompts claim nothing more.

D2. Which files: the tracked files at the SHA `_phase_probes` already uses per repo
(base, or the adopted head for the adopted repo) whose path the request text or the
approved SPEC product (goal, boundaries, criteria text, decisions text) names. A path
counts when the full repo-relative path appears with no path character on either side,
or when its basename (must contain a `.`) appears the same way and is unique among that
tree's tracked files. Sorted, capped at 20 (`_NAMED_FILES_CAP`). No named file in a repo:
no probe run and no entry for that repo. Rationale: PLAN has not chosen files yet; the
text is the only deterministic source, and it is what the interface doc already says.

D3. No network in the program: `plan_probes` drops the `docs` key and `docs_probe`
(plus `_dp_*` helpers and their tests) is deleted, since it has no other caller. `deps`
stays (offline). The planner has WebFetch and is told to fetch current docs for a listed
dependency whose API a task uses.

D4. Read at the SHA, not the working tree: per repo with named files, a clean checkout
`plan-probes-<repo>-<sha12>-<uuid8>` under `paths.checkouts_dir`, probes run there, the
checkout removed in `finally` (`repo_module.remove_worktree(..., force=True)`), same
shape as `verify._base_layers`. Every path string in the output that starts with the
checkout root is rewritten repo-relative (one small recursive helper in probes.py).

D5. Security signals move to review time, where the files are known: `_range_style_probes`
adds `"securitySignals"`: `security_signal` over the files that range touched, each
`file` repo-relative. So EXECUTE's per-task `task_state["probes"]` (diff_probes, which
already covers close-outs via the diff) and VERIFY's `rangeProbes` both carry them.
The separate `securitySignals` input keys go (execute.py 524/531, 584/602; verify.py
287/293; controller.py 1548). The reviewer reads them at `inputs.probes.securitySignals`
(EXECUTE) or `inputs.rangeProbes.securitySignals` (VERIFY); `roles.py:160` and
`roles/code-reviewer/SKILL.md` say so. A disposition's `signal` field is the signal's
file path.

D6. E11 becomes: for each task in the EXECUTE product, the signals are
`state["execute"]["tasks"][id]["probes"]["securitySignals"]` (None probes or missing key:
none); every signal's `file` must appear as the `signal` of one of that task's review
`securityDispositions`. `state["probes"]` is no longer read. Text change in
`external.POSTCONDITION_TEXT["E11"]` and phase-interface E11 row, same diff:
"for a task whose reviewed diff touches a file with a security signal, the review record
carries a disposition naming that file".

D7. VERIFY checkout key: `verify-<repo>-<head12>-<p8><suffix>` where `p8` is the first 8
hex of sha256 of `prepare or ""`. `_verify_checkout` takes `repo_name`. On prepare
failure it removes the checkout before raising. `iterate.py:56` reads
`store.state["verify"]["checkouts"][first_repo]` (verify state is never cleared) instead
of rebuilding the name. Left alone, with reason: `controller._run_verify_reruns`
(`verify-<criterion>-<head12>`), `execute-*`, `observe-*` and `verify-base-*` are created
and removed inside one call, sequentially, and `clean_checkout` refuses an existing
destination rather than reusing it.

## Changes

1. probes.py: `named_files(repo_path, sha, texts) -> list[str]` (uses `git ls-tree -r
   --name-only <sha>` via `repo_module.run_git`); `plan_probes` without `docs`; delete
   `docs_probe` and `_dp_*`; `_relativize(obj, root)`; `securitySignals` in
   `_range_style_probes` (repo-relative).
2. controller.py `_phase_probes`: needs `paths` (for `checkouts_dir`); for `plan` add
   `"named": {repo: {"files": [...], **plan_probes(checkout, files)}}` per D2/D4.
   Update its caller in `build_envelope`. Drop `securitySignals: []` at line 1548.
3. execute.py, verify.py: remove the separate `securitySignals` inputs (D5).
4. postconditions.py `_e11` per D6; external.py E11 text.
5. verify.py `_verify_checkout` per D7 (both callers pass the repo name); iterate.py:56.
6. roles.py:160, `roles/code-reviewer/SKILL.md` (signal = file path, where to find
   them), `roles/planner/SKILL.md` step 1 (read `inputs.probes.named.<repo>`: house
   style, duplication, indirection, security signals, deps; fetch docs yourself).
7. docs/loop-spec/phase-interface-7.0.md rows 29, 128, E11.
8. Version 7.1.1 in `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`,
   README `Current version:`, every `skills/*/manifest.toml`; CHANGELOG entry.

## Tests (one focused test per behavior)

- test_probes: `named_files` (full path, unique basename, ambiguous basename skipped,
  untracked file ignored); `range_probes` security signal file is repo-relative;
  remove `docs_probe` tests.
- test_controller (or wherever `_phase_probes` is covered): plan envelope for a repo
  whose request names a file gets `named.<repo>.files` and a relative signal path, and
  no `plan-probes-*` directory remains; a repo with no named file has no entry.
- test_postconditions `test_e11`: signal on the task's probes with and without a
  disposition naming the file.
- test_verify: two repos at one SHA get two checkouts; a changed prepare gets a new
  one; a failing prepare leaves no directory.
- Full suite green (`python3 -m unittest discover -s tests`, 575 before).

## Live run

One live cycle on the `checks-cli` fixture with a request that names a file, frozen
plugin clone at the commit under test; record in `docs/loop-spec/live-runs-7.0.md` that
the PLAN envelope carried `named` probes.

## Questions for the auditor

- Does `build_envelope` run more than once per PLAN attempt (critic, retries), making
  the checkout cost repeat? If so, is caching by (repo, sha, files) in the attempt dir
  worth it or is the repeat acceptable?
- Is `task_state["probes"]` at E11 time always the probes of the review that was
  accepted (resets at execute.py 852, 885, 1316)?
- Any consumer of `plan_probes()["docs"]` or `docs_probe` outside probes.py and tests?
