# Teammate alignment audit (7.8.3)

For a reviewer checking these findings before anyone plans fixes. Each finding
makes one claim, cites the code behind it, and says how to confirm it. Your job
is to confirm, refute, or re-rank each finding. This document proposes no fixes.

## The prompt

The audit answered this request, verbatim:

> Identify areas of the plugin that do not align with this statement. This plugin
> should function how a human engineer works throught the SDLC process and is a
> good teamate to others who work on the same projects as they do

## Scope and method

- Commit: `80dede8e` (`main`, v7.8.3).
- Method: static reading of `skills/loop-spec/program/loop_spec/` and
  `skills/loop-spec/roles/`. No live run was made, so every claim is about what
  the code and prompts say, not observed behavior.
- Standard used: what a careful engineer on a shared repository does at each
  SDLC stage, from picking up work through review and merge.
- Paths below are relative to `skills/loop-spec/` unless they start with `docs/`.

## Already aligned

These behaviors match the statement. They are listed so a reviewer does not
re-report them as gaps.

| Behavior | Where |
| --- | --- |
| DELIVER never force-pushes; every push refusal says "never force" | `program/loop_spec/deliver.py:141` |
| The program never commits into the operator's own checkout | `deliver.py:286`, `roles/implementer/contract.md:1` |
| A moved base is merged in, not rebased, so reviewed commits keep their SHAs | `execute.py:1221` |
| Commits added after VERIFY are refused, with a rescue-branch recipe | `deliver.py:34` |
| A run that converged with caveats opens a draft PR | `deliver.py:210` |
| `.loop-spec/` goes in `.git/info/exclude`, not a committed `.gitignore` | `paths.py:110` |
| Bot commits on allowed paths are accepted, not overwritten | `deliver.py:313` |
| SPEC interviews the requester and states assumptions | `roles/spec-writer/SKILL.md:9`, `:43` |

## Findings

Severity is the auditor's ranking. **High** means the plugin acts against a
teammate's work or interest. **Medium** means it skips a step a human engineer
takes. **Low** means it ignores a team convention.

### Starting work

#### TA-1 (High): the run branches from local HEAD without fetching

- **Claim:** A run's base is whatever commit the operator's checkout has checked
  out. Nothing fetches origin first. Nothing checks that the base is on
  `origin/<default>`.
- **Evidence:** `program/loop_spec/controller.py:375` sets
  `base_sha = repo_module.head_sha(entry.path)`. The only `fetch_base` call is
  in DELIVER (`deliver.py:250`).
- **Consequence:** Started from another feature branch, or with unpushed local
  commits, the PR carries those unrelated commits. If the base is not on origin,
  DELIVER refuses with a "rewritten history" message (`deliver.py:256`). That
  message is misleading, and it arrives after the whole run.
- **Engineer's practice:** Update the default branch, then branch from it.
- **Verify by:** Check out an unpushed local branch in a fixture, start a cycle,
  and read `state.repos.<repo>.baseSha`.

#### TA-2 (Medium): no check for duplicate or claimed work

- **Claim:** Before SPEC, nothing looks for an open PR, a remote branch, or an
  assigned issue that already covers the request.
- **Evidence:** `repo.py:234` (`free_branch`) handles a taken `feat/<slug>` by
  choosing `feat/<slug>-2`. The collision is the signal that someone else may
  be working on this, and the code hides it.
- **Engineer's practice:** Check whether someone already owns the work.
- **Verify by:** Grep the program for any `gh pr list` or `gh issue` call made
  before SPEC. The only `gh pr list` is in DELIVER (`deliver.py:63`).

#### TA-3 (Medium): no issue-tracker entry or link

- **Claim:** No entry takes an issue, and no PR body links one.
- **Evidence:** `entries.py:16` allows `takes` to be only `"request"` or `"pr"`.
  `render.py:58` writes no `Closes #N`. The 6.x issue-intake entry was not
  carried into 7.x.
- **Engineer's practice:** Pick up a ticket, link the PR to it, and let the
  merge close it.

### Changing others' work

#### TA-4 (High): revise adopts any open PR, whoever wrote it

- **Claim:** revise pushes commits onto a teammate's PR branch without asking.
  It checks neither the PR author nor whether the operator was asked to take
  over.
- **Evidence:** `repo.py:507` (`adopt_pr`) refuses only a PR that is not open
  or comes from a fork.
- **Engineer's practice:** Ask before pushing to someone else's branch, or
  suggest changes in review instead.

#### TA-5 (High): every re-delivery overwrites the PR description

- **Claim:** When a PR exists, DELIVER replaces its body with the generated
  one. Text a person added is lost: screenshots, test notes, context, or a
  template checklist.
- **Evidence:** `deliver.py:77` runs `gh pr edit --body-file` unconditionally
  on an existing PR.
- **Engineer's practice:** Edit only their own section of the description, or
  post a comment.

#### TA-6 (Medium): the direct role may force-push a shared branch

- **Claim:** The only force-push rule is "never force-push a branch the request
  did not name". A request that names a shared PR branch allows a rebase and
  force-push, which rewrites teammates' commits.
- **Evidence:** `roles/direct/SKILL.md:38`.
- **Engineer's practice:** Never rewrite a branch other people have pushed to.

### Code review

#### TA-7 (High): revise never replies to or resolves review threads

- **Claim:** revise reads comments and pushes. It posts no reply and resolves
  no thread. It does not re-request review.
- **Evidence:** `revise.py:22` (`gaps_from_pr`) only reads. Grep finds no
  `reply`, `resolveReviewThread`, or re-request call in the program.
- **Consequence:** The reviewer has to diff the push to learn which comments
  were handled.
- **Engineer's practice:** Reply "done in `<sha>`" or explain, resolve the
  thread, and re-request review.

#### TA-8 (Medium): no way to push back on a review comment

- **Claim:** Every comment must become a criterion, a task, or an open
  question. Declining a suggestion with a reason is not an outcome. Open
  questions stay in local state and never reach the PR.
- **Evidence:** `roles/reviser/SKILL.md:46` and `:61`.
- **Engineer's practice:** Disagree in the thread when a suggestion is wrong.

#### TA-9 (Medium): review comments are not filtered

- **Claim:** Every comment and review body becomes a gap. That includes bot
  output (coverage, CI, changelog bots), "LGTM", the PR author's own notes, and
  resolved or outdated threads.
- **Evidence:** `revise.py:30` and `:43` keep every non-empty body. The only
  filter is the earlier-run cutoff in `roles/reviser/SKILL.md:22`.

### What teammates see

#### TA-10 (High): the PR body is written for the program, not a reviewer

- **Claim:** The body shows the goal, criterion-ID tables, finding IDs, and
  "Rewinds used: n/m". It leaves out the spec's decisions, its open questions,
  and how to test the change. It ignores the repository's PR template.
- **Evidence:** `render.py:58` (`pr_body`). The decisions and open questions
  appear only in `spec_md` (`render.py:22`), which stays in the state home on
  the operator's machine. Grep finds no reference to `pull_request_template`.
- **Consequence:** The PR body is the only record teammates get, and it does
  not say why the change was made this way.

#### TA-11 (Low): commit history carries run-internal IDs

- **Claim:** Commit messages name task IDs, and the program adds
  `loop-spec: integrate T-n` merge commits. These IDs mean nothing once the run
  state is gone. The repository's own commit style is never detected.
- **Evidence:** `roles/implementer/contract.md:4` ("messages naming the task
  id"); `execute.py:1516`.

#### TA-12 (Low): branch names are hard-coded

- **Claim:** Every run uses `feat/<slug>`, including a debug fix, whatever the
  team's naming convention is.
- **Evidence:** `controller.py:378`.

#### TA-13 (Low): no reviewers, labels, or assignee on PR creation

- **Evidence:** `deliver.py:92` passes only base, head, title, body, and
  `--draft`.

### CI and completeness

#### TA-14 (High): CI is not followed after the PR opens

- **Claim:** By default nothing reads CI. With `deliver.readiness: "checks"`,
  one `gh pr checks` call runs and nothing waits for it. A failing check after
  delivery has no path back into the loop, because revise reads only comments.
- **Evidence:** `references/contract.md:316`;
  `program/loop_spec/external.py:82` (D3 text).
- **Engineer's practice:** Get CI green before asking for review, and fix red
  CI on their own PR.

#### TA-15 (Medium): a clean base move is not re-verified

- **Claim:** DELIVER sends the run back to EXECUTE only when the new base
  conflicts textually. A base that merges cleanly but breaks the change ships
  on the old VERIFY result.
- **Evidence:** `deliver.py:261` to `:263`.

#### TA-16 (Medium): repository conventions are read for one purpose only

- **Claim:** The planner reads `CLAUDE.md` and `CONTRIBUTING*` only to decide
  whether to add a changelog entry. `AGENTS.md`, commit and branch conventions,
  and documentation rules are never read.
- **Evidence:** `roles/planner/SKILL.md:59`. Grep finds no `AGENTS.md`
  reference.

#### TA-17 (Medium): no work beyond the code itself

- **Claim:** No role is told to update user-facing docs that a behavior change
  makes false, check callers outside the diff, or flag a breaking change. The
  code reviewer reviews only the diff.
- **Evidence:** Grep of `roles/*/SKILL.md` for `readme`, `breaking`,
  `deprecat`, and `caller` finds none of these duties.
  `roles/plan-critic/SKILL.md:32` covers rollback only.

#### TA-18 (Low): blocked runs say nothing on the PR

- **Claim:** When a run ends escalated or `delivery blocked` and a PR exists,
  the reason goes only to the operator. People watching the PR get no signal.
- **Evidence:** `deliver.py` and `result.py` write the reason to the result
  file and state. Grep finds no `gh pr comment` call.

## Auditor's priority

TA-1, TA-4, TA-5, TA-7, TA-10, and TA-14 are where the plugin acts unlike a
teammate today. The rest concern fitting a team's conventions.

## Questions for the reviewer

1. Is any finding wrong because a code path handles it that this audit missed?
2. Does any High finding belong at Medium, or the reverse?
3. Which gaps does the plugin not cover at all, against the same statement?
