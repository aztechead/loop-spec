# Native attestation probe: record

Reference for the M1 implementer writing the `host-attested` check, and for the
re-auditor deciding whether roadmap section 19's first item is answered. It records
what native Claude Code exposed on one host on 2026-09-22, the check that was run
against it, and each case's outcome. It is one observation on one version, not a
compatibility promise.

## Host

| Item | Observed |
|---|---|
| Claude Code | 2.1.278, interactive session, maintainer present |
| Platform | macOS, Darwin 25.5.0 |
| Python | 3.13.2 |
| Install shape | plugin from the local tree; permission mode `bypassPermissions` |
| Runner | native: the lead dispatched each worker with the Agent tool, `model: sonnet`, background |
| Session id in the lead's shell | `CLAUDE_CODE_SESSION_ID`, set |

## What the host exposes

| Fact | Detail |
|---|---|
| Transcript location | `~/.claude/projects/<cwd with / replaced by ->/<session id>/subagents/` |
| Transcript name | `agent-a<dispatch name>-<16 hex>.jsonl`, with a sidecar `.meta.json`. The lead chooses the dispatch name; the hex suffix is the host's and is not returned to the lead |
| When written | from spawn, streamed; the opening record existed within seconds of dispatch, before the worker finished |
| Opening record | `type: user`, the dispatched prompt verbatim inside a `<teammate-message>` wrapper, plus `agentId`, `sessionId`, `timestamp`, `version`, `cwd`, `gitBranch` |
| Closing record | `type: assistant`, the worker's final message |
| Sidecar | `agentType`, `name`, `model`, `permissionMode`, `requestNonInteractive`, `spawnDepth` |
| Worker tools | no `AskUserQuestion`; a worker that tries finds it absent from the tool list and the deferred index |

## The check

The program composes the dispatch name from the step attempt id, so the name is
unique per attempt. Given the name, the composed prompt opening, the result file, and
the time the step was issued, the check:

1. resolves exactly one `agent-a<name>-*.jsonl` in the current session's `subagents/`
   directory; zero or more than one is `unattested`;
2. requires the first record to be `type: user` and to contain the composed opening;
3. requires the first record's timestamp to postdate the step issue;
4. hashes the result file and requires the last record to be `type: assistant` whose
   text ends with `LOOP_SPEC_RESULT_DIGEST sha256:<digest>`;
5. reads the sidecar for `model` and `permissionMode` into the evidence record.

The digest also appears earlier in the transcript as tool output from the worker's own
hash command, so the rule is "the closing record ends with", never "the transcript
contains".

## Results

| Case | Answer | Reason |
|---|---|---|
| step 0001, its own prompt and result | `host-attested` | opening matched; timestamp after issue; closing record ended with the result digest; 69 records |
| step 0002, its own prompt and result | `host-attested` | same; 30 records |
| step 0001's transcript checked against step 0002's prompt | `unattested` | opening does not contain the composed prompt |
| step 0001's transcript checked against step 0002's result file | `unattested` | closing record does not end with the result digest |
| a correct result file with a dispatch name that was never used | `unattested` | zero transcripts for that name |

The forged case is the second review's first finding: a lead writing a plausible result
file itself. It fails at step 1 because no transcript carries the name.

## Cancellation

A fourth worker ran a twelve-tick shell loop. `TaskStop` on its name returned success.
The loop's ticks stopped at the second one and no orphan process remained, so on this
host the stop also ended the worker's child process. The transcript ends on the
interrupted tool call with no `type: assistant` closing record, so a cancelled worker
can never attest. The stop tool's success result is the "host reporting the dispatch
ended" that roadmap section 5 requires before a retired worktree may be deleted.

## Question handling

A third worker was told to call `AskUserQuestion`. The tool was absent from its tool
list and from the deferred-tool index, and the worker reported that in its result file.
Workers cannot ask on this host, which matches section 8: interactive skills bind only
to lead roles.

## Not observed

- Permission denial. The session ran with `bypassPermissions`, so no tool call was
  denied. Observe under the default permission mode at M6.
- The SDK runner. This probe is native only.
- A retired worktree. No worktree was created for these steps.

## Consequences for the contract

- The dispatch name is the submittable id. The program names each dispatch after the
  step attempt and the lead passes that name to the Agent tool; `submit` needs nothing
  the tool result does not already give the lead.
- The program reads `CLAUDE_CODE_SESSION_ID` from its own environment to find the
  session directory. Under the SDK runner the check is not needed, because that runner
  is `controller-observed`.
- The review contract section tells the worker to end its final message with the
  digest line. A worker that does not is `unattested` by rule 4, which is the intended
  failure.
- Native review is the default review runner from this date.

## Files

The worker prompts, result files, and the check script live only in the session
scratchpad and are not committed. No transcript content beyond the fields named above
was copied anywhere.
