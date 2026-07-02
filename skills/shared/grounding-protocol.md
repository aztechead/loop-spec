# Grounding protocol — probe-before-assert contract

Every load-bearing fact a design phase asserts about an external system must be
backed by evidence, not model memory. This document defines how that evidence is
gathered, recorded, cited, and checked.

## Claim taxonomy

| Claim type | What it covers | How to back it |
|---|---|---|
| **Codebase claim** | File existence, function signature, line content, dependency version inside the repo | Cite `file:line` or quote graphify query output (`graphify query`, `graphify path`, `graphify explain`); no probe needed. |
| **External-system claim** | Dataset schema, API capability or limitation, service config, infra state, cloud resource attributes | Run the cheapest read-only probe, record the result in the evidence ledger, cite `EVID-NNN`. |
| **Ecosystem / library claim** | Version, API surface, behavior of a third-party package or CLI already installed locally | Probe local install (`<tool> --version`, `pip show`, `npm list`, local docs); if unavailable, write `ASSUMPTION`. |
| **User-stated fact** | Something the user asserted in the transcript | Cite the transcript ("user stated in session that …"); no probe needed, but do not extend the claim beyond what was said. |

## Probe-before-assert rule

**Never assert an external-system capability, limitation, schema, or configuration
from model memory.** Before treating any such premise as fact, run the cheapest
read-only probe available and record its output.

### Example read-only probes

```
bq show --format=prettyjson project:dataset.table
bq query --dry_run --nouse_legacy_sql 'SELECT ...'
gcloud describe <resource> --project=<project>
aws <service> describe-<resource> --region <region>
psql -c '\d tablename'
curl -s https://api.example.com/schema
<tool> --version
pip show <package>
npm list <package>
```

These are illustrative, not exhaustive. The criterion is: read-only and producing
a concrete, citable output.

### Explicit prohibition

Probes must never mutate external systems. Commands containing `INSERT`, `UPDATE`,
`DELETE`, `create`, `apply`, `deploy`, `rm`, `drop`, or equivalent write verbs are
**not probes** — they are actions. Design phases must never run them as evidence
gathering. The read-only constraint is absolute.

## The evidence ledger

Each probe result is recorded in a per-feature append-only ledger committed
alongside the artifacts.

**Ledger path:** `docs/loop-spec/features/{slug}/EVIDENCE.md`

**Line format:**
```
- EVID-NNN | <ISO-8601 UTC ts> | claim: <claim> | cmd: <command> | out: <output>
```

**Write via `lib/evidence.sh` only.** Never append manually; use the script to
guarantee sequential ids, sanitization, and idempotency:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/evidence.sh" add \
  "docs/loop-spec/features/{slug}/EVIDENCE.md" \
  "<claim>" \
  "<command>" \
  "<output>"
```

The script prints the assigned or existing `EVID-NNN` on stdout. Use that id to
populate the artifact's `## Grounding` section.

`evidence.sh list <ledger>` prints all recorded entries.
`evidence.sh next-id <ledger>` previews the id the next `add` would assign.

## The lead-runs-probes rule

Teammates (spec-writer, planner, challenger, advocate) have **no Bash tool by
design** — write-scope containment. Only the LEAD (orchestrator / main thread)
can run probes.

Protocol:
1. Before dispatching a writer, the lead enumerates external systems named in the
   ask, runs the appropriate read-only probes, and calls `evidence.sh add` for each
   result.
2. The lead includes the `EVID-NNN` ids and the relevant output excerpts in the
   writer's brief under a field such as `evidence_path:` and `evidence:`.
3. Writers cite the ids they were handed (`EVID-NNN`) — they do not invent or
   assert external facts independently.
4. When a challenger raises an `UNGROUNDED:` finding (see below), the lead runs
   the suggested probe, appends to the ledger, and re-dispatches the writer with
   the new `EVID-NNN`.

## Fallback: unverifiable claims

When a probe cannot run (no CLI installed, no credentials, offline environment):

**Write:** `ASSUMPTION: <claim> | verify: <command that would verify it>`

Rules:
- In **autonomous styles**: record the assumption in the decisions record
  (`lib/decisions.sh add`) and proceed — never block on a user question. The
  audit trail is the point.
- In **step / interactive styles**: the assumption may be surfaced conversationally,
  but the operator must not be blocked indefinitely; if no answer arrives, treat
  as autonomous and record.
- The `verify:` command must be syntactically valid shell (checked by
  `bash -n -c "<cmd>"`); it is the probe that would have been run with access.

## UNVERIFIED — the writer's last-resort placeholder

`UNVERIFIED: <claim>` is the writer's signal that a load-bearing external fact
can **neither** be evidenced (no probe available) **nor** framed as a testable
`ASSUMPTION` (no concrete verify command can be written). It is an explicit
admission of a gap, not a shorthand for "I didn't check."

Writers should strongly prefer:
1. Waiting for the lead to supply an `EVID-NNN` (request in `NEEDS_CONTEXT`).
2. Framing as `ASSUMPTION: ... | verify: ...` if a verify command is conceivable.

If `UNVERIFIED` is written inside `## Grounding`, the `lib/grounding-lint.sh` gate
will **reject the artifact** with a FLAG. It must be resolved before the artifact
can be committed.

## The `## Grounding` artifact section

Every SPEC.md and PLAN.md carries a `## Grounding` section. Its bullets must
match one of three forms exactly:

1. **No external load-bearing facts:**
   ```
   - none
   ```
   (optionally followed by a parenthetical: `- none (reason)`)

2. **Evidenced fact:**
   ```
   - EVID-NNN: <one-line description of what the probe confirmed>
   ```
   The `NNN` must resolve to a `- EVID-NNN | ` entry in the feature's
   `EVIDENCE.md` ledger.

3. **Unverifiable assumption:**
   ```
   - ASSUMPTION: <claim> | verify: <command>
   ```
   The verify command must pass `bash -n -c "<cmd>"` (syntactic check).

`- none` may not coexist with `EVID-` or `ASSUMPTION` bullets in the same section.

`lib/grounding-lint.sh` is the deterministic gate. It runs before the DISCUSS
Step 6 commit and before the PLAN Step 5.5 gate cluster clears. Exit 1 (with
`FLAG <artifact>:<lineno>:` lines) blocks the commit and re-dispatches the writer.
Exit 0 (`grounding-lint: ok`) clears the gate. The lint strips complete
`<!-- ... -->` comment blocks before validation and only inspects `- `-prefixed
lines inside the section — prose and blanks are ignored.

## Challenger marker: `UNGROUNDED:`

When the challenger audits an artifact and finds an external-system assertion that
lacks an `EVID-NNN` citation or an `ASSUMPTION` marker, it emits one line per
finding beginning exactly:

```
UNGROUNDED: "<verbatim quote of the offending sentence>" — probe: <read-only command>
```

Example:
```
UNGROUNDED: "the dataset cannot be partitioned by UTC day" — probe: bq show --format=prettyjson proj:ds.table (read-only)
```

The suggested probe must itself be read-only. The lead extracts every `UNGROUNDED:`
line, runs the probe, appends via `evidence.sh add`, and re-dispatches the writer
with the resulting `EVID-NNN`. This is the resolution path — the lead never asks
the user to do it.
