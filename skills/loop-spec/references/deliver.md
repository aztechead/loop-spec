# Phase 6: deliver, then see CI and review through

For the lead of a loop-spec run in DELIVER. The job: open the PR for the verified,
reviewed head, then answer its CI and its reviewers until CI passes and nobody has
asked for anything new.

## The description

Write the PR description to `pr.md` in `runDir`, following the template `LS status`
names on its `pr.md` line (`prTemplate` in `LOOP_SPEC_RUN`): the repository's own PR
template when it has one, else the bundled visual-pr format; the `next` line names the
files to read for it. Describe the change as it stands at the head you deliver, and
update `pr.md` when a later fix changes it. Deliver appends the criteria, and how verify showed each, folded below your
text. A revise run leaves the PR's description alone and needs no `pr.md`.

## Deliver

Run `LS deliver`. It pushes the feature branch and opens the PR, or updates the one it
opened before. It refuses, and says why, when:

- there is no `pr.md`, or it still has lines of the template's `{...}` placeholders;
- `gh` is missing or not signed in (checked before anything is pushed);
- verify did not pass at this head: verify again;
- origin moved: run `LS sync`, resolve any conflict in `work` keeping both sides' intent
  (`git commit --no-edit`), verify, and deliver again.

Use `--unverified`, which opens a draft that says so, only with the user's say-so, or,
in an autonomous run, when a check cannot run here for a reason outside the change. If
there is nothing to deliver, `LS finish --status no-change --summary "..."`.

## The feedback loop

Run `LS feedback`. It waits for the PR's checks, then shows each failed check's log and
each new review item (reviews, inline comments, conversation comments) once. Then:

- **Checks still running:** run it again.
- **CI passed and nothing new:** the run ends.
- **A failed check or a review item this change should address:** fix it in `work`,
  verify, deliver, and run `feedback` again.
- **A question, or a request you decline with a reason:** answer it in a comment, with
  `deliver --comment-file F` alongside your next fix, or `gh pr comment` when there is
  none.
- **A check that also fails on the base branch:** not this change's to fix; say so in a
  comment.
- **Feedback that cannot be satisfied** (it contradicts the spec, or needs a decision
  only the user can make): `LS finish --status escalated --summary "..."` naming what
  is needed.

There is no limit on rounds.

When the project's config names feedback skills (`feedback.skills` in
`.loop-spec/config.json`), `feedback` lists them once CI and review are clear. Invoke
each with the `Skill` tool and the PR URL, treat what it reports like review comments,
and when nothing is left, `LS finish --status completed --summary "..."`.
