---
name: cycle
description: "ENTRY POINT for loop-spec. Give it a feature description OR a path to a pre-authored spec .md file (spec-file ingest skips the interview). Runs SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY -> ITERATE -> DELIVER. Resumes incomplete features automatically. Do not use for a pasted stack trace (that's /loop-spec:debug) or a one-file ad-hoc fix (that's /loop-spec:micro)."
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
| `Agent` | One-shot dispatch: Step 5.5b background codebase domain mappers; DISCUSS Step 1.75 background PATTERNS.md prefetch |
| `Bash` | Invoking `lib/*.sh` scripts, git commands, file inspection |
| `Read` | Reading SPEC / PLAN / feature.json / source files |
| `Write`, `Edit` | Updating skill-owned artifacts only (feature.json via `lib/feature-write.sh`) |
| `AskUserQuestion` | Style / title prompts; pause-and-escalate decisions |
| `Skill` | Invoking another loop-spec skill (`Skill(loop-spec:plan)`) |
| `Glob`, `Grep` | Code exploration |
| `EnterWorktree` | Switch the session into the feature worktree (Step 5 create; Step 1 resume) |
| `ExitWorktree` | Leave the feature worktree on pause or completion (action: "keep") |
| `ToolSearch` | Deferred-tool rescue only (Step 2 guarded contract): load a team primitive's schema before treating its failure as a capability refutation |
| `Workflow` | Opt-in fan-out rungs only: plan multi-angle authoring, verify acceptance/code-review workflows, EXECUTE DAG rung (gated on `runtime.json.workflowsAvailable`) |

Any tool not listed above is not permitted. `EnterWorktree` and `ExitWorktree` are used for the FEATURE-level worktree only (Step 5 / resume); per-TASK worktrees in EXECUTE use raw `git worktree add` via `lib/git-ops.sh` and do NOT use the harness tools. `WebFetch`, `WebSearch` are banned (offline by design). `CronCreate`, `CronList`, `CronDelete`, `ScheduleWakeup` are banned (synchronous execution only).

If a step you're about to take requires a tool not on the whitelist, stop and re-read the skill -- you're misinterpreting the instruction.

## Dispatch convention (CRITICAL)

Team-capable phases (DISCUSS, PLAN, EXECUTE, VERIFY, MAP-CODEBASE and their sub-skills)
run inside a persistent **team** of named teammates spawned at phase start; SPEC, ITERATE,
and DELIVER are main-thread phases and create no team. `.loop-spec/runtime.json.teamsMode`
(set in Step 2) picks the mechanism:

- **`explicit`** (CC < 2.1.178): the lead creates the roster with `TeamCreate` and tears
  it down with `TeamDelete` at the phase boundary, before the next phase's `TeamCreate`.
- **`implicit`** (CC >= 2.1.178): the session already has one team. Probe
  `lib/implicit-team-model.sh spawn-kind --teams-mode implicit --selector <feature.models.role>`
  per teammate and spawn per **`skills/shared/implicit-team-mode.md`** (`named` →
  `Agent({name, description, subagent_type, prompt})` with no `model` key; `oneshot` →
  a nameless Agent with the same required keys plus the alias as `model`). No
  `TeamCreate`, no `TeamDelete` (they throw); at phase end just clear
  `feature.json.currentTeamName` and stop messaging.
- **`none`** (equivalently `teamsAvailable == false`): every rule here degrades per the
  substitution table in **`skills/shared/no-teams-fallback.md`** — teammates become
  one-shot `Agent` calls with the same agent types, models, and prompt templates; rework
  re-dispatches with prior summaries from `gate-logs/` inlined; EXECUTE's ladder selects
  the loop-fleet or subagent rung. Phases MUST NOT call team tools (they throw).

Rework within a phase goes to the SAME teammate via `SendMessage({to: "<teammate-name>",
message: ...})` in both team modes — never a fresh `Agent` call. (Implicit `oneshot`
spawns and the no-teams fallback re-dispatch a fresh nameless Agent with the prior round
inlined instead.) Fresh `Agent` calls are reserved for main-thread one-shot dispatches:
the Step 5.5b background mappers, the DISCUSS Step 1.75 PATTERNS.md prefetch, ITERATE's
`iterate-judge`, and implicit-team `oneshot` spawns.

**Subagent depth.** Claude Code caps subagent nesting at a fixed depth (5 in the 2.1.x
line; no variable raises it). loop-spec never approaches it: only the main thread spawns
teammates and mappers, role definitions do not grant `Agent`, and a teammate needing more
fan-out surfaces it to the lead. EXECUTE's loop-fleet rung is separate top-level
`claude -p` processes, not nested subagents.

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
every phase skill honors it. Headless form for an explicitly full run:
`claude -p "/loop-spec:cycle autonomous <description>"`; under OpenCode or ADK,
load the `cycle` skill with the native skill tool and send `autonomous <description>`.
Use `/loop-spec:auto <description>` when
the autonomous entry should semantically choose micro, debug, or the full cycle before
paying the full-cycle startup cost.
Setup answers made before SPEC.md exists (workspace repos, resume choice, commands) are
recorded to disk immediately — `lib/decisions.sh add .loop-spec/decisions-staging cycle
"<q>" "<a>" "<why>"` — never buffered in model memory (compaction would drop them). Step 5
migrates the staging record into the feature dir; SPEC renders it into SPEC.md's
`## Decisions (assumed — autonomous)` list via `decisions.sh render`.

## Route exit contract

This skill is a route, and a route ends by publishing `.loop-spec/last-result.json` —
a run that ends without one reads as a failure to every headless caller
(**`skills/shared/route-exit-contract.md`**).

`protocol-mismatch` is for a genuine **non-task** only (a pure question, or work that
needs a different product entirely). A rebase, a branch sync, a merge-conflict
resolution, a PR re-review, or a one-command chore is repository work. If
`/loop-spec:auto` already routed here, that commitment stands — execute the cycle; do
not decline it. Heavy ceremony is the maintenance profile (`profile=maintenance`,
`skills/shared/tier-matrix.md`): SPEC synthesizes, the graph short path skips DISCUSS /
spec-critique / code-review when no security signal fires, and PLAN / EXECUTE / VERIFY /
ITERATE / DELIVER still run. Walk that path. Do not skip ITERATE or DELIVER because the
task felt small; the graph owns sequencing, and a delivered change without a terminal
result is the unaccounted ending this contract exists to prevent.

When the request is genuinely not repository work, stop before changing the tree:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" write-terminal \
  --result-root "$(git rev-parse --show-toplevel)" --cycle-type full \
  --status escalated --outcome protocol-mismatch --converged false \
  --title "<request title>" --reason "<why this is not repository work>" \
  --summary "<what the request actually needs; no repository work was done>"
```

Then stop, so the caller can re-route. The writer requires an unmodified tracked tree:
once this cycle has changed the repository, mismatch is no longer the honest ending and
the run reports what it actually did.

## Procedure

**Startup is silent — and batched in ONE call.** The mechanical checks behind Steps 0
(workspace detection), 1 (resume scan), 2 (health-check) and the workflow probe run as a
single script; do NOT invoke workspace.sh / teams-capability.sh /
workflow-availability.sh / backlog.sh individually, and do NOT narrate:

```bash
pf="$(bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-preflight.sh" run)"
# {workspace: {mode, root, repos?}, teams: {mode, available}, workflows: {available},
#  backlog: {count},
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

Greenfield consequences downstream (each step carries its own branch): Step 4 skips command detection (commands are backfilled by EXECUTE after the scaffold task lands), Step 5.5 skips the codebase map (VERIFY's refresh writes the first one), SPEC round 1 runs the **Foundations** perspective (stack/structure/tooling — `skills/spec/SKILL.md`), and PLAN must emit a scaffold-first task DAG (`skills/plan/SKILL.md`, "Greenfield plans"). Persist the flag as `feature.json.greenfield = true` (Step 5).

The `new` token inside an EXISTING repo (mode `single`) is refused — `greenfield-bootstrap.sh` exits 4 with `already a git repo — greenfield is for empty directories. Run the normal cycle, or cd into an empty directory for a new app.` Workspace mode has no greenfield variant (exit 5; multi-repo bootstrap is out of scope; deferred). Relay the script's message verbatim and stop the greenfield path.

Announce the discovered repos, confirm participation (interactive `AskUserQuestion`; `LOOP_SPEC_ANSWER_REPOS` when non-interactive; autonomous mode takes all discovered repos and records the assumption — `skills/shared/autonomous-mode.md`), filter `workspace_repos_json` to the participating repos, and merge `workspaceMode`/`workspaceRoot`/`workspaceRepos` into `.loop-spec/runtime.json` -- exact prompts and merge-write snippet in `${CLAUDE_SKILL_DIR}/references/workspace-mode.md` ("Step 0 detail").

### Step 1 - Resume detection

The mechanical scan is DONE — `.resume.candidates` in the preflight blob holds every
schema-7, non-completed, non-stale feature, most-recently-updated first (each with
`{slug, currentPhase, updatedAt, currentTeamName, needs_probe, source, featureRoot,
worktreePath, worktreeAbs, workspace, teamsMode, parse_source}`); `.resume.skipped`
and `.warnings` hold what was dropped and
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

If the user picks resume, use the candidate's absolute `featureRoot` before reading any
feature-relative path. The preflight already discovered whether state came from the
invocation checkout or a registered feature worktree.

1. **Adopt the execution root first.** Workspace and `executionRootMode == "in-place"`
   features require the session cwd to equal `featureRoot`; otherwise print the absolute
   path and stop so the harness can be relaunched there. For a Claude feature-worktree
   candidate, call `EnterWorktree({path: worktreeAbs})`. OpenCode/ADK features use the
   clean in-place branch path and never emulate a cwd switch with `git worktree add`.
2. Load `feature.json` from the adopted root and refresh `.loop-spec/runtime.json` with the
   and the Step 5.4 freshness decision for every non-greenfield source repository. A matching
   validated source stamp reuses the local graph; every changed or unprovable input refreshes it.
   Workspace resumes apply the same decision to each participating repo. A resume directly into
   DELIVER is the exception: do not mutate its terminal verified candidate. Then route to
   Step 6 after re-grounding.
3. Read `.loop-spec/features/{slug}/PROGRESS.md`, then run `git log --oneline -10` on the
   feature branch (workspace mode: per repo).
4. If ignored `delivery.json` has `nextPhase == "completed"` and `status ==
   "ready-for-review"`, this is interrupted completion finalization: **skip project tests
   and the delivery controller, run DELIVER Step 4's feedback check against the existing
   PR targets, then jump directly to On completion**. The exact SHA and checks were
   already proven; a flaky local environment must not reopen delivered work, but recovery
   must not skip terminal feedback observation.
5. Otherwise resume the recorded phase. Do not run the repository-wide
   test/lint/typecheck comparison here: VERIFY Step 1.75 is the only place it
   runs. When `artifacts.tasks` exists, print what is already published and what
   is left — that is the pickup, not a suite:

   ```bash
   tasks_sidecar="$(jq -r '.artifacts.tasks // empty' ".loop-spec/features/${slug}/feature.json")"
   if [[ -n "$tasks_sidecar" && -f "$tasks_sidecar" ]]; then
     done_ids="$(bash "${CLAUDE_SKILL_DIR}/../../lib/task-progress.sh" done "$tasks_sidecar")"
     remaining_ids="$(bash "${CLAUDE_SKILL_DIR}/../../lib/task-progress.sh" remaining "$tasks_sidecar")"
     echo "[RESUME] tasks done: ${done_ids:-none}"
     echo "[RESUME] tasks remaining: ${remaining_ids:-none}"
   fi
   ```

   EXECUTE seeds `mergedSet` from the done ids and dispatches only remaining
   work. Never recapture a baseline on resume.

Full algorithm: `skills/shared/cycle-resume-escalation.md`.

### Step 2 - Startup health-check

Validate deployment fan-out policy before probing capabilities:

```bash
if [[ -n "${LOOP_SPEC_MAX_PARALLEL_SUBAGENTS:-}" \
      && ! "$LOOP_SPEC_MAX_PARALLEL_SUBAGENTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "loop-spec: LOOP_SPEC_MAX_PARALLEL_SUBAGENTS must be a positive integer." >&2
  exit 2
fi
```

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
    command -v "$(bash "${CLAUDE_SKILL_DIR}/../../lib/harness.sh" cli)" >/dev/null 2>&1 && loops_hint="loop-fleet + subagent fallback"
    echo "loop-spec: agent teams off (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS != 1)."
    echo "  Continuing with ${loops_hint}. For persistent phase teams: export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1." ;;
  implicit)
    echo "loop-spec: agent teams on (implicit-team model, CC >= 2.1.178)."
    echo "  Named inherit teammates spawn via Agent({name}); a role alias spawns a nameless one-shot Agent. TeamCreate/TeamDelete are not used. See skills/shared/implicit-team-mode.md." ;;
  explicit)
    echo "loop-spec: agent teams on (explicit-team model, CC < 2.1.178). Per-phase TeamCreate/TeamDelete." ;;
esac
```

**`teams_mode` decides every phase's dispatch path** — per the Dispatch convention
section above. Harness overlays when `teams_mode == "none"` (the preflight blob's
`harness.name` is always `none`-mode on these):

- `adk`: one-shot dispatches run through the bridge's `dispatch_subagent` tool — apply
  **`skills/shared/adk-harness.md`** on top (same call shape, role names without the
  `loop-spec:` prefix, model probe skipped).
- `opencode`: dispatches run natively through opencode's `task` tool — apply
  **`skills/shared/opencode-harness.md`** on top (agent ids spelled `loop-spec-<role>`,
  model probe skipped).
- `codex`: dispatches run through Codex `spawn_agent` — apply
  **`skills/shared/codex-harness.md`** on top (agent ids spelled `loop-spec-<role>`,
  model probe skipped).

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


Model availability is probed in Step 3.5. There is no preset axis; the probe
covers the complete effective selector set after phase and role overrides.

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
# {mode: description|spec-file|backlog|bare, title, slug, style, profile, autonomous,
#  greenfield, phase_mode: fresh|continuous|null, no_run, spec_path, legacy: []}
```

`.mode` selects the branch below; `.style` defaults to `auto`; `.autonomous` /
`.greenfield` feed the autonomous contract and Step 0's greenfield branch.
`.phase_mode` controls fresh-main-context handoffs and is stripped from the feature
title. `.legacy` non-empty gets the one-line "ignored legacy token" notice.

**Execution profile.** Resolve it once here and carry it for the whole cycle — the gate
ladder must not change shape mid-run:

```bash
inv_profile="$(jq -r '.profile // empty' <<<"$inv")"
class_json=""
if [[ -f "${workspace_root:-.}/.loop-spec/active-run.json" ]]; then
  class_json="$(jq -c '.classification // empty' \
    "${workspace_root:-.}/.loop-spec/active-run.json" 2>/dev/null || true)"
fi
if [[ -n "$inv_profile" ]]; then
  profile_line="$(LOOP_SPEC_CYCLE_PROFILE="$inv_profile" \
    bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-profile.sh" select)"
elif [[ -n "$class_json" ]]; then
  profile_line="$(printf '%s' "$class_json" | \
    LOOP_SPEC_CYCLE_PROFILE="${LOOP_SPEC_CYCLE_PROFILE:-auto}" \
    bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-profile.sh" select -)"
else
  profile_line="$(LOOP_SPEC_CYCLE_PROFILE="${LOOP_SPEC_CYCLE_PROFILE:-auto}" \
    bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-profile.sh" select)"
fi
echo "loop-spec: $profile_line"
cycle_profile="${profile_line#profile=}"; cycle_profile="${cycle_profile%% *}"
```

The inline `profile:` token outranks `LOOP_SPEC_CYCLE_PROFILE`, matching how
`phase:fresh` outranks `LOOP_SPEC_PHASE_HANDOFF`. `/loop-spec:auto` is the caller that
supplies the token AND persists the validated classification on the armed run
(`.loop-spec/active-run.json`). If the token is dropped, this step still reads that
classification so the maintenance short path survives a forgotten argument.

`profile=maintenance` runs the lightened ladder (`skills/shared/tier-matrix.md`,
"Maintenance profile"): SPEC skips the Socratic interview and synthesizes the spec, and
the graph short path skips DISCUSS, spec-critique, and the code-review agent when no
security signal fires. PLAN critique skip is `plan-critique.sh` / the skill fast-path,
not that short path. The ambiguity gate, the feasibility check, and the deterministic
VERIFY gates stay. `profile=standard` (the default, and the answer whenever the
invocation carries no `profile:` token) is today's full ladder.

Resolution order:

1. **Non-interactive** (`LOOP_SPEC_NON_INTERACTIVE=1`): read env vars. Resolve and
   validate them before creating feature state:
   ```bash
   style="${LOOP_SPEC_ANSWER_STYLE:-auto}"
   case "$style" in
     auto|step|interactive|review-only) ;;
     *) echo "loop-spec: LOOP_SPEC_ANSWER_STYLE must be auto, step, interactive, or review-only" >&2; exit 2 ;;
   esac
   title="${LOOP_SPEC_ANSWER_TITLE:-}"
   spec_file="${LOOP_SPEC_SPEC_FILE:-}"
   if [[ -n "$spec_file" ]]; then
     [[ -r "$spec_file" && "$spec_file" == *.md ]] || {
       echo "loop-spec: LOOP_SPEC_SPEC_FILE must name a readable .md file" >&2
       exit 2
     }
   elif [[ -z "$title" ]]; then
     echo "loop-spec: LOOP_SPEC_ANSWER_TITLE is required when LOOP_SPEC_SPEC_FILE is unset" >&2
     exit 2
   fi
   ```
   When a spec file is present and title is empty, title falls back to its first `# `
   heading, then its filename. Apply the spec-file invocation branch (3) below.
   Legacy `LOOP_SPEC_ANSWER_TIER` / `LOOP_SPEC_ANSWER_PRESET` env vars, if set, are
   ignored with a one-line notice (single-tier operation; model routing uses the
   explicit phase/role env contracts instead of presets).

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
> the SPEC reflects the clarified scope, not just the raw one-liner. Do not repeat the
> session-start 2-4 questions once SPEC is running — SPEC's Socratic interview continues
> the grill, and DISCUSS still runs its design-shape grill afterward unless the run is
> autonomous. In autonomous mode the hook suppresses the directive (`LOOP_SPEC_AUTONOMOUS=1`);
> there is nobody to grill. `execStyle: auto` is not autonomous.

### Step 3.5 - Model probe + Workflow availability probe

The portable default is `inherit`, with optional phase/role routes to a Claude
alias or full model ID. Probe results are cached 24h only for an identical selector
set (`LOOP_SPEC_SKIP_HEALTHCHECK=1` skips). Run the model dispatch probe now,
verbatim per `${CLAUDE_SKILL_DIR}/references/startup-probes.md` (probe mechanics,
cache format, degraded-mode handling). The `Workflow` availability answer is
already in the preflight blob (`jq -r '.workflows.available' <<<"$pf"`) — do not
re-probe; persist it as `workflowsAvailable` per the same reference. The cycle
proceeds regardless of probe outcomes; fan-out skills read `runtime.json` to
pick their dispatch path (`skills/shared/dispatch-fanout.md`).

### Step 4 - Detect project commands

Auto-detect test/lint/typecheck commands (best effort) and confirm with the user (one `AskUserQuestion`; skipped when `LOOP_SPEC_NON_INTERACTIVE=1`, where `LOOP_SPEC_CMD_*` env vars win; autonomous mode trusts the detection — `LOOP_SPEC_CMD_*` still wins — and records the assumption).

**Greenfield:** skip detection entirely (there is nothing to detect); leave all three commands empty with a one-line note. EXECUTE backfills them by re-running `lib/detect-test-cmd.sh` after the scaffold task (task-001) merges — see `skills/execute/SKILL.md` "Greenfield command backfill". Workspace mode detects per-repo commands (authoritative in `workspace.repos[].commands`; top-level `commands` stays empty). Apply the detection heuristics and confirmation flow verbatim from `${CLAUDE_SKILL_DIR}/references/detect-commands.md`.

### Step 5 - Initialize state

**New feature only — apply the initialization procedure verbatim from
`${CLAUDE_SKILL_DIR}/references/feature-init.md`.** If resuming: load feature.json into
memory and skip it. What the procedure does, and the judgment calls it leaves to the lead:

- **PR adoption:** a request that names an open PR (`#114`, a GitHub pull URL, or
  "this/the PR" on a branch that already has one) is probed via `lib/adopt-pr.sh resolve`
  and checked out instead of minting `feat/{slug}`, so conflict resolution and re-review
  land on the PR DELIVER will update. Single-repo only; dirt on the adopted branch is the
  work, dirt on any other branch still aborts.
- **Execution root:** Claude Code enters a feature worktree (`EnterWorktree`;
  `LOOP_SPEC_WORKTREES=0` keeps the in-place branch). OpenCode and ADK have no
  session-root switch, so they use a clean in-place `feat/{slug}` branch and never
  emulate a cwd switch with `git worktree add`.
- **Fail-terminal setup:** base resolution, `prepare-environment.sh`, and the opt-in
  startup baseline (`LOOP_SPEC_STARTUP_BASELINE=1`; default off — VERIFY then treats
  every observed failure as blocking) each write an `infrastructure-failed` terminal
  result and exit non-zero on failure.
- **State:** `lib/feature-init.sh skeleton` builds the schema-7 feature.json (never
  hand-build it inline), the autonomous/greenfield flags persist via `feature-write.sh`,
  and staged pre-SPEC decisions migrate into the feature dir.

#### Workspace mode Step 5 variant

In workspace mode (`workspaceMode == "workspace"`), do NOT call `create-feature-worktree` and do NOT call `EnterWorktree`; all work stays at the workspace root on in-place `feat/{slug}` branches. Named-PR adoption is single-repo only. Apply the two-phase procedure (Phase 1: pre-flight cleanliness check across ALL repos before ANY branch is created; Phase 2: per-repo branch creation + the workspace-mode `feature-init.sh` skeleton) verbatim from `${CLAUDE_SKILL_DIR}/references/workspace-mode.md` ("Step 5 variant").

Provenance fields:
- `artifacts.patternsSource` -- one of `"gsd-ingest"`, `"pattern-mapper"`, `"manual"`, or `null` until written. Set in PLAN Step 0.
- `artifacts.codebaseSource.{domain}` -- one of `"gsd-ingest"`, `"mapper"`, `"manual"`, or `null` until written. Set per-domain in Step 5.5.

Print cost estimate based on expected scope:
```
Estimated cost: ~{N}k tokens
```

### Step 5.5 - First-run codebase map (one-time per project)

Resolve the automatic bootstrap policy first:

```bash
map_bootstrap="$(bash "${CLAUDE_SKILL_DIR}/../../lib/map-policy.sh" bootstrap)"
```

When it returns `skip`, print `codebase map bootstrap skipped by LOOP_SPEC_MAP_BOOTSTRAP=0` and continue to Step 5.9 without ingest or mapper dispatch. Otherwise, one time per project: ingest an existing GSD `.planning/codebase/` if present (Step 5.5a), then fire background mappers only for the domains still missing (Step 5.5b). Skip when all 5 domain docs already exist in `docs/loop-spec/codebase/` — **or when greenfield** (an empty repo has nothing to map; VERIFY's end-of-cycle refresh writes the first map from the shipped code). Apply the full procedure verbatim from `${CLAUDE_SKILL_DIR}/references/codebase-map-bootstrap.md` (GSD ingest rules, mapper dispatch, commit discipline, `bootstrapPendingDomains` bookkeeping, workspace-mode behavior).

When `LOOP_SPEC_MAX_PARALLEL_SUBAGENTS` is set, apply
`skills/shared/subagent-concurrency.md`: dispatch missing-domain mappers in bounded
waves and await them before entering SPEC. Do not leave bootstrap mappers running
across the phase boundary.

### Step 5.9 - Activate the current phase's model routing

Every phase skill reads `feature.models.<role>` as the selector. Add a `model`
key only when it is one of the four Agent aliases **and** the spawn is nameless
(a one-shot Agent, the no-teams fallback, or implicit-team `oneshot`). When it is
`inherit`, **emit no `model` key at all**. Named implicit-team spawns also omit
`model`: they inherit the session regardless
(`skills/shared/implicit-team-mode.md`). The Agent tool rejects the literal
string `inherit` with `InputValidationError` — inheritance is expressed by omission
(`skills/shared/harness-call-contracts.md`). Immediately
before a phase launch, `feature-init.sh activate` resolves and persists the exact
map those Agent calls consume:

1. task-level `model` / `modelTier` (where that rung supports it);
2. explicit `LOOP_SPEC_MODEL_<ROLE>`;
3. explicit `LOOP_SPEC_PHASE_MODEL_<PHASE>`;
4. canonical role default.

The activation also persists all seven configured phase overrides in
`feature.phaseModels`. This is the handoff contract used by a Claude Code CLI or
Python Agent SDK supervisor to select the main model for the next fresh phase
query. An unset phase entry is `null` and leaves that query on its ordinary
`CLAUDE_MODEL` / session default.

Older features either lack these blocks or carry a stale map from the removed
preset scheme. Activate the recorded current phase on every new run/resume and
drop vestigial `preset` and `tier` fields:

Sequencing is owned by the declared graph (`graph/cycle.graph.json`), never a bare
`currentPhase` read — `docs/loop-spec/features/gdd/REMEDIATION-CONTRACT.md` sec 1-6.
`lib/graph/run.sh --step` processes exactly one node and returns its JSON dispatch
descriptor (`{node, label, kind, body, effort, nextEdge, terminal, paused}`); it already
resumes from wherever the last step/pause/checkpoint left off (contract sec 5), so this
is also the resume path — there is no separate manual `checkpoint.sh latest` + `--resume`
call to make. The engine dispatches in-process anything it can execute itself (`function`/
`gate` bodies, a real nested `subgraph` run, an unadmitted `human` node's skip-and-route);
this loop only stops at an `agent` node (this phase's own dispatch — the orchestrator, not
the engine, drives an agent through `Skill(...)`), an admitted `human` node (exit 4,
pause), a route abort (exit 5), or the graph's terminal node. Entering or leaving a
working-phase node also emits `phase_start` / `phase_end` on stderr (the JSON
descriptor stays on stdout so this snippet's `step_json=$(...)` capture stays
parseable). This exact snippet resolves
`currentPhase` for dispatch both here (session entry) and at the bottom of Step 6
(continuing after a phase returns) — same snippet, same call, one authority:

```bash
feat_dir=".loop-spec/features/${slug}"
fjson="${feat_dir}/feature.json"
GRAPH="${CLAUDE_SKILL_DIR}/../../graph/cycle.graph.json"
while :; do
  set +e
  step_json="$(bash "${CLAUDE_SKILL_DIR}/../../lib/graph/run.sh" --step \
    --feature-dir "$feat_dir" "$GRAPH")"
  step_rc=$?
  set -e
  case "$step_rc" in
    4)
      echo "loop-spec: paused at human node $(jq -r '.node' <<<"$step_json") -- resumable; re-invoke /loop-spec:cycle to continue." >&2
      exit 0
      ;;
    5)
      echo "loop-spec: graph routing aborted -- a node had route edges and none was satisfied, with no routeDefault. See stderr above for the probe diagnostics." >&2
      exit 1
      ;;
    0) ;;
    *)
      echo "loop-spec: run.sh --step failed unexpectedly (exit $step_rc)" >&2
      exit 1
      ;;
  esac
  [[ "$(jq -r '.terminal' <<<"$step_json")" == "true" ]] && break
  [[ "$(jq -r '.kind' <<<"$step_json")" == "agent" ]] && break
  # function/gate/subgraph/skipped-human: the engine already dispatched it
  # in-process. Nothing for the orchestrator to do here -- step again.
done
currentPhase="$(jq -r '.node' <<<"$step_json")"
current_phase="$currentPhase"
currentLabel="$(jq -r '.label' <<<"$step_json")"
node_effort="$(jq -r '.effort' <<<"$step_json")"
# The label is what the node MEANS; the id is what the graph calls it. Announce
# both so a resumed run reads as work rather than as a node identifier.
if [[ "$(jq -r '.terminal' <<<"$step_json")" == "true" ]]; then
  echo "loop-spec: graph traversal reached its terminal node -- ${currentLabel} (${currentPhase})."
else
  echo "loop-spec: ${currentLabel} (${currentPhase}, effort ${node_effort})."
  bash "${CLAUDE_SKILL_DIR}/../../lib/feature-init.sh" activate \
    "$feat_dir" "$current_phase"
fi
if [[ "$(jq 'has("preset") or has("tier")' "$fjson")" == "true" ]]; then
  new_json="$(jq 'del(.preset) | del(.tier)' "$fjson")"
  bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" "$feat_dir" "$new_json"
  echo "Dropped legacy tier/preset fields."
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

Sequencing is owned by the declared graph. `currentPhase` for this iteration was
already resolved by the Step 5.9 `run.sh --step` snippet — that is the single
authority for phase successors, ITERATE rewind targets, DELIVER's CI-remediation
path, critique subgraphs, and human pauses; this step does not re-derive it. Resume
is that same snippet's built-in pause-record/checkpoint-ledger/`currentPhase`
resolution (contract sec 5) — not a separate prose scan-and-infer, and not a manual
`checkpoint.sh latest` + `--resume` call made anywhere in this skill.

Exit 4 from `run.sh --step` is a human-node pause (resumable; the snippet already
returned to the user). Exit 0 with `.terminal == true` is a completed traversal —
the graph reached its `completed` node, which the engine's own dispatch of
`lib/cycle-result.sh` already published as the terminal result; jump to "On
completion" below. Exit 0 with `.kind == "agent"` is this step's normal case: the
snippet stopped at a real phase to dispatch.

Consume `$node_effort` as model-independent guidance. It never chooses a model:
Claude Code and OpenCode may expose different catalogs, and both inherit the model that
launched the session by default. For `system1`, keep the phase direct and avoid optional
extra review rounds. For `system2`, state the assumptions and check their evidence before
committing to the phase result. Every declared gate runs in either mode.

The cycle does NOT create the phase team. Each phase skill owns its own team lifecycle: `TeamCreate` at phase start, `TeamDelete` + clear `currentTeamName` at phase end. This keeps team rosters phase-specific (each phase has different teammates) and avoids double-`TeamCreate` errors.

Resolve and persist the main-context policy before invoking a phase. The inline token
(`phase:fresh` or `phase:continuous`) wins, then `LOOP_SPEC_PHASE_HANDOFF=0|1`, then
the value already stored in `feature.json.phaseHandoff`; the default is `false`.
Reject any other environment value. Persist the resolved boolean with
`feature-write.sh` so a bare resume command keeps the same policy. This policy is
orthogonal to subagents: it replaces the phase orchestrator between phases, while
one-shot role agents may still run inside each phase.

```bash
feature_dir=".loop-spec/features/${slug}"
phase_handoff="$(jq -r '.phaseHandoff // false' "$feature_dir/feature.json")"
case "${LOOP_SPEC_PHASE_HANDOFF:-}" in
  "") ;;
  0) phase_handoff=false ;;
  1) phase_handoff=true ;;
  *) echo "loop-spec: LOOP_SPEC_PHASE_HANDOFF must be 0 or 1." >&2; exit 2 ;;
esac
case "$(jq -r '.phase_mode // empty' <<<"$inv")" in
  fresh) phase_handoff=true ;;
  continuous) phase_handoff=false ;;
esac
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set \
  "$feature_dir" phaseHandoff "$phase_handoff"
```

Node bodies remain the phase skills. The engine selects the next node; the lead
dispatches `Skill(loop-spec:{currentPhase})` for agent nodes and reacts to the
return. DELIVER remains the sole owner of push, PR reconciliation, required
checks, and readiness.

Cycle's responsibility after the engine names a node is to invoke that phase skill and react to its return:

1. **Invoke phase skill** (with the watchdog stamp):
   Before every invocation—including continuous routing after a prior phase
   returns—activate that phase's effective model map. This call is mandatory; do
   not invoke a phase against the previous phase's map. Since every team,
   implicit-team (named inherit or nameless oneshot), and one-shot fallback launch
   reads `feature.models.<role>`,
   this is the enforcement point that makes phase routing apply to authors,
   implementers, verifiers, and phase-gate reviewers alike. Named implicit-team
   spawns still inherit the session model; an alias must take the oneshot path
   (`skills/shared/implicit-team-mode.md`).
   ```bash
   feature_dir=".loop-spec/features/${slug}"
   bash "${CLAUDE_SKILL_DIR}/../../lib/feature-init.sh" activate \
     "$feature_dir" "$currentPhase"
   feature_json="$(cat "$feature_dir/feature.json")"
   ```
   DELIVER owns all pre-delivery candidate mutation through
   `lib/finalize-delivery-candidate.sh`, called by `lib/deliver.sh`. The helper finalizes
   only the named retro/rules/digest artifacts before first observation and becomes a
   strict no-op when an eligible sidecar target already binds the retry SHA. The cycle
   must not create its own pre-DELIVER commits or duplicate the binding predicate.
   ```bash
   # DELIVER has deterministic per-command and total check timeouts; avoid a
   # tracked watchdog write after its candidate SHA was finalized.
   if [[ "$currentPhase" != "deliver" ]]; then
     bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set \
       ".loop-spec/features/${slug}" currentPhaseStartedAt "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
   fi
   # phase_start/phase_end are emitted by run.sh --step at the node
   # transition (lib/graph/engine.py). Do not re-emit here — a second copy
   # is noise, and this call is the compliance gap that hid the console bar
   # when a coder ran the phase inline.
   bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" begin \
     --result-root "$repo_root" --cycle-type full --title "$title" --slug "$slug" \
     --branch "feat/${slug}" --base-branch "$base_branch" \
     --feature-dir "$(cd ".loop-spec/features/${slug}" && pwd -P)" \
     --phase "$currentPhase" --autonomous "$active_autonomous"
   ```
   Then load anything this project declared for the phase. Both calls are silent in a
   project that declared nothing, which is the normal case:
   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../lib/extension-points.sh" instructions "$currentPhase" prepend
   bash "${CLAUDE_SKILL_DIR}/../../lib/extension-points.sh" facts
   ```
   Treat each emitted instruction as a directive for this phase, and each `fact=file`
   path as standing context to read before the phase begins. Run the `append` instructions
   after the skill returns. These are accelerators: they may shape how work is done, never
   whether a gate passes, and the path fails open — no output means no extensions.

   The Step 5.9 `--step` call already printed the greppable boundary
   (`LOOP_SPEC_PHASE_START` / `[{CURRENTPHASE}] start` on stderr). The matching
   `done` line is printed by the next `--step`, when the engine leaves this
   node. Do not print them by hand — `skills/shared/report-style.md`.
   ```
   Skill(loop-spec:{currentPhase})
   ```
   `{currentPhase}` is read from the in-memory `feature_json`. Team-capable phases own
   their team lifecycle; SPEC, ITERATE, and DELIVER run on the main thread. Every phase
   advances `currentPhase` through `lib/feature-write.sh`.

2. **React to the phase's return** — full procedure in
   `references/phase-loop.md` (read it before acting; it is this loop's other
   half). Sequence: re-load `feature.json` (a declined SPEC gate is terminal for
   the invocation), check the phase watchdog ceiling, append the PROGRESS.md
   journal block, commit the resume contract per `lib/state-commit-policy.sh`,
   then the autonomous remote checkpoint.

3. **Route to next iteration** — also in `references/phase-loop.md`. Terminal
   completion jumps to "On completion" below; a deliver→deliver return branches
   on the deterministic delivery record (no-change completion vs escalation);
   the fresh phase orchestrator and fresh-context rewind are opt-in exits;
   otherwise re-run the Step 5.9 snippet verbatim and loop back to item 1.

## Resume strategy + phase pause/escalation

Full algorithm and escalation handling (iteration limit exhausted, NEEDS_CONTEXT, etc.) in **`skills/shared/cycle-resume-escalation.md`**. Step 1 carries the inline fast-path.

## On completion

Reachable only after DELIVER wrote `delivery.json.nextPhase = "completed"`. The
full contract — sidecar status assertion, terminal result write with retry,
summary style and deferral lint, per-target delivery summary, and the
autonomous chain decision — is `references/completion.md`. Read it before
writing the result. The maintenance short path also lands here; do not exit
after EXECUTE because the task felt like a sync.
