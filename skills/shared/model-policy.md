# Model Policy

> Imported from design doc 2026-05-05.

## Allowed models

Canonical selection is fixed per role (no preset axis); the authoritative
routing and override contract is `skills/shared/model-matrix.md`.

| Family | Alias | Roles |
|--------|-------|-------|
| Heavy | `opus` | spec-writer, planner, challenger, iterate-judge, code-reviewer |
| Standard | `sonnet` | advocate, spec-compliance-reviewer, implementer, verifier, mapper-*, pattern-mapper (1M-ctx flag when available) |

Dispatch uses harness ALIASES, not pinned IDs: the modern Agent tool's `model`
parameter is an alias enum and rejects literal IDs. `haiku` and `fable` are
accepted override values but are not canonical defaults.

Per-phase defaults can be overridden with
`LOOP_SPEC_PHASE_MODEL_<SPEC|DISCUSS|PLAN|EXECUTE|VERIFY|ITERATE|DELIVER>`, and
per-role defaults with `LOOP_SPEC_MODEL_<ROLE>`. Role overrides win over phase
overrides; task metadata wins where supported. All must be harness aliases.

## Consuming-project compatibility

Some projects' `CLAUDE.md` hard-codes earlier model IDs (e.g., chrisbobrowitz/superpowers fork bans anything other than 4.6 / 4.5). Before adopting loop-spec, that policy section MUST allow whatever the harness's `opus` and `sonnet` aliases currently resolve to. The cycle skill's startup health-check will fail loud if the policy blocks dispatches.

## Health check (cycle startup)

The cycle skill calls `feature-init.sh all-models` and probes every effective
alias at startup. The 24-hour cache is valid only for the same sorted alias set.
Retries 3x with 2s backoff. Failure prints:

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

Cycle MUST run `feature-init.sh activate` before every phase invocation. Phase
skills MUST pass `model:` explicitly on every teammate spawn and every one-shot
`Agent` dispatch, reading the activated alias from `feature.models.<role>`.
Never rely on the agent frontmatter default.

## Deployment alias mapping (Bedrock/Vertex)

Harness aliases (`opus`, `sonnet`, etc.) resolve to concrete model IDs inside
the harness layer; loop-spec deliberately does not carry its own model-ID
catalog because the Agent tool rejects literal IDs with InputValidationError. A
deployment environment missing a model family must remap at the harness level
or route affected phases/roles to an available alias. The startup health-check
probes the effective union and fails loud.
