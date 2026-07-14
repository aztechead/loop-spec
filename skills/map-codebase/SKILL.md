---
name: map-codebase
description: Map codebase across 5 domains (tech/arch/quality/concerns/domain). Incremental by default; --full or --domain to override.
argument-hint: "[--full] [--domain tech,arch,...]"
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet
---

# map-codebase

Standalone skill that builds or refreshes `docs/loop-spec/codebase/*.md`. Also auto-invoked by `loop-spec:verify` after its gates, before ITERATE and DELIVER.

> **Team-mode adaptation (Step 3–5):** read `.loop-spec/runtime.json.teamsMode`.
> - `none` → no team: run each mapper as a one-shot `Agent` call (`skills/shared/no-teams-fallback.md`); skip the `TeamCreate`/`TeamDelete` steps and collect each mapper's returned report directly.
> - `implicit` (CC >= 2.1.178) → `TeamCreate`/`TeamDelete` were removed and throw. Skip the `TeamCreate` in Step 3 and the `TeamDelete` in Step 5; spawn each mapper with `Agent({name: "mapper-{domain}-1", description, subagent_type, model, prompt})`, folding its `SendMessage` work prompt into the spawn. Mapper-to-mapper and `DOMAIN_DONE` messaging via `SendMessage` is unchanged. Per `skills/shared/implicit-team-mode.md`.
> - `explicit` → the `TeamCreate`/`TeamDelete` steps below run as written.

## Modes

- **incremental** (default): only re-map domains whose tracked files changed since last refresh
- **full**: re-map all 5 domains regardless

## Inputs

When auto-invoked from verify:
- `mode: "incremental"`
- `since_sha: feature.baseSha`

When standalone (`Skill(loop-spec:map-codebase)`):
- Optional args: `--full` (forces full mode), `--domain tech,arch` (filter to subset)
- `since_sha`: derived from latest "refresh codebase mapping" commit, or HEAD~1 if none

Mapper model is fixed at the `sonnet` alias (see `skills/shared/model-matrix.md`); there is no preset input.

## Procedure

### Step 0 - Graphify pre-flight (required)

graphify is a hard requirement. Refresh (or first-build) the code graph deterministically via the preflight lib — `graphify <dir>` builds, `graphify <dir> --update` re-extracts only changed files; both run on AST and need no LLM/API key. Do NOT use the `--update --wiki` slash-skill form here (it requires an LLM key and errors out in CLI context).

```bash
if ! bash "${CLAUDE_SKILL_DIR}/../../lib/graphify-preflight.sh" check; then
  # Prints install instructions (uv tool install graphifyy). Hard requirement.
  exit 1
fi
bash "${CLAUDE_SKILL_DIR}/../../lib/graphify-preflight.sh" build . \
  || echo "warn: graphify build failed (set LOOP_SPEC_REQUIRE_GRAPHIFY=0 to bypass)" >&2
```

### Step 1 - Determine stale domains

If `mode == "full"` or `--domain` specified: stale_domains = explicit list (or all 5)

Else (incremental):
```bash
changedFiles=$(git diff {since_sha} HEAD --name-only)
# Read .loop-spec/codebase/index.json
# index.json structure: {"file_path": ["domain1", "domain2", ...], ...}
stale_domains=$(jq -r --argjson files "$(echo "$changedFiles" | jq -R . | jq -s .)" \
  '[.[$files[]] // [] | .[]] | unique' .loop-spec/codebase/index.json 2>/dev/null || echo '["arch"]')

# Always include "arch" if any new files added (changedFiles contains paths not in index)
```

If `stale_domains` empty: print "No stale domains, nothing to refresh." Exit.

### Step 2 - Dispatch (workflow path or fallback)

Read `.loop-spec/runtime.json`. If `workflowsAvailable=true` AND
`stale_domains` has 2+ entries, prefer the workflow path:

```text
Workflow({
  scriptPath: "${CLAUDE_SKILL_DIR}/../../lib/workflows/map-codebase.js",
  args: {
    staleDomains: stale_domains,
    sinceSha: since_sha,
  }
})
```

Result shape: `{domains: [{name, mdPath, coverage, weakSpots}]}`.
Skill consumes `domains[].mdPath` as the canonical refresh outputs and writes
no additional artifacts (workflow agents wrote the files).

If `workflowsAvailable=false` OR `stale_domains` has 1 entry (no fan-out gain),
fall through to the existing TeamCreate path below.

(Existing TeamCreate Step 2 content follows verbatim, unchanged.)

### Step 3 - Create map-codebase team and spawn mapper teammates

Derive `project_id` in a workspace-aware way -- never call bare `git rev-parse --show-toplevel` without first confirming the cwd is a git repo:

```bash
ws_json="$(bash "${CLAUDE_SKILL_DIR}/../../lib/workspace.sh" detect 2>/dev/null || true)"
ws_mode="$(echo "$ws_json" | jq -r '.mode // "single"')"
ws_root="$(echo "$ws_json" | jq -r '.root // ""')"
project_id="$(basename "$ws_root")"
```

In both single and workspace modes `project_id` is the basename of the detected root (the repo toplevel in single mode, the workspace parent directory in workspace mode). This avoids running `git rev-parse --show-toplevel` at a non-repo workspace root.

**Workspace mode note:** in workspace mode the repo list is available from `ws_json`. Pass each repo's absolute path and name to mappers so they can cover each repo with per-repo sections. The commit step in Step 6 is gated on the root being a git repo (see Step 6 below).

Resolve `mapper_model`: when invoked inside a cycle (feature.json present) use `feature.models.mapper`; standalone, use `sonnet` (the fixed mapper alias per `skills/shared/model-matrix.md`). Pass it explicitly on every mapper spawn so they never inherit the orchestrator's session model.

**Dispatch telemetry (`skills/shared/dispatch-events.md`):** when invoked inside a cycle (feature dir exists), emit one `dispatch` event per mapper launched — `bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" dispatch --phase "map-codebase" --data '{"role":"mapper","model":"<mapper_model>","rung":"<team|subagent|workflow>"}' || true`. Standalone invocations (no feature dir) skip this.

```
TeamCreate({
  name: "loop-spec-map-codebase-{project_id}",
  teammates: [
    { name: "mapper-quality-1",   subagent_type: "loop-spec:mapper-quality",  model: mapper_model },
    { name: "mapper-concerns-1",  subagent_type: "loop-spec:mapper-concerns", model: mapper_model },
    { name: "mapper-domain-1",    subagent_type: "loop-spec:mapper-domain",   model: mapper_model }
  ]
})
```

Only include teammates whose domain is in `stale_domains`.

graphify is a hard requirement, so ARCH and TECH domains are graph-backed by default. In the `LOOP_SPEC_REQUIRE_GRAPHIFY=0` degraded mode only, ARCH and TECH are not refreshed by this skill invocation (quality, concerns, and domain mapping continue normally); install graphify to restore full coverage.

Send each spawned mapper its work prompt via `SendMessage`:

```
SendMessage({
  to: "mapper-{domain}-1",
  message: """
    mode: {full | incremental}
    since_sha: {since_sha if incremental}
    target_path: docs/loop-spec/codebase/{DOMAIN}.md
    teammates: [mapper-quality-1, mapper-concerns-1, mapper-domain-1]

    Run your mapping. You may SendMessage any other mapper by name to share intermediate
    findings (e.g. module boundaries, tech-stack observations) that would improve their
    output. When your domain doc is complete, send:
      SendMessage({ to: "lead", message: "DOMAIN_DONE: {domain} files: [<list of inspected file paths>]" })
  """
})
```

Lead does not interject while mappers are running. Mappers communicate directly with each other as needed.

### Step 4 - Collect domain reports and build index.json

Wait for each spawned mapper to send `DOMAIN_DONE: {domain} files: [...]` to `lead`.

For each report received, extract the list of inspected files and update the file-to-domain mapping:

```
for file in mapper.inspected_files:
  index[file].add(domain)
```

Also update `index.json` field `last_refreshed_at.{domain}` to the current ISO-8601 timestamp.

Atomic write to `.loop-spec/codebase/index.json`.

### Step 5 - Delete map-codebase team

```
TeamDelete({ name: "loop-spec-map-codebase-{project_id}" })
```

Clear `currentTeamName` and `currentTeammates` in `feature.json` (if invoked from within a cycle).

### Step 6 - Commit

In single mode, commit unconditionally:

```bash
git add docs/loop-spec/codebase/ .loop-spec/codebase/index.json
git commit -m "docs: NO_JIRA refresh codebase mapping (feature: {slug if available, else 'standalone'})"
```

In workspace mode, gate the commit on the workspace root being a git repo:

```bash
if git -C "$ws_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$ws_root" add docs/loop-spec/codebase/ .loop-spec/codebase/index.json
  git -C "$ws_root" commit -m "docs: NO_JIRA refresh codebase mapping (feature: {slug if available, else 'standalone'})"
else
  echo "workspace root not a git repo; leaving codebase docs uncommitted"
fi
```

Note: `.loop-spec/codebase/index.json` is NOT gitignored (it's a tracking file the mapping needs across machines). Only `.loop-spec/features/` and `.loop-spec/worktrees/` are gitignored. Update `.gitignore` accordingly if needed (this should already be correct from Task 0).

### Step 7 - Report

Print:
- Domains refreshed: list
- Files inspected: count
- New domains added (if any new files)

## Standalone CLI

```
Skill(loop-spec:map-codebase)              # incremental
Skill(loop-spec:map-codebase) args: --full # all domains
Skill(loop-spec:map-codebase) args: --domain tech,arch
```

Mappers always run on the `sonnet` alias (fixed; see `skills/shared/model-matrix.md`).

## Quarterly forced full re-map

`index.json` records `last_refreshed_at` per domain. Skill warns if any domain unrefreshed in 90+ days; suggests `--full`.
