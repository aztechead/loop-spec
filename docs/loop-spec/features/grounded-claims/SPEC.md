# Grounded claims — probe-before-assert for the design phases

**Slug:** `grounded-claims`
**Created:** 2026-07-02
**Tier:** standard
**Execution style:** step

## Problem

During SPEC/DISCUSS/PLAN, the orchestrator and its teammates assert facts about
external systems from model memory. Observed failure: a session using this plugin
stated a BigQuery dataset "could not be split out by UTC"; when the user pushed back
and said "actually query BigQuery first," the claim reversed. The wrong claim would
otherwise have flowed into SPEC.md and PLAN.md as a design constraint.

Root cause: grounding is enforced for the **codebase** (graphify is a hard
requirement and the design phases are instructed to query it) but facts about
**external reality** — dataset schemas, API capabilities, service configuration,
infra state — have no probe-before-assert requirement, no evidence trail, and no
gate that catches an unevidenced claim. Prose guidance alone ("state assumptions,
never guess silently" in `agents/spec-writer.md:51` and `agents/planner.md:146`)
already exists and demonstrably did not prevent the failure.

<decisions>
- Decision: enforce grounding with a deterministic lint gate + a committed evidence ledger + a challenger claim-audit, not with more prompt prose. Rationale: prose guidance already existed and failed; the repo's proven pattern is deterministic scripts wired into gates (decision-coverage, criteria-coverage, acceptance-lint). Alternatives considered: prompt-only reinforcement (rejected — it is the thing that failed); a regex hook that blocks capability-language ("cannot", "not supported") in artifacts (rejected — hopelessly false-positive prone as a blocker; semantic detection belongs to the challenger, structural enforcement to the lint).
- Decision: the lead/orchestrator runs all probes; teammates cite evidence they are handed. Rationale: spec-writer, planner, challenger, and advocate have no Bash tool by design (write-scope containment); centralizing probes in the lead preserves that boundary and keeps probes under the session's permission mode. Alternatives considered: granting Bash to spec-writer/planner (rejected — widens the blast surface the agent tool allow-lists exist to contain).
- Decision: probes are read-only, always. Rationale: design phases must never mutate external systems; a probe that writes is an action, not evidence. Alternatives considered: none viable.
- Decision: an unverifiable claim is written as `ASSUMPTION: <claim> | verify: <command>` — never as fact — and in autonomous styles this never blocks on a user question. Rationale: the goal is grounding "autonomously, without user prompting"; this matches the existing autonomous-mode contract (self-answer, record, proceed). Alternatives considered: escalating unverifiable claims to the user (rejected for auto/review-only styles — violates the no-block contract; step/interactive styles may still surface them conversationally).
- Decision: the evidence ledger lives at `docs/loop-spec/features/{slug}/EVIDENCE.md` and is committed alongside SPEC.md/PLAN.md. Rationale: the audit trail is the point — a reviewer must be able to see which probe backed which claim after the fact; `.loop-spec/features/*` transcripts are gitignored per-machine churn, artifacts under `docs/` are the committed record. Alternatives considered: `.loop-spec/features/{slug}/evidence.md` (rejected — gitignored, trail dies with the machine).
- Decision: the machine-readable challenger marker is the fixed prefix `UNGROUNDED:` followed by a verbatim quote. Rationale: the lead needs a deterministic way to extract grounding findings from free-prose critique; fixed string contracts are the repo's existing coupling mechanism (contract-strings.test.sh pins both sides). Alternatives considered: structured JSON critique output (rejected — bigger change to the debate protocol than the feature needs).
</decisions>

## Goals

- Encode a **probe-before-assert** protocol: before any design phase asserts a
  capability, limitation, schema, or configuration of an external system, it runs
  the cheapest read-only probe (`bq show`, `bq query --dry_run`, `gcloud describe`,
  `aws ... describe`, `psql -c '\d'`, `curl -s`, a CLI `--version`, ...) and records
  the result; claims cite evidence, not memory.
- Give evidence a durable, machine-checkable home: a per-feature append-only ledger
  (`EVIDENCE.md`) written via a new `lib/evidence.sh`, with stable `EVID-NNN` ids
  cited from SPEC.md/PLAN.md.
- Gate the artifacts deterministically: a new `lib/grounding-lint.sh` blocks
  DISCUSS's commit and PLAN's coverage-gate cluster when a `## Grounding` section is
  missing/malformed, an `EVID-*` reference does not resolve to the ledger, an
  `ASSUMPTION` entry lacks a runnable `verify:` command, or an `UNVERIFIED`
  placeholder survives inside the `## Grounding` section (the writer's explicit
  "could not even form an assumption" marker, defined in the protocol doc).
- Make the challenger hunt ungrounded claims: a new issue class with a fixed
  `UNGROUNDED: "<quote>"` marker; the lead resolves each by running the probe
  itself, appending to the ledger, and re-dispatching the writer with the evidence.
- All of it autonomous: probes self-run; what cannot be verified becomes an explicit
  recorded assumption; no new user prompts in auto/review-only/non-interactive
  styles.

## Non-goals

- Grounding enforcement in EXECUTE/VERIFY/ITERATE (implementation phases have the
  test suite as their grounding; this feature targets the design phases named in
  the goal).
- Verifying claims about the *codebase* beyond what graphify already provides.
- Semantic detection of ungrounded prose in the deterministic lint (that is the
  challenger's job; the lint checks structure only).
- A general fact-checking framework for conversation text outside the cycle.

## Boundaries (what NOT to do)

- Never run a mutating probe. The protocol text, the skill wiring, and the
  challenger prompt must all state probes are read-only; no `INSERT`/`create`/
  `delete`/`apply` verbs in suggested probes.
- Do not add Bash (or any new tool) to `agents/spec-writer.md`, `agents/planner.md`,
  `agents/challenger.md`, or `agents/advocate.md`.
- Do not modify EXECUTE, VERIFY, or ITERATE skills.
- Do not make `lib/grounding-lint.sh` flag free prose by pattern-matching capability
  language — it checks the `## Grounding` section structure, `EVID-*` resolution,
  `ASSUMPTION` well-formedness, and leftover `UNVERIFIED` tokens only.
- Do not add runtime dependencies beyond bash/git/jq/python3, and do not make the
  offline test suite require network, credentials, or graphify.
- Do not relax or remove any existing gate.

## Constraints

- New lib scripts follow existing conventions: `set -uo pipefail`, usage text,
  actionable guidance on stderr, exit 0/1 as pass/block, unit-testable offline.
- Skills reference the new scripts via `${CLAUDE_SKILL_DIR}/../../lib/...` (never
  `${CLAUDE_PLUGIN_ROOT}`).
- New string couplings (script name in skill prose, `UNGROUNDED:` marker,
  `EVID-` prefix) are pinned in `tests/contract-strings.test.sh`.
- Every `*.test.sh` added is registered in `tests/run-all.sh` in the same change
  (meta-test `tests/all-tests-registered.test.sh` enforces this).
- Retry handling for the new gate reuses the existing budget machinery
  (`retryBudget.perGateUsed`, per-phase, global) — no new budget knobs.

## User-facing behavior

A user running `/loop-spec:cycle` on a feature that touches an external system sees:
during SPEC/DISCUSS the lead runs visible read-only probe commands *before* stating
external facts in questions or options; SPEC.md and PLAN.md carry a `## Grounding`
section listing each load-bearing external fact as `EVID-NNN` (backed by a ledger
entry showing the exact command and output) or as an explicit
`ASSUMPTION: ... | verify: ...`; `docs/loop-spec/features/{slug}/EVIDENCE.md` is
committed with the artifacts. If a spec-writer or planner asserts an external fact
without evidence, the challenger flags it `UNGROUNDED:`, the lead runs the probe and
re-dispatches — the user never has to say "actually query BigQuery first."

## Success criteria

### Good Enough

- [ ] `lib/evidence.sh add <ledger> <claim> <command> <output>` appends a
      well-formed entry, assigns sequential `EVID-NNN` ids, is idempotent on
      identical claim+command (returns the existing id), and `list`/`next-id`
      behave; proven by `bash tests/lib/evidence.test.sh`.
- [ ] `lib/grounding-lint.sh <artifact> [ledger]` strips complete (multi-line)
      `<!-- ... -->` comment blocks first and validates only `- `-prefixed lines
      inside the `## Grounding` section; it exits 1 (with `FLAG <artifact>:<lineno>:`
      lines) on: missing `## Grounding` section; a malformed grounding bullet; an
      `EVID-NNN` reference anywhere in the artifact with no ledger entry; an
      `ASSUMPTION` bullet whose `verify:` command (split on the LAST ` | verify: `)
      is absent or fails `bash -n`; a whole-word `UNVERIFIED` inside the
      `## Grounding` section; `- none` mixed with evidence bullets. Exits 0 on a
      well-formed artifact including the bare `- none` form AND on a section that is
      byte-identical to the artifact-template block (4-line comment + `- none`);
      proven by `bash tests/lib/grounding-lint.test.sh` (fixtures include the
      template block verbatim and a `|` inside a verify command).
- [ ] `skills/shared/artifact-templates/SPEC.md.template` and
      `PLAN.md.template` contain a `## Grounding` section.
- [ ] `skills/shared/grounding-protocol.md` exists and defines the claim taxonomy
      (codebase / external-system / ecosystem / user-stated), the probe-before-assert
      rule, read-only probe examples, the `ASSUMPTION: ... | verify: ...` fallback,
      and the ledger format.
- [ ] `agents/spec-writer.md` and `agents/planner.md` require every load-bearing
      external-system fact to cite an `EVID-NNN` ledger entry or be written as an
      explicit `ASSUMPTION`, and list a missing/defective `## Grounding` section as
      an artifact defect.
- [ ] `agents/challenger.md` and `skills/shared/team-prompts/challenger.md` define
      the Ungrounded-claim issue class with the `UNGROUNDED: "<verbatim quote>"`
      output marker and a suggested read-only probe per finding.
- [ ] `skills/discuss/SKILL.md` (a) instructs probe-before-assert during the Step 1
      loop, (b) passes the evidence ledger path in the spec-writer brief, (c) maps
      `UNGROUNDED:` findings to lead-run probes + `lib/evidence.sh add` + writer
      re-dispatch in Step 5, and (d) runs `lib/grounding-lint.sh` as a blocking gate
      before the Step 6 commit, re-dispatching on exit 1 under the existing retry
      budgets; the Step 6 commit includes `EVIDENCE.md` when present.
- [ ] `skills/plan/SKILL.md` runs `lib/grounding-lint.sh` on PLAN.md in the
      Step 5.5 gate cluster with the same blocking/re-dispatch handling, the
      planner brief carries the ledger path, and the plan critique's fix-list
      synthesis maps challenger `UNGROUNDED:` findings to lead-run read-only probes
      + `lib/evidence.sh add` + planner re-dispatch, exactly as DISCUSS Step 5 does.
- [ ] `skills/spec/SKILL.md` Step 1 scout enumerates external systems named in the
      ask and probes factual premises (read-only) before treating them as fact, with
      the autonomous-mode fallback (unverifiable -> recorded `ASSUMPTION`, no user
      question).
- [ ] `tests/contract-strings.test.sh` pins both sides of the new couplings:
      `grounding-lint.sh"` in discuss+plan skills, `evidence.sh" add` in
      spec+discuss+plan skills, `UNGROUNDED:` in challenger agent + team prompt +
      discuss skill + plan skill, `EVID-` in `lib/evidence.sh` +
      `lib/grounding-lint.sh`.
- [ ] `bash tests/run-all.sh` passes with the two new suites registered.

### Exceptional

- [ ] README.md documents the grounding protocol (philosophy bullet or dedicated
      subsection) so plugin users know why probes run during design phases.
- [ ] CHANGELOG.md entry + `.claude-plugin/plugin.json` version bump to 2.7.0 with
      the feature described.
- [ ] `lib/grounding-lint.sh` FLAG output names the offending line number, so the
      re-dispatch fix-list is directly actionable.

## Out of scope

- Caching/expiry of evidence across features (each feature re-probes; stale
  evidence is a future concern).
- Probing during EXECUTE task implementation (implementers have tests).
- An allowlist/registry of "approved probe commands" (the read-only rule is prose +
  challenger-audited; a command classifier is not buildable deterministically in
  bash without heavy false positives).
- Backfilling `## Grounding` into previously shipped feature specs.

## Grounding

- none (this feature changes only repo-internal prose, bash, and tests; every
  factual premise above cites a repo file/line and no external-system fact is
  load-bearing)

## Open questions

(none - resolved during design)
