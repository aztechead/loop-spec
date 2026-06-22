---
name: cycle
description: ENTRY POINT for loop-spec. Spec-driven feature cycle (SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY -> ITERATE, where ITERATE judges the result against the original goal and loops back until converged or the iteration budget is spent). Just give it a feature description -- tier (quality/balanced/quick) is INFERRED from the prompt, execution style defaults to auto; both are overridable inline but never asked. Model selection is fixed (no preset). Resumes incomplete features automatically.
argument-hint: "[feature description]  (optional inline overrides: tier:quick|balanced|quality style:auto|step|interactive|review-only)"
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet EnterWorktree ExitWorktree
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
| `AskUserQuestion` | Tier / style / title prompts; pause-and-escalate decisions |
| `Skill` | Invoking another loop-spec skill (`Skill(loop-spec:plan)` etc.) |
| `Glob`, `Grep` | Code exploration |
| `EnterWorktree` | Switch the session into the feature worktree (Step 5 create; Step 1 resume) |
| `ExitWorktree` | Leave the feature worktree on pause or completion (action: "keep") |

Any tool not listed above is not permitted. `EnterWorktree` and `ExitWorktree` are used for the FEATURE-level worktree only (Step 5 / resume); per-TASK worktrees in EXECUTE use raw `git worktree add` via `lib/git-ops.sh` and do NOT use the harness tools. `WebFetch`, `WebSearch` are banned (offline by design). `CronCreate`, `CronList`, `CronDelete`, `ScheduleWakeup` are banned (synchronous execution only).

If a step you're about to take requires a tool not on the whitelist, stop and re-read the skill -- you're misinterpreting the instruction.

## Dispatch convention (CRITICAL)

Every phase runs inside a persistent **team** created via `TeamCreate`. Teammates are spawned at phase start and persist for the full phase; they are NOT one-shot dispatches that die after one reply.

Inter-agent communication within a phase team uses `SendMessage`. This is the correct tool for routing work, critique rounds, and notifications between the lead and teammates (or between teammates directly by name).

Whenever a phase skill or this orchestrator says "instruct teammate X to revise" or "notify implementer of rework":
- Use `SendMessage({to: "<teammate-name>", body: "..."})` to address the teammate by their assigned name (e.g., `advocate-1`, `implementer-2`, `spec-writer-1`).
- Do NOT issue a fresh `Agent` call for rework within a phase -- teammates persist and can receive further instructions via `SendMessage`.
- A fresh `Agent` call is reserved for the Step 5.5b background codebase domain mappers and the ITERATE phase's one-shot `iterate-judge` dispatch (`skills/iterate/SKILL.md`); both are main-thread one-shot dispatches, not team rework.

When a phase ends: call `TeamDelete` to tear down the team before the next phase's `TeamCreate`.

This rule applies in DISCUSS, PLAN, EXECUTE, VERIFY, MAP-CODEBASE, and any sub-skill called from this cycle.

**No-teams fallback:** when `.loop-spec/runtime.json.teamsAvailable == false`,
every rule above degrades per the substitution table in
**`skills/shared/no-teams-fallback.md`**: no `TeamCreate`/`TeamDelete`/`SendMessage`
— teammates become one-shot `Agent` calls with the same agent types, models, and
prompt templates, rework rounds re-dispatch with prior summaries from
`gate-logs/` inlined, and EXECUTE's ladder selects the loop-fleet or subagent
rung. Phases MUST NOT call team tools when `teamsAvailable == false`; doing so
throws harness errors.

## Non-interactive mode

Set `LOOP_SPEC_NON_INTERACTIVE=1` to skip all AskUserQuestion calls (used by the manual non-interactive end-to-end matrix and CI).
When set, read answers from env vars instead:

| Env var | Values | AskUserQuestion it replaces |
|---|---|---|
| `LOOP_SPEC_ANSWER_TIER` | `quality`, `balanced`, `quick` | Tier selection (Step 3) |
| `LOOP_SPEC_ANSWER_STYLE` | `auto`, `step`, `interactive`, `review-only` | Execution style (Step 3) |
| `LOOP_SPEC_ANSWER_TITLE` | free text | Feature title (Step 3) |
| `LOOP_SPEC_ANSWER_MIGRATE_SCHEMA` | `1` | Migrate v3 feature to v4 on resume (Step 1). Default: continue on v3. |

Note: Non-interactive mode bypasses `AskUserQuestion` entirely by reading env vars. The S2 batching change (4 questions in one call) has no effect on non-interactive paths.

## Procedure

**Startup is silent.** Run Steps 0 (workspace detection), 1 (resume detection), 2 (health-check), 3.5 (model probe), and the workflow-availability probe quietly: do NOT narrate each one. Batch their checks and emit output ONLY when (a) a check fails, (b) a resumable feature is found and a choice is needed, or (c) Step 3 announces the launch line. No "Running Step 0...", no per-step status prose. The user wants to land in the workflow, not watch a preflight.

### Step 0 - Workspace detection

Run workspace detection FIRST, before resume or tier selection. The result determines whether every subsequent step runs in single-repo mode or workspace mode.

```bash
ws_json="$(bash "${CLAUDE_SKILL_DIR}/../../lib/workspace.sh" detect)"
workspace_mode="$(echo "$ws_json" | jq -r '.mode')"
workspace_root="$(echo "$ws_json" | jq -r '.root')"
workspace_repos_json="$(echo "$ws_json" | jq -c '.repos // []')"
```

**mode == "none":** abort with:
```
loop-spec: not a git repo and no child repos found.
cd into a repo or create .loop-spec/workspace.json to pin a workspace.
```

**mode == "single":** continue as normal (all existing steps apply). Set `workspaceMode="single"`.

**mode == "workspace":** announce the discovered repos, confirm participation, and set `workspaceMode="workspace"`.

Announcement (print to user):
```
workspace mode: {N} repos ({name1}, {name2}, ...}
  State and artifacts will be rooted at: {workspace_root}
Advisory: if {workspace_root} is or becomes a git repo, add .loop-spec/ to its .gitignore.
```

Confirmation (interactive):
```
AskUserQuestion({
  question: "Workspace repos: {list each repo name and relative path}. A feat/{slug} branch will be created IN PLACE in each participating repo (no worktree; the checkout switches branches). Proceed with all repos, or customize?",
  options: ["All repos", "Customize"]
})
```

If "Customize": ask the user to list repo names (comma-separated); filter `workspace_repos_json` to only those named.

Non-interactive (`LOOP_SPEC_NON_INTERACTIVE=1`): read `LOOP_SPEC_ANSWER_REPOS` (comma-separated repo names, default = all). Skip AskUserQuestion.

After confirmation, `workspace_repos_json` holds only the participating repos.

Merge workspace fields into `.loop-spec/runtime.json` (same python3 merge-write pattern as the workflow probe):

```bash
mkdir -p .loop-spec
python3 -c "
import json, sys, os
path = '.loop-spec/runtime.json'
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except Exception:
        data = {}
data['workspaceMode']  = sys.argv[1]
data['workspaceRoot']  = sys.argv[2]
data['workspaceRepos'] = json.loads(sys.argv[3])
json.dump(data, open(path, 'w'))
" "$workspace_mode" "$workspace_root" "$workspace_repos_json"
```

### Step 1 - Resume detection

Scan `.loop-spec/features/*/feature.json` (if directory exists). For each:
- Parse safely (try/except; on parse fail, try `feature.json.bak`)
- Skip if `currentPhase == "completed"`
- **schemaVersion 3 detection:** if `schemaVersion == 3`, prompt the user via AskUserQuestion (before the orphan probe):
  - header: `"In-flight v3 feature detected"`
  - question: `"Feature {slug} is on schemaVersion 3. Migrate to v4 (adds spec-phase fields, does NOT rewind completed phases) or continue on v3?"`
  - options: `["Migrate to v4", "Continue on v3"]`
  - "Migrate to v4": run `bash "${CLAUDE_SKILL_DIR}/../../lib/migrate-schema-v3-to-v4.sh" ".loop-spec/features/{slug}"`, reload feature.json
  - "Continue on v3": proceed without migration; cycle will use the existing v3 behavior (no spec phase)
  - When `LOOP_SPEC_NON_INTERACTIVE=1`: default to "Continue on v3" unless `LOOP_SPEC_ANSWER_MIGRATE_SCHEMA=1` is set
- **Orphan detection:** if `currentTeamName != null`, probe team liveness by calling `TaskList({team: currentTeamName})`. (When agent teams are unavailable this probe is meaningless: treat the team as gone, clear `currentTeamName`, and add the feature to the resumable list — see `skills/shared/no-teams-fallback.md`.) Otherwise:
  - If `TaskList` returns without error: the team is still live (orphaned). Print:
    ```
    Previous team {currentTeamName} for feature {slug} was orphaned and is still live in the harness.
    Run TeamDelete for team {currentTeamName} (e.g., via the harness CLI or by re-invoking cycle in cleanup mode), then restart cycle to resume feature {slug}.
    ```
    Add to a "needs cleanup" sub-list. Do NOT add to resumable list.
  - If `TaskList` errors (team not found): the prior team is gone. Print `"feature {slug} had stale team reference {currentTeamName}; cleared and ready to resume"`. Clear `currentTeamName` in `feature.json` via `lib/feature-write.sh`. Add to resumable list.
- If `currentTeamName == null` AND `(now - updatedAt) < stalenessHours * 3600`: add to resumable list.

If "needs cleanup" sub-list is non-empty: display it to the user after presenting resume options, so they know which teams require manual `TeamDelete`.

If resumable list non-empty: present via AskUserQuestion (or skip if `LOOP_SPEC_NON_INTERACTIVE=1`):
- "Resume {slug} (phase: {currentPhase}, last updated {ago})?"
- Options: each resumable feature + "New feature"

If user picks resume: load feature.json into memory, skip Steps 2-5, route to Step 6.
- **Workspace resume (schemaVersion 7, `workspace` block non-null):** resume IN PLACE at the workspace root. No worktree probe; do NOT call `EnterWorktree`. Assert that the current session cwd equals `feature.workspace.root`; if it does not, tell the user: `"cd to {feature.workspace.root} and re-invoke cycle to resume this feature."` and abort. All phase work proceeds from `workspace.root` using per-repo absolute paths.
- **Worktree resume (schemaVersion 7 with `workspace == null`, or schemaVersion 6, `worktreePath` present):** run `git-ops.sh list-feature-worktrees` to confirm it exists, then `EnterWorktree({ path: feature.worktreePath })` before Step 6. If the worktree is gone, warn and offer to re-create or continue in-place.
- **Legacy resume (no `worktreePath`):** resume in-place. Do NOT force-migrate.
- Full algorithm: `skills/shared/cycle-resume-escalation.md`.

### Step 2 - Startup health-check

Probe agent-teams availability. Teams are an ACCELERATOR, not a prerequisite:
when they are unavailable the cycle still runs end-to-end on the documented
fallbacks (DISCUSS/PLAN/VERIFY: one-shot subagent fallback per the **No-teams
fallback** contract below; EXECUTE: loop-fleet or subagent rung). Do NOT abort.

```bash
teams_available=true
if [[ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" != "1" ]]; then
  teams_available=false
  loops_hint="subagent fallback"
  command -v claude >/dev/null 2>&1 && loops_hint="loop-fleet + subagent fallback"
  echo "loop-spec: agent teams unavailable (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS != 1)."
  echo "  Continuing with ${loops_hint}. For persistent phase teams: export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1."
fi
```

`teams_available` is persisted into `.loop-spec/runtime.json` together with the
workflow probe below; phase skills read it to pick their dispatch path.

**Graphify is a HARD requirement** (unlike teams). graphify is loop-spec's de-facto
code-graph solution; the design phases (SPEC / DISCUSS / PLAN) query the graph to ground
their work, so the cycle aborts when it is missing rather than degrading. This gate runs as
part of the silent startup batch:

```bash
if ! bash "${CLAUDE_SKILL_DIR}/../../lib/graphify-preflight.sh" check; then
  # The preflight printed install instructions (uv tool install graphifyy).
  echo "loop-spec: aborting -- graphify is required. Install it, or set LOOP_SPEC_REQUIRE_GRAPHIFY=0 to bypass (not recommended)." >&2
  exit 1
fi
```

The only escape hatch is `LOOP_SPEC_REQUIRE_GRAPHIFY=0` (constrained environments); with it
set, the design phases fall back to Glob/Grep grounding and emit a degraded-mode warning.

Model availability is probed in Step 3.5. Model selection is fixed (no preset), so the probe always covers the same two models.

### Step 3 - Infer tier + style + feature

Goal: launch straight into the workflow with **zero menu friction**. The tier is no
longer a user-facing question — the model **infers** it from the prompt (and from the
grill answers, if a grill pass ran). The user can still override inline, but is never
asked to choose. Style defaults to `auto` and is likewise inference-free unless overridden.

**Tier-inference rubric** (apply to the feature description + any grill answers; pick the
highest tier whose signals are present, default `balanced` when signals are mixed or thin):

| Tier | Choose when the work looks like… |
|---|---|
| `quick` | Single-file or trivially-scoped change: typo, copy edit, small bugfix, one isolated function, a config tweak. Low blast radius, one obvious acceptance check, no cross-cutting concerns. |
| `balanced` (default) | A normal multi-file feature or module: moderate scope, a handful of acceptance criteria, contained blast radius. Also the fallback whenever the signals are mixed or the prompt is thin. |
| `quality` | High blast radius or high cost of being wrong: auth/security/permissions, payments/billing, data migrations or anything risking data loss, public API or wire-contract changes, concurrency/locking, "production"/"critical"/"compliance" framing, or a wide cross-cutting refactor. Also when the user explicitly asks for rigor. |

**Safety floor (overrides the rubric):** if the prompt carries any security-relevant signal — auth, authentication, authorization, permissions, credentials/API keys/secrets/tokens, crypto, payments/billing, PII, or data migration/deletion — **never infer `quick`** (which skips the critique gate), even when the prompt is short and reads as trivially scoped. Floor it at `balanced` and lean `quality`. A one-liner like "add an API key check to this endpoint" is small in words but security-critical in blast radius; the critique gate must run.

Resolution order:

1. **Non-interactive** (`LOOP_SPEC_NON_INTERACTIVE=1`): read env vars. Defaults when unset: `LOOP_SPEC_ANSWER_TIER` → `quick` (unchanged CI/smoke contract — inference is NOT applied in non-interactive mode), `LOOP_SPEC_ANSWER_STYLE` → `auto`, `LOOP_SPEC_ANSWER_TITLE` → required (abort if unset). A `LOOP_SPEC_ANSWER_PRESET` env var, if set, is ignored (model selection is fixed).

2. **Invocation carries a feature description** (`$ARGUMENTS` is non-empty -- the user typed `/loop-spec:cycle <description>`): this is the default fast path.
   - Title = `$ARGUMENTS` (slugified). Parse optional inline overrides anywhere in the text: `tier:quick|balanced|quality`, `style:auto|step|interactive|review-only`. A legacy `preset:...` token, if present, is silently ignored.
   - **Tier:** if given inline, use it. Otherwise **infer** it from the description via the rubric above. Style defaults to `auto` unless given inline.
   - Do NOT call `AskUserQuestion`. Print one line and proceed:
     `Launching: tier={tier} (inferred: {reason}) style={style} title="{title}". (Reply within this turn with e.g. "tier:quality" to adjust before SPEC starts.)`
     When the tier was given inline rather than inferred, drop the `(inferred: ...)` clause.

3. **Bare invocation** (no description): the only thing genuinely required is the work itself. Ask ONE free-text `AskUserQuestion` for what the user wants to build — do NOT ask for tier or style. Infer the tier from that answer (plus the grill pass) via the rubric; style = `auto`. Use the answer as the title. Never present a tier/style menu.

Slug = kebab-case of title (lowercase, replace spaces+special with `-`, dedupe consecutive `-`).

> The grill directive (`hooks/team/grill-inject.sh`, on by default) may already have
> elicited disambiguating answers before SPEC runs; feed those into the inference above so
> the tier reflects the clarified scope, not just the raw one-liner. Do not re-grill once
> the SPEC phase starts — SPEC's Socratic interview is the in-cycle grill.

### Step 3.5 - Model probe

Model selection is fixed (see `skills/shared/model-matrix.md`): the unique model set is always `{claude-opus-4-8, claude-sonnet-4-6}`.

**Probe cache (speed):** the probe result is cached in `.loop-spec/runtime.json`
(`modelsProbedAt`, ISO-8601). Skip the probe entirely — zero Agent dispatches —
when either holds:

```bash
skip_probe=false
[[ "${LOOP_SPEC_SKIP_HEALTHCHECK:-}" == "1" ]] && skip_probe=true
probed_at=$(jq -r '.modelsProbedAt // empty' .loop-spec/runtime.json 2>/dev/null || true)
if [[ -n "$probed_at" ]]; then
  age=$(( $(date -u +%s) - $(python3 -c "import sys,datetime;print(int(datetime.datetime.strptime(sys.argv[1],'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()))" "$probed_at" 2>/dev/null || echo 0) ))
  [[ "$age" -lt 86400 ]] && skip_probe=true   # probed within the last 24h
fi
```

A model-policy failure surfaces identically on the first real dispatch, so the
cache trades nothing for the saved startup latency. On probe success, write
`modelsProbedAt` into `runtime.json` (merged with the workflow probe below).

When not skipped, dispatch one probe Agent per unique model (parallel, single tool message):

```
Parallel:
  Agent({subagent_type: "loop-spec:spec-writer", model: "claude-opus-4-8",   prompt: "Reply with the single word: ok"})
  Agent({subagent_type: "loop-spec:implementer", model: "claude-sonnet-4-6", prompt: "Reply with the single word: ok"})
```

Retry each on transient error (2x, 2s backoff). On hard failure:
```
loop-spec health check FAILED
  Model: {model_id}
  Error: {error}
  Suggested fix: update CLAUDE.md model policy to allow {model_id}
```
Then abort.

Set `sonnet_1m_available = false` (1M context probe removed; defaults to false; the skill will use standard context windows).

### Workflow availability probe

After the model health-check, write `.loop-spec/runtime.json` recording (a) whether the `Workflow` tool is available, gated deterministically on the Claude Code version (`Workflow` ships in CC `>= 2.1.154`; do not rely on model self-introspection), and (b) whether the operator opted into the EXECUTE workflow rung:

```bash
mkdir -p .loop-spec
wf="$(bash "${CLAUDE_SKILL_DIR}/../../lib/workflow-availability.sh")"
optin=false
[[ "${LOOP_SPEC_EXECUTE_WORKFLOW:-}" == "1" ]] && optin=true
# Merge-write: preserves modelsProbedAt (Step 3.5 cache) across cycles.
python3 -c "
import json, sys, os
path = '.loop-spec/runtime.json'
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except Exception:
        data = {}
data['workflowsAvailable'] = sys.argv[1] == 'true'
data['workflowExecuteOptIn'] = sys.argv[2] == 'true'
data['teamsAvailable'] = sys.argv[3] == 'true'
json.dump(data, open(path, 'w'))
" "$wf" "$optin" "$teams_available"
```

`lib/workflow-availability.sh` gates on the CC version; set `LOOP_SPEC_WORKFLOWS_AVAILABLE=1|0` to force it (testing).

`workflowExecuteOptIn` gates the heaviest EXECUTE rung. EXECUTE's concurrency ladder
(`skills/shared/tier-matrix.md`) selects subagent or agent-team dispatch by DAG width on
its own; it escalates to a Workflow DAG **only** when the operator sets
`LOOP_SPEC_EXECUTE_WORKFLOW=1` AND the DAG is wide enough (`W >= t_wf`) AND the
`Workflow` tool is available. This honors the Anthropic guidance that Workflow runs only
on explicit opt-in. With the flag unset, EXECUTE never dispatches a Workflow even on a
very wide DAG; it tops out at the agent-team rung. (The flag does not affect the
opportunistic fan-out workflows in PLAN/VERIFY/map-codebase, which remain gated on
`workflowsAvailable` alone.)

Then invoke the permission check hook (non-fatal advisory):

```bash
bash "${CLAUDE_SKILL_DIR}/../../hooks/pre-cycle-permission-check.sh"
```

`workflowsAvailable` is `true` on Claude Code `>= 2.1.154` (where `Workflow` is
supported), else `false`. The cycle proceeds regardless; fan-out skills read
`runtime.json` to decide their dispatch path. See `skills/shared/dispatch-fanout.md`.

### Step 4 - Detect project commands

**Single-repo mode (unchanged):**

Auto-detect (best effort):
- test: parse package.json scripts.test, Makefile `test` target, pyproject.toml [tool.pytest], go.mod presence (`go test ./...`)
- lint: scripts.lint, Makefile lint, ruff/eslint config files
- typecheck: scripts.typecheck, mypy.ini, tsconfig.json + tsc

Confirm with user via AskUserQuestion (one Q with options):
- "Detected commands: test=`{X}`, lint=`{Y}`, typecheck=`{Z}`. Use these?"
- Options: "Yes", "Customize"

If customize: ask each separately.

Skip this confirmation step when `LOOP_SPEC_NON_INTERACTIVE=1` (use auto-detected values as-is).

Normalize all three to strings so `feature.commands` always carries `test`/`lint`/`typecheck` keys (undetected = empty string, never null; phases treat empty as "skip this check"): `cmd_test="${cmd_test:-}"; cmd_lint="${cmd_lint:-}"; cmd_typecheck="${cmd_typecheck:-}"`.

**Workspace mode (additive):**

Run the same auto-detection per participating repo using the repo's absolute path as the probe dir. Collect per-repo command maps:

```bash
declare -A repo_cmds_test repo_cmds_lint repo_cmds_typecheck
for repo_entry in $(echo "$workspace_repos_json" | jq -c '.[]'); do
  rname="$(echo "$repo_entry" | jq -r '.name')"
  rpath="${workspace_root}/$(echo "$repo_entry" | jq -r '.path')"
  # run same detection logic against "$rpath"
  repo_cmds_test["$rname"]="${detected_test:-}"
  repo_cmds_lint["$rname"]="${detected_lint:-}"
  repo_cmds_typecheck["$rname"]="${detected_typecheck:-}"
done
```

Present a single AskUserQuestion listing all repos and detected commands; user confirms or customizes per-repo. Skip when `LOOP_SPEC_NON_INTERACTIVE=1`. Top-level `commands` in feature.json will carry empty strings (workspace mode per-repo commands are authoritative in `workspace.repos[].commands`).

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

# Model IDs are fixed (no preset). Persisted to feature.json.models ONCE here.
# Every phase skill reads literal IDs from feature.models.<role> instead of re-deriving
# from model-matrix.md per spawn -- this is what guarantees teammates never silently
# inherit the orchestrator's session model. Mirrors skills/shared/model-matrix.md:
#   opus   -> spec-writer, planner, advocate, challenger, spec-compliance-reviewer
#   sonnet -> implementer, code-reviewer, verifier, mapper-*, pattern-mapper
opus_model="claude-opus-4-8"
sonnet_model="claude-sonnet-4-6"

feature_json=$(jq -n \
  --arg slug "$slug" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg tier "$tier" --arg style "$execStyle" \
  --arg branch "feat/${slug}" --arg sha "$base_sha" --arg basebranch "$base_branch" \
  --arg opus "$opus_model" --arg sonnet "$sonnet_model" \
  --arg test "$cmd_test" --arg lint "$cmd_lint" --arg typecheck "$cmd_typecheck" \
  --arg wt ".claude/worktrees/${slug}" \
  '{
    schemaVersion: 7,
    slug: $slug,
    createdAt: $now, updatedAt: $now,
    tier: $tier, execStyle: $style,
    models: {
      specWriter: $opus, planner: $opus,
      advocate: $opus, challenger: $opus, specComplianceReviewer: $opus,
      iterateJudge: $opus,
      implementer: $sonnet, codeReviewer: $sonnet, verifier: $sonnet,
      mapper: $sonnet, patternMapper: $sonnet
    },
    currentPhase: "spec",
    completedPhases: [],
    artifacts: {
      specInterview: null,
      spec: null, patterns: null, plan: null, execution: null, verification: null,
      iteration: null,
      patternsSource: null,
      codebaseSource: {tech: null, arch: null, quality: null, concerns: null, domain: null}
    },
    branch: $branch,
    baseSha: $sha,
    baseBranch: $basebranch,
    worktreePath: $wt,
    workspace: null,
    currentTeamName: null,
    currentTeammates: [],
    currentGate: {round: 0, phase: null},
    mergeQueue: [],
    pendingRemediationTasks: [],
    fileConflictExcludeGlobs: [],
    gateHistory: [],
    retryBudget: {
      perGate: (if $tier == "quick" then 1 elif $tier == "balanced" then 2 else 3 end),
      perPhase: {
        spec: (if $tier == "quick" then 1 elif $tier == "balanced" then 2 else 3 end),
        discuss: (if $tier == "quick" then 1 elif $tier == "balanced" then 2 else 3 end),
        plan: (if $tier == "quick" then 1 elif $tier == "balanced" then 3 else 4 end),
        execute: null,
        verify: (if $tier == "quick" then 2 elif $tier == "balanced" then 3 else 4 end),
        iterate: (if $tier == "quick" then 1 elif $tier == "balanced" then 2 else 3 end)
      },
      global: (if $tier == "quick" then 10 elif $tier == "balanced" then 20 else 30 end),
      globalUsed: 0,
      perGateUsed: {},
      perPhaseUsed: {spec: 0, discuss: 0, plan: 0, execute: 0, verify: 0, iterate: 0}
    },
    iterate: {
      maxIterations: (if $tier == "quick" then 1 elif $tier == "balanced" then 2 else 3 end),
      used: 0,
      lastVerdict: null,
      feedback: null,
      history: []
    },
    commands: {test: $test, lint: $lint, typecheck: $typecheck},
    stalenessHours: 48,
    warnings: [],
    bootstrapPendingDomains: []
  }')

bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" ".loop-spec/features/${slug}" "$feature_json"

#### Workspace mode Step 5 variant

In workspace mode (`workspaceMode == "workspace"`), do NOT call `create-feature-worktree` and do NOT call `EnterWorktree`. All work stays at the workspace root. Replace the single-repo branch setup above with the following two-phase procedure.

**Phase 1 -- pre-flight cleanliness check (ALL repos, before ANY branch is created):**

```bash
dirty_repos=()
for repo_entry in $(echo "$workspace_repos_json" | jq -c '.[]'); do
  rname="$(echo "$repo_entry" | jq -r '.name')"
  rpath="${workspace_root}/$(echo "$repo_entry" | jq -r '.path')"
  if ! bash "${CLAUDE_SKILL_DIR}/../../lib/git-ops.sh" -C "$rpath" ensure-clean-or-stash 2>/dev/null; then
    dirty_repos+=("$rname ($rpath)")
  fi
done
if [[ ${#dirty_repos[@]} -gt 0 ]]; then
  echo "loop-spec: cannot create feature branches -- the following repos have uncommitted changes:"
  for r in "${dirty_repos[@]}"; do echo "  $r"; done
  echo "Please commit or stash changes in each repo above, then re-invoke cycle."
  exit 1
fi
```

If any repo is dirty, abort with the message above. No branches are created.

**Phase 2 -- per-repo branch creation (only when all repos are clean):**

```bash
declare -A repo_base_sha repo_base_branch
for repo_entry in $(echo "$workspace_repos_json" | jq -c '.[]'); do
  rname="$(echo "$repo_entry" | jq -r '.name')"
  rpath="${workspace_root}/$(echo "$repo_entry" | jq -r '.path')"
  base_sha_r="$(git -C "$rpath" rev-parse HEAD)"
  base_branch_r="$(bash "${CLAUDE_SKILL_DIR}/../../lib/git-ops.sh" -C "$rpath" detect-base-branch)"
  git -C "$rpath" checkout -b "feat/${slug}" "$base_sha_r"
  repo_base_sha["$rname"]="$base_sha_r"
  repo_base_branch["$rname"]="$base_branch_r"
done
```

**State dirs** are created at the workspace root:

```bash
mkdir -p "${workspace_root}/.loop-spec/features/${slug}" \
         "${workspace_root}/.loop-spec/codebase" \
         "${workspace_root}/docs/loop-spec/features/${slug}"
```

**feature.json construction for workspace mode:**

Build the `workspace.repos` array from the per-repo data collected above, then write feature.json:

```bash
repos_json_array="$(echo "$workspace_repos_json" | jq -c \
  --argjson base_shas "$(for rname in "${!repo_base_sha[@]}"; do
      echo "{\"name\":\"$rname\",\"sha\":\"${repo_base_sha[$rname]}\"}"; done | jq -s .)" \
  --argjson base_branches "$(for rname in "${!repo_base_branch[@]}"; do
      echo "{\"name\":\"$rname\",\"branch\":\"${repo_base_branch[$rname]}\"}"; done | jq -s .)" \
  '[.[] | . as $r |
    ($base_shas[] | select(.name == $r.name) | .sha) as $sha |
    ($base_branches[] | select(.name == $r.name) | .branch) as $bb |
    {
      name: $r.name,
      path: $r.path,
      branch: ("feat/" + env.slug),
      baseSha: $sha,
      baseBranch: $bb,
      commands: {
        test: (env["REPO_TEST_" + ($r.name | gsub("[^A-Za-z0-9]"; "_"))] // ""),
        lint: (env["REPO_LINT_" + ($r.name | gsub("[^A-Za-z0-9]"; "_"))] // ""),
        typecheck: (env["REPO_TYPECHECK_" + ($r.name | gsub("[^A-Za-z0-9]"; "_"))] // "")
      }
    }
  ]')"
# (In practice, per-repo commands detected in Step 4 are substituted in directly
#  rather than via env vars; the structure above is illustrative of the shape.)

workspace_feature_json=$(jq -n \
  --arg slug "$slug" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg tier "$tier" --arg style "$execStyle" \
  --arg opus "$opus_model" --arg sonnet "$sonnet_model" \
  --arg wsroot "$workspace_root" \
  --argjson repos "$repos_json_array" \
  '{
    schemaVersion: 7,
    slug: $slug,
    createdAt: $now, updatedAt: $now,
    tier: $tier, execStyle: $style,
    models: {
      specWriter: $opus, planner: $opus,
      advocate: $opus, challenger: $opus, specComplianceReviewer: $opus,
      iterateJudge: $opus,
      implementer: $sonnet, codeReviewer: $sonnet, verifier: $sonnet,
      mapper: $sonnet, patternMapper: $sonnet
    },
    currentPhase: "spec",
    completedPhases: [],
    artifacts: {
      specInterview: null,
      spec: null, patterns: null, plan: null, execution: null, verification: null,
      iteration: null,
      patternsSource: null,
      codebaseSource: {tech: null, arch: null, quality: null, concerns: null, domain: null}
    },
    branch: null,
    baseSha: null,
    baseBranch: null,
    worktreePath: null,
    workspace: {
      root: $wsroot,
      repos: $repos
    },
    currentTeamName: null,
    currentTeammates: [],
    currentGate: {round: 0, phase: null},
    mergeQueue: [],
    pendingRemediationTasks: [],
    fileConflictExcludeGlobs: [],
    gateHistory: [],
    retryBudget: {
      perGate: (if $tier == "quick" then 1 elif $tier == "balanced" then 2 else 3 end),
      perPhase: {
        spec: (if $tier == "quick" then 1 elif $tier == "balanced" then 2 else 3 end),
        discuss: (if $tier == "quick" then 1 elif $tier == "balanced" then 2 else 3 end),
        plan: (if $tier == "quick" then 1 elif $tier == "balanced" then 3 else 4 end),
        execute: null,
        verify: (if $tier == "quick" then 2 elif $tier == "balanced" then 3 else 4 end),
        iterate: (if $tier == "quick" then 1 elif $tier == "balanced" then 2 else 3 end)
      },
      global: (if $tier == "quick" then 10 elif $tier == "balanced" then 20 else 30 end),
      globalUsed: 0,
      perGateUsed: {},
      perPhaseUsed: {spec: 0, discuss: 0, plan: 0, execute: 0, verify: 0, iterate: 0}
    },
    iterate: {
      maxIterations: (if $tier == "quick" then 1 elif $tier == "balanced" then 2 else 3 end),
      used: 0,
      lastVerdict: null,
      feedback: null,
      history: []
    },
    commands: {test: "", lint: "", typecheck: ""},
    stalenessHours: 48,
    warnings: [],
    bootstrapPendingDomains: []
  }')

bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" \
  "${workspace_root}/.loop-spec/features/${slug}" "$workspace_feature_json"
```

Schema notes for workspace feature.json:
- `schemaVersion: 7`; top-level `branch`, `baseSha`, `baseBranch`, `worktreePath` are `null`; top-level `commands` holds empty strings.
- `workspace.root` is the absolute workspace parent path.
- `workspace.repos[]` carries `name`, `path` (relative to workspace root), `branch` (`feat/{slug}`), `baseSha`, `baseBranch`, and `commands` (per-repo detected commands) -- matching the schema in `skills/shared/feature-state-schema.md`.
```

No initial commit is made here: `create-feature-worktree` already pointed `feat/{slug}` at a real commit (`base_sha`), and `feature.json` is gitignored runtime state (it lives in the worktree's working dir and is read back on resume, never committed -- consistent with the rest of loop-spec). Phase artifacts under `docs/loop-spec/features/{slug}/` are committed by each phase as it writes them (SPEC, PLAN, VERIFY).

Provenance fields:
- `artifacts.patternsSource` -- one of `"gsd-ingest"`, `"pattern-mapper"`, `"manual"`, or `null` until written. Set in PLAN Step 0.
- `artifacts.codebaseSource.{domain}` -- one of `"gsd-ingest"`, `"mapper"`, `"manual"`, or `null` until written. Set per-domain in Step 5.5.

Print cost estimate based on tier + expected scope:
```
Estimated cost: ~{N}k tokens (tier: {tier})
```

### Step 5.4 - Graphify bootstrap pre-flight (always; before the codebase-map skip)

**Workspace mode:** graphify operates on a single repo root, so workspace mode builds one graph **per participating repo** (see the workspace block at the end of this step) rather than skipping. graphify is still required in workspace mode.

---

Runs on EVERY cycle (single-repo mode). graphify is a hard requirement (enforced at Step 2), so the graph is built unconditionally and a build failure aborts — the design phases depend on it. It must NOT be gated behind the Step 5.5 "all 5 docs exist" skip: the graph (`graphify-out/graph.json`) is independent of the loop-spec codebase docs, so a repo that already has the 5 docs but no graph still needs one built. Idempotent, no LLM.

Decision tree:
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

**Workspace mode -- GSD ingest:** GSD ingest is a single-repo operation (`.planning/codebase/` lives inside one repo). Skip Step 5.5a (GSD ingest) entirely in workspace mode and log one line:

```
workspace mode: skipping GSD ingest (single-repo only)
```

Proceed directly to Step 5.5b mapper dispatch using the workspace-mode variant described below.

---

Required loop-spec docs: `docs/loop-spec/codebase/{TECH,ARCH,QUALITY,CONCERNS,DOMAIN}.md`.

If all 5 already exist: skip this step. Incremental refresh runs at end of cycle automatically (in VERIFY).

Mapping (used by `lib/gsd-ingest.sh codebase`):

| GSD source files (`.planning/codebase/`) | Loop-spec target (`docs/loop-spec/codebase/`) |
|---|---|
| `STACK.md` + `INTEGRATIONS.md` | `TECH.md` |
| `ARCHITECTURE.md` + `STRUCTURE.md` | `ARCH.md` |
| `CONVENTIONS.md` + `TESTING.md` | `QUALITY.md` |
| `CONCERNS.md` | `CONCERNS.md` |
| (no GSD analog) | `DOMAIN.md` -- always mapped by `mapper-domain` |

Graphify (and GSD supersession when graphify is present) is handled in Step 5.4 above, which always runs. The remaining sub-steps below build any loop-spec codebase docs that are still missing.

#### Step 5.5a - GSD ingestion (if applicable)

```bash
ingest_output="$(bash "${CLAUDE_SKILL_DIR}/../../lib/gsd-ingest.sh" codebase)"
echo "$ingest_output"
```

The script writes any `INGESTED <DOMAIN>` lines for domains it filled and `SKIPPED <DOMAIN> (no source)` for ones it couldn't. If `.planning/codebase/` doesn't exist it prints `NONE`.

Update `feature.artifacts.codebaseSource.{domain} = "gsd-ingest"` for each `INGESTED` line by calling `bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set ".loop-spec/features/${slug}" .artifacts.codebaseSource.{domain} '"gsd-ingest"'` per domain.

`.loop-spec/codebase/index.json` is **not** rebuilt here -- the next incremental refresh (end of VERIFY) populates it from the actual file scan. Leaving it absent at this point is correct; the incremental code paths handle the missing-file case.

If GSD ingest produced any new files, commit immediately so the repo state is clean before mapper agents touch it:

```bash
if ! git diff --quiet docs/loop-spec/codebase/; then
  git add docs/loop-spec/codebase/
  git commit -m "docs: NO_JIRA ingest GSD codebase map (domains: <csv>)"
fi
```

#### Step 5.5b - Map missing domains

```bash
missing=()
for d in TECH ARCH QUALITY CONCERNS DOMAIN; do
  [[ -f "docs/loop-spec/codebase/${d}.md" ]] || missing+=("${d,,}")
done
```

If `missing` is non-empty:

- Print: `First loop-spec run. Bootstrapping {N} codebase domain(s) in background: {csv}...`

- Model for mappers: `model_mapper = feature.models.mapper` (resolved once at Step 5; do not re-derive from model-matrix).

- **Single-repo mode:** background mappers are subagents and do NOT inherit the worktree cwd. Resolve the repo root once and pass ABSOLUTE paths in every Agent prompt:
  ```bash
  WT_ROOT="$(git rev-parse --show-toplevel)"
  ```

- **Workspace mode mapper dispatch:** do NOT run `git rev-parse --show-toplevel` at the workspace root (it may not be a git repo). Instead, build a repo-list string from the participating repos and pass it in each mapper prompt:

  ```bash
  repo_list=""
  for repo_entry in $(echo "$workspace_repos_json" | jq -c '.[]'); do
    rname="$(echo "$repo_entry" | jq -r '.name')"
    rpath="${workspace_root}/$(echo "$repo_entry" | jq -r '.path')"
    repo_list="${repo_list}${rname}=${rpath}, "
  done
  repo_list="${repo_list%, }"   # strip trailing comma+space
  ```

  Fire one background `Agent` call per missing domain (workspace variant):

  ```
  Parallel (background):
    Agent({
      subagent_type: "loop-spec:mapper-{domain-1}",
      model: model_mapper,
      run_in_background: true,
      description: "Bootstrap codebase map: {domain-1}",
      prompt: """
        You are bootstrapping the codebase map for this workspace.
        slug: {slug}
        Workspace root (absolute): {workspace_root}
        Repos: {repo_list}   (format: name=abs-path, ...)
        Produce {workspace_root}/docs/loop-spec/codebase/{DOMAIN-1}.md per your role definition.
        Cover each repo with per-repo sections. Use absolute paths throughout. Do NOT commit.
        When done, reply with: "DONE: {domain-1}"
      """
    })
    // ... one Agent call per missing domain
  ```

  After mapper agents complete, commit the codebase docs only when the workspace root is itself a git repo:

  ```bash
  if git -C "$workspace_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if ! git -C "$workspace_root" diff --quiet docs/loop-spec/codebase/ 2>/dev/null; then
      git -C "$workspace_root" add docs/loop-spec/codebase/
      git -C "$workspace_root" commit -m "docs: NO_JIRA bootstrap codebase map (workspace)"
    fi
  else
    echo "workspace root not a git repo; leaving codebase docs uncommitted"
  fi
  ```

- **Single-repo mode** fire one background `Agent` call per missing domain:

  ```
  Parallel (background):
    Agent({
      subagent_type: "loop-spec:mapper-{domain-1}",
      model: model_mapper,
      run_in_background: true,
      description: "Bootstrap codebase map: {domain-1}",
      prompt: """
        You are bootstrapping the codebase map for this project.
        slug: {slug}
        Working directory (absolute): {WT_ROOT}
        Produce {WT_ROOT}/docs/loop-spec/codebase/{DOMAIN-1}.md per your role definition (agents/mapper-{domain-1}.md).
        Use the template at {WT_ROOT}/skills/shared/artifact-templates/{DOMAIN-1}.md.template if it exists.
        Write only your assigned domain file using absolute paths. Do NOT commit.
        When done, reply with: "DONE: {domain-1}"
      """
    })
    // ... one Agent call per missing domain; always pass WT_ROOT-prefixed absolute paths
  ```

- Record pending domains in `feature.json`:
  ```bash
  lib/feature-write.sh set bootstrapPendingDomains '["tech", "arch", ...]'
  ```
  (list only the domains that were fired as background agents)

- Proceed immediately to Step 6 (do NOT wait here). The DISCUSS skill will wait for these files before dispatching the spec-writer.

The DISCUSS skill waits for all 5 docs before dispatching spec-writer (see discuss/SKILL.md Step 1.5).

If `missing` is empty (all ingested from GSD): no mapper dispatch, no second commit.

This produces at most two clean commits per first run (one ingest, one mapper bootstrap) and never amends. This is the ONLY one-time setup the cycle performs per project; everything else is per-feature.

### Step 5.9 - Normalize feature.models (resume backfill + migration)

Phase skills read `model: feature.models.<role>` literally and do NOT re-derive from `model-matrix.md`. Model selection is fixed, so the canonical map is the same for every feature. Older features either lack a `models` block (pre-v2.3.0) or carry a stale one from the removed preset scheme (opus reviewers, or haiku roles). Before routing to any phase, write the canonical fixed map idempotently and drop the vestigial `preset` field. This is the single fallback point, so no individual phase skill needs its own:

```bash
feat_dir=".loop-spec/features/${slug}"
fjson="${feat_dir}/feature.json"
canonical=$(jq -n --arg o "claude-opus-4-8" --arg s "claude-sonnet-4-6" '{
  specWriter:$o, planner:$o, advocate:$o, challenger:$o, specComplianceReviewer:$o,
  implementer:$s, codeReviewer:$s, verifier:$s, mapper:$s, patternMapper:$s
}')
# Rewrite only when models differ from canonical or a vestigial preset field lingers.
# Only .models and .preset are touched; all other fields (including worktreePath) are preserved.
if [[ "$(jq -c '.models // {}' "$fjson")" != "$(echo "$canonical" | jq -c .)" \
      || "$(jq 'has("preset")' "$fjson")" == "true" ]]; then
  new_json="$(jq --argjson m "$canonical" '.models = $m | del(.preset)' "$fjson")"
  bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" "$feat_dir" "$new_json"
  echo "Normalized feature.models to the fixed model map."
fi
```

### Step 6 - Route to phase

The cycle does NOT create the phase team. Each phase skill owns its own team lifecycle: `TeamCreate` at phase start, `TeamDelete` + clear `currentTeamName` at phase end. This keeps team rosters phase-specific (each phase has different teammates) and avoids double-`TeamCreate` errors.

For new features, `currentPhase` is initialized to `"spec"` (Step 5), so `Skill(loop-spec:spec)` is invoked first. After spec completes, `currentPhase` advances to `"discuss"`, then `"plan"`, `"execute"`, `"verify"`, then `"iterate"`, and finally `"completed"`. The `iterate` phase is the outer convergence loop: it judges the result against the original goal and may route `currentPhase` **back** to `"execute"`, `"plan"`, or (with your approval) `"spec"`/`"discuss"` to fix a gap, or forward to `"completed"` when converged or the iteration budget is spent. Because ITERATE can rewind the phase pointer, the cycle's phase loop (below) naturally re-invokes the upstream phase.

Cycle's only responsibility here is to invoke the phase skill and react to its return:

1. **Invoke phase skill:**
   ```
   Skill(loop-spec:{currentPhase})
   ```
   `{currentPhase}` is read from the in-memory `feature_json` loaded earlier (`feature_json.currentPhase`). The phase skill runs inside its own team, writes `currentTeamName` on entry, advances `currentPhase`, and clears `currentTeamName` on exit (all via `lib/feature-write.sh`).

2. **Re-load feature.json** after the skill returns (the skill may have advanced `currentPhase` and updated artifacts):
   ```bash
   feature_json=$(cat ".loop-spec/features/${slug}/feature.json")
   next_phase=$(echo "$feature_json" | jq -r '.currentPhase')
   ```

3. **Route to next iteration:**
   - If `next_phase == "completed"`: jump to the "On completion" section below.
   - If `execStyle` is `auto` or `review-only`: continue the loop -- invoke `Skill(loop-spec:{next_phase})`.
   - If `execStyle` is `step` or `interactive`: print phase summary and return to user. User re-invokes `Skill(loop-spec:cycle)` to continue (resume detection in Step 1 picks up the in-progress state).

## Resume strategy + phase pause/escalation

Full algorithm and escalation handling (budget exhausted, NEEDS_CONTEXT, etc.) in **`skills/shared/cycle-resume-escalation.md`**. Step 1 carries the inline fast-path.

## On completion

Phase chain finishes when verify completes successfully. Before marking completed:

1. Call `TeamDelete({name: feature_json.currentTeamName})` (if `currentTeamName` is non-null) to tear down the final phase team.
2. Update `feature.json` via `lib/feature-write.sh`:
   ```bash
   completed_json="$(echo "$feature_json" | jq \
     '.currentPhase = "completed" | .currentTeamName = null | .currentTeammates = [] | .currentGate = {round: 0, phase: null} | .updatedAt = now | strftime("%Y-%m-%dT%H:%M:%SZ")')"
   bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" ".loop-spec/features/${slug}" "$completed_json"
   ```

Then print final summary (PR URL, commits, time, cost).

**Note:** `TeamDelete` is called explicitly here at the orchestration layer. It is NOT implemented as a bash `trap` because `TeamDelete` is a harness MCP tool callable only from the lead's tool-using context, not from a shell signal handler. See the resume strategy orphan-detection path for killed-session cleanup.
