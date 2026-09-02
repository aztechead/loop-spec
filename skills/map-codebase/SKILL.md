---
name: map-codebase
description: Use when the user says "map the codebase", "refresh the code map", or a cycle needs docs/loop-spec/codebase/. Incremental by default; --full or --domain to override. Do not use this in place of reading the files a change touches, and do not use it to implement a feature.
argument-hint: "[--full] [--domain tech,arch,...]"
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet
---

# map-codebase

Standalone skill that builds or refreshes `docs/loop-spec/codebase/*.md`. Also auto-invoked by `loop-spec:verify` after its gates, before ITERATE and DELIVER.

> **Team-mode adaptation (Step 3–5):** read `.loop-spec/runtime.json.teamsMode`.
> - `none` → no team: run each mapper as a one-shot `Agent` call (`skills/shared/dispatch.md`); skip the `TeamCreate`/`TeamDelete` steps and collect each mapper's returned report directly.
> - `implicit` (CC >= 2.1.178) → `TeamCreate`/`TeamDelete` were removed and throw. Skip the `TeamCreate` in Step 3 and the `TeamDelete` in Step 5. Probe `lib/implicit-team-model.sh spawn-kind --teams-mode implicit --selector <feature.models.mapper>` per domain. `named`: `Agent({name: "mapper-{domain}-1", description, subagent_type, prompt})` with no `model` key; mapper-to-mapper and `DOMAIN_DONE` messaging via `SendMessage` is unchanged. `oneshot`: nameless Agent with the alias so routing binds. Per `skills/shared/dispatch.md`.
> - `explicit` → the `TeamCreate`/`TeamDelete` steps below run as written.
>
> Every one-shot mapper fallback obeys `skills/shared/dispatch.md`.
> Dispatch at most `LOOP_SPEC_MAX_PARALLEL_SUBAGENTS` mappers per wave when set.
> Every mapper whose report this step still needs: issue the call, then stop.
> Never AskUserQuestion as a wait (`skills/shared/dispatch.md`).

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

Mapper agents inherit the session model (see `skills/shared/model-matrix.md`); there is no preset input.

## Procedure

### Step 0 - Decide whether a map refresh is needed

In single-repository incremental mode, this deterministic decision is mandatory:

```bash
refresh_decision="$(bash "${CLAUDE_SKILL_DIR}/../../lib/map-refresh.sh" decide \
  "$repo_root" "$since_sha" --mode "$mode")"
if [[ "$(jq -r '.refresh' <<<"$refresh_decision")" != "true" ]]; then
  echo "map-codebase: skip ($(jq -r '.reason' <<<"$refresh_decision")); existing complete map remains authoritative."
  return
fi
stale_domains="$(jq -c '.domains' <<<"$refresh_decision")"
```

`map-refresh.sh` returns `refresh: false` only when all five map artifacts plus the
index are complete and the feature diff has no map-relevant source changes. Feature
state, telemetry, and previous map output are ignored; an unknown
source path, a missing/corrupt map, an unreadable base, `--full`, or `--domain` fails
closed to a refresh. In workspace mode, retain the existing per-repository stale-domain
calculation until the shared workspace index has the same deterministic helper; never
borrow a single-repo no-op verdict for a workspace.

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

Resolve `mapper_model`: when invoked inside a cycle (feature.json present) use
`feature.models.mapper`; standalone, use `inherit`. Start every Claude mapper
object without `model`, adding it only when `mapper_model` is an Agent alias.
Omit it for `inherit`. Under OpenCode, omit the per-call model and use the
generated agent's native inheritance.

**Dispatch telemetry (`skills/shared/dispatch.md`):** when invoked inside a cycle (feature dir exists), emit one `dispatch` event per mapper launched — `bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" dispatch --phase "map-codebase" --data '{"role":"mapper","model":"<mapper_model>","rung":"<team|subagent|workflow>"}' || true`. Standalone invocations (no feature dir) skip this.

```
TeamCreate({
  name: "loop-spec-map-codebase-{project_id}",
  teammates: [
    { name: "mapper-tech-1",      subagent_type: "loop-spec:mapper-tech" },
    { name: "mapper-arch-1",      subagent_type: "loop-spec:mapper-arch" },
    { name: "mapper-quality-1",   subagent_type: "loop-spec:mapper-quality" },
    { name: "mapper-concerns-1",  subagent_type: "loop-spec:mapper-concerns" },
    { name: "mapper-domain-1",    subagent_type: "loop-spec:mapper-domain" }
  ]
})
```

Only include teammates whose domain is in `stale_domains`.

All five domains are derived by reading the tree — `tech` and `arch` included. They were covered by an external code graph until 2.35.0; `agents/mapper-tech.md` and `agents/mapper-arch.md` now derive them like every other domain. Mappers fan out, cite `file:line`, and a claim nobody can point at does not get written.

Send each spawned mapper its work prompt via `SendMessage`:

```
SendMessage({
  to: "mapper-{domain}-1",
  message: """
    mode: {full | incremental}
    since_sha: {since_sha if incremental}
    target_path: docs/loop-spec/codebase/{DOMAIN}.md
    teammates: [mapper-tech-1, mapper-arch-1, mapper-quality-1, mapper-concerns-1, mapper-domain-1]

    Run your mapping. You may SendMessage any other mapper by name to share intermediate
    findings (e.g. module boundaries, tech-stack observations) that would improve their
    output. When your domain doc is complete, send:
      SendMessage({ to: "lead", message: "DOMAIN_DONE: {domain} files: [<list of inspected file paths>]" })
  """
})
```

Lead does not interject while mappers are running. Mappers communicate directly with each other as needed.

### Step 4 - Collect domain reports and build index.json

Stop. The harness resumes this turn as each spawned mapper sends `DOMAIN_DONE: {domain} files: [...]` to `lead`. Never AskUserQuestion as a wait.

For each report received, extract the list of inspected files and update the file-to-domain mapping:

```
for file in mapper.inspected_files:
  index.files[file].add(domain)
```

Also update `index.json` field `last_refreshed_at.{domain}` to the current ISO-8601 timestamp.

Atomic write to `.loop-spec/codebase/index.json`.

Then prune the index — a deleted file must stop voting on which domains are stale, and
pruning is a script, never an instruction someone remembers:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/map-index-prune.sh"
```

### Step 4.5 - Mark trust on every refreshed domain

Every document this refresh wrote is machine-inferred prose until a human says otherwise.
Stamp each refreshed domain unconditionally:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/map-trust.sh" mark "docs/loop-spec/codebase/{DOMAIN}.md" generated
```

This also VOIDS any prior `verified` ratification on that document — the human confirmed
the old prose, not the new (`lib/map-trust.sh` drops `verified_at`/`verified_by` on a
`generated` mark).

**Promotion is an operator action.** When a human has walked a domain document and
confirmed its claims, they (or an interactive session acting on their explicit
confirmation) promote it:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/map-trust.sh" mark "docs/loop-spec/codebase/{DOMAIN}.md" verified --by "{user}"
```

NEVER run the promotion in autonomous mode or on your own judgment — a model promoting
its own map to `verified` is a model grading its own gate. In interactive standalone
runs you may OFFER the promotion for a domain the user has just reviewed; the user's
explicit yes is the trigger, and their name goes in `--by`.

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

### Step 6.5 - Audit the map that was just written

A regenerated map is not automatically a true one. Measure it:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/map-audit.sh" audit || true
```

Five facts, none of them judgments: total size against the ceiling
(`LOOP_SPEC_MAP_MAX_LINES`, default 1000 lines), cited paths that no longer exist in the
tree, `index.json` entries whose file is gone, per-domain age plus any document that
declares itself stale while the index records it as fresh, and the trust split — how much
of the map a human has actually ratified, and any `verified` document that changed after
its ratification.

Report every finding in Step 7 and act on what this refresh owns:

- `stale-claim` in a domain you just refreshed is a defect in the refresh — fix the claim
  or cut it before committing.
- `orphan-index-entry` means a deleted file still maps to a domain and still votes on
  staleness. Re-run `lib/map-index-prune.sh` (Step 4) — an orphan surviving it means the
  entry's path exists but is untracked-weird; investigate rather than hand-edit.
- `over-budget` means the map must shrink, never that the ceiling should rise. The whole
  point of a budget is that it is not negotiated by the thing being measured. Step 6.6
  names the cuts.
- `trust-disagreement` means the prose and the machine state disagree about freshness.
  Believe the prose and re-derive that domain.
- `trust-expired` means a `verified` document changed after its ratification. Re-mark it
  `generated` (Step 4.5 does this for domains this refresh wrote) — the promise must be
  re-earned, never re-dated.

Findings outside this refresh's scope are reported, not silently carried: append them to
`.loop-spec/BACKLOG.md`. This never blocks the commit — an audit that could refuse to
record a refreshed map would leave the map staler than the one it rejected.

### Step 6.6 - Fresh-eyes pruning pass (only when over budget)

Runs iff Step 6.5 reported `finding=over-budget` — the budget probe says the map must
shrink; this pass names what. Dispatch ONE context-free reviewer (never a mapper that
wrote a domain this refresh) carrying `${CLAUDE_SKILL_DIR}/../../skills/shared/review-prompts/prose-pruning.md`
verbatim, plus the domain documents under `docs/loop-spec/codebase/` and nothing else —
no mapper reports, no refresh conversation.
Dispatch the reviewer, then stop: never AskUserQuestion as a wait (`skills/shared/dispatch.md`).

The reviewer lists `cut:`/`merge:`/`shrink:` proposals; the lead applies the ones it
accepts, re-runs `lib/map-audit.sh budget`, and commits the shrunken map (a follow-up
commit — never amend). Proposals declined and the reason go to `.loop-spec/BACKLOG.md`.
Carve-outs in the prompt are hard: trust frontmatter and STALE banners are never cuts.

### Step 7 - Report

Print:
- Domains refreshed: list
- Files inspected: count
- New domains added (if any new files)
- Audit findings from Step 6.5: count by kind, or "clean"

## Standalone CLI

```
Skill(loop-spec:map-codebase)              # incremental
Skill(loop-spec:map-codebase) args: --full # all domains
Skill(loop-spec:map-codebase) args: --domain tech,arch
```

Mappers inherit the session model unless the operator configured a route (see `skills/shared/model-matrix.md`).

## Quarterly forced full re-map

`index.json` records `last_refreshed_at` per domain. Skill warns if any domain unrefreshed in 90+ days; suggests `--full`.
