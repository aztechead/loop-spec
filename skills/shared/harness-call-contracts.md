# Harness call contracts (verified against live tool schemas)

Every harness tool call a skill instructs MUST match the tool's real parameter schema —
a call that "reads right" but fails `InputValidationError` silently downgrades the whole
cycle (that is exactly how pinned model IDs broke every implicit-team spawn; v2.5.1).
This file is the recorded contract; `tests/lib/harness-call-shapes.test.sh` lints the
skill corpus against it.

**Verification method:** schemas re-fetched from live Claude Code sessions (ToolSearch /
system tool definitions), CC 2.1.187, 2026-07-03 — in BOTH a teams-off session and a
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` session, plus a live implicit-team e2e (named
spawns, shared-TaskList self-claim, peer SendMessage, teammate→main relay). Re-verify
after harness upgrades: `ToolSearch("select:<Tool>")` in a live session and diff against
this file.

## Agent

```
Agent({
  description: "<3-5 word task label>",   // REQUIRED
  prompt: "<the task>",                    // REQUIRED
  subagent_type: "loop-spec:<role>",       // optional; omit = general-purpose
  model: "sonnet" | "opus" | "haiku" | "fable",  // optional; ALIAS ENUM — literal IDs REJECTED
  name: "<teammate-name>",                 // optional; named = persistent, SendMessage-addressable
  mode: "acceptEdits" | ... | "plan",     // optional permission mode for the spawned agent
  isolation: "worktree" | "remote",        // optional
})
```

- `description` and `prompt` are required. Every skill example must carry both.
- `model` takes harness aliases only (see `model-matrix.md`).
- `run_in_background`: never emit it. It is absent from the teams-off schema but
  ACCEPTED on a teams-enabled CC 2.1.187 (verified by live spawn) — i.e. it exists on
  some harness generations and not others, and is redundant everywhere: subagents are
  backgrounded by the harness itself (background-by-default rollout, CC changelog
  2.1.198). Parallel fan-out means issuing multiple Agent calls in one message, NOT
  setting a background flag.
- `name` is live on the core tool as of CC 2.1.187 — verified in a session WITHOUT
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` by an actual named spawn + `SendMessage` by
  name (the teams surface merged into core; the flag remains loop-spec's routing gate
  via `lib/teams-capability.sh`, not a schema gate). `name` pattern:
  `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`.
- `team_name` is accepted but ignored (harness marks it deprecated) — never emit it.

## AskUserQuestion

```
AskUserQuestion({
  questions: [{                            // REQUIRED array (1-4)
    question: "…ends with a question mark?",
    header: "<= 12 chars",                 // REQUIRED chip label
    options: [                             // 2-4 REQUIRED option OBJECTS
      { label: "Short choice", description: "What picking it means" },
      ...
    ],
    multiSelect: false                     // REQUIRED
  }]
})
```

- The flat `{header, question, options: ["A","B"]}` shape is INVALID: no `questions`
  wrapper, bare-string options, missing `multiSelect`, missing option descriptions.
- "Other" is provided automatically; never add it as an option.

## TaskCreate

```
TaskCreate({
  subject: "…",        // REQUIRED
  description: "…",    // REQUIRED — omitting it is an InputValidationError
  activeForm: "…",     // optional spinner text
  metadata: { ... }     // optional; loop-spec carries blockedBy/files/verifyCommand/etc. here
})
```

## TaskUpdate

`{taskId REQUIRED, status, subject, description, activeForm, owner, metadata (merge; null deletes a key), addBlocks, addBlockedBy}`.

## TaskList / TaskGet

- `TaskList()` — **takes NO parameters** on the modern harness. `TaskList({status: …})`
  is invalid; fetch the list and filter client-side.
- `TaskList({team: …})` exists only on the legacy explicit-team harness
  (`teamsMode == "explicit"`); it is the orphan-liveness probe. In `implicit` and `none`
  modes never pass arguments — and the probe is meaningless anyway (teammates do not
  survive the session), so skip it and treat the recorded team as gone.
- `TaskGet({taskId REQUIRED})`.

## EnterWorktree / ExitWorktree

- These are Claude Code-only session-root operations. OpenCode and pi follow their
  additive `executionRootMode: "in-place"` contracts and never emulate either tool.
- `EnterWorktree({path})` to switch into an EXISTING worktree registered in
  `git worktree list` (loop-spec's Step 5 flow: `git-ops.sh` creates, then enter by
  path). `EnterWorktree({name})` creates fresh — not the loop-spec flow. `name`/`path`
  mutually exclusive.
- `ExitWorktree({action: "keep" | "remove", discard_changes?})` — `action` REQUIRED.

## Skill

`Skill({skill: "loop-spec:<name>", args: "…"})`. Prose shorthand `Skill(loop-spec:plan)`
in skill bodies is an instruction to the orchestrating model, which must expand it to
the real shape. External skills remain unnamespaced: Graphify is
`Skill({skill: "graphify", args: ". --update"})`, never `loop-spec:graphify`.

## SendMessage

```
SendMessage({
  to: "<teammate-name>",   // REQUIRED string
  message: "<text>",       // REQUIRED string (was documented as 'body' — that is INVALID)
  summary: "<5-10 words>", // optional preview shown in the UI
})
```

- `message` is the correct parameter name. `body` is INVALID and was never the real
  parameter; every call using `body` fails InputValidationError at runtime.
- `summary` is optional ("5-10 word summary shown as a preview in the UI, required when
  message is a string" per live schema — the harness accepts the call without it but the
  UI preview is blank).
- `additionalProperties: false` — no extra keys are accepted.
- Live-verifiable even in sessions WITHOUT `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`:
  `SendMessage` is a deferred tool exposed in all modern sessions (verified CC 2.1.187).
  Load its schema with `ToolSearch("select:SendMessage")` before the first call.
- Schema is IDENTICAL with the teams flag on (re-verified in a
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` session, CC 2.1.187): `{to, message, summary}`,
  and the full lead→teammate→peer→main round trip works with these exact shapes.

## Team primitives (teams harnesses only)

`TeamCreate` / `TeamDelete`: legacy explicit harness only (CC < 2.1.178).
Deferred-schema rescue applies to all team-related tools (cycle Step 2).

## pi harness (no CC tool surface)

Everything above describes the Claude Code tool surface. Under pi
(`lib/harness.sh detect` == `pi`) NONE of these tools exist — the built-in set is
`read`, `bash`, `edit`, `write`, `grep`, `find`, `ls`, and there is no deferred-tool
mechanism to rescue. Do not emit `Agent`, `AskUserQuestion`, `SendMessage`,
`TaskCreate`/`TaskUpdate`, `Workflow`, or `ToolSearch` calls there; apply the
substitution table and inline dispatch rule in `skills/shared/pi-harness.md`
instead. Headless dispatch goes through the pi CLI
(`pi --mode json "<prompt>" --model <pi-model-id>`), which is the same seam the
loop-runner's `--agent-cli pi` backend drives.

## opencode harness (native near-equivalents)

Under opencode (`lib/harness.sh detect` == `opencode`) most CC tools have
NATIVE counterparts with near-identical shapes: `Agent` → `task`
(`{description, prompt, subagent_type}` parameters; `subagent_type` is required
and agent ids are `loop-spec-<role>`, hyphen not colon), `AskUserQuestion` →
`question` (rename `multiSelect` to `multiple`),
`Skill` → `skill({name: "loop-spec-<name>"})`, Read/Write/Edit/Bash/Glob/Grep → their lowercase
twins. Teams tools, `Workflow`, `TaskCreate`/`TaskUpdate`, and `ToolSearch`
still do not exist — apply the substitution table and dispatch mapping rule
in `skills/shared/opencode-harness.md`. Headless dispatch goes through
`opencode run --format json "<prompt>" --model <provider/model>`, the same
seam the loop-runner's `--agent-cli opencode` backend drives.

External skills use their own names. Graphify is `skill({name: "graphify"})`; OpenCode's
skill tool accepts no arguments, so the surrounding prompt carries `. --update`.
