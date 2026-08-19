# Harness call contracts (verified against live tool schemas)

Every harness tool call a skill instructs MUST match the tool's real parameter schema —
a call that "reads right" but fails `InputValidationError` silently downgrades the whole
cycle (that is exactly how pinned model IDs broke every implicit-team spawn; v2.5.1).
This file is the recorded contract; `tests/lib/harness-call-shapes.test.sh` lints the
skill corpus against it.

**Verification method:** the Agent `model` enum was re-verified LIVE on 2026-08-11 by
issuing `Agent({model: "inherit", ...})`, which returns
`InputValidationError: Invalid option: expected one of "sonnet"|"opus"|"haiku"|"fable"`.
The public subagent reference documents `inherit` for an agent DEFINITION's frontmatter;
that is a different surface from this tool parameter, and reading the prose instead of
the schema is what this file exists to prevent. Named spawn, shared-TaskList, and peer
SendMessage behavior was previously live-verified in both teams-off and teams-enabled
sessions on CC 2.1.187. Re-verify after harness upgrades with the authoritative SDK types
and `ToolSearch("select:<Tool>")` in a live session, then diff against this file.

## Agent

```
Agent({
  description: "<3-5 word task label>",   // REQUIRED
  prompt: "<the task>",                    // REQUIRED
  subagent_type: "loop-spec:<role>",       // optional; omit = general-purpose
  model: "sonnet" | "opus" | "haiku" | "fable",  // optional; ALIAS ENUM — "inherit" and literal IDs REJECTED
  name: "<teammate-name>",                 // optional; named = persistent, SendMessage-addressable
  run_in_background: true | false,          // optional; see portability rule below
  mode: "acceptEdits" | ... | "plan",      // deprecated and ignored since CC 2.1.212
  isolation: "worktree" | "remote",        // optional
})
```

- `description` and `prompt` are required. Every skill example must carry both.
- `model` is an ALIAS ENUM on this tool: `sonnet`, `opus`, `haiku`, `fable`. The literal
  string `inherit` and full model IDs are both rejected here, even though the CLI's
  `--model` flag and an agent definition's frontmatter accept them. **Inheritance is
  expressed by OMITTING the field** — an omitted `model` uses the agent definition's
  model, or the parent session's. A resolved selector of `inherit` therefore means
  "emit no `model` key", never `model: "inherit"` (see `model-matrix.md`).
- `run_in_background` is part of the current public schema, but loop-spec never emits it
  because older supported harness generations omitted it and modern subagents are
  backgrounded by default (CC 2.1.198). Parallel fan-out means issuing multiple Agent
  calls in one message, not setting a background flag.
- `mode` is deprecated and ignored since CC 2.1.212. Subagents inherit the parent
  session's permission mode, subject to their agent-definition tool restrictions.
- `name` is live on the core tool as of CC 2.1.187 — verified in a session WITHOUT
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` by an actual named spawn + `SendMessage` by
  name (the teams surface merged into core; the flag remains loop-spec's routing gate
  via `lib/teams-capability.sh`, not a schema gate). `name` pattern:
  `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`. On the implicit-team harness (CC >= 2.1.178 with
  the flag set), passing `name` starts an **in-process teammate** that inherits the
  lead session model; `model` and the agent definition's `model:` frontmatter are
  ignored. Honor a role alias by omitting `name` (`lib/implicit-team-model.sh`,
  `skills/shared/implicit-team-mode.md`).
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

- These are Claude Code-only session-root operations. OpenCode and ADK follow their
  additive `executionRootMode: "in-place"` contracts and never emulate either tool.
- `EnterWorktree({path})` to switch into an EXISTING worktree registered in
  `git worktree list` (loop-spec's Step 5 flow: `git-ops.sh` creates, then enter by
  path). `EnterWorktree({name})` creates fresh — not the loop-spec flow. `name`/`path`
  mutually exclusive.
- The `path` form has TWO different requirements, and loop-spec only ever uses the
  first: on first entry **from the launch directory** the path merely has to appear in
  `git worktree list` for this repository (or a repository nested inside it), so a
  worktree that `lib/worktree-base.sh` placed outside the repository is enterable.
  Switching **while already inside a worktree**, or from an agent with a pinned cwd,
  additionally requires the target to be under `.claude/worktrees/` of the same repo.
  Every loop-spec entry (Step 5, resume, post-pause re-entry after `ExitWorktree`)
  happens from the launch directory.
- `ExitWorktree({action: "keep" | "remove", discard_changes?})` — `action` REQUIRED.

## Skill

`Skill({skill: "loop-spec:<name>", args: "…"})`. Prose shorthand `Skill(loop-spec:plan)`
in skill bodies is an instruction to the orchestrating model, which must expand it to
the real shape. Any external skill remains unnamespaced:
`Skill({skill: "<name>", args: "..."})`, never `loop-spec:<name>`.

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

## ADK harness (a framework, not a coding agent)

Under ADK (`lib/harness.sh detect` == `adk`) the tool surface is the one the
bundled bridge builds: `Execute` / `ReadFile` / `WriteFile` / `EditFile` from
`EnvironmentToolset`, `list_skills` / `load_skill` / `load_skill_resource` from
`SkillToolset`, and `dispatch_subagent` over `AgentTool` — which takes the same
`{description, prompt, subagent_type}` shape as `Agent`. Glob and Grep have no
native tools; use `Execute`. Team tools, `Workflow`, `TaskCreate`/`TaskUpdate`,
and `ToolSearch` do not exist — apply the substitution table and dispatch mapping
rule in `skills/shared/adk-harness.md`. Headless dispatch goes through
`adk run <agent-dir> "<prompt>" --jsonl`, the same seam the loop-runner's
`--agent-cli adk` backend drives.

## opencode harness (native near-equivalents)

Under opencode (`lib/harness.sh detect` == `opencode`) most CC tools have
NATIVE counterparts with near-identical shapes: `Agent` → `task`
(`{description, prompt, subagent_type, task_id?, command?}` parameters;
`subagent_type` is required and agent ids are `loop-spec-<role>`, hyphen not
colon; `task_id` resumes a prior child session), `AskUserQuestion` →
`question` (rename `multiSelect` to `multiple`),
`Skill` → `skill({name: "loop-spec-<name>"})`, Read/Write/Edit/Bash/Glob/Grep → their lowercase
twins. Teams tools, `Workflow`, `TaskCreate`/`TaskUpdate`, and `ToolSearch`
still do not exist — apply the substitution table and dispatch mapping rule
in `skills/shared/opencode-harness.md`. Headless dispatch goes through
`opencode run --format json "<prompt>" --model <provider/model>`, the same
seam the loop-runner's `--agent-cli opencode` backend drives.

External skills use their own names — `skill({name: "<name>"})`. OpenCode's
skill tool accepts no arguments, so the surrounding prompt carries `. --update`.

## Codex harness (native plugin + spawn_agent)

Under the Codex harness (`lib/harness.sh detect` == `codex`) the tool surface
is Codex's own: file tools plus `apply_patch`, `Bash` / `exec_command`, skills
invoked as `$loop-spec-<name>` (or a plugin skill `$<name>`), and one-shot
dispatch through `spawn_agent`. Glob and Grep have no native tools; use Bash.
Team tools, `Workflow`, `TaskCreate`/`TaskUpdate`, and `ToolSearch` do not
exist — apply the substitution table and dispatch mapping rule in
`skills/shared/codex-harness.md`. Headless dispatch goes through
`codex exec --json --sandbox workspace-write "<prompt>"`, the same seam the
loop-runner's `--agent-cli codex` backend drives.

`spawn_agent` is the `Agent` counterpart (`features.multi_agent`, on by
default). Map `subagent_type: "loop-spec:<role>"` to `agent_type:
"loop-spec-<role>"` (installer-written `~/.codex/agents/loop-spec-<role>.toml`
or `.codex/agents/loop-spec-<role>.toml`), `prompt` to `message`, and
`description` to `task_name` when that field is on the schema. Pass
`fork_turns: "none"` (or `fork_context: false`) so a full-history fork cannot
reject the override. Optional `model` is a Codex slug; omit `inherit` and
Claude aliases. When a release hides `agent_type`, still spawn and prefix the
message with the role charter from `agents/<role>.md`.
