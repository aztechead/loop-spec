# Audit of v741-plan.md (gap 5), Fable

For the author of the 7.4.1 gap-5 change. Each finding checks a plan claim against
the code on `v7` at `667c587f`. Line numbers are from that commit.

1. **note** — `deliver.step` does not exist; the phase entry is `deliver.run`
   (`loop_spec/deliver.py:165`). The rest of item 4 is accurate: `_touched_repos`
   (`deliver.py:23-30`) compares against `baseSha`, so the adopted repo counts as
   touched and the push at `deliver.py:230` would run.

2. **should-fix** — Item 5 says D6 compares the row's `headSha` to "the verified
   head". Use `verified_heads(store)[adoption["repo"]]` (`postconditions.py:136`), not
   `verified_head` (`postconditions.py:124`), which reads the first repo and is wrong
   on a workspace run with an adopted repo plus others. Also say that the existing
   `test_d6` (`tests/test_postconditions.py:755-759`) is replaced, not kept: it builds
   the boundary on `self.execute_product` (exit `integrated`), so under "inert unless
   `no change`" its second assertion turns vacuous and the test must set the execute
   exit explicitly.

3. **should-fix** — `adoption.headSha` is read once, in `_adopt`
   (`controller.py:362-378`). A resumed revise or micro run (`controller.py:268-270`
   returns before `_adopt`) keeps the value from the first session, so the no-change
   row can name a PR head the PR no longer sits at. D2 skips every non-`delivered`
   row (`postconditions.py:1023`), so nothing confirms the row against the live PR.
   Give D6 the same `gh pr view --json state,headRefOid` read D2 does for the adopted
   row: state `OPEN` and `headRefOid` equal to the row's `headSha`. That is a read,
   not a remote write, so it stays inside the user's decision, and it is the same
   identity check a delivered row already gets.

4. **note** — The plan does not name `verify._touched_repos` (`verify.py:40-42`)
   or `iterate._touched_repos` (`iterate.py:34-36`), both `head != baseSha`. On this
   path the adopted repo is therefore touched: VERIFY reviews and probes
   `baseSha..PRhead` in full (`verify.py:200-207`) and the ITERATE judge reads the
   PR diff (`iterate.py:50`). That is the right behavior (the run certifies the PR's
   work) and matches an integrated revise run, so leave both on `baseSha`, but say so
   in item 1 alongside `roles.repo_map`, and word the doc row as "VERIFY at the head,
   over `base..head`" rather than "at the start commit", which reads as an empty
   range.

5. **note** — The adopted-range review at EXECUTE entry (`controller.py:598-600`)
   still runs on this path. Its result is only projected onto `adopted` tasks
   (`execute.py:1131-1138`), so on a `no change` exit the review step is spent and its
   findings are dropped; VERIFY's own full-range review covers the same range. No
   interaction with the exit or the postconditions; cost only, out of scope.

6. **note** — "The credential check is skipped too" is true only of `deliver.run`'s
   refusal loop (`deliver.py:181-186`, iterates `touched`). The controller's
   `_record_deliver_credentials` (`controller.py:614-619`) still runs before the
   phase: `git ls-remote` and `gh auth status` (`repo.py:498-513`), reads only. D7
   skips `skipped` rows (`postconditions.py:1082-1083`), so wiring D6 and an all-
   skipped product break nothing in D7. State which check the plan means.

7. **note** — `integrated` requires `!E9` (`postconditions.py:78`). After item 2 the
   range half of E9 passes on a revise run whose only work is adopted tasks with no
   new commits (`PRhead..head` is empty), so `integrated` there holds solely on the
   disposition half (`adopted` is not in `already-satisfied`/`removed`,
   `postconditions.py:747-749`). It holds; add one test for it: `integrated` with only
   `adopted` tasks and `heads[repo] == adoption.headSha` still fails E9.

8. **note** — Simpler-design check. Without item 4, DELIVER on this path pushes
   `PRhead:refs/heads/<branch>` (a no-op on the wire, the remote already holds it) and
   reconciles the existing PR, giving a `delivered` row and `workDelivered: true`. The
   user chose no write and `workDelivered: false`, so item 4 stands. Its smallest form:
   in `run`, `touched = {}` when the execute exit is `no change`, and fill the adopted
   row from `adoption` inside the existing skipped branch (`deliver.py:190-192`). No
   new helper.

9. **note** — `iterate.py:29` and `verify.py:35` comments describe `verified_head`'s
   no-change special case; item 3 makes them false. Fix in the same diff.

10. **note** — Checked and holding: E9 is unchanged for a run without adoption;
    `verified_head` callers' fixtures (`tests/test_controller.py:1991`, `:2034`) set
    heads equal to base and stay green; D8 on `delivered` has an empty `required` set
    with no `done`/`adopted` task (`postconditions.py:1096-1100`); D4 records the
    adopted PR number for the skipped row (`postconditions.py:1055-1063`), harmless
    and stable across retries; the product `heads` for an untouched adopted repo is
    `lastKnownHead` = `candidate.head_sha` (`execute.py:323`, `controller.py:371`),
    so item 3's "PR head" claim holds; `_unmapped_commits_pause` subtracts the
    adopted commits (`execute.py:673-675`) and does not fire; the row's `pr` shape
    matches `schemas/deliver.json` from `adoption` (`controller.py:373-377`).

verdict: go
