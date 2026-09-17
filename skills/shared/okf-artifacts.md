# OKF 0.2 artifact contract

The authoritative [OKF 0.2 specification](https://github.com/GoogleCloudPlatform/open-knowledge-format/blob/main/SPEC.md) defines the document model. This plugin's feature-bundle profile applies that model to the artifacts below.

Feature documents use a small YAML header before their Markdown body. For example:

```yaml
---
type: Specification
---
```

The filename mapping is:

| Filename | `type` |
|---|---|
| `SPEC.md` | Specification |
| `PLAN.md` | Implementation Plan |
| `PATTERNS.md` | Pattern Index |
| `EVIDENCE.md` | Evidence |
| `VERIFICATION.md` | Verification Report |
| `ITERATION.md` | Iteration Report |
| `REVIEW-ORDER.md` | Review Order |
| `REVISION.md` | Revision Report |

Feature bundles live under `docs/loop-spec/features/{slug}/`. The bundle `index.md`
is generated for optional discovery; it is not a required phase read. Only the root
index carries `okf_version: "0.2"`; every document header requires `type`, while
other metadata remains optional and minimal.

Use a YAML `sources` array for optional source context:

```yaml
sources:
  - resource: SPEC.md
  - resource: PATTERNS.md
```

Sources are repository context, not approval or runtime authority. A `verified`
field, when present, is advisory evidence and never substitutes for phase gates,
approval, or verification status. Runtime JSON remains runtime state.

The local bounded parser accepts at most 64 KiB of header bytes, limits YAML nodes,
aliases, and nesting, and reserves `index.md` and `log.md` for bundle metadata.
Keep the existing Markdown body, freeze, approval, grounding, and substantive
acceptance gates unchanged.
