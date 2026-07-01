# Cycle Step 3 -- tier-inference rubric (reference)

Extracted verbatim from `skills/cycle/SKILL.md`; the SKILL stub points here. Apply as written.

**Tier-inference rubric** (apply to the feature description + any grill answers; pick the
highest tier whose signals are present, default `balanced` when signals are mixed or thin):

| Tier | Choose when the work looks like… |
|---|---|
| `quick` | Single-file or trivially-scoped change: typo, copy edit, small bugfix, one isolated function, a config tweak. Low blast radius, one obvious acceptance check, no cross-cutting concerns. |
| `balanced` (default) | A normal multi-file feature or module: moderate scope, a handful of acceptance criteria, contained blast radius. Also the fallback whenever the signals are mixed or the prompt is thin. |
| `quality` | High blast radius or high cost of being wrong: auth/security/permissions, payments/billing, data migrations or anything risking data loss, public API or wire-contract changes, concurrency/locking, "production"/"critical"/"compliance" framing, or a wide cross-cutting refactor. Also when the user explicitly asks for rigor. |

**Safety floor (overrides the rubric):** if the prompt carries any security-relevant signal — auth, authentication, authorization, permissions, credentials/API keys/secrets/tokens, crypto, payments/billing, PII, or data migration/deletion — **never infer `quick`** (which skips the critique gate), even when the prompt is short and reads as trivially scoped. Floor it at `balanced` and lean `quality`. A one-liner like "add an API key check to this endpoint" is small in words but security-critical in blast radius; the critique gate must run.
