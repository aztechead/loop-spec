# PR 79 revision

Date: 2026-08-30  
PR: https://github.com/aztechead/loop-spec/pull/79  
Revision commit: `2fc3dc048f7fe264af3274cd6ea88b1746218b4f`

## Intent

Restore concrete `AskUserQuestion` call contracts after placeholder waits could be
emitted in their place. The PR adds a Claude Code `PreToolUse` guard and changes
agent-joining phases to dispatch and stop instead of manufacturing a question to
keep the lead alive.

## Audit outcomes

- Require every question in a batch to match its phase contract; a valid header
  can no longer mask a forbidden question.
- Match the full published question and exact option-label set, reject
  multi-select variants, and keep headers within the harness's 12-character
  limit.
- Derive phase restrictions from the active skill transcript instead of stale
  persisted feature state. Nested utility skills preserve the parent phase,
  while cycle, SPEC, DISCUSS, and PLAN clear late-phase restrictions.
- Stop classifying legitimate product questions about ping or keepalive behavior
  as placeholder waits.
- Make specifying-gates collect runnable proof: criteria include an observable
  and exact pass/fail rule, proof mechanisms are shell-executable commands or a
  fully specified subagent dispatch, and briefing metadata uses the canonical
  `dispatchBrief` field.
- Preserve `requiresUserSpecification` whenever the user chooses to stop rather
  than silently treating an incomplete gate as specified.

## Accepted risk

The guard remains intentionally fail-open on malformed input, missing Python,
or internal parsing errors, and retains
`LOOP_SPEC_PLACEHOLDER_QUESTION_GUARD=0` as a kill switch. This favors harness
availability over enforcement when the guard itself cannot evaluate a call; the
PR owner explicitly selected this policy during revision.

## Verification

- `bash hooks/team/placeholder-question-guard.test.sh`: 33 passed.
- `bash tests/lib/harness-call-shapes.test.sh`: 36 passed.
- `bash tests/delivery-phase-coverage.test.sh`: 50 passed.
- `bash tests/validate-manifest.test.sh`: 8 passed.
- `bash lib/bump-version.sh --check`: `4.7.2`.
- Final independent code review: no remaining findings.
- Style, comment, failure, documentation, indirection, and whitespace checks
  passed. Duplication scanning reported only standalone hook/test patterns that
  intentionally remain local to avoid cross-hook runtime coupling.

The broad repository suite produced 191 passes and 5 failures. Re-running those
failures in the untouched base checkout reproduced four environment/runtime
failures; the remaining phase-handoff test passed there and was affected by the
active revision worktree state. None was introduced by this PR's diff.
