# PLAN Step 0 -- PATTERNS.md cache, ingest, and mapper (reference)

Extracted from `skills/plan/SKILL.md`; the SKILL stub points here. Apply as written.
Never `sleep` to join a background Agent. Never AskUserQuestion as a wait.

Contents: 0-pre prefetch join · 0a cache · 0b GSD ingest · 0c one-shot mapper.

### Step 0 - PATTERNS.md cache check, GSD ingestion, and mapper dispatch

Before spawning the team, check in order:

**0-pre - Join the DISCUSS prefetch (if in flight):**

DISCUSS Step 1.75 may have fired a background pattern-mapper. If
`feature.json.artifacts.patternsPrefetch == "in-flight"`, check once whether
`docs/loop-spec/features/${slug}/PATTERNS.md` exists. Never `sleep`.

Whatever the outcome, resolve the marker via `lib/feature-write.sh`: file present →
`artifacts.patternsPrefetch = "landed"` (0a below takes the cached path); still
missing → `artifacts.patternsPrefetch = "timeout"` and continue to 0a/0b/0c as if
no prefetch happened (the one-shot mapper in 0c produces PATTERNS.md; the prefetch
prompt's existence guard keeps a late mapper from clobbering a landed file).

**0a - Existing PATTERNS.md (any source):**

```bash
patterns_target="docs/loop-spec/features/${slug}/PATTERNS.md"
if [[ -f "$patterns_target" ]]; then
  echo "CACHED"
fi
```

If the file exists: update `feature.json` via `lib/feature-write.sh` (nested `set`
takes the dot path directly — value must be JSON-quoted; never raw jq; see
`skills/shared/feature-state-schema.md` "Writing rules"):

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" artifacts.patterns '"docs/loop-spec/features/'"${slug}"'/PATTERNS.md"'
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" artifacts.patternsSource '"pattern-mapper"'
```

Then proceed to Step 1 (TeamCreate). Planner will detect PATTERNS.md exists and skip
production. This applies on any resume or re-trigger where PATTERNS.md was already
produced.

**0b - GSD ingestion (if no cached file):**

```bash
target="docs/loop-spec/features/${slug}/PATTERNS.md"
result="$(bash "${CLAUDE_SKILL_DIR}/../../lib/gsd-ingest.sh" patterns "$slug" "$target")"
echo "$result"
```

The script prints `INGESTED <source-path>` on success or `NONE` if no GSD PATTERNS.md matched the slug.

If `INGESTED`: update `feature.json` via `lib/feature-write.sh` (same nested-`set`
call shape as 0a, with `artifacts.patternsSource = "gsd-ingest"`).

Then proceed to Step 1 (TeamCreate). Planner will detect PATTERNS.md exists and skip
production.

If `NONE`: continue to 0c.

**0c - One-shot pattern-mapper (if still missing):**

Do not pay the opus planner to mine analogs. Dispatch ONE `loop-spec:pattern-mapper`
Agent, then stop. The harness resumes this turn. Never AskUserQuestion as a wait
(`skills/shared/harness-call-contracts.md`).

Build the call without a `model` key. If `feature.models.patternMapper` is one of
the four Agent aliases, add that key with the alias; when it is `inherit`, leave
the key absent. Resolve `WT_ROOT="$(git rev-parse --show-toplevel)"` and pass
absolute paths (background/one-shot subagents do not inherit the worktree cwd):

```
Agent({
  subagent_type: "loop-spec:pattern-mapper",
  description: "Produce PATTERNS.md: {slug}",
  prompt: """
    slug: {slug}
    spec_path: {WT_ROOT}/docs/loop-spec/features/{slug}/SPEC.md
    codebase_mapping_paths: {WT_ROOT}/docs/loop-spec/codebase/*.md

    Produce {WT_ROOT}/docs/loop-spec/features/{slug}/PATTERNS.md per your role
    definition (agents/pattern-mapper.md). Use absolute paths throughout. Do NOT commit.

    Existence guard: if PATTERNS.md already exists at the moment you are about to
    write, STOP without writing — a prefetch produced it first and its version wins.

    When done, reply: "DONE: patterns"
  """
})
```

On resume: if the file exists, run the 0a bookkeeping and proceed to Step 1. If it
is still missing, proceed to Step 1 anyway — the planner brief's FIRST clause is
the last-resort fallback. Emit a `dispatch` event for the mapper launch
(`skills/shared/dispatch-events.md`).
