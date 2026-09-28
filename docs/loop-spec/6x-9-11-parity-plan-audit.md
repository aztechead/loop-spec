# Audit: 6.9.1–6.11.0 parity plan (7.2.0)

For the plan's author. Read-only audit of `docs/loop-spec/6x-9-11-parity-plan.md`
against `v7` at cbb2143 and the 6.x commits it cites. Paths under
`skills/loop-spec/program/` unless given in full.

## Findings

1. **should-fix, G6.** Making `existingCode` `required` breaks every plan-shaped
   fixture in the suite and buys nothing the program can check (an empty array is
   allowed anyway). `plan.json` has `additionalProperties: false` and P1 validates
   (`postconditions.py:329`), so every fixture without the key fails P1:
   `tests/test_schema.py:98-108` (minimal plan instance), `test_controller.py` (16
   `mustFlip` fixtures), `test_execute.py` (10), `test_verify.py` (3), `test_debug.py`,
   `test_revise.py`, `test_render.py`, `test_postconditions.py`, `test_execute_waves.py`,
   plus the planner/debugger/reviser `## Example` blocks (`tests/test_roles.py:28-36`
   validates each against its schema). Fix: make `existingCode` optional (absent =
   none); P8 checks entries when present; the planner SKILL step and the Example make
   the planner fill it. Fixture churn drops to the three role examples and the two
   embedded schemas (finding 2).

2. **blocker, G6.** `debug.json` and `revise.json` carry their own copy of the plan
   shape (`schemas/debug.json:121-129`, `schemas/revise.json:73-76`), and
   `tests/test_schema.py:172-190` pins `debug.json $defs.plan` equal to `plan.json`
   minus the envelope. Both compacted PLAN halves go through P1-P7 via
   `_begin_compaction` -> `_accept_product` (`controller.py:722-760`; ROUTES `debug`
   `reproduced` at `postconditions.py:104`), so P8 is reachable for them. The plan's
   "auditor to confirm" is now confirmed: add `existingCode` (same shape) to both
   embedded defs in the same diff, add `P8` to `ROUTES["debug"]["reproduced"]`,
   `external.PHASE_POSTCONDITIONS["plan"]` (`external.py:27`), and the doc rows at
   `phase-interface-7.0.md:145` and `:315` ("P1 to P7"). Debugger and reviser SKILL
   Examples gain `"existingCode": []` only if the field is required (finding 1).

3. **should-fix, G6 (P8 SHA).** P8 reads cites at "the plan SHA (base, or adopted
   head)". On a PLAN remediation after EXECUTE integrated commits (`plan gap` from
   EXECUTE or VERIFY, `postconditions.py:79,87`), the planner may legitimately
   `extend` code an earlier task of this run added; that path does not exist at base
   and P8 would reject a correct plan. Fix: resolve the cite at the base/adopted SHA
   (`controller._phase_probes` rule, `controller.py:439-440`), and when
   `store.state.get("execute")` exists also accept the repo's current head
   (`state["execute"]["repos"][name]["head"]`, `execute.py:952`). Say which SHA in the
   P8 text.

4. **note, G6 (fit).** P8 is the right v7 shape (program facts: repo in state, task ids
   in the plan, path exists at a SHA via `git show <sha>:<path>`, line range within the
   blob; the role decides reuse/extend/new). It is not over-built once finding 1
   lands. Two cuts: drop the "`new` entry has a non-empty `reason`" P8 rule and use
   schema `minLength: 1` on `reason` instead (P1 already validates); drop `repo` from
   the entry and take it from the cited tasks' `repo` only if all listed tasks share
   one, otherwise keep `repo` (multi-repo plans exist, `postconditions.py:387`). Keep
   `repo`; it is one key. The existing `git show` idiom is `repo_module._git(repo,
   "show", f"{sha}:{name}")` (`probes.py:1771`); reuse it, no new helper.

5. **should-fix, G6 (implementer input).** The plan says "`execute.py` ~470"; the site
   is `_implement_request`, `execute.py:457-478` (`inputs` dict at 469-475). Filter
   `plan["existingCode"]` by `task_id in entry["tasks"]` and add as
   `inputs["existingCode"]`. `render.py:31-33` renders the plan product per task; the
   PR body needs no change.

6. **should-fix, G1 (widen once).** vitest and cargo summaries keep counts too:
   ` Test Files  1 failed | 40 passed (41)` and `test result: FAILED. 1 passed; 1
   failed; ...` normalize with digits intact (probed). The 7.1.0 comment at
   `baseline.py:188` claims vitest coverage it does not have. One version bump should
   close all of them. Regexes accepted (applied after `_LINE_NO`/`_TIME`, so the
   pytest suffix is already `(0:<LINE>)`):
   - pytest/unittest-q: `^[=\s-]*\d+ \w+(?:\s*[,|]\s*\d+ \w+)*(?: in <TIME>(?: \(\d+:<LINE>\))?)?[=\s-]*$`
   - jest: `^(?:Tests?|Test Suites|Snapshots):\s+.*\b\d+ total$`
   - vitest: `^(?:Test Files|Tests)\s+\d+ \w+(?:\s*\|\s*\d+ \w+)*\s*\(\d+\)$`
   - cargo: `^test result: \w+\. \d+ passed; \d+ failed;.*$`
   All five (with the unchanged unittest one) verified against the samples above;
   `AssertionError: expected 1 errors` and `FAILED ... assert 1 == 2` keep their digits.

7. **should-fix, G1 (pass-token regex).** "Last word is a pass token" misses pytest
   `-v` (`... PASSED [ 50%]`, the exact 6.9.1 test case, 9d84349
   `tests/lib/verification-baseline.test.sh`) and xdist (`[gw0] [ 50%] PASSED ...`).
   Match 6.9.1 (`\bPASSED\b` anywhere) plus the leading forms. Accepted:
   `^\s*(?:ok\b|✓|√|PASS\b|--- PASS:)|\bPASSED\b|\.\.\. ok\s*$`, applied to the
   ANSI-stripped raw line in `fingerprint_candidates` (`baseline.py:227`), before
   `_FAILURE_MARKER`. Verified: drops the 8 pass shapes, keeps `FAILED`, `not ok`,
   `FAIL src/...`, `--- FAIL:`, `... FAILED`. Strip ANSI first: `\b` fails between
   `m` of `\x1b[32m` and `PASSED`.

8. **note, G1 (Q1 answered).** Nothing compares `NORMALIZATION_VERSION` by literal.
   `controller.check_compatible` uses the constant (`controller.py:261`);
   `compare_to_baseline` compares run-to-run (`baseline.py:725`). Tests use literal
   `1` against the constant or against literal `2` on the other side
   (`tests/test_baseline.py:239,469`; `tests/test_controller.py:1751,1982,2333`), so a
   bump to 3 changes no outcome. `capture_baseline` stamps the constant
   (`baseline.py:592`). No other store.

9. **should-fix, G2 (handler guard).** `cli.main`'s handler (`cli.py:243-246`) also
   catches errors from `emit` (no `project_root` attribute, `cli.py:69-72`) and
   `phase` (`--project-root` optional, `cli.py:55`). `args.project_root` in the handler
   raises `AttributeError`/formats `None`. Guard: rewrite only when
   `getattr(args, "project_root", None)` is set; otherwise print the repair as is.

10. **note, G2 (Q2 answered).** Parsers taking both flags: the ten
    `_CONTROLLER_ENTRIES` (`cli.py:22-23,38-40`), `status` (`:49`), `submit` (`:57-61`),
    `answer` (`:63-67`); `phase` takes them optionally (`:55`); `emit` takes neither.
    Repair strings naming a command: 18 (steps.py:196,217,223,227,338,359;
    ledger.py:108; questions.py:27,58,64; controller.py:84,111,199; cli.py:168;
    verify.py:537; state.py:32,63,71). The one non-command mention is
    `controller.py:265` ("the loop-spec version that started it"), without backticks,
    so an anchor on `` `loop-spec (<sub>)\b `` skips it. Accepted rewrite:
    `re.sub(r"`loop-spec (status|cycle|micro|debug|revise|spec|plan|execute|verify|iterate|deliver|submit|answer)\b", ...)`
    inserting `` `<launcher> <sub> --project-root <q(root)> --state-home <q(home)> `` with
    `shlex.quote`. `state.py:32` (`loop-spec status --slug <slug>`) comes out with the
    flags before `--slug`, which argparse accepts. Launcher path
    `Path(__file__).resolve().parents[1] / "loop-spec"` is correct
    (`program/loop-spec` exists; there is no `skills/loop-spec/loop-spec`). No test
    asserts a repair string's `loop-spec` text (`grep` of tests: only
    `test_deliver.py:181` comment, `test_roles.py:80` a path).

11. **note, G2 (stubs).** The two operator lines are `skills/*/SKILL.md:56` and `:65`
    in each of the 12 stubs (`loop-spec/SKILL.md:72,78-81` variant). `${CLAUDE_SKILL_DIR}`
    and `${CLAUDE_PLUGIN_DATA}` are substituted inline in skill content (memory:
    host facts), so a full launcher line printed to the operator is right. Twelve
    identical edits; no stub test exists.

12. **note, G3.** `_handle_rewind` reason at `execute.py:960-963`; the entry is
    `store.state["verifyRuns"][criterion]` with `rerun` (a `CommandRun.to_dict()`),
    written per VERIFY submission (`controller.py:1161`) and popped for a malformed
    command (`:1131`). `describe_failure(Comparison("regression", run.failure_identities,
    ""), run)` gives ids for a parsed run and `tail` for an unparsed one
    (`baseline.py:656-672`). Check remediations put the same lines in the task title
    (`verify.py:448`), so "already do this" holds. Add one guard: append only when
    `rerun["sha"] == feature_head` (`execute.py:952`), since the entry is keyed by
    criterion and survives a later attempt whose verdict was not `pass`/`fail`.

13. **note, G4.** Confirmed: reuse at `controller.py:1139-1147` matches repo, sha,
    command only; `prepare` comes from the plan at `:1118`. Compare with
    `prior.get("prepare") == prepare` so an entry written before 7.2.0 (no key) still
    reuses when the plan's prepare is `None`; `tests/test_controller.py:1923` builds such
    an entry. No test asserts entry equality.

14. **note, G5.** Confirmed: `pr_title` (`deliver.py:33-39`) is fed `spec_product["goal"]`
    (`:239-240`) and never splits lines. `" ".join(title.split())` before the length
    test is the whole fix; `tests/test_deliver.py:380-391` still holds.

15. **note, items not changed.** Agreed on all. 6.11.0's opt-in integration checks
    (`LOOP_SPEC_INTEGRATE_REPO_CHECKS`) are `checks` run after every task
    (`execute.py:1403`, planner SKILL step 6). c57cdce's stuck note guards a lead that
    re-calls `next`; 7.x has no `next`. The "Critical only" claim is ROADMAP-7.0.md:351-355.

16. **note, Q3.** P1 runs at submission only (`Boundary.check`, `postconditions.py:259`);
    nothing re-validates a stored product on resume (`grep validate(`: `contract.py:97,110`
    for the `phase` subcommand's files, `steps.py:239` for step results). An old run
    resumes with its recorded plan untouched; a PLAN remediation produces a new
    product under the new schema. No `check_compatible` change. With finding 1 the
    question is moot.

17. **note, tests.** Add to the plan's list: `test_schema` minimal plan instance with an
    `existingCode` entry; `test_schema` debug/revise def equality already pins finding
    2; `test_roles` example validation covers the planner Example once it carries one
    `reuse` entry. Keep G1's version bump test as is.

## Plan fixes, in order

- G6: `existingCode` optional; add to `debug.json`/`revise.json` defs; P8 in
  `ROUTES["plan"]["ready"]`, `ROUTES["debug"]["reproduced"]`, `external.py:27,37+`,
  doc rows 135-145 and 315; P8 accepts a cite at base/adopted SHA or the repo's current
  execute head; `reason` via schema `minLength`.
- G1: five summary regexes, pass-token regex on the ANSI-stripped raw line, version 3.
- G2: `getattr` guard in the handler; fixed subcommand list; `shlex.quote`.
- G3: `rerun["sha"] == feature_head` guard.
- G4: `prior.get("prepare")`.


## Round 2

Revision 1 adopts every round-1 finding; each item was re-checked against the code.

1. **note, P8 line range.** The rule `a <= b <= line count` should also require
   `a >= 1` (the schema pattern `^[0-9]+-[0-9]+$` admits `0-3`). One comparison.
2. **note, P8 execute head.** The key path `state["execute"]["repos"][<repo>]["head"]`
   is the one `execute.py:167,431,870` reads; correct.
3. **note, cargo regex.** `test result: ok. 5 passed; 0 failed; ...` carries no failure
   marker, so it is never a candidate; the regex only matters for `FAILED.` lines. Fine.
4. **note, revise.json.** Its plan def is not pinned by a test the way debug.json's is
   (`tests/test_schema.py:172`). Optional: one more `assertEqual` there, same shape.
5. **note, G2 stub.** `skills/loop-spec/SKILL.md:78-81` already prints the full launcher
   line for `answer`; only its `:72` submit line changes there.

No blockers, no should-fixes remain.

VERDICT: go
