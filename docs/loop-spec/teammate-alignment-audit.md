# Teammate alignment audit (7.8.3)

For a reviewer or planner deciding which gaps to fix. The document lists where
loop-spec's default behavior falls short of working like a human engineer on a
shared repository. Each finding makes one claim, cites the code behind it, and
gives one final rank. The 7.9.0 column records what that release changed;
see `CHANGELOG.md` for how.

This is one consolidated list. It merges the original audit with an
independent review that corrected, re-ranked, and added findings. Where the two
disagreed, the rank and wording here are the settled result.

## The prompt

The audit answered this request, verbatim:

> Identify areas of the plugin that do not align with this statement. This plugin
> should function how a human engineer works throught the SDLC process and is a
> good teamate to others who work on the same projects as they do

## Scope and method

- Commit: `80dede8e` (`main`, v7.8.3). Implementation is unchanged at `b0976f34`.
- Stages covered: intake, specification, planning, implementation,
  verification, review, delivery, and responsibility after delivery.
- Standard: what a careful engineer on a shared repository does at each stage.
- Evidence: reading the program, role prompts, route requirements, runner
  protocol, and tests. Local probes, run during the review, checked branch
  selection (TA-1, TA-19), readiness routing (TA-21), and PR rendering (TA-10).
  They used a temporary Git repository, mocked `gh` responses, and an in-memory
  fixture. No live cycle ran and no real PR was changed. The other findings rest
  on static control-flow and prompt evidence.
- Defaults only. Projects can bind other phases and roles and configure
  `deliver.after` follow-up skills (`references/runner.md:162`,
  `program/loop_spec/result.py:168`). A finding says the default lacks a
  behavior, not that customization cannot supply it.
- Paths are relative to `skills/loop-spec/` unless they start with `docs/`.

The rendering, review-intake, and delivery suites passed (6, 9, and 32 tests,
from `skills/loop-spec/program`). Those tests prove their own assertions, not
compliance with this standard.

## Severity

- **High:** the plugin acts against a teammate's work, targets the wrong place,
  or ships an integration nobody verified.
- **Medium:** it skips a step a careful engineer takes.
- **Low:** it ignores a team convention.

A conditional rank ("High when ...") applies the higher rank only in the named
case.

## Already aligned

These behaviors meet the standard. Do not re-report them as gaps.

| Behavior | Where | Limit |
| --- | --- | --- |
| DELIVER never force-pushes; each push refusal says "never force" | `program/loop_spec/deliver.py:141` | |
| Implementation never commits into the operator's checkout | `deliver.py:286`, `roles/implementer/contract.md:1` | `direct` runs in the operator's checkout (`defaults.py:47`) |
| A moved base is merged in, not rebased, so reviewed SHAs survive | `execute.py:1221` | |
| Commits added after VERIFY are refused, with a rescue-branch recipe | `deliver.py:34` | |
| A run that converged with caveats opens a draft PR | `deliver.py:210` | New PRs only; see TA-22 |
| `.loop-spec/` goes in `.git/info/exclude`, not a committed file | `paths.py:110` | |
| Bot commits on allowed paths are accepted, not overwritten | `deliver.py:313` | |
| SPEC interviews the requester and states assumptions | `roles/spec-writer/SKILL.md:9`, `:43` | |
| PLAN searches for existing code and records reuse decisions | `roles/planner/SKILL.md:73`, P8 | |
| Implementers match house style and write a failing test first | `roles/implementer/SKILL.md:22`, `:43`, `:71` | |
| Verification evidence is bound to a SHA and re-run in a clean checkout | `roles/verifier/SKILL.md:19`, V3–V5 | |
| Base-conflict resolution keeps both intents and escalates contradictions | `roles/resolver/SKILL.md:23`, `:34` | Not the `direct` route; see TA-20 |
| Cleanup protects active and quarantined worker paths | `controller.py:1749` | |

## Findings

| ID | Rank | Stage | Gap | 7.9.0 |
| --- | --- | --- | --- | --- |
| TA-1 | High | Intake | Branches from local HEAD without fetching | Fixed |
| TA-2 | Medium | Intake | No check for duplicate or claimed work | Fixed |
| TA-3 | Medium | Intake | No structured issue association | Fixed |
| TA-4 | Medium | Others' work | Cannot tell review help from branch edits | Disclosed in the reply comment; not gated |
| TA-5 | High | Others' work | Re-delivery overwrites the PR description | Fixed |
| TA-6 | High when shared | Others' work | `direct` may force-push a shared branch | Fixed (prompt) |
| TA-7 | High | Review | revise never replies to review | Fixed; threads left to reviewers |
| TA-8 | Medium | Review | No reasoned decline of a review comment | Fixed |
| TA-9 | Medium | Review | Review comments are not filtered | Fixed |
| TA-10 | Medium | Handoff | PR body omits decisions and criterion text | Fixed; template appended, not filled |
| TA-11 | Low | Handoff | Commit history carries run-internal IDs | Fixed (prompt) |
| TA-12 | Low | Handoff | Branch names are hard-coded | Fixed |
| TA-13 | Low | Handoff | No reviewers, labels, or assignee | Fixed |
| TA-14 | High | Integration | CI is not followed after the PR opens | Partial: one read, then a short wait for checks to register |
| TA-15 | High | Integration | A clean base move is not re-verified | Fixed |
| TA-16 | Medium | Conventions | Team instruction files are barely read | Fixed (prompt) |
| TA-17 | Medium | Completeness | No change-impact duty beyond the diff | Fixed (prompt) |
| TA-18 | Low | Handoff | Blocked runs say nothing on the PR | Fixed |
| TA-19 | High | Intake | Missing `origin/HEAD` makes the current branch the PR target | Fixed |
| TA-20 | Medium; High for code conflicts | Integration | `direct` conflict resolution ships untested | Fixed (prompt, router) |
| TA-21 | High | Integration | Partial delivery skips configured CI readiness | Fixed |
| TA-22 | Medium | Handoff | Caveats never return a ready PR to draft | Fixed |
| TA-23 | Medium | Handoff | Workspace PRs lack sibling links | Fixed |
| TA-24 | Medium | Lifecycle | The run ends at an open PR with no named owner | Partial: assignee and owner line |

### Intake

#### TA-1 (High): the run branches from local HEAD without fetching

- **Claim:** A run's base is the commit the operator's checkout has checked
  out. Nothing fetches origin first or checks that the base is on
  `origin/<default>`.
- **Evidence:** `program/loop_spec/controller.py:375` sets
  `base_sha = repo_module.head_sha(entry.path)`. The only `fetch_base` call is
  in DELIVER (`deliver.py:250`). DELIVER's containment check at `deliver.py:256`
  is skipped when the fetched tip is already an ancestor of the head
  (`deliver.py:254`).
- **Consequence:** Started on a local feature branch, the run can ship that
  branch's unrelated commits in the PR with no refusal. When the base is off
  origin and the skip does not apply, DELIVER refuses with a misleading
  "rewritten history" message after the whole run.
- **Engineer's practice:** Update the integration branch, then branch from it.
- **Verify by:** Check out an unpushed local branch in a fixture, start a
  cycle, and read `state.repos.<repo>.baseSha`. The review probe observed this.

#### TA-19 (High): a missing `origin/HEAD` makes the current branch the PR target

- **Claim:** Without a local `refs/remotes/origin/HEAD`, default-branch
  detection returns the checked-out branch. A detached checkout yields `HEAD`.
- **Evidence:** `program/loop_spec/repo.py:207` falls back to
  `git rev-parse --abbrev-ref HEAD`. `controller.py:379` stores the result as
  `defaultBranch` unless `deliver.base` is set, and `deliver.py:343` opens the
  PR against it.
- **Consequence:** A run started on a teammate's feature branch opens its PR
  against that branch. If the branch is absent remotely, delivery blocks.
  TA-1 picks the wrong starting commit; this picks the wrong destination.
- **Engineer's practice:** Establish the integration branch from repository
  policy or remote metadata before starting.
- **Verify by:** In a temporary repository with no `origin/HEAD` and no
  `deliver.base`, check out `feature/teammate` and call `_resolve_repos`. The
  review probe observed the feature commit as `baseSha` and `feature/teammate`
  as `defaultBranch`.

#### TA-2 (Medium): no check for duplicate or claimed work

- **Claim:** Before SPEC, nothing looks for related open PRs, issue ownership,
  or active branches covering the request.
- **Evidence:** `repo.py:234` (`free_branch`) reads remote branch names with
  `ls-remote`, but only to avoid a name collision; it picks `feat/<slug>-2`.
  The only `gh pr list` call is in DELIVER (`deliver.py:63`).
- **Qualification:** A taken name can be a stale branch. It is a clue that
  someone may be working on this, not proof.
- **Engineer's practice:** Check whether someone already owns the work.

#### TA-3 (Medium): no structured issue association

- **Claim:** No entry takes an issue as structured input, and no PR body links
  or closes one.
- **Evidence:** `entries.py:16` allows `takes` of `"request"` or `"pr"` only.
  `render.pr_body` (`render.py:58`) writes no issue reference.
- **Qualification:** A plain-text request can name a ticket. Nothing turns that
  into a link on the PR.
- **Engineer's practice:** Pick up a ticket, link the PR to it, and let the
  merge close it.

### Others' work

#### TA-4 (Medium): cannot tell review help from branch edits

- **Claim:** revise pushes commits onto any open PR the request names. It does
  not consider who owns the branch or whether the requester wanted review
  comments or commits.
- **Evidence:** `controller.py:361` adopts a named PR. `repo.py:507`
  (`adopt_pr`) refuses only a closed PR or a fork. A2
  (`postconditions.py:1307`) rejects a routed PR the request did not name.
- **Qualification:** Naming a teammate's PR is a form of authorization, and
  another author alone does not make adoption wrong. The gap is ambiguity:
  "help with #42" can mean review or commits.
- **Engineer's practice:** Confirm before pushing to someone else's branch.

#### TA-5 (High): re-delivery overwrites the PR description

- **Claim:** When a PR exists, DELIVER replaces its entire body with the
  generated one. It never reads the current body, so human additions are lost:
  screenshots, test notes, context, a template checklist.
- **Evidence:** `deliver.py:77` runs `gh pr edit --body-file` on every existing
  PR it reconciles. A no-change run skips reconciliation.
- **Engineer's practice:** Edit only their own section, or comment instead.

#### TA-6 (High when a shared branch is involved): `direct` may force-push

- **Claim:** The only force-push rule is "never force-push a branch the request
  did not name". A request naming a shared PR branch allows a rebase and
  force-push that rewrites teammates' commits. There is no shared-history check
  and no `--force-with-lease` requirement.
- **Evidence:** `roles/direct/SKILL.md:38`.
- **Qualification:** This permits a risky action. It does not show that every
  direct run force-pushes.
- **Engineer's practice:** Never rewrite a branch other people have pushed to.

### Review

#### TA-7 (High): revise never replies to review

- **Claim:** revise reads comments and pushes. It posts no reply, resolves no
  thread, and does not re-request review.
- **Evidence:** `revise.py:22` (`gaps_from_pr`) only reads. Grep finds no
  reply, `resolveReviewThread`, or re-request call in the program.
- **Consequence:** Reviewers must diff the push to learn which comments were
  handled. Silent pushes in answer to review are the most visible way the
  plugin falls short as a teammate.
- **Qualification:** Who resolves a thread is team policy. Replying is not.
- **Engineer's practice:** Reply "done in `<sha>`" or explain, and re-request
  review.

#### TA-8 (Medium): no reasoned decline of a review comment

- **Claim:** Every comment must become a criterion, a task, or an open
  question. Declining a suggestion with a reason is not an outcome.
- **Evidence:** `roles/reviser/SKILL.md:46`, `:61`.
- **Qualification:** Open questions reach the operator through SPEC
  (`controller.py:1730`). They never reach the PR thread.
- **Engineer's practice:** Disagree in the thread when a suggestion is wrong.

#### TA-9 (Medium): review comments are not filtered

- **Claim:** Every non-empty comment and review body becomes a gap: bot output,
  "LGTM", the author's own notes, resolved and outdated threads.
- **Evidence:** `revise.py:30`, `:43`. Inline gaps keep URL, author, path,
  line, and time, but drop thread state. The earlier-run cutoff in
  `roles/reviser/SKILL.md:22` reduces repeats only.

### Handoff

#### TA-10 (Medium): the PR body omits decisions and criterion text

- **Claim:** The body has the goal, boundaries, an acceptance table with each
  check's command and SHA, findings, and rejected Critical plan-critic
  findings. It omits the SPEC's decisions, its open questions, and the text of
  each criterion, and it ignores the repository's PR template.
- **Evidence:** `render.py:58` (`pr_body`), `render.py:39`
  (`_acceptance_table`). Decisions and open questions appear only in `spec_md`
  (`render.py:22`), which stays in the operator's state home. Grep finds no
  `pull_request_template` reference.
- **Consequence:** A reviewer sees bare AC IDs without the SPEC that defines
  them, and cannot see why the change took this shape.

#### TA-11 (Low): commit history carries run-internal IDs

- **Claim:** Commit messages name task IDs, and the program adds
  `loop-spec: integrate T-n` merge commits. The IDs lose meaning once run state
  is gone. The repository's commit convention is never detected.
- **Evidence:** `roles/implementer/contract.md:4`; `execute.py:1516`.

#### TA-12 (Low): branch names are hard-coded

- **Claim:** Fresh runs use `feat/<slug>`, including debug fixes, whatever the
  team's convention. Adopted PRs keep their branch (`controller.py:396`).
- **Evidence:** `controller.py:378`.

#### TA-13 (Low): no reviewers, labels, or assignee

- **Evidence:** `deliver.py:92` passes only base, head, title, body, and
  `--draft`. Repository automation may assign them independently.

#### TA-18 (Low): blocked runs say nothing on the PR

- **Claim:** When a run ends escalated or `delivery blocked` and a PR exists,
  the cause reaches only the operator.
- **Evidence:** The result keeps publication history and causes
  (`result.py:95`, `controller.py:1695`). Grep finds no `gh pr comment` call.

#### TA-22 (Medium): caveats never return a ready PR to draft

- **Claim:** A delivery that should be a draft leaves an existing ready PR
  ready.
- **Evidence:** `deliver.py:210` derives draft status. `_reconcile_pr` can mark
  a draft ready but, per its own comment at `deliver.py:80`, never converts a
  ready PR back. `--draft` applies only to a new PR (`deliver.py:93`).
- **Consequence:** A revise run with unresolved caveats leaves the PR
  advertised as ready for review.

#### TA-23 (Medium): workspace PRs lack sibling links

- **Claim:** Each repository gets the same whole-run PR body, with no links to
  sibling PRs and no landing-order note.
- **Evidence:** `deliver.py:343` calls `render.pr_body(store)` with no
  repository or sibling argument. `result.py:95` collects the URLs for the
  operator only.
- **Qualification:** Independent changes need no landing order. The gap matters
  when repositories must change together.

### Integration

#### TA-14 (High): CI is not followed after the PR opens

- **Claim:** By default nothing reads CI. With `deliver.readiness: "checks"`,
  D3 reads checks once and does not wait. A failing check has no path back into
  implementation, because revise reads only comments.
- **Evidence:** `postconditions.py:1124` (`_d3`); `references/contract.md:316`.
- **Engineer's practice:** Get CI green before asking for review, and fix red CI
  on their own PR.

#### TA-15 (High): a clean base move is not re-verified

- **Claim:** DELIVER sends the run back to EXECUTE only on a textual conflict.
  A base that merges cleanly is neither integrated nor verified together with
  the change.
- **Evidence:** `deliver.py:261`–`:263`.
- **Consequence:** Another PR can change a callee while this one changes its
  caller. The textual merge is clean; the behavior is broken.

#### TA-20 (Medium; High for code conflicts): `direct` conflict resolution ships untested

- **Claim:** The router sends merge-conflict and branch-sync requests to
  `direct`, which requires no test run or review even when resolution changes
  code.
- **Evidence:** `roles/router/SKILL.md:23` routes there when the request "says,
  or plainly implies, that it needs no design or verification".
  `roles/direct/SKILL.md:16` requires no test. The `done` route requires X1 and
  X2 (`postconditions.py:118`); `_x2` (`:1326`) checks reported remote
  identities, not the merged code. The warning at `controller.py:1802` comes
  after the push.
- **Qualification:** The router's condition limits how often this happens. A
  code conflict needs a test run whatever the requester implies. The `resolver`
  role does require tests, but not on this route.

#### TA-21 (High): partial delivery skips configured CI readiness

- **Claim:** A workspace delivery that publishes one repository and fails
  another skips D3, even with `deliver.readiness: "checks"`.
- **Evidence:** `delivered` requires D3; `partially delivered` omits it
  (`postconditions.py:104`–`:105`). `Boundary.check` (`:313`) evaluates only the
  chosen route's requirements.
- **Consequence:** A published PR can have red CI unchecked because a different
  repository failed.
- **Verify by:** With readiness on and `run_gh` mocked to fail,
  `Boundary.check(only=frozenset({"D3"}))` made one call and one failure on
  `delivered`, and neither on `partially delivered` (review probe).

### Conventions and completeness

#### TA-16 (Medium): team instruction files are barely read

- **Claim:** No default role is told to find and follow `AGENTS.md`, branch or
  commit policy, or a PR template.
- **Evidence:** `roles/planner/SKILL.md:59` names `CLAUDE.md` and
  `CONTRIBUTING*` only to decide on a changelog entry. Grep finds no `AGENTS.md`
  reference.
- **Qualification:** Roles do read neighboring files for house style, and probes
  find lint and test commands. The host may load some instruction files on its
  own.

#### TA-17 (Medium): no change-impact duty beyond the diff

- **Claim:** No role must find unchanged docs or external callers that a
  behavior change makes wrong, or assess compatibility and deprecation.
- **Evidence:** Grep of `roles/*/SKILL.md` finds no such duty.
  `roles/plan-critic/SKILL.md:32` covers rollback only.
- **Qualification:** SPEC reads related entry points and tests
  (`roles/spec-writer/SKILL.md:19`), and `probes.py:1931` checks changed
  Markdown for broken links and stale paths. Neither covers unchanged files.

### Lifecycle

#### TA-24 (Medium): the run ends at an open PR with no named owner

- **Claim:** A run is complete once DELIVER passes with an open PR. Nothing
  names who carries it through approval, merge, release, or monitoring.
- **Evidence:** D2 requires `state == "OPEN"` (`postconditions.py:1119`). The
  `delivered` route is terminal (`:104`). `deliver.after` skills run after the
  result is final (`result.py:168`, `references/runner.md:162`).
- **Qualification:** This is a handoff gap. It is not a case for merging or
  deploying without authorization.

## Priority

1. **Wrong place:** TA-1 and TA-19 pick the wrong source or target.
2. **Destroys others' work:** TA-5 always; TA-6 on shared branches.
3. **Unverified integration:** TA-14, TA-15, TA-21, and TA-20 for code
   conflicts.
4. **Silent in review:** TA-7.
5. **Medium findings:** review dialogue (TA-8, TA-9), change impact (TA-17),
   handoff context (TA-10, TA-22, TA-23, TA-24), intake (TA-2, TA-3, TA-4), and
   conventions (TA-16).
6. **Low findings:** TA-11, TA-12, TA-13, TA-18.
