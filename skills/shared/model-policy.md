# Model Policy

> Imported from design doc 2026-05-05.

## Allowed models

Model selection is fixed per role (no preset axis); the authoritative role -> model map is `skills/shared/model-matrix.md`. The two tiers below are the only models any role runs on.

| Family | Alias | Roles |
|--------|-------|-------|
| Heavy | `opus` | spec-writer, planner, challenger, iterate-judge, code-reviewer |
| Standard | `sonnet` | advocate, spec-compliance-reviewer, implementer, verifier, mapper-*, pattern-mapper (1M-ctx flag when available) |

Dispatch uses harness ALIASES, not pinned IDs: the modern Agent tool's `model` parameter is an alias enum and rejects literal IDs. `haiku` is allowed by policy but no longer assigned to any role.

Per-role canonical defaults can be overridden at deployment time via `LOOP_SPEC_MODEL_<ROLE>` env vars (SCREAMING_SNAKE of the JSON key); see `skills/shared/model-matrix.md` "Per-role override" for the full contract. Overrides must be harness aliases; literal model IDs are rejected at startup.

## Consuming-project compatibility

Some projects' `CLAUDE.md` hard-codes earlier model IDs (e.g., chrisbobrowitz/superpowers fork bans anything other than 4.6 / 4.5). Before adopting loop-spec, that policy section MUST allow whatever the harness's `opus` and `sonnet` aliases currently resolve to. The cycle skill's startup health-check will fail loud if the policy blocks dispatches.

## Health check (cycle startup)

The cycle skill probes the fixed model set at startup with a 1-token completion. Retries 3x with 2s backoff. Failure prints:

```
loop-spec health check FAILED
  Model alias: opus
  Error: <error text>
  Suggested fix: update CLAUDE.md model policy to allow the model the opus alias resolves to
```

Then aborts. No silent fallback.

## 1M-context flag

Sonnet 4.6 supports 1M context with the `context-1m-2025-08-07` beta flag (or equivalent CC harness option). Cycle skill probes with a >200k-token noop input. On rejection: fall back to standard sonnet 4.6 (200k), record warning in `feature.json.warnings[]`. Phases continue.

## Dispatch rule

Phase skills MUST pass `model:` explicitly on every teammate spawn and every one-shot `Agent` dispatch, reading the resolved ID from `feature.models.<role>`. Never rely on the agent frontmatter default. See `skills/shared/model-matrix.md` "Dispatch rule" for the canonical `TeamCreate` shape and the Step 5.5b background-mapper exception.

## Deployment alias mapping (Bedrock/Vertex)

Harness aliases (`opus`, `sonnet`, etc.) resolve to concrete model IDs inside the harness layer; loop-spec deliberately does not carry its own model-ID catalog because the Agent tool rejects literal IDs with InputValidationError. A deployment environment missing a model family (e.g. a Bedrock deployment without sonnet) must remap at the harness level via `ANTHROPIC_MODEL` / provider settings, or route affected roles to an available alias using `LOOP_SPEC_MODEL_<ROLE>`. The cycle startup health-check probes the resolved aliases and fails loud on any error — there is no silent fallback.
