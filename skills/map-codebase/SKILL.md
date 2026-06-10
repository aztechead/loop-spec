---
name: map-codebase
description: Map codebase across 5 domains (tech/arch/quality/concerns/domain). Incremental by default; --full or --domain to override.
argument-hint: "[--full] [--domain tech,arch,...]"
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet
---

# map-codebase

Standalone skill that builds or refreshes `docs/super-spec/codebase/*.md`. Also auto-invoked by `super-spec:verify` at end of feature cycle.

## Modes

- **incremental** (default): only re-map domains whose tracked files changed since last refresh
- **full**: re-map all 5 domains regardless

## Inputs

When auto-invoked from verify:
- `mode: "incremental"`
- `since_sha: feature.baseSha`
- `tier: feature.tier`

When standalone (`Skill(super-spec:map-codebase)`):
- Optional args: `--full` (forces full mode), `--domain tech,arch` (filter to subset)
- `since_sha`: derived from latest "refresh codebase mapping" commit, or HEAD~1 if none

Mapper model is fixed at `claude-sonnet-4-6` (see `skills/shared/model-matrix.md`); there is no preset input.

## Procedure

### Step 0 - Graphify pre-flight detection

Refresh (or first-build) the code graph deterministically. `graphify update .` re-extracts via AST and needs no LLM/API key; do NOT use the `--update --wiki` slash-skill form here (it requires an LLM key and errors out in CLI context).

```bash
if command -v graphify > /dev/null 2>&1; then
  graphify update . || echo "warn: 'graphify update .' failed; continuing without graph refresh" >&2
else
  echo "graphify not found. Install with: pip install graphifyy  (or: uv tool install graphifyy)" >&2
fi
```

### Step 1 - Determine stale domains

If `mode == "full"` or `--domain` specified: stale_domains = explicit list (or all 5)

Else (incremental):
```bash
changedFiles=$(git diff {since_sha} HEAD --name-only)
# Read .super-spec/codebase/index.json
# index.json structure: {"file_path": ["domain1", "domain2", ...], ...}
stale_domains=$(jq -r --argjson files "$(echo "$changedFiles" | jq -R . | jq -s .)" \
  '[.[$files[]] // [] | .[]] | unique' .super-spec/codebase/index.json 2>/dev/null || echo '["arch"]')

# Always include "arch" if any new files added (changedFiles contains paths not in index)
```

If `stale_domains` empty: print "No stale domains, nothing to refresh." Exit.

### Step 2 - Dispatch (workflow path or fallback)

Read `.super-spec/runtime.json`. If `workflowsAvailable=true` AND
`stale_domains` has 2+ entries, prefer the workflow path:

```text
Workflow({
  scriptPath: "${CLAUDE_SKILL_DIR}/../../lib/workflows/map-codebase.js",
  args: {
    tier: feature.tier,
    staleDomains: stale_domains,
    sinceSha: since_sha,
  }
})
```

Result shape: `{domains: [{name, mdPath, coverage, weakSpots}], tier}`.
Skill consumes `domains[].mdPath` as the canonical refresh outputs and writes
no additional artifacts (workflow agents wrote the files).

If `workflowsAvailable=false` OR `stale_domains` has 1 entry (no fan-out gain),
fall through to the existing TeamCreate path below.

(Existing TeamCreate Step 2 content follows verbatim, unchanged.)

### Step 3 - Create map-codebase team and spawn mapper teammates

Derive `project_id` from the repo root path hash (e.g. `$(basename $(git rev-parse --show-toplevel))`).

Resolve `mapper_model`: when invoked inside a cycle (feature.json present) use `feature.models.mapper`; standalone, use `claude-sonnet-4-6` (the fixed mapper model per `skills/shared/model-matrix.md`). Pass it explicitly on every mapper spawn so they never inherit the orchestrator's session model.

```
TeamCreate({
  name: "super-spec-map-codebase-{project_id}",
  teammates: [
    { name: "mapper-quality-1",   subagent_type: "super-spec:mapper-quality",  model: mapper_model },
    { name: "mapper-concerns-1",  subagent_type: "super-spec:mapper-concerns", model: mapper_model },
    { name: "mapper-domain-1",    subagent_type: "super-spec:mapper-domain",   model: mapper_model }
  ]
})
```

Only include teammates whose domain is in `stale_domains`.

When graphify is not installed, ARCH and TECH domains are not refreshed by this skill invocation. Install graphify to restore full coverage. This is the fallback mode: quality, concerns, and domain mapping continue normally, but ARCH and TECH analysis depends on graphify being present.

Send each spawned mapper its work prompt via `SendMessage`:

```
SendMessage({
  to: "mapper-{domain}-1",
  body: """
    mode: {full | incremental}
    since_sha: {since_sha if incremental}
    target_path: docs/super-spec/codebase/{DOMAIN}.md
    teammates: [mapper-quality-1, mapper-concerns-1, mapper-domain-1]

    Run your mapping. You may SendMessage any other mapper by name to share intermediate
    findings (e.g. module boundaries, tech-stack observations) that would improve their
    output. When your domain doc is complete, send:
      SendMessage({ to: "lead", body: "DOMAIN_DONE: {domain} files: [<list of inspected file paths>]" })
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

Atomic write to `.super-spec/codebase/index.json`.

### Step 5 - Delete map-codebase team

```
TeamDelete({ name: "super-spec-map-codebase-{project_id}" })
```

Clear `currentTeamName` and `currentTeammates` in `feature.json` (if invoked from within a cycle).

### Step 6 - Commit

```bash
git add docs/super-spec/codebase/ .super-spec/codebase/index.json
git commit -m "docs: NO_JIRA refresh codebase mapping (feature: {slug if available, else 'standalone'})"
```

Note: `.super-spec/codebase/index.json` is NOT gitignored (it's a tracking file the mapping needs across machines). Only `.super-spec/features/` and `.super-spec/worktrees/` are gitignored. Update `.gitignore` accordingly if needed (this should already be correct from Task 0).

### Step 7 - Report

Print:
- Domains refreshed: list
- Files inspected: count
- New domains added (if any new files)

## Standalone CLI

```
Skill(super-spec:map-codebase)              # incremental
Skill(super-spec:map-codebase) args: --full # all domains
Skill(super-spec:map-codebase) args: --domain tech,arch
```

Mappers always run on `claude-sonnet-4-6` (fixed; see `skills/shared/model-matrix.md`).

## Quarterly forced full re-map

`index.json` records `last_refreshed_at` per domain. Skill warns if any domain unrefreshed in 90+ days; suggests `--full`.
