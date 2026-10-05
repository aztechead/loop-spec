# A micro run

For the lead of a loop-spec run of kind `micro`: a small, well-defined change. Read it
before the spec; it changes the workflow in SKILL.md as follows, and everything else
stands.

- **Spec:** skip the interview. Write one or two criteria.
- **Plan:** one task, which you do yourself in its worktree, then `LS task done`.
- **Iterate:** look over the verified diff yourself. Dispatch the `loop-spec:reviewer`
  only if the change touches behavior other code relies on, and skip the simplifier.
  Still run `LS iterate`.
