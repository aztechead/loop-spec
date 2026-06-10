---
name: cycle
description: ENTRY POINT for super-spec. Spec-driven feature cycle (SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY). Pick tier (quality/balanced/quick) + execution style (auto/step/interactive/review-only) + feature title. Model selection is fixed (no preset). Resumes incomplete features automatically.
argument-hint: "[feature description]  (optional inline: tier:quick|balanced|quality style:auto|step|interactive|review-only)"
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet EnterWorktree ExitWorktree
---

# super-spec:cycle

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
| `Skill` | Invoking another super-spec skill (`Skill(super-spec:plan)` etc.) |
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
- A fresh `Agent` call is reserved for the Step 5.5b background codebase domain mappers only.

When a phase ends: call `TeamDelete` to tear down the team before the next phase's `TeamCreate`.

This rule applies in DISCUSS, PLAN, EXECUTE, VERIFY, MAP-CODEBASE, and any sub-skill called from this cycle.

## Non-interactive mode

Set `SUPER_SPEC_NON_INTERACTIVE=1` to skip all AskUserQuestion calls (used by the manual non-interactive end-to-end matrix and CI).
When set, read answers from env vars instead:

| Env var | Values | AskUserQuestion it replaces |
|---|---|---|
| `SUPER_SPEC_ANSWER_TIER` | `quality`, `balanced`, `quick` | Tier selection (Step 3) |
| `SUPER_SPEC_ANSWER_STYLE` | `auto`, `step`, `interactive`, `review-only` | Execution style (Step 3) |
| `SUPER_SPEC_ANSWER_TITLE` | free text | Feature title (Step 3) |
| `SUPER_SPEC_ANSWER_MIGRATE_SCHEMA` | `1` | Migrate v3 feature to v4 on resume (Step 1). Default: continue on v3. |

Note: Non-interactive mode bypasses `AskUserQuestion` entirely by reading env vars. The S2 batching change (4 questions in one call) has no effect on non-interactive paths.

## Procedure

**Startup is silent.** Run Steps 1 (resume detection), 2 (health-check), 3.5 (model probe), and the workflow-availability probe quietly: do NOT narrate each one. Batch their checks and emit output ONLY when (a) a check fails, (b) a resumable feature is found and a choice is needed, or (c) Step 3 announces the launch line. No "Running Step 1...", no per-step status prose. The user wants to land in the workflow, not watch a preflight.

### Step 1 - Resume detection

Scan `.super-spec/features/*/feature.json` (if directory exists). For each:
- Parse safely (try/except; on parse fail, try `feature.json.bak`)
- Skip if `currentPhase == "completed"`
- **schemaVersion 3 detection:** if `schemaVersion == 3`, prompt the user via AskUserQuestion (before the orphan probe):
  - header: `"In-flight v3 feature detected"`
  - question: `"Feature {slug} is on schemaVersion 3. Migrate to v4 (adds spec-phase fields, does NOT rewind completed phases) or continue on v3?"`
  - options: `["Migrate to v4", "Continue on v3"]`
  - "Migrate to v4": run `bash "${CLAUDE_SKILL_DIR}/../../lib/migrate-schema-v3-to-v4.sh" ".super-spec/features/{slug}"`, reload feature.json
  - "Continue on v3": proceed without migration; cycle will use the existing v3 behavior (no spec phase)
  - When `SUPER_SPEC_NON_INTERACTIVE=1`: default to "Continue on v3" unless `SUPER_SPEC_ANSWER_MIGRATE_SCHEMA=1` is set
- **Orphan detection:** if `currentTeamName != null`, probe team liveness by calling `TaskList({team: currentTeamName})`:
  - If `TaskList` returns without error: the team is still live (orphaned). Print:
    ```
    Previous team {currentTeamName} for feature {slug} was orphaned and is still live in the harness.
    Run TeamDelete for team {currentTeamName} (e.g., via the harness CLI or by re-invoking cycle in cleanup mode), then restart cycle to resume feature {slug}.
    ```
    Add to a "needs cleanup" sub-list. Do NOT add to resumable list.
  - If `TaskList` errors (team not found): the prior team is gone. Print `"feature {slug} had stale team reference {currentTeamName}; cleared and ready to resume"`. Clear `currentTeamName` in `feature.json` via `lib/feature-write.sh`. Add to resumable list.
- If `currentTeamName == null` AND `(now - updatedAt) < stalenessHours * 3600`: add to resumable list.

If "needs cleanup" sub-list is non-empty: display it to the user after presenting resume options, so they know which teams require manual `TeamDelete`.

If resumable list non-empty: present via AskUserQuestion (or skip if `SUPER_SPEC_NON_INTERACTIVE=1`):
- "Resume {slug} (phase: {currentPhase}, last updated {ago})?"
- Options: each resumable feature + "New feature"

If user picks resume: load feature.json into memory, skip Steps 2-5, route to Step 6.
- **Worktree resume (schemaVersion 6+, `worktreePath` present):** run `git-ops.sh list-feature-worktrees` to confirm it exists, then `EnterWorktree({ path: feature.worktreePath })` before Step 6. If the worktree is gone, warn and offer to re-create or continue in-place.
- **Legacy resume (no `worktreePath`):** resume in-place. Do NOT force-migrate.
- Full algorithm: `skills/shared/cycle-resume-escalation.md`.

### Step 2 - Startup health-check

Check that `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` is set to `1`:

```bash
if [[ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS}" != "1" ]]; then
  echo "super-spec health check FAILED"
  echo "  Capability: agent teams"
  echo "  Error: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS is not set to 1"
  echo "  Suggested fix: export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 and re-run"
  exit 1
fi
```

Abort immediately if unset or not equal to `1`.

Model availability is probed in Step 3.5. Model selection is fixed (no preset), so the probe always covers the same two models.

### Step 3 - Pick tier + style + feature

Goal: launch straight into the workflow. Do NOT open a blocking 4-question prompt when the invocation already carries a feature description.

Resolution order:

1. **Non-interactive** (`SUPER_SPEC_NON_INTERACTIVE=1`): read env vars. Defaults when unset: `SUPER_SPEC_ANSWER_TIER` → `quick` (unchanged CI/smoke contract), `SUPER_SPEC_ANSWER_STYLE` → `auto`, `SUPER_SPEC_ANSWER_TITLE` → required (abort if unset). A `SUPER_SPEC_ANSWER_PRESET` env var, if set, is ignored (model selection is fixed).

2. **Invocation carries a feature description** (`$ARGUMENTS` is non-empty -- the user typed `/super-spec:cycle <description>`): this is the default fast path.
   - Title = `$ARGUMENTS` (slugified). Parse optional inline overrides anywhere in the text: `tier:quick|balanced|quality`, `style:auto|step|interactive|review-only`. A legacy `preset:...` token, if present, is silently ignored.
   - Apply defaults for anything not given inline: **tier `balanced`, style `auto`.**
   - Do NOT call `AskUserQuestion`. Print one line and proceed:
     `Launching: tier={tier} style={style} title="{title}". (Reply within this turn with e.g. "tier:quality" to adjust before SPEC starts.)`

3. **Bare invocation** (no description): the only thing genuinely required is a title. Ask a SINGLE `AskUserQuestion` for the feature title, and offer tier/style as optional same-call questions defaulted to `balanced`/`auto` (the user can accept defaults with one click). Never block the launch on more than this.

Slug = kebab-case of title (lowercase, replace spaces+special with `-`, dedupe consecutive `-`).

### Step 3.5 - Model probe

Model selection is fixed (see `skills/shared/model-matrix.md`): the unique model set is always `{claude-opus-4-8, claude-sonnet-4-6}`.

Dispatch one probe Agent per unique model (parallel, single tool message):

```
Parallel:
  Agent({subagent_type: "super-spec:spec-writer", model: "claude-opus-4-8",   prompt: "Reply with the single word: ok"})
  Agent({subagent_type: "super-spec:implementer", model: "claude-sonnet-4-6", prompt: "Reply with the single word: ok"})
```

Retry each on transient error (2x, 2s backoff). On hard failure:
```
super-spec health check FAILED
  Model: {model_id}
  Error: {error}
  Suggested fix: update CLAUDE.md model policy to allow {model_id}
```
Then abort.

Set `sonnet_1m_available = false` (1M context probe removed; defaults to false; the skill will use standard context windows).

### Workflow availability probe

After the model health-check, write `.super-spec/runtime.json` recording (a) whether the `Workflow` tool is available, gated deterministically on the Claude Code version (`Workflow` ships in CC `>= 2.1.154`; do not rely on model self-introspection), and (b) whether the operator opted into the EXECUTE workflow rung:

```bash
mkdir -p .super-spec
wf="$(bash "${CLAUDE_SKILL_DIR}/../../lib/workflow-availability.sh")"
optin=false
[[ "${SUPER_SPEC_EXECUTE_WORKFLOW:-}" == "1" ]] && optin=true
python3 -c "import json,sys; json.dump({'workflowsAvailable': sys.argv[1]=='true', 'workflowExecuteOptIn': sys.argv[2]=='true'}, open('.super-spec/runtime.json','w'))" "$wf" "$optin"
```

`lib/workflow-availability.sh` gates on the CC version; set `SUPER_SPEC_WORKFLOWS_AVAILABLE=1|0` to force it (testing).

`workflowExecuteOptIn` gates the heaviest EXECUTE rung. EXECUTE's concurrency ladder
(`skills/shared/tier-matrix.md`) selects subagent or agent-team dispatch by DAG width on
its own; it escalates to a Workflow DAG **only** when the operator sets
`SUPER_SPEC_EXECUTE_WORKFLOW=1` AND the DAG is wide enough (`W >= t_wf`) AND the
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

Auto-detect (best effort):
- test: parse package.json scripts.test, Makefile `test` target, pyproject.toml [tool.pytest], go.mod presence (`go test ./...`)
- lint: scripts.lint, Makefile lint, ruff/eslint config files
- typecheck: scripts.typecheck, mypy.ini, tsconfig.json + tsc

Confirm with user via AskUserQuestion (one Q with options):
- "Detected commands: test=`{X}`, lint=`{Y}`, typecheck=`{Z}`. Use these?"
- Options: "Yes", "Customize"

If customize: ask each separately.

Skip this confirmation step when `SUPER_SPEC_NON_INTERACTIVE=1` (use auto-detected values as-is).

Normalize all three to strings so `feature.commands` always carries `test`/`lint`/`typecheck` keys (undetected = empty string, never null; phases treat empty as "skip this check"): `cmd_test="${cmd_test:-}"; cmd_lint="${cmd_lint:-}"; cmd_typecheck="${cmd_typecheck:-}"`.

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
mkdir -p ".super-spec/features/${slug}" .super-spec/codebase "docs/super-spec/features/${slug}"

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
    schemaVersion: 6,
    slug: $slug,
    createdAt: $now, updatedAt: $now,
    tier: $tier, execStyle: $style,
    models: {
      specWriter: $opus, planner: $opus,
      advocate: $opus, challenger: $opus, specComplianceReviewer: $opus,
      implementer: $sonnet, codeReviewer: $sonnet, verifier: $sonnet,
      mapper: $sonnet, patternMapper: $sonnet
    },
    currentPhase: "spec",
    completedPhases: [],
    artifacts: {
      specInterview: null,
      spec: null, patterns: null, plan: null, execution: null, verification: null,
      patternsSource: null,
      codebaseSource: {tech: null, arch: null, quality: null, concerns: null, domain: null}
    },
    branch: $branch,
    baseSha: $sha,
    baseBranch: $basebranch,
    worktreePath: $wt,
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
        verify: (if $tier == "quick" then 2 elif $tier == "balanced" then 3 else 4 end)
      },
      global: (if $tier == "quick" then 10 elif $tier == "balanced" then 20 else 30 end),
      globalUsed: 0,
      perGateUsed: {},
      perPhaseUsed: {spec: 0, discuss: 0, plan: 0, execute: 0, verify: 0}
    },
    commands: {test: $test, lint: $lint, typecheck: $typecheck},
    stalenessHours: 48,
    warnings: [],
    bootstrapPendingDomains: []
  }')

bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" ".super-spec/features/${slug}" "$feature_json"
```

No initial commit is made here: `create-feature-worktree` already pointed `feat/{slug}` at a real commit (`base_sha`), and `feature.json` is gitignored runtime state (it lives in the worktree's working dir and is read back on resume, never committed -- consistent with the rest of super-spec). Phase artifacts under `docs/super-spec/features/{slug}/` are committed by each phase as it writes them (SPEC, PLAN, VERIFY).

Provenance fields:
- `artifacts.patternsSource` -- one of `"gsd-ingest"`, `"pattern-mapper"`, `"manual"`, or `null` until written. Set in PLAN Step 0.
- `artifacts.codebaseSource.{domain}` -- one of `"gsd-ingest"`, `"mapper"`, `"manual"`, or `null` until written. Set per-domain in Step 5.5.

Print cost estimate based on tier + expected scope:
```
Estimated cost: ~{N}k tokens (tier: {tier})
```

### Step 5.4 - Graphify bootstrap pre-flight (always; before the codebase-map skip)

Runs on EVERY cycle when `graphify` is installed. It must NOT be gated behind the Step 5.5 "all 5 docs exist" skip: the graph (`graphify-out/graph.json`) is independent of the super-spec codebase docs, so a repo that already has the 5 docs but no graph still needs one built. Idempotent, no LLM.

Decision tree:
- graphify not installed -> skip.
- `graphify-out/graph.json` exists -> do nothing.
- missing -> `graphify update .` (deterministic AST extraction, no API key).
- missing + GSD `.planning/codebase/` present -> build the graph, then supersede the GSD docs: fold their content into `docs/super-spec/codebase/` (gsd-ingest) and remove the raw GSD source (committed, recoverable).

```bash
if command -v graphify >/dev/null 2>&1; then
  if [[ -f graphify-out/graph.json ]]; then
    echo "graphify graph present (graphify-out/graph.json); skipping bootstrap"
  else
    echo "First graphify run: building code graph (no LLM)..."
    if graphify update .; then
      git add graphify-out/ 2>/dev/null || true
      git commit -m "chore: NO_JIRA bootstrap graphify code graph" >/dev/null 2>&1 || true
      # Supersede GSD codebase docs: preserve content into super-spec docs, then remove raw GSD.
      if [[ -d .planning/codebase ]]; then
        bash "${CLAUDE_SKILL_DIR}/../../lib/gsd-ingest.sh" codebase >/dev/null 2>&1 || true
        if ! git diff --quiet docs/super-spec/codebase/ 2>/dev/null; then
          git add docs/super-spec/codebase/
          git commit -m "docs: NO_JIRA ingest GSD codebase map before graphify supersession" >/dev/null 2>&1 || true
        fi
        git rm -r --quiet .planning/codebase 2>/dev/null || rm -rf .planning/codebase
        git add -A .planning 2>/dev/null || true
        git commit -m "chore: NO_JIRA remove GSD codebase docs superseded by graphify" >/dev/null 2>&1 || true
        echo "Superseded GSD codebase docs (.planning/codebase) and removed the raw GSD source"
      fi
    else
      echo "warn: 'graphify update .' failed; continuing without a graph" >&2
    fi
  fi
fi
```

### Step 5.5 - First-run codebase map (one-time per project)

Required super-spec docs: `docs/super-spec/codebase/{TECH,ARCH,QUALITY,CONCERNS,DOMAIN}.md`.

If all 5 already exist: skip this step. Incremental refresh runs at end of cycle automatically (in VERIFY).

Mapping (used by `lib/gsd-ingest.sh codebase`):

| GSD source files (`.planning/codebase/`) | Super-spec target (`docs/super-spec/codebase/`) |
|---|---|
| `STACK.md` + `INTEGRATIONS.md` | `TECH.md` |
| `ARCHITECTURE.md` + `STRUCTURE.md` | `ARCH.md` |
| `CONVENTIONS.md` + `TESTING.md` | `QUALITY.md` |
| `CONCERNS.md` | `CONCERNS.md` |
| (no GSD analog) | `DOMAIN.md` -- always mapped by `mapper-domain` |

Graphify (and GSD supersession when graphify is present) is handled in Step 5.4 above, which always runs. The remaining sub-steps below build any super-spec codebase docs that are still missing.

#### Step 5.5a - GSD ingestion (if applicable)

```bash
ingest_output="$(bash "${CLAUDE_SKILL_DIR}/../../lib/gsd-ingest.sh" codebase)"
echo "$ingest_output"
```

The script writes any `INGESTED <DOMAIN>` lines for domains it filled and `SKIPPED <DOMAIN> (no source)` for ones it couldn't. If `.planning/codebase/` doesn't exist it prints `NONE`.

Update `feature.artifacts.codebaseSource.{domain} = "gsd-ingest"` for each `INGESTED` line by calling `bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set ".super-spec/features/${slug}" .artifacts.codebaseSource.{domain} '"gsd-ingest"'` per domain.

`.super-spec/codebase/index.json` is **not** rebuilt here -- the next incremental refresh (end of VERIFY) populates it from the actual file scan. Leaving it absent at this point is correct; the incremental code paths handle the missing-file case.

If GSD ingest produced any new files, commit immediately so the repo state is clean before mapper agents touch it:

```bash
if ! git diff --quiet docs/super-spec/codebase/; then
  git add docs/super-spec/codebase/
  git commit -m "docs: NO_JIRA ingest GSD codebase map (domains: <csv>)"
fi
```

#### Step 5.5b - Map missing domains

```bash
missing=()
for d in TECH ARCH QUALITY CONCERNS DOMAIN; do
  [[ -f "docs/super-spec/codebase/${d}.md" ]] || missing+=("${d,,}")
done
```

If `missing` is non-empty:

- Print: `First super-spec run. Bootstrapping {N} codebase domain(s) in background: {csv}...`

- Model for mappers: `model_mapper = feature.models.mapper` (resolved once at Step 5; do not re-derive from model-matrix).

- **IMPORTANT:** background mappers are subagents and do NOT inherit the worktree cwd. Resolve the repo root once and pass ABSOLUTE paths in every Agent prompt:
  ```bash
  WT_ROOT="$(git rev-parse --show-toplevel)"
  ```

- Fire one background `Agent` call per missing domain (all in a single tool message so they run concurrently):

  ```
  Parallel (background):
    Agent({
      subagent_type: "super-spec:mapper-{domain-1}",
      model: model_mapper,
      run_in_background: true,
      description: "Bootstrap codebase map: {domain-1}",
      prompt: """
        You are bootstrapping the codebase map for this project.
        slug: {slug}
        Working directory (absolute): {WT_ROOT}
        Produce {WT_ROOT}/docs/super-spec/codebase/{DOMAIN-1}.md per your role definition (agents/mapper-{domain-1}.md).
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
feat_dir=".super-spec/features/${slug}"
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

For new features, `currentPhase` is initialized to `"spec"` (Step 5), so `Skill(super-spec:spec)` is invoked first. After spec completes, `currentPhase` advances to `"discuss"`, then `"plan"`, `"execute"`, `"verify"`, and finally `"completed"`.

Cycle's only responsibility here is to invoke the phase skill and react to its return:

1. **Invoke phase skill:**
   ```
   Skill(super-spec:{currentPhase})
   ```
   `{currentPhase}` is read from the in-memory `feature_json` loaded earlier (`feature_json.currentPhase`). The phase skill runs inside its own team, writes `currentTeamName` on entry, advances `currentPhase`, and clears `currentTeamName` on exit (all via `lib/feature-write.sh`).

2. **Re-load feature.json** after the skill returns (the skill may have advanced `currentPhase` and updated artifacts):
   ```bash
   feature_json=$(cat ".super-spec/features/${slug}/feature.json")
   next_phase=$(echo "$feature_json" | jq -r '.currentPhase')
   ```

3. **Route to next iteration:**
   - If `next_phase == "completed"`: jump to the "On completion" section below.
   - If `execStyle` is `auto` or `review-only`: continue the loop -- invoke `Skill(super-spec:{next_phase})`.
   - If `execStyle` is `step` or `interactive`: print phase summary and return to user. User re-invokes `Skill(super-spec:cycle)` to continue (resume detection in Step 1 picks up the in-progress state).

## Resume strategy + phase pause/escalation

Full algorithm and escalation handling (budget exhausted, NEEDS_CONTEXT, etc.) in **`skills/shared/cycle-resume-escalation.md`**. Step 1 carries the inline fast-path.

## On completion

Phase chain finishes when verify completes successfully. Before marking completed:

1. Call `TeamDelete({name: feature_json.currentTeamName})` (if `currentTeamName` is non-null) to tear down the final phase team.
2. Update `feature.json` via `lib/feature-write.sh`:
   ```bash
   completed_json="$(echo "$feature_json" | jq \
     '.currentPhase = "completed" | .currentTeamName = null | .currentTeammates = [] | .currentGate = {round: 0, phase: null} | .updatedAt = now | strftime("%Y-%m-%dT%H:%M:%SZ")')"
   bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" ".super-spec/features/${slug}" "$completed_json"
   ```

Then print final summary (PR URL, commits, time, cost).

**Note:** `TeamDelete` is called explicitly here at the orchestration layer. It is NOT implemented as a bash `trap` because `TeamDelete` is a harness MCP tool callable only from the lead's tool-using context, not from a shell signal handler. See the resume strategy orphan-detection path for killed-session cleanup.
