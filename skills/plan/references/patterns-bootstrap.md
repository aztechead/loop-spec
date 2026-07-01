# PLAN Step 0 -- PATTERNS.md cache check and GSD ingestion (reference)

Extracted verbatim from `skills/plan/SKILL.md`; the SKILL stub points here. Apply as written.

### Step 0 - PATTERNS.md cache check and GSD ingestion

Before spawning the team, check in order:

**0a - Existing PATTERNS.md (any source):**

```bash
patterns_target="docs/loop-spec/features/${slug}/PATTERNS.md"
if [[ -f "$patterns_target" ]]; then
  echo "CACHED"
fi
```

If the file exists: update `feature.json` via `lib/feature-write.sh`:
- `artifacts.patterns = "docs/loop-spec/features/${slug}/PATTERNS.md"`
- `artifacts.patternsSource = "pattern-mapper"`

Then proceed to Step 1 (TeamCreate). Planner will detect PATTERNS.md exists and skip its Step 0 production. This applies on any resume or re-trigger where PATTERNS.md was already produced.

**0b - GSD ingestion (if no cached file):**

```bash
target="docs/loop-spec/features/${slug}/PATTERNS.md"
result="$(bash "${CLAUDE_SKILL_DIR}/../../lib/gsd-ingest.sh" patterns "$slug" "$target")"
echo "$result"
```

The script prints `INGESTED <source-path>` on success or `NONE` if no GSD PATTERNS.md matched the slug.

If `INGESTED`: update `feature.json` via `lib/feature-write.sh`:
- `artifacts.patterns = "docs/loop-spec/features/${slug}/PATTERNS.md"`
- `artifacts.patternsSource = "gsd-ingest"`

Then proceed to Step 1 (TeamCreate). Planner will detect PATTERNS.md exists and skip its Step 0 production.

If `NONE`: continue to Step 1.
