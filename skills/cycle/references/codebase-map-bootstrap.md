# Cycle Step 5.5 -- First-run codebase map (reference)

Extracted verbatim from `skills/cycle/SKILL.md`; the SKILL stub points here. Apply as written.

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
  All Agent calls in ONE message (parallel; the harness runs subagents in the background):
    Agent({
      subagent_type: "loop-spec:mapper-{domain-1}",
      model: model_mapper,
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

- **Single-repo mode** fire one `Agent` call per missing domain:

  ```
  All Agent calls in ONE message (parallel; the harness runs subagents in the background):
    Agent({
      subagent_type: "loop-spec:mapper-{domain-1}",
      model: model_mapper,
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
