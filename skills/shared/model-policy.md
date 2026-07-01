# Model Policy

> Imported from design doc 2026-05-05.

## Allowed models

Model selection is fixed per role (no preset axis); the authoritative role -> model map is `skills/shared/model-matrix.md`. The two tiers below are the only models any role runs on.

| Tier | Model ID | Roles |
|------|----------|-------|
| Heavy | `claude-opus-4-8` | spec-writer, planner, advocate, challenger, spec-compliance-reviewer |
| Standard | `claude-sonnet-4-6` | implementer, code-reviewer, verifier, mapper-*, pattern-mapper (1M-ctx flag when available) |

`claude-haiku-4-5` is allowed by policy but no longer assigned to any role (the `fast` preset that used it was removed).

## Consuming-project compatibility

Some projects' `CLAUDE.md` hard-codes earlier model IDs (e.g., chrisbobrowitz/superpowers fork bans anything other than 4.6 / 4.5). Before adopting loop-spec, that policy section MUST be updated to allow `claude-opus-4-8`. The cycle skill's startup health-check will fail loud if the policy blocks dispatches.

## Health check (cycle startup)

The cycle skill probes the fixed model set at startup with a 1-token completion. Retries 3x with 2s backoff. Failure prints:

```
loop-spec health check FAILED
  Model: claude-opus-4-8
  Error: <error text>
  Suggested fix: update CLAUDE.md model policy to allow claude-opus-4-8
```

Then aborts. No silent fallback.

## 1M-context flag

Sonnet 4.6 supports 1M context with the `context-1m-2025-08-07` beta flag (or equivalent CC harness option). Cycle skill probes with a >200k-token noop input. On rejection: fall back to standard sonnet 4.6 (200k), record warning in `feature.json.warnings[]`. Phases continue.

## Dispatch rule

Phase skills MUST pass `model:` explicitly on every teammate spawn and every one-shot `Agent` dispatch, reading the resolved ID from `feature.models.<role>`. Never rely on the agent frontmatter default. See `skills/shared/model-matrix.md` "Dispatch rule" for the canonical `TeamCreate` shape and the Step 5.5b background-mapper exception.
