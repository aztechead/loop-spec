# PLAN Step 0 -- PATTERNS.md cache check and GSD ingestion (reference)

Extracted verbatim from `skills/plan/SKILL.md`; the SKILL stub points here. Apply as written.

### Step 0 - PATTERNS.md cache check and GSD ingestion

Before spawning the team, check in order:

**0-pre - Join the DISCUSS prefetch (if in flight):**

DISCUSS Step 1.75 may have fired a background pattern-mapper. It has had the whole
critique gate to run, so this is usually already on disk. Check once — do not sleep.
A `sleep` loop freezes the session between DISCUSS and PLAN
(`skills/shared/harness-call-contracts.md`).

```bash
# Check once. Never sleep to join a background Agent.
if [[ -f "docs/loop-spec/features/${slug}/PATTERNS.md" ]]; then
  echo present
else
  echo missing
fi
```

Whatever the outcome, resolve the marker via `lib/feature-write.sh`: file present → `artifacts.patternsPrefetch = "landed"` (0a below takes the cached path); still missing → `artifacts.patternsPrefetch = "timeout"` and continue to 0a/0b as if no prefetch happened (the planner produces PATTERNS.md itself; the prefetch prompt's existence guard keeps a late mapper from clobbering the planner's version). Never AskUserQuestion as a wait.

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

Then proceed to Step 1 (TeamCreate). Planner will detect PATTERNS.md exists and skip its Step 0 production. This applies on any resume or re-trigger where PATTERNS.md was already produced.

**0b - GSD ingestion (if no cached file):**

```bash
target="docs/loop-spec/features/${slug}/PATTERNS.md"
result="$(bash "${CLAUDE_SKILL_DIR}/../../lib/gsd-ingest.sh" patterns "$slug" "$target")"
echo "$result"
```

The script prints `INGESTED <source-path>` on success or `NONE` if no GSD PATTERNS.md matched the slug.

If `INGESTED`: update `feature.json` via `lib/feature-write.sh` (same nested-`set`
call shape as 0a, with `artifacts.patternsSource = "gsd-ingest"`).

Then proceed to Step 1 (TeamCreate). Planner will detect PATTERNS.md exists and skip its Step 0 production.

If `NONE`: continue to Step 1.
