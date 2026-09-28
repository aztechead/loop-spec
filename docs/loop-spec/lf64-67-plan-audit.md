# Audit of plan-lf64-67 (read-only, against v7 @ 58639ed)

Verdict: **go with corrections**. Root causes for all four hold. LF-64 works end to end
as written. LF-65 is over-built: `resume` cannot lead anywhere but the E4 pause, so drop
the head-adoption machinery and make both pauses fix-and-re-enter/stop. LF-66 must land
after LF-65 step 1 or the default answer produces an in-process infinite loop.

## LF-64: VERIFY has no exit for an open Critical finding

1. Root cause confirmed. `verify.py:355-364` picks the exit from verdicts only;
   `verify.py:344-354` builds remediation tasks from `fail` verdicts only;
   `postconditions.py:829-831` (V7) rejects `passed` on an open Critical from
   `effective_findings`; `controller.py:1254-1268` re-enters remediation and asks after
   `retry_limit()`. `_handle_rejection` (`verify.py:88-113`) re-reviews the same head, so
   the reviewer re-reports the carried-forward finding (`verify.py:283` feeds it
   `openFindings`) and the loop repeats. Matches the event log.
2. The `implementation gap` route accepts an all-pass product. `ROUTES` at
   `postconditions.py:83` requires V1, V2, V8, T1: V1 = schema + bound (`:721`), V2 =
   criteria coverage (`:725`), V8 = supersedes (`:834`), T1 = budget (`:1079`). None
   reads a failing verdict. `schemas/verify.json` has no exit-conditional; `planTask`
   requires `criteria` minItems 1 and id `^[TR]-[0-9]+$`, which the plan's task satisfies
   (`verify: ""` is a plain string, allowed).
3. `_handle_rewind` maps the task. `controller.py:1118-1123` copies `remediationTasks`
   and only `fail` verdicts into the payload; `execute.py:809-818` finds owners by
   `repo == rem.repo` and criteria intersection, then prefers file overlap. With the
   plan's criteria (union of the file-owning tasks' criteria) the `prefer` filter narrows
   to exactly the file-owning tasks. In a single-repo run plan-task `repo` is normalized
   to the repo name (`controller.py:551-561`) and reviewer findings carry that same key
   (`verify.py:326`), so the repo equality holds. `cause_by_criterion` is empty for an
   all-pass product (`execute.py:806`), so the reason text change at `:833-838` is
   needed, as the plan says.
4. Termination holds. Ledger findings are recorded on every accepted VERIFY exit
   (`controller.py:1221-1244`, gated on phase only). The backward route spends the
   budget (`controller.py:1144-1146`); `_finalize` refuses the exit when T1 has no room
   (`:1084-1090`) and escalates. Next VERIFY is `fresh` after EXECUTE `integrated`; its
   inputs differ so `verify_state` resets (`verify.py:427-432`); the reviewer sees the
   open finding (`verify.py:283`), disposes it `fixed`, `effective_findings` overlays it,
   V7 passes.
5. Correction (simplify): pass `store.state["repos"]` straight to
   `effective_findings`; it only uses `len(repos)` and `next(iter(repos))`
   (`ledger.py:40`). No `Path` dict needed. `_repo_entries` is `state.get("repos") or {}`
   (`postconditions.py:289`), i.e. no filtering to match.
6. Note, not a blocker: the fallback "last plan task's criteria" can reopen more than one
   task when several tasks share a criterion and none own the file (`prefer` is empty at
   `execute.py:811`). Acceptable; say so in the test comment.
7. Doc: also `phase-interface-7.0.md:211` (V7 row) is unchanged and correct; `:218` and
   `:152` as planned. `external.py:19` lists exit names only; no change, as the plan says.

## LF-65: an EXECUTE pause answer is never read

8. Root cause confirmed. `controller.py:527-532` calls `questions.ask` with the default
   `save=True` and returns; nothing sets `phase.blockedQuestionId`; the handler at
   `:338-354` therefore never sees it; the next `_drive_phase` re-runs `execute.step`,
   which pauses again at `execute.py:1070-1072`. `retire_attempt_questions` has no
   caller, so nothing else consumes the answer.
9. Step 1 is correct and interacts cleanly. `_finish_refusals` waits while
   `blockedQuestionId` is set (`controller.py:1475`); `criticQuestionId` is a separate
   field; the "fix-and-re-enter: phase.entry is already remediation" branch at `:353`
   just saves and re-invokes the same `attemptId`, which is exactly right for a module
   pause (the module re-runs its own check). A policy answer resolved inside `ask`
   (`questions.py:46`) is saved by the caller's single `store.save()`. Condition on
   `request["kind"] == "blocked"`: every module question today is `blocked`
   (`execute.py:517,534`); no other kind flows through this path.
10. Correction (delete steps 2 and 3): `resume` has no useful meaning. After the head is
    adopted, the out-of-band commit belongs to no task, E4 (`postconditions.py:550-571`)
    rejects `integrated`, and `_unmapped_commits_pause` (`execute.py:655-659`) asks
    fix-and-re-enter/stop anyway; the plan says so itself ("E4 may pause"). The operator
    must reconcile the branch in both paths, so `resume` only adds a detour plus
    `pauseAnswer`, `blockedPayload`, `feature_head_adopted`, an `is_ancestor` branch and
    two tests. Replace: `_pause_request` (`execute.py:508-524`) uses `_BLOCKED_OPTIONS`
    with text "...reset `<branch>` to `<expected>` (or move the commit into a task
    worktree), then fix-and-re-enter, or stop"; the handler at `controller.py:343` then
    needs no `abort` alias. Step 4 (leftover task branch, `execute.py:349-352`) follows
    for free since it calls `_pause_request`. `repo.is_ancestor` exists at `repo.py:187`
    but is not needed.
11. Consequence for the doc: E8 (`phase-interface-7.0.md:166`, "not moved out of band")
    stays true; the plan's "resume adopts the new head" would have contradicted it. Add
    only that the pause's answers are fix-and-re-enter/stop.
12. Tests: keep the two `test_controller.py` cases (module blocked question answered
    `stop` -> `escalated`; `fix-and-re-enter` with the drift repaired -> no re-ask, next
    step issued). Drop the two `test_execute.py` adoption tests.
    `tests/test_contract.py:149` uses resume/abort only as fixture data; no change.
13. Minor: the escalated reason at `controller.py:349-351` reads "execute paused;
    operator chose 'stop'" with no cause. Optional: append the question's `text` from
    `questions.answered[...]`/the open record so the terminal result names the drift.

## LF-66: headless runs improvise on blocked questions with no default

14. Root cause confirmed. `default_value=None` at `controller.py:1265,1297,1482` and
    `execute.py:517,534`; `resolve_policy_answer` returns without answering when the
    default is None (`questions.py:93-96`). `examples/sdk-plugin/run_loop_spec.py:145`
    answers with `options[0]["label"]`; `examples/supervisor/supervisor.py:110-114`
    prefers `defaultValue`, then `options[0]`. Both land on "stop" after the fix.
15. `default="stop"` is consistent with the contract: the handler treats `"stop"` as
    escalate (`controller.py:343`) and the doc rows already say "a `run`-scoped default
    policy exits terminal `escalated`" (`phase-interface-7.0.md:175,222,290`).
    `question.json` does not tie `defaultValue` to an option, so ordering is free.
16. Correction (ordering): LF-66 depends on LF-65 step 1. With `default="stop"` on
    `_blocked_pause_request` but no `blockedQuestionId`, `continue_run`'s `while True`
    (`controller.py:324`) asks, auto-answers, re-runs `execute.step`, asks again, with no
    open question to return on: an in-process infinite loop. Commit LF-65 first (the
    plan's order) and say so in the LF-66 commit body.
17. Correction (doc): `phase-interface-7.0.md:66` says the refusal question has "no
    default"; change to "default `stop`". That row describes `_finish_refusals`
    (`controller.py:1481-1482`), one of the four the plan changes.
18. Step 2 reorder: no test asserts option order (grep of `tests/` for
    `fix-and-re-enter`, `options[0]`, `_BLOCKED_OPTIONS` finds none). Safe.
19. Step 3 stub sentence: `skills/cycle/SKILL.md:48-52` already says "You never answer a
    question yourself"; put the new sentence beside it. It is stub-level behavior (how
    to act on `LOOP_SPEC_NEXT`), so it does not violate the thin-stub rule. Check
    `skills/micro`, `skills/debug`, `skills/revise` for the same `question` bullet and
    add it only where that bullet exists.

## LF-67: verify on_submit StopIteration

20. Confirmed at `verify.py:453-454`; the sibling at `:473` already uses
    `next(..., None)`. Fix as planned. `execute.on_submit` (`execute.py:1314-1317`)
    already raises `LoopSpecError` for the same shape; no other unguarded `next(` over
    a submit path exists.

## Out of scope note

21. No doc contains "root commit". The repo id is `paths.py:32-41` (`git rev-list
    --max-parents=0 HEAD`); the state layout is described at
    `docs/loop-spec/migrating-6-to-7.md:121-124` and `architecture.md:44`. Put the
    one-sentence caveat next to `migrating-6-to-7.md:121`.

## Summary of corrections

- LF-64: pass `store.state["repos"]` to `effective_findings`; no Path dict.
- LF-65: keep step 1 only; make `_pause_request` use `_BLOCKED_OPTIONS`; delete
  steps 2-3 (pauseAnswer/blockedPayload/abort alias/head adoption) and their tests;
  doc says fix-and-re-enter/stop, E8 unchanged.
- LF-66: commit after LF-65; also edit `phase-interface-7.0.md:66` ("no default").
- LF-67: as planned.
