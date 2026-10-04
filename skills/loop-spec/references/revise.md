# A revise run

For the lead of a loop-spec run of kind `revise` (`start --pr N`): review feedback on an
open pull request. Read it before the spec; it changes the workflow in SKILL.md as
follows, and everything else stands.

- **The branch:** the run works on the PR's own branch, and deliver pushes to it.
- **Spec:** `start` lists the PR's review so far, each item once; `feedback` later shows
  only what comes after it. Make one criterion per item you change code for.
- **Deliver:** no `pr.md`; deliver leaves the PR's description alone. Write a reply
  covering each comment (what changed, or why not) to a file in `runDir` and pass it as
  `LS deliver --comment-file F`.
