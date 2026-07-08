---
name: cycle
description: ENTRY POINT for loop-spec. Spec-driven feature cycle (SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY -> ITERATE, where ITERATE judges the result against the original goal and loops back until converged or the iteration limit is spent). Give it a feature description OR a path to a pre-authored spec .md file (spec-file ingest skips the interview). Single-tier operation: gate behavior is fixed; trivially-scoped plans skip the plan critique via a structural fast-path. Execution style defaults to auto (overridable inline, never asked). Model selection is fixed. Resumes incomplete features automatically.
argument-hint: "[new] [feature description | path/to/spec.md | backlog]  (optional inline overrides: style:auto|step|interactive|review-only, autonomous)"
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet EnterWorktree ExitWorktree ToolSearch Workflow
---

# loop-spec:cycle

Top-level orchestrator.

## Tool whitelist (CRITICAL)

The orchestrator (this skill running on the main thread) and every phase sub-skill it invokes may use ONLY these tools:

| Tool | Purpose |
|---|---|
| `TeamCreate` | Create a phase team (one per phase: discuss, plan, execute, verify, map-codebase) |
| `TeamDelete` | Tear down the current phase team at phase boundary; only the lead calls this |
| `SendMessage` | Lead-to-teammate and teammate-to-teammate messaging within a phase team |
| `TaskCreate` | Pre-populate the phase team's task list (lead only, at phase start) |
| `TaskUpdate` | Transition task status or write metadata fields (lead and teammates) |
| `TaskList` | Query current task states (lead and teammates) |
| `TaskGet` | Fetch a single task with full metadata (lead and teammates) |
| `Agent` | One-shot dispatch: Step 5.5b background codebase domain mappers |
| `Bash` | Invoking `lib/*.sh` scripts, git commands, file inspection |
| `Read` | Reading SPEC / PLAN / feature.json / source files |
| `Write`, `Edit` | Updating skill-owned artifacts only (feature.json via `lib/feature-write.sh`) |
| `AskUserQuestion` | Style / title prompts; pause-and-escalate decisions |
| `Skill` | Invoking another loop-spec skill (`Skill(loop-spec:plan)` etc.) |
| `Glob`, `Grep` | Code exploration |
| `EnterWorktree` | Switch the session into the feature worktree (Step 5 create; Step 1 resume) |
| `ExitWorktree` | Leave the feature worktree on pause or completion (action: "keep") |
| `ToolSearch` | Deferred-tool rescue only (Step 2 guarded contract): load a team primitive's schema before treating its failure as a capability refutation |
| `Workflow` | Opt-in fan-out rungs only: plan multi-angle authoring, verify acceptance/code-review workflows, EXECUTE DAG rung (gated on `runtime.json.workflowsAvailable`) |

Any tool not listed above is not permitted. `EnterWorktree` and `ExitWorktree` are used for the FEATURE-level worktree only (Step 5 / resume); per-TASK worktrees in EXECUTE use raw `git worktree add` via `lib/git-ops.sh` and do NOT use the harness tools. `WebFetch`, `WebSearch` are banned (offline by design). `CronCreate`, `CronList`, `CronDelete`, `ScheduleWakeup` are banned (synchronous execution only).

If a step you're about to take requires a tool not on the whitelist, stop and re-read the skill -- you're misinterpreting the instruction.

## Dispatch convention (CRITICAL)

Every phase runs inside a persistent **team** of named teammates. Teammates are spawned at phase start and persist for the full phase; they are NOT one-shot dispatches that die after one reply. How the team is created depends on `.loop-spec/runtime.json.teamsMode` (set in Step 2):
- **`explicit`** (CC < 2.1.178): the lead creates the roster with `TeamCreate` and tears it down with `TeamDelete` at the phase boundary.
- **`implicit`** (CC >= 2.1.178): the session already has one team. The lead spawns each teammate directly with `Agent({name: "<teammate-name>", description, subagent_type, model, prompt})` — no `TeamCreate`, no `TeamDelete`. See **`skills/shared/implicit-team-mode.md`**.

Inter-agent communication within a phase team uses `SendMessage` in BOTH team modes. This is the correct tool for routing work, critique rounds, and notifications between the lead and teammates (or between teammates directly by name).

Whenever a phase skill or this orchestrator says "instruct teammate X to revise" or "notify implementer of rework":
- Use `SendMessage({to: "<teammate-name>", message: "..."})` to address the teammate by their assigned name (e.g., `advocate-1`, `implementer-2`, `spec-writer-1`).
- Do NOT issue a fresh `Agent` call for rework within a phase -- teammates persist and can receive further instructions via `SendMessage`. (In `implicit` mode the *initial* spawn is an `Agent({name})` call; rework after that still goes through `SendMessage`.)
- A fresh `Agent` call is reserved for the Step 5.5b background codebase domain mappers and the ITERATE phase's one-shot `iterate-judge` dispatch (`skills/iterate/SKILL.md`); both are main-thread one-shot dispatches, not team rework.

When a phase ends: in `explicit` mode call `TeamDelete` before the next phase's `TeamCreate`; in `implicit` mode there is nothing to delete — just clear `feature.json.currentTeamName` and stop messaging the phase's teammates.

This rule applies in DISCUSS, PLAN, EXECUTE, VERIFY, MAP-CODEBASE, and any sub-skill called from this cycle.

**Subagent depth (CC caps nested subagents at 5 levels; forked subagents count toward the cap).** loop-spec's dispatch stays well inside this: the orchestrator (depth 0) spawns phase teammates (depth 1), and a teammate may spawn at most one helper (e.g. a background mapper, depth 2). Phase teammates MUST NOT build their own deep subagent chains — if a teammate needs more fan-out, surface it to the lead rather than nesting. EXECUTE's loop-fleet rung sidesteps the cap entirely (each loop is a separate top-level `claude -p` process, not a nested subagent).

**No-teams fallback:** when `.loop-spec/runtime.json.teamsMode == "none"` (equivalently
`teamsAvailable == false`), every rule above degrades per the substitution table in
**`skills/shared/no-teams-fallback.md`**: no `TeamCreate`/`TeamDelete`/`SendMessage`
— teammates become one-shot `Agent` calls with the same agent types, models, and
prompt templates, rework rounds re-dispatch with prior summaries from
`gate-logs/` inlined, and EXECUTE's ladder selects the loop-fleet or subagent
rung. Phases MUST NOT call team tools when `teamsMode == "none"`; doing so
throws harness errors.

## Non-interactive mode

Set `LOOP_SPEC_NON_INTERACTIVE=1` to skip all AskUserQuestion calls (used by the manual non-interactive end-to-end matrix and CI).
When set, read answers from env vars instead:

| Env var | Values | AskUserQuestion it replaces |
|---|---|---|
| `LOOP_SPEC_ANSWER_STYLE` | `auto`, `step`, `interactive`, `review-only` | Execution style (Step 3) |
| `LOOP_SPEC_ANSWER_TITLE` | free text | Feature title (Step 3) |
| `LOOP_SPEC_SPEC_FILE` | path to an existing `.md` | Spec-file invocation (Step 3): headless equivalent of `/loop-spec:cycle path/to/spec.md`. When set, the title falls back to the file's first `# ` heading if `LOOP_SPEC_ANSWER_TITLE` is unset. |

Note: Non-interactive mode bypasses `AskUserQuestion` entirely by reading env vars. The S2 batching change (4 questions in one call) has no effect on non-interactive paths.

## Autonomous mode

The inline token `autonomous` (or `LOOP_SPEC_AUTONOMOUS=1`) is strictly stronger than
non-interactive: instead of requiring pre-pinned `LOOP_SPEC_ANSWER_*` values, every
`AskUserQuestion` site self-answers with the recommended option and records the assumption
in the decisions record. Style is forced to `auto`. Explicit `LOOP_SPEC_ANSWER_*` /
`LOOP_SPEC_CMD_*` vars still win where set. Full contract — trigger, precedence,
self-answer rule, decisions record, per-site map — in **`skills/shared/autonomous-mode.md`**;
every phase skill honors it. Headless form: `claude -p "/loop-spec:cycle autonomous <description>"`.
Setup answers made before SPEC.md exists (workspace repos, resume choice, commands) are
recorded to disk immediately — `lib/decisions.sh add .loop-spec/decisions-staging cycle
"<q>" "<a>" "<why>"` — never buffered in model memory (compaction would drop them). Step 5
migrates the staging record into the feature dir; SPEC renders it into SPEC.md's
`## Decisions (assumed — autonomous)` list via `decisions.sh render`.

## Procedure

**Startup is silent — and batched in ONE call.** The mechanical checks behind Steps 0
(workspace detection), 1 (resume scan), 2 (health-check) and the workflow probe run as a
single script; do NOT invoke workspace.sh / teams-capability.sh / graphify-preflight.sh /
workflow-availability.sh / backlog.sh individually, and do NOT narrate:

```bash
pf="$(bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-preflight.sh" run)"
# {workspace: {mode, root, repos?}, teams: {mode, available}, workflows: {available},
#  graphify: {ok, required, graph}, backlog: {count},
#  resume: {candidates: [...], skipped: [...]}, warnings: [...]}
```

Steps 0-2 below consume this blob — each step keeps only its decision points (greenfield
routing, repo confirmation, resume choice, orphan probes, hard-gate verdicts). Emit output
ONLY when (a) a check fails or `.warnings` is non-empty (print those lines verbatim), (b) a
resumable candidate exists and a choice is needed, or (c) Step 3 announces the launch line.
No "Running Step 0...", no per-step status prose. The user wants to land in the workflow,
not watch a preflight. (Step 3.5's model probe stays separate — it needs harness tools.)

### Step 0 - Workspace detection

Workspace mode comes FIRST, before resume detection or feature setup — it determines whether every subsequent step runs in single-repo mode or workspace mode. Read it from the preflight blob:

```bash
workspace_mode="$(jq -r '.workspace.mode' <<<"$pf")"
workspace_root="$(jq -r '.workspace.root' <<<"$pf")"
workspace_repos_json="$(jq -c '.workspace.repos // []' <<<"$pf")"
```

**mode == "none":** route to the greenfield branch below — this is no longer an unconditional abort. **mode == "single":** continue as normal; set `workspaceMode="single"`. **mode == "workspace":** announce repos, confirm participation, set `workspaceMode="workspace"`.

#### Greenfield branch (net-new application; `mode == "none"`)

`mode == "none"` means there is no repo here — which is exactly where a net-new
application starts. Resolve it:

1. **Greenfield requested** (`lib/parse-invocation.sh` reports `.greenfield == true` — the `new` token; Step 3 runs the same parse), **or** autonomous mode with a feature description: bootstrap a repo in place and continue as greenfield:
   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../lib/greenfield-bootstrap.sh" bootstrap
   ```
   (`git init -b <default>` + empty root commit; pre-existing untracked files are left untouched — never bulk-added. The script re-checks the workspace mode itself: exit 4 = existing repo refused, exit 5 = workspace refused, with the messages below.) Set `greenfield=1` and `workspaceMode="single"`. Autonomous mode records the bootstrap as an assumed decision (`lib/decisions.sh add .loop-spec/decisions-staging cycle ...`).
2. **Interactive, no `new` token:** ask ONE AskUserQuestion — "Not a git repo. Start a net-new application here (`git init`), or abort?" Options: `Start new project here` / `Abort`. On start, run the bootstrap above.
3. **Non-interactive without autonomous, or no description to build from:** abort with the original message (`loop-spec: not a git repo and no child repos found. cd into a repo, create .loop-spec/workspace.json, or start a net-new app with /loop-spec:cycle new <description>.`).

Greenfield consequences downstream (each step carries its own branch): Step 4 skips command detection (commands are backfilled by EXECUTE after the scaffold task lands), Step 5.4 defers the graphify build until source exists, Step 5.5 skips the codebase map (VERIFY's refresh writes the first one), SPEC round 1 runs the **Foundations** perspective (stack/structure/tooling — `skills/spec/SKILL.md`), and PLAN must emit a scaffold-first task DAG (`skills/plan/SKILL.md`, "Greenfield plans"). Persist the flag as `feature.json.greenfield = true` (Step 5).

The `new` token inside an EXISTING repo (mode `single`) is refused — `greenfield-bootstrap.sh` exits 4 with `already a git repo — greenfield is for empty directories. Run the normal cycle, or cd into an empty directory for a new app.` Workspace mode has no greenfield variant (exit 5; multi-repo bootstrap is out of scope; deferred). Relay the script's message verbatim and stop the greenfield path.

Announce the discovered repos, confirm participation (interactive `AskUserQuestion`; `LOOP_SPEC_ANSWER_REPOS` when non-interactive; autonomous mode takes all discovered repos and records the assumption — `skills/shared/autonomous-mode.md`), filter `workspace_repos_json` to the participating repos, and merge `workspaceMode`/`workspaceRoot`/`workspaceRepos` into `.loop-spec/runtime.json` -- exact prompts and merge-write snippet in `${CLAUDE_SKILL_DIR}/references/workspace-mode.md` ("Step 0 detail").

### Step 1 - Resume detection

The mechanical scan is DONE — `.resume.candidates` in the preflight blob holds every
schema-7, non-completed, non-stale feature, most-recently-updated first (each with
`{slug, currentPhase, updatedAt, currentTeamName, needs_probe, worktreePath, workspace,
teamsMode, parse_source}`); `.resume.skipped` and `.warnings` hold what was dropped and
why (unparseable both ways, `schemaVersion != 7` — loop-spec is **schema-7 only** —
staleness). Do not re-scan the directory. What remains is the judgment the script cannot
make:
- **Orphan probes** (`needs_probe == true`, i.e. `currentTeamName != null`): if the
  candidate's `teamsMode == "explicit"` (legacy harness — only there does `TaskList`
  accept a `team` argument), probe team liveness (`TaskList({team: ...})`) and sort the
  feature into the resumable list or a "needs cleanup" sub-list — exact probe outcomes,
  messages, and the staleness rule per `skills/shared/cycle-resume-escalation.md`
  ("Step 1 orphan detection"). In `implicit`/`none` modes do NOT probe (the modern
  `TaskList` takes no parameters and teammates never survive the session): clear
  `currentTeamName` and treat the candidate as resumable.

If resumable list non-empty: present via AskUserQuestion (or skip if `LOOP_SPEC_NON_INTERACTIVE=1`):
- "Resume {slug} (phase: {currentPhase}, last updated {ago})?"
- Options: each resumable feature + "New feature"
- Autonomous mode: no question — resume the most recently updated resumable feature; if the invocation carries a new description that matches none of them, start the new feature instead. Record the choice.

If user picks resume: load feature.json into memory, skip Steps 2-5, route to Step 6 — **after the re-grounding protocol below.**

**Resume re-grounding (MANDATORY before re-entering any phase).** A resumed session knows nothing the previous one learned, and the tree may be silently broken. Re-orient from durable state before building on it:

1. Read `.loop-spec/features/{slug}/PROGRESS.md` (the narrative journal: what happened, what's next, gotchas). If absent (pre-2.5.0 feature), skip without warning.
2. `git log --oneline -10` on the feature branch (workspace mode: per participating repo) — reconcile against the journal.
3. Run `feature.commands.test` once (workspace mode: per repo with a non-empty test command). **If it fails:** do NOT re-enter the recorded phase on top of a broken tree — append a FULL-SHAPE remediation task (`subject = "Fix: test suite broken at resume"`, `verifyCommand = feature.commands.test`, `blockedBy = []`, `files = []` (unknown until diagnosed), `acceptanceCriteria = ["test suite passes"]` — partial-shape tasks get DENIED by the task guard when EXECUTE registers them) to `pendingRemediationTasks[]`, set `currentPhase = "execute"`, and print one line saying resume was redirected to remediation. If it passes (or no test command is configured): continue to the recorded phase.
- **Workspace resume (`workspace` block non-null):** resume IN PLACE at the workspace root. No worktree probe; do NOT call `EnterWorktree`. Assert that the current session cwd equals `feature.workspace.root`; if it does not, tell the user: `"cd to {feature.workspace.root} and re-invoke cycle to resume this feature."` and abort. All phase work proceeds from `workspace.root` using per-repo absolute paths.
- **Worktree resume (`workspace == null`, `worktreePath` present):** run `git-ops.sh list-feature-worktrees` to confirm it exists, then `EnterWorktree({ path: feature.worktreePath })` before Step 6. If the worktree is gone, warn and offer to re-create or continue in-place.
- Full algorithm: `skills/shared/cycle-resume-escalation.md`.

### Step 2 - Startup health-check

Probe agent-teams availability. Teams are an ACCELERATOR, not a prerequisite:
when they are unavailable the cycle still runs end-to-end on the documented
fallbacks (DISCUSS/PLAN/VERIFY: one-shot subagent fallback per the **No-teams
fallback** contract below; EXECUTE: loop-fleet or subagent rung). Do NOT abort.

Agent teams come in **two harness generations**, and the cycle must route to the right
one. Claude Code **>= 2.1.178** removed the `TeamCreate` / `TeamDelete` tools: every
session now has one implicit team and teammates are spawned directly via `Agent({name})`.
Earlier versions use the explicit `TeamCreate` / `TeamDelete` roster model. `lib/teams-capability.sh`
resolves which generation is live into a single **mode** word (deterministic, version-gated —
mirrors the `Workflow` probe; does not rely on model self-introspection):

```bash
teams_mode="$(jq -r '.teams.mode' <<<"$pf")"          # none | explicit | implicit
teams_available="$(jq -r '.teams.available' <<<"$pf")"

case "$teams_mode" in
  none)
    loops_hint="subagent fallback"
    command -v claude >/dev/null 2>&1 && loops_hint="loop-fleet + subagent fallback"
    echo "loop-spec: agent teams off (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS != 1)."
    echo "  Continuing with ${loops_hint}. For persistent phase teams: export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1." ;;
  implicit)
    echo "loop-spec: agent teams on (implicit-team model, CC >= 2.1.178)."
    echo "  Teammates are spawned via Agent({name}); TeamCreate/TeamDelete are not used. See skills/shared/implicit-team-mode.md." ;;
  explicit)
    echo "loop-spec: agent teams on (explicit-team model, CC < 2.1.178). Per-phase TeamCreate/TeamDelete." ;;
esac
```

**`teams_mode` decides every phase's dispatch path:**

- `none` → no teams. Phases use **`skills/shared/no-teams-fallback.md`** (one-shot
  `Agent`; EXECUTE uses the loop-fleet or subagent rung). Phases MUST NOT call any team tool.
- `implicit` → teams are live but `TeamCreate` / `TeamDelete` do **not** exist. Phases
  spawn named teammates with `Agent({name})` and message them via `SendMessage` per
  **`skills/shared/implicit-team-mode.md`**. Phases MUST NOT call `TeamCreate` / `TeamDelete`
  (they throw `No such tool available`).
- `explicit` → the per-phase `TeamCreate` / `TeamDelete` roster model, as written in each phase skill.

**Guarded-team-op contract (CRITICAL — explicit-mode safety net):** the version gate is
deterministic, but a non-standard harness could still disagree with it. So in **`explicit`
mode only**, whenever a phase issues its first `TeamCreate` (or any team op) and it throws
`No such tool available` (or any "tool not found"/unknown-tool error from a team primitive),
treat it as a capability refutation, NOT a fatal error:

1. If the harness is the modern one (the tools were removed, not the flag), re-resolve via
   `LOOP_SPEC_TEAMS_MODE=implicit` and re-run the phase per `skills/shared/implicit-team-mode.md`.
   Otherwise downgrade to `none`. Merge-write the corrected mode:
   ```bash
   python3 -c "import json,sys;p='.loop-spec/runtime.json';d=json.load(open(p));m=sys.argv[1];d['teamsMode']=m;d['teamsAvailable']=(m!='none');json.dump(d,open(p,'w'))" implicit   # or: none
   ```
2. Print: `loop-spec: explicit team tools not exposed by this harness; switching to <implicit-team | one-shot Agent> dispatch.`
3. Re-run the current phase on the corrected path. Do NOT re-attempt the explicit team op in this session.

In `implicit` and `none` mode the contract is a no-op — those phases never call `TeamCreate`,
so there is nothing to refute. This keeps a version/tool-surface disagreement self-healing on
the first op instead of a hard stop mid-phase.

**Deferred-tool rescue (applies in `implicit` AND `explicit` mode, BEFORE any refutation):**
modern harnesses may expose team primitives (`SendMessage`, `TaskCreate`, `TaskUpdate`,
`TaskList`, `TaskGet`) as **deferred tools** — the tool exists but its schema is not loaded,
and a direct call fails with `InputValidationError` (or a "schema not loaded" / "tool not
loaded" error) rather than `No such tool available`. That failure is NOT a capability
refutation. When any team primitive fails this way:

1. Call `ToolSearch("select:<ToolName>")` (e.g. `ToolSearch("select:SendMessage,TaskCreate,TaskUpdate,TaskList,TaskGet")`)
   to load the schema, then retry the op ONCE.
2. Only if `ToolSearch` reports no matching deferred tool (or the retry still throws
   `No such tool available`) does the failure count as a refutation for the guarded
   contract above.

Misreading a deferred tool as a missing tool is exactly the failure that silently downgrades
a teams-capable harness to the no-teams fallback — rescue first, refute second.

`teams_mode` and `teams_available` are persisted into `.loop-spec/runtime.json` together with
the workflow probe below; phase skills read them to pick their dispatch path.

**Graphify is a HARD requirement** (unlike teams). graphify is loop-spec's de-facto
code-graph solution; the design phases (SPEC / DISCUSS / PLAN) query the graph to ground
their work, so the cycle aborts when it is missing rather than degrading. This gate runs as
part of the silent startup batch:

```bash
if [[ "$(jq -r '.graphify.ok' <<<"$pf")" != "true" && "$(jq -r '.graphify.required' <<<"$pf")" == "true" ]]; then
  # Print install instructions (graphify-preflight.sh check emits them on stderr).
  bash "${CLAUDE_SKILL_DIR}/../../lib/graphify-preflight.sh" check || true
  echo "loop-spec: aborting -- graphify is required. Install it, or set LOOP_SPEC_REQUIRE_GRAPHIFY=0 to bypass (not recommended)." >&2
  exit 1
fi
```

The only escape hatch is `LOOP_SPEC_REQUIRE_GRAPHIFY=0` (constrained environments); with it
set, the design phases fall back to Glob/Grep grounding and emit a degraded-mode warning.

Model availability is probed in Step 3.5. Model selection is fixed (no preset), so the probe always covers the same two models.

### Step 3 - Resolve style + feature

Goal: launch straight into the workflow with **zero menu friction**. There is NO tier:
gate behavior is fixed (`skills/shared/tier-matrix.md`), and trivially-scoped
work is handled by the structural fast-path AFTER planning (measured scope), never by an
intent tier inferred from the prompt. Style defaults to `auto` unless overridden inline.

Token parsing is DETERMINISTIC — do not parse `$ARGUMENTS` by prose. One call
classifies the invocation and strips every recognized token from the title (a stray
`tier:quality` left in `feature_title` pollutes the ITERATE oracle — that bug is why
this script exists):

```bash
inv="$(bash "${CLAUDE_SKILL_DIR}/../../lib/parse-invocation.sh" parse -- "$ARGUMENTS")"
# {mode: description|spec-file|backlog|bare, title, slug, style, autonomous,
#  greenfield, no_run, spec_path, legacy: []}
```

`.mode` selects the branch below; `.style` defaults to `auto`; `.autonomous` /
`.greenfield` feed the autonomous contract and Step 0's greenfield branch; `.legacy`
non-empty gets the one-line "ignored legacy token" notice.

Resolution order:

1. **Non-interactive** (`LOOP_SPEC_NON_INTERACTIVE=1`): read env vars. Defaults when unset: `LOOP_SPEC_ANSWER_STYLE` → `auto`, `LOOP_SPEC_ANSWER_TITLE` → required (abort if unset — EXCEPT when `LOOP_SPEC_SPEC_FILE` is set, where the title falls back to the spec file's first `# ` heading, else its filename). If `LOOP_SPEC_SPEC_FILE` points to an existing readable `.md`, apply the spec-file invocation branch (3) below with that path (abort if set but unreadable). Legacy `LOOP_SPEC_ANSWER_TIER` / `LOOP_SPEC_ANSWER_PRESET` env vars, if set, are ignored with a one-line notice (single-tier operation; model selection is fixed).

2. **`mode == "description"`** (the user typed `/loop-spec:cycle <description>`): this is the default fast path.
   - Title = `.title`, slug = `.slug`, style = `.style` — all token-stripped by the parser. `autonomous` forces style `auto` (`skills/shared/autonomous-mode.md`); `greenfield` routes through Step 0's greenfield branch.
   - Do NOT call `AskUserQuestion`. Print one line and proceed:
     `Launching: style={style} title="{title}".`

3. **`mode == "spec-file"`** (loop-driven development from a spec file — `.spec_path` is the already-absolutized path): the user pre-authored the spec — do NOT run the SPEC interview against them. (This is also the handoff path from `/loop-spec:intake`, which converts non-spec sources — Slack messages, Jira tickets, prompts — into a draft at `.loop-spec/intake/{slug}.md` and invokes this branch.)
   - Title = the file's first `# ` heading (strip the `# `); fall back to the filename without extension. Slugify as usual.
   - `spec_draft_abs=".spec_path"` (the parser resolved it — Step 5 enters a worktree and relative paths die there).
   - Style = `.style`.
   - Print: `Launching from spec file: {path} — style={style} title="{title}".`
   - In Step 5, once the feature dir exists (single-repo: after the worktree `mkdir -p`; workspace: after the workspace-root `mkdir -p` in the Step 5 variant), copy the draft in: `cp "$spec_draft_abs" ".loop-spec/features/${slug}/spec-draft.md"` (workspace mode: prefix with `${workspace_root}/`). The SPEC phase detects `spec-draft.md` and runs **spec-file ingest mode** (validate + normalize the draft through the ambiguity gate, no interview — see `skills/spec/SKILL.md`).

4. **`mode == "backlog"`** (backlog-drain mode, optionally with inline overrides): the bounded Ralph loop over `.loop-spec/BACKLOG.md` — one feature per loop, explicit stop conditions.
   ```bash
   entry_json="$(bash "${CLAUDE_SKILL_DIR}/../../lib/backlog.sh" next --json)" || { echo "backlog empty — nothing to drain"; exit 0; }
   entry="$(jq -r '.text' <<<"$entry_json")"
   entry_id="$(jq -r '.id // empty' <<<"$entry_json")"
   ```
   - Use the entry text as the feature description (branch 2 above; style `auto` unless overridden). Run the full cycle for it. Record the originating entry on the feature (after Step 5 creates feature.json): `feature.json.backlogEntry = "<entry text>"` and `feature.json.backlogEntryId = "<entry_id>"` (null when the entry carries no id) — ITERATE's autonomous terminal rule matches the id exactly to detect a gap spending its rounds twice.
   - On completion (the On-completion section finishing cleanly), mark it off: `bash .../lib/backlog.sh done "$entry"`.
   - **Loop bound:** `LOOP_SPEC_MAX_FEATURES` (default `1`). After marking an entry done, if features completed this invocation `< LOOP_SPEC_MAX_FEATURES` and `backlog.sh next` yields another entry, start the next cycle from Step 3 branch 2 with it. Stop when the bound is hit, the backlog is empty, or any feature ends paused/escalated (never chain past a failure).
   - Overnight form: an outer `while :; do claude -p "/loop-spec:cycle backlog"; done` gets one feature per fresh session — the Ralph loop with real stop conditions.

5. **`mode == "bare"`** (no description): the only thing genuinely required is the work itself. Ask ONE free-text `AskUserQuestion` for what the user wants to build — do NOT ask for style. Style = `auto`. Use the answer as the title. Never present a style menu. Autonomous mode cannot self-answer this (there is no goal to infer): abort with `autonomous invocations must carry a feature description, a spec file path, or 'backlog'.` — unless resume detection (Step 1) already selected a resumable feature.

Slug = the parser's `.slug` (kebab-case of title); for titles resolved after parsing (spec-file heading, bare-invocation answer) use `lib/git-ops.sh slugify "$title"`.

> The grill directive (`hooks/team/grill-inject.sh`, on by default) may already have
> elicited disambiguating answers before SPEC runs; feed those into the inference above so
> the SPEC reflects the clarified scope, not just the raw one-liner. Do not re-grill once
> the SPEC phase starts — SPEC's Socratic interview is the in-cycle grill. In autonomous
> mode the hook suppresses the directive (`LOOP_SPEC_AUTONOMOUS=1`); there is nobody to grill.

### Step 3.5 - Model probe + Workflow availability probe

Model selection is fixed (aliases `{opus, sonnet}`); probe results are cached 24h in `.loop-spec/runtime.json` (`LOOP_SPEC_SKIP_HEALTHCHECK=1` skips). Run the model dispatch probe now, verbatim per `${CLAUDE_SKILL_DIR}/references/startup-probes.md` (probe mechanics, cache format, degraded-mode handling). The `Workflow` availability answer is already in the preflight blob (`jq -r '.workflows.available' <<<"$pf"`) — do not re-probe; persist it as `workflowsAvailable` per the same reference. The cycle proceeds regardless of probe outcomes; fan-out skills read `runtime.json` to pick their dispatch path (`skills/shared/dispatch-fanout.md`).

### Step 4 - Detect project commands

Auto-detect test/lint/typecheck commands (best effort) and confirm with the user (one `AskUserQuestion`; skipped when `LOOP_SPEC_NON_INTERACTIVE=1`, where `LOOP_SPEC_CMD_*` env vars win; autonomous mode trusts the detection — `LOOP_SPEC_CMD_*` still wins — and records the assumption).

**Greenfield:** skip detection entirely (there is nothing to detect); leave all three commands empty with a one-line note. EXECUTE backfills them by re-running `lib/detect-test-cmd.sh` after the scaffold task (task-001) merges — see `skills/execute/SKILL.md` "Greenfield command backfill". Workspace mode detects per-repo commands (authoritative in `workspace.repos[].commands`; top-level `commands` stays empty). Apply the detection heuristics and confirmation flow verbatim from `${CLAUDE_SKILL_DIR}/references/detect-commands.md`.

### Step 5 - Initialize state

If resuming: load feature.json into memory.

If new feature: compute slug + base_sha + base_branch in the MAIN checkout, create the feature worktree, enter it, then write feature.json INSIDE the worktree:

```bash
slug="$(bash "${CLAUDE_SKILL_DIR}/../../lib/git-ops.sh" slugify "$title")"
base_sha="$(git rev-parse HEAD)"
base_branch="$(bash "${CLAUDE_SKILL_DIR}/../../lib/git-ops.sh" detect-base-branch)"

# a. Create worktree on feat/{slug}; b. Enter it (all writes now land on feat/{slug}).
bash "${CLAUDE_SKILL_DIR}/../../lib/git-ops.sh" create-feature-worktree "$slug" "$base_sha"
EnterWorktree({ path: ".claude/worktrees/${slug}" })
# c. Create dirs and write feature.json INSIDE the worktree.
mkdir -p ".loop-spec/features/${slug}" .loop-spec/codebase "docs/loop-spec/features/${slug}"

# Build the full schema-7 skeleton from the single source of truth (lib/feature-init.sh).
# Model IDs, the fixed iterate block, and the artifact scaffold all
# live in that one script -- never hand-build feature.json inline (that drift is what
# previously dropped iterateJudge from the normalized models map). Every phase skill reads
# literal model IDs from feature.models.<role>, which guarantees teammates never silently
# inherit the orchestrator's session model.
feature_json=$(bash "${CLAUDE_SKILL_DIR}/../../lib/feature-init.sh" skeleton --mode single \
  --slug "$slug" --now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --style "$execStyle" --title "$title" \
  --branch "feat/${slug}" --base-sha "$base_sha" --base-branch "$base_branch" \
  --worktree ".claude/worktrees/${slug}" \
  --test "$cmd_test" --lint "$cmd_lint" --typecheck "$cmd_typecheck")

bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" ".loop-spec/features/${slug}" "$feature_json"

# Autonomous mode: persist the flag so phase skills and resumed sessions see it
# without re-parsing the invocation (skills/shared/autonomous-mode.md).
# Greenfield mode: persist it the same way (Step 0 greenfield branch set $greenfield).
[[ "${autonomous:-0}" == "1" ]] && bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set ".loop-spec/features/${slug}" autonomous true
[[ "${greenfield:-0}" == "1" ]] && bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set ".loop-spec/features/${slug}" greenfield true

# Move any pre-SPEC assumed decisions (recorded during Steps 0-4) into the feature dir
# so SPEC can render them; no-op when nothing was staged.
bash "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" migrate ".loop-spec/decisions-staging" ".loop-spec/features/${slug}"

#### Workspace mode Step 5 variant

In workspace mode (`workspaceMode == "workspace"`), do NOT call `create-feature-worktree` and do NOT call `EnterWorktree`; all work stays at the workspace root on in-place `feat/{slug}` branches. Apply the two-phase procedure (Phase 1: pre-flight cleanliness check across ALL repos before ANY branch is created; Phase 2: per-repo branch creation + the workspace-mode `feature-init.sh` skeleton) verbatim from `${CLAUDE_SKILL_DIR}/references/workspace-mode.md` ("Step 5 variant").

Provenance fields:
- `artifacts.patternsSource` -- one of `"gsd-ingest"`, `"pattern-mapper"`, `"manual"`, or `null` until written. Set in PLAN Step 0.
- `artifacts.codebaseSource.{domain}` -- one of `"gsd-ingest"`, `"mapper"`, `"manual"`, or `null` until written. Set per-domain in Step 5.5.

Print cost estimate based on expected scope:
```
Estimated cost: ~{N}k tokens
```

### Step 5.4 - Graphify bootstrap pre-flight (always; before the codebase-map skip)

**Workspace mode:** graphify operates on a single repo root, so workspace mode builds one graph **per participating repo** (see the workspace block at the end of this step) rather than skipping. graphify is still required in workspace mode.

---

Runs on EVERY cycle (single-repo mode). graphify is a hard requirement (enforced at Step 2), so the graph is built unconditionally and a build failure aborts — the design phases depend on it. It must NOT be gated behind the Step 5.5 "all 5 docs exist" skip: the graph (`graphify-out/graph.json`) is independent of the loop-spec codebase docs, so a repo that already has the 5 docs but no graph still needs one built. Idempotent, no LLM.

Decision tree:
- **Greenfield (`feature.json.greenfield` / `$greenfield == 1`) with no source files yet** -> defer: a graph of an empty repo grounds nothing. Print `greenfield: graphify build deferred until source exists (VERIFY refresh builds it)` and continue — the design phases ground in the stated goal and stack conventions instead, and VERIFY's map-refresh step builds the graph once EXECUTE has landed code. graphify itself must still be installed (Step 2 gate is unchanged).
- `graphify-out/graph.json` exists -> do nothing (already built).
- missing -> build via `lib/graphify-preflight.sh build .` (`graphify .`, deterministic AST extraction, no API key). A build failure aborts the cycle (unless `LOOP_SPEC_REQUIRE_GRAPHIFY=0`).
- missing + GSD `.planning/codebase/` present -> build the graph, then supersede the GSD docs: fold their content into `docs/loop-spec/codebase/` (gsd-ingest) and remove the raw GSD source (committed, recoverable).

```bash
graph_status="$(bash "${CLAUDE_SKILL_DIR}/../../lib/graphify-preflight.sh" graph-status .)"
if [[ "$graph_status" == "present" ]]; then
  echo "graphify graph present (graphify-out/graph.json); skipping bootstrap"
else
  echo "Building code graph (graphify, no LLM)..."
  if bash "${CLAUDE_SKILL_DIR}/../../lib/graphify-preflight.sh" build .; then
    git add graphify-out/ 2>/dev/null || true
    git commit -m "chore: NO_JIRA bootstrap graphify code graph" >/dev/null 2>&1 || true
    # Supersede GSD codebase docs: preserve content into loop-spec docs, then remove raw GSD.
    if [[ -d .planning/codebase ]]; then
      bash "${CLAUDE_SKILL_DIR}/../../lib/gsd-ingest.sh" codebase >/dev/null 2>&1 || true
      if ! git diff --quiet docs/loop-spec/codebase/ 2>/dev/null; then
        git add docs/loop-spec/codebase/
        git commit -m "docs: NO_JIRA ingest GSD codebase map before graphify supersession" >/dev/null 2>&1 || true
      fi
      git rm -r --quiet .planning/codebase 2>/dev/null || rm -rf .planning/codebase
      git add -A .planning 2>/dev/null || true
      git commit -m "chore: NO_JIRA remove GSD codebase docs superseded by graphify" >/dev/null 2>&1 || true
      echo "Superseded GSD codebase docs (.planning/codebase) and removed the raw GSD source"
    fi
  elif [[ "${LOOP_SPEC_REQUIRE_GRAPHIFY:-1}" == "0" ]]; then
    echo "warn: graphify build failed but requirement bypassed; design phases will use Glob/Grep fallback" >&2
  else
    echo "loop-spec: aborting -- 'graphify .' failed and graphify is required (set LOOP_SPEC_REQUIRE_GRAPHIFY=0 to bypass)." >&2
    exit 1
  fi
fi
```

**Workspace mode:** graphify operates on a single repo root. Build a graph **per participating repo** (loop over `workspace_repos_json`, running `lib/graphify-preflight.sh build "$repo_abs"` in each), committing each repo's `graphify-out/` in place. A per-repo build failure aborts unless bypassed. The design phases query whichever repo's graph is in scope.

### Step 5.5 - First-run codebase map (one-time per project)

One-time per project: ingest an existing GSD `.planning/codebase/` if present (Step 5.5a), then fire background mappers only for the domains still missing (Step 5.5b). Skip only when all 5 domain docs already exist in `docs/loop-spec/codebase/` — **or when greenfield** (an empty repo has nothing to map; VERIFY's end-of-cycle refresh writes the first map from the shipped code). Apply the full procedure verbatim from `${CLAUDE_SKILL_DIR}/references/codebase-map-bootstrap.md` (GSD ingest rules, mapper dispatch, commit discipline, `bootstrapPendingDomains` bookkeeping, workspace-mode behavior).

### Step 5.9 - Normalize feature.models (resume backfill + migration)

Phase skills read `model: feature.models.<role>` literally and do NOT re-derive from `model-matrix.md`. Model selection is fixed, so the canonical map is the same for every feature. Older features either lack a `models` block (pre-v2.3.0) or carry a stale one from the removed preset scheme. Before routing to any phase, write the canonical fixed map idempotently and drop the vestigial `preset` and `tier` fields (single-tier hard cutover: any legacy retryBudget block in the file is simply ignored, and the tier axis no longer exists). This is the single fallback point, so no individual phase skill needs its own:

```bash
feat_dir=".loop-spec/features/${slug}"
fjson="${feat_dir}/feature.json"
# Canonical map comes from the SAME source Step 5 uses (lib/feature-init.sh models), so
# the two can never drift -- this drift is what previously dropped iterateJudge here.
canonical="$(bash "${CLAUDE_SKILL_DIR}/../../lib/feature-init.sh" models)"
# Normalize by MERGE, not replace: force canonical IDs for known roles while preserving
# any extra role the skeleton may carry. Rewrite only when the merged result differs from
# the current map, or a vestigial preset field lingers. Only .models and .preset are
# touched; all other fields (including worktreePath) are preserved.
merged="$(jq -c --argjson m "$canonical" '(.models // {}) * $m' "$fjson")"
if [[ "$(jq -c '.models // {}' "$fjson")" != "$merged" \
      || "$(jq 'has("preset") or has("tier")' "$fjson")" == "true" ]]; then
  new_json="$(jq --argjson m "$canonical" '.models = ((.models // {}) * $m) | del(.preset) | del(.tier)' "$fjson")"
  bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" "$feat_dir" "$new_json"
  echo "Normalized feature.models to the fixed model map (and dropped legacy tier/preset)."
fi

# Backfill feature_title (pre-2.4.0 features lack it). It is the IMMUTABLE original
# goal that the ITERATE judge scores against; without it the judge silently falls back
# to SPEC.md -- the exact drift the dual oracle exists to prevent. The slug is the only
# available (lossy) stand-in on old features; never overwrite an existing value.
if [[ "$(jq -r '.feature_title // ""' "$fjson")" == "" ]]; then
  new_json="$(jq '.feature_title = .slug' "$fjson")"
  bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" "$feat_dir" "$new_json"
  echo "Backfilled feature_title from slug (pre-2.4.0 feature; lossy stand-in for the original goal)."
fi
```

### Step 6 - Route to phase

The cycle does NOT create the phase team. Each phase skill owns its own team lifecycle: `TeamCreate` at phase start, `TeamDelete` + clear `currentTeamName` at phase end. This keeps team rosters phase-specific (each phase has different teammates) and avoids double-`TeamCreate` errors.

For new features, `currentPhase` is initialized to `"spec"` (Step 5), so `Skill(loop-spec:spec)` is invoked first. After spec completes, `currentPhase` advances to `"discuss"`, then `"plan"`, `"execute"`, `"verify"`, then `"iterate"`, and finally `"completed"`. The `iterate` phase is the outer convergence loop: it judges the result against the original goal and may route `currentPhase` **back** to `"execute"`, `"plan"`, or (with your approval) `"spec"`/`"discuss"` to fix a gap, or forward to `"completed"` when converged or the iteration limit is spent. Because ITERATE can rewind the phase pointer, the cycle's phase loop (below) naturally re-invokes the upstream phase.

Cycle's only responsibility here is to invoke the phase skill and react to its return:

1. **Invoke phase skill** (with the watchdog stamp):
   ```bash
   # Phase watchdog: stamp the phase start so a hung phase is detectable (resume + exit check).
   bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set ".loop-spec/features/${slug}" currentPhaseStartedAt "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
   bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" phase_start --phase "${currentPhase}" || true
   ```
   ```
   Skill(loop-spec:{currentPhase})
   ```
   `{currentPhase}` is read from the in-memory `feature_json` loaded earlier (`feature_json.currentPhase`). The phase skill runs inside its own team, writes `currentTeamName` on entry, advances `currentPhase`, and clears `currentTeamName` on exit (all via `lib/feature-write.sh`).

2. **Re-load feature.json** after the skill returns (the skill may have advanced `currentPhase` and updated artifacts):
   ```bash
   feature_json=$(cat ".loop-spec/features/${slug}/feature.json")
   next_phase=$(echo "$feature_json" | jq -r '.currentPhase')
   ```

   **Phase watchdog check:** compare now against `currentPhaseStartedAt` and the phase ceiling — 60 minutes default, overridable via `LOOP_SPEC_PHASE_TIMEOUT_MINS`. If the phase that just returned exceeded its ceiling, print a one-line warning (`phase {name} took {N}m, ceiling {M}m`) and append it to `warnings[]`; if a RESUMED feature's `currentPhaseStartedAt` is already past the ceiling before re-invoking (the previous session hung or died mid-phase), do NOT blindly re-enter — surface it: `phase {name} exceeded its {M}m ceiling in a prior session; resuming from last durable state` and let the phase skill's own resume logic pick up from artifacts. The watchdog never kills work; it makes a wedged loop visible instead of silently eternal.

   **Progress journal (append-only narrative — the machine state's "why").** Append one short block to `.loop-spec/features/{slug}/PROGRESS.md` (create with a `# Progress — {slug}` heading if absent):
   ```
   ## {ISO timestamp} — {phase} → {next_phase}
   - did: <1-2 lines: what this phase produced/decided>
   - next: <1 line: what the next phase must do>
   - gotchas: <0-2 lines: anything a fresh session must know (build quirks, env, partial work); omit if none>
   ```
   Commit it together with feature.json below — and ensure the gitignore exception exists first (the feature dir is ignored except named files; without this line the add silently no-ops):
   ```bash
   grep -qxF '!/.loop-spec/features/*/PROGRESS.md' .gitignore 2>/dev/null \
     || printf '!/.loop-spec/features/*/PROGRESS.md\n' >> .gitignore
   ```
   `events.jsonl` and `result.json` are local telemetry, deliberately not committed — the default `.loop-spec/features/*/` gitignore covers them and no exception is added.

   feature.json says WHERE the loop is; PROGRESS.md says WHY — it is what a fresh or compacted session reads to re-orient (Step 1 re-grounding), and the handoff document for fresh-context rewinds.

   Emit the `phase_end` event before committing (the event is non-fatal — it must not gate the commit):
   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" phase_end \
     --phase "{phase}" --data "{\"next\":\"${next_phase}\"}" || true
   ```

   **Commit the resume contract (single point).** feature.json is committed (not gitignored)
   so resume survives a clone or hand-off to another machine. The cycle is the one place
   that observes every phase transition, so it snapshots state here -- phase skills do NOT
   each commit feature.json. Guarded so workspace-mode (where the root may not be a git
   repo) is a safe no-op:
   ```bash
   fj=".loop-spec/features/${slug}/feature.json"
   if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
     git add "$fj" ".loop-spec/features/${slug}/PROGRESS.md" 2>/dev/null
     git diff --cached --quiet 2>/dev/null || git commit -q -m "chore: NO_JIRA ${slug} state @ ${next_phase}" || true
   fi
   ```

3. **Route to next iteration:**
   - If `next_phase == "completed"`: jump to the "On completion" section below.
   - **Fresh-context rewind (opt-in, `LOOP_SPEC_ITERATE_FRESH=1`):** if the phase that just returned was `iterate` AND `next_phase` is a rewind (not `completed`) AND the env var is set: do NOT continue inline. The Ralph-loop bet is that a fresh context beats an accumulated one — the durable state (feature.json + PROGRESS.md + iterate.feedback) IS the handoff. Print:
     `fresh-context rewind: state committed; relaunch with /loop-spec:cycle (or let your outer loop do it) to re-enter {next_phase} in a clean session.`
     and return to the user. An outer `while :; do claude -p "/loop-spec:cycle"; done` (or the loop-runner) drives the relaunch; resume detection re-enters at `{next_phase}` with a fresh window.
   - If `execStyle` is `auto` or `review-only`: continue the loop -- invoke `Skill(loop-spec:{next_phase})`.
   - If `execStyle` is `step` or `interactive`: print phase summary and return to user. User re-invokes `Skill(loop-spec:cycle)` to continue (resume detection in Step 1 picks up the in-progress state).

## Resume strategy + phase pause/escalation

Full algorithm and escalation handling (iteration limit exhausted, NEEDS_CONTEXT, etc.) in **`skills/shared/cycle-resume-escalation.md`**. Step 1 carries the inline fast-path.

## On completion

Phase chain finishes when verify completes successfully. Before marking completed:

1. Call `TeamDelete({name: feature_json.currentTeamName})` (if `currentTeamName` is non-null) to tear down the final phase team.
2. Update `feature.json` via `lib/feature-write.sh`:
   ```bash
   completed_json="$(echo "$feature_json" | jq \
     '.currentPhase = "completed" | .currentTeamName = null | .currentTeammates = [] | .currentGate = {round: 0, phase: null} | .updatedAt = now | strftime("%Y-%m-%dT%H:%M:%SZ")')"
   bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" ".loop-spec/features/${slug}" "$completed_json"
   ```

Then print final summary (PR URL, commits, time, cost) — **and `warnings[]`, always checked:**

```bash
jq -r '.warnings[]?' ".loop-spec/features/${slug}/feature.json"
```

If non-empty, print them under a `## Shipped with warnings` heading, one bullet each, before
the PR URL. `iterate-budget-spent:` entries are accepted goal gaps — a completion that hides
them is indistinguishable from a clean converge, which is precisely how an unmet requirement
ships unnoticed. If empty, print nothing extra.

Also print the backlog state (one line, always):

```bash
n="$(bash "${CLAUDE_SKILL_DIR}/../../lib/backlog.sh" count)"
[[ "$n" -gt 0 ]] && echo "Backlog: ${n} deferred item(s) — drain with /loop-spec:cycle backlog"
```

And the retrospective signal (READ-ONLY, one line, non-fatal — the telemetry
loop's nudge; it never mutates rules on its own):

```bash
rc="$(bash "${CLAUDE_SKILL_DIR}/../../lib/retro.sh" report --json 2>/dev/null \
      | jq 'map(select(.kind == "rule-candidate")) | length' 2>/dev/null || echo 0)"
[[ "${rc:-0}" -gt 0 ]] && echo "Retro: ${rc} repeated-pattern rule candidate(s) — review with /loop-spec:retro (apply with /loop-spec:retro apply)"
```

Write the machine-readable result contract and emit the `completed` event (non-fatal):

```bash
_pr_url="$(jq -r '.prUrl // empty' ".loop-spec/features/${slug}/feature.json")"
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" write ".loop-spec/features/${slug}" \
  --status completed ${_pr_url:+--pr-url "$_pr_url"} || true
```

`.loop-spec/last-result.json` is the stable pointer headless wrappers should read; it is
overwritten on each cycle completion. `events.jsonl` (one JSON object per line, canonical
event names) records the full phase trace. Both are local telemetry and are not committed.

**Autonomous chaining (`feature.json.autonomous == true`).** An autonomous run manages its
own iteration cycles end-to-end — it does not complete by leaving `iterate-budget-spent`
gaps for a human to read (`skills/shared/autonomous-mode.md`, continuation ladder). The
chain decision is DETERMINISTIC — do not re-derive it from the ladder prose; call the
predicate and obey its verdict:

```bash
verdict="$(bash "${CLAUDE_SKILL_DIR}/../../lib/autonomous-chain.sh" should-chain "$feature_dir" --completed "$features_completed_this_invocation")"
```

- `{"chain": true, "entry": {...}}` → chain directly into backlog-drain mode (Step 3
  branch 4) with that entry. The chained feature inherits `autonomous` and carries
  `backlogEntry` + `backlogEntryId` from the entry JSON, so a gap that spends a second
  full round of iterations goes terminal instead of looping forever. After the chained cycle
  completes, re-run the predicate with the incremented `--completed` count.
- `{"chain": false, "reason": ...}` → stop chaining. The reasons encode the bounds that
  keep drain mode finite: `max-features-reached` (`LOOP_SPEC_MAX_FEATURES`, default 1),
  `feature-not-completed` (never chain past a paused/escalated cycle),
  `next-entry-terminal` (ITERATE's autonomous terminal rule), `backlog-empty`,
  `no-budget-spent-gaps`, `not-autonomous`.

When the verdict is `max-features-reached` with entries still queued (`backlog.sh count`
> 0), print the overnight form — `while :; do claude -p "/loop-spec:cycle backlog
autonomous"; done` — which drains the rest one bounded fresh-session cycle at a time.
Warnings stay in the PR as the audit trail; the backlog + chain is what actually handles
them.

**Note:** `TeamDelete` is called explicitly here at the orchestration layer. It is NOT implemented as a bash `trap` because `TeamDelete` is a harness MCP tool callable only from the lead's tool-using context, not from a shell signal handler. See the resume strategy orphan-detection path for killed-session cleanup.
