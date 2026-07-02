# Grounded claims — Implementation Plan

**Spec:** `docs/loop-spec/features/grounded-claims/SPEC.md`
**Created:** 2026-07-02

## Architecture overview

Two new deterministic lib scripts (`lib/evidence.sh` ledger writer,
`lib/grounding-lint.sh` artifact gate) follow the acceptance-lint/decision-coverage
pattern; a shared protocol doc defines the probe-before-assert contract; agent
definitions and the challenger team prompt gain an Ungrounded-claim issue class with
a fixed `UNGROUNDED:` marker; the spec/discuss/plan skills wire probes, the ledger
path, and the lint gate into their existing steps and retry budgets. No new
dependencies, no new budget knobs, no changes to EXECUTE/VERIFY/ITERATE.

## Pinned interfaces (implementers: do NOT improvise beyond this)

### `lib/evidence.sh`

```
Usage:
  evidence.sh add <ledger_path> <claim> <command> <output>
  evidence.sh list <ledger_path>
  evidence.sh next-id <ledger_path>
```

- `add`: creates the ledger with a `# Evidence ledger` heading line if missing;
  sanitizes `claim`/`command`/`output` (literal `|` -> `/`, newlines/tabs -> single
  space); truncates `output` to 300 chars (append `…` when truncated); appends ONE
  line:
  `- EVID-NNN | <ISO-8601 UTC ts> | claim: <claim> | cmd: <command> | out: <output>`
  where NNN is zero-padded 3-digit sequential (first id is 001). Idempotent: if an
  existing entry has the same sanitized claim AND command, do not append; print the
  existing id. Always prints the id (existing or new) on stdout as the last line.
- `list`: prints all `- EVID-` lines (nothing + exit 0 for empty/missing ledger).
- `next-id`: prints the id `add` would assign next.
- Errors (missing args, unwritable path) -> message on stderr, exit 1.
- `set -uo pipefail`, pure bash + coreutils (no jq needed), executable-safe when
  invoked as `bash lib/evidence.sh ...`.

### `lib/grounding-lint.sh`

```
Usage: grounding-lint.sh <artifact_path> [ledger_path]
```

- Default `ledger_path`: `EVIDENCE.md` in the artifact's directory.
- Extract the `## Grounding` section (from the `## Grounding` line to the next
  `^## ` heading or EOF). **Preprocessing (pinned):** within the section, remove
  complete `<!-- ... -->` comment BLOCKS first (multi-line: everything from a line
  containing `<!--` through the line containing the matching `-->`, inclusive).
  After stripping, ONLY lines matching `^- ` are validated as bullets; every other
  line (blank, prose, leftover text) is ignored — never flagged. Checks, each
  producing a `FLAG <artifact>:<lineno>: <why>` line on stdout:
  1. No `## Grounding` section in the artifact -> FLAG (line 0).
  2. Every `^- ` bullet line in the (comment-stripped) section must match one of:
     - `- none` (optionally followed by ` (` explanation `)` — i.e. prefix match on
       `- none`)
     - `- EVID-[0-9][0-9][0-9]: <non-empty text>`
     - `- ASSUMPTION: <non-empty text> | verify: <non-empty command>` — parsed by
       splitting on the LAST occurrence of ` | verify: ` (so a literal `|` inside
       the verify command or claim is safe; a claim must not itself contain
       ` | verify: `)
     Anything else -> FLAG malformed bullet.
  3. Every `ASSUMPTION` bullet's `verify:` command must pass `bash -n -c "<cmd>"`
     -> else FLAG.
  4. Every `EVID-[0-9]{3}` token appearing ANYWHERE in the artifact must have a
     `- EVID-NNN | ` entry line in the ledger -> else FLAG (missing evidence).
  5. Any line INSIDE the (comment-stripped) `## Grounding` section containing the
     whole word `UNVERIFIED` -> FLAG. (`UNVERIFIED` is the protocol's explicit
     "could not even form an assumption" placeholder — it must never survive to the
     gate. The rest of the artifact is NOT scanned for it.)
  6. A `- none` bullet coexisting with any `EVID-`/`ASSUMPTION` bullet in the
     section -> FLAG (contradiction).
- Any FLAG -> guidance paragraph on stderr (what to fix: cite a ledger entry via
  `lib/evidence.sh add`, or rewrite as `ASSUMPTION: ... | verify: ...`), exit 1.
- No FLAGs -> print `grounding-lint: ok`, exit 0.
- Missing artifact file -> stderr message, exit 1. Missing ledger is OK unless an
  `EVID-` token needs resolving.

### Challenger marker (string contract)

Each grounding finding in the challenger's critique is one line beginning exactly
`UNGROUNDED: ` followed by a verbatim quote of the offending artifact sentence,
then ` — ` and a suggested READ-ONLY probe command. Example:
`UNGROUNDED: "the dataset cannot be partitioned by UTC day" — probe: bq show --format=prettyjson proj:ds.table (read-only)`

### `## Grounding` template section (both artifact templates)

```
## Grounding

<!-- Probe-before-assert (skills/shared/grounding-protocol.md): every load-bearing
     fact about an external system (dataset, API, service, infra) must cite an
     EVIDENCE.md entry (EVID-NNN) or be an explicit ASSUMPTION with a verify probe.
     Keep the single `- none` line if nothing external is load-bearing. -->
- none
```

## File map

- Create: `lib/evidence.sh` — evidence ledger writer (add/list/next-id)
- Create: `lib/grounding-lint.sh` — deterministic grounding gate
- Create: `tests/lib/evidence.test.sh` — unit suite
- Create: `tests/lib/grounding-lint.test.sh` — unit suite
- Modify: `tests/run-all.sh` — register the two suites
- Create: `skills/shared/grounding-protocol.md` — claim taxonomy + probe rules + ledger format
- Modify: `skills/shared/artifact-templates/SPEC.md.template` — add `## Grounding`
- Modify: `skills/shared/artifact-templates/PLAN.md.template` — add `## Grounding`
- Modify: `agents/spec-writer.md` — grounding defect + evidence-citation principle
- Modify: `agents/planner.md` — same for PLAN.md
- Modify: `agents/challenger.md` — Ungrounded-claim issue class + `UNGROUNDED:` marker
- Modify: `skills/shared/team-prompts/challenger.md` — same marker in per-round protocol
- Modify: `skills/spec/SKILL.md` — Step 1 external-reality scout + autonomous fallback
- Modify: `skills/discuss/SKILL.md` — Step 1 probes, Step 3 brief, Step 5 UNGROUNDED handling, new Step 5.75 lint gate, Step 6 commit includes EVIDENCE.md
- Modify: `skills/plan/SKILL.md` — planner brief ledger path + Step 5.5 grounding-lint check + commit includes EVIDENCE.md
- Modify: `tests/contract-strings.test.sh` — pin new couplings
- Modify: `CHANGELOG.md`, `.claude-plugin/plugin.json` (2.7.0), `README.md`

## Task DAG

| ID | Subject | BlockedBy | Files | Est scope |
|----|---------|-----------|-------|-----------|
| task-001 | evidence.sh + grounding-lint.sh + unit tests + run-all registration | - | lib/evidence.sh, lib/grounding-lint.sh, tests/lib/evidence.test.sh, tests/lib/grounding-lint.test.sh, tests/run-all.sh | medium |
| task-002 | grounding-protocol.md + template Grounding sections | - | skills/shared/grounding-protocol.md, skills/shared/artifact-templates/SPEC.md.template, skills/shared/artifact-templates/PLAN.md.template | small |
| task-003 | agent definitions + challenger team prompt | task-001, task-002 | agents/spec-writer.md, agents/planner.md, agents/challenger.md, skills/shared/team-prompts/challenger.md | small |
| task-004 | skill wiring (spec, discuss, plan) | task-001, task-002 | skills/spec/SKILL.md, skills/discuss/SKILL.md, skills/plan/SKILL.md | medium |
| task-005 | contract-strings pins + changelog + version + README | task-003, task-004 | tests/contract-strings.test.sh, CHANGELOG.md, .claude-plugin/plugin.json, README.md | small |

Waves: wave 1 = {task-001, task-002}; wave 2 = {task-003, task-004}; wave 3 = {task-005}.
Same-wave file sets are disjoint.

## Tasks

### task-001: evidence.sh + grounding-lint.sh + unit tests + run-all registration

**Goal:** Ship the two deterministic scripts exactly per "Pinned interfaces", with offline unit suites registered in run-all.

**Files:** `lib/evidence.sh`, `lib/grounding-lint.sh`, `tests/lib/evidence.test.sh`, `tests/lib/grounding-lint.test.sh`, `tests/run-all.sh`

**read_first:** `lib/acceptance-lint.sh` (style/exit-code pattern), `lib/decisions.sh` (lib header style), `tests/lib/acceptance-lint.test.sh` (test harness pattern), `tests/run-all.sh:80-90`

**Verify:** `bash tests/lib/evidence.test.sh && bash tests/lib/grounding-lint.test.sh && bash tests/all-tests-registered.test.sh` -> all pass

**Acceptance criteria:**
- [ ] `bash tests/lib/evidence.test.sh` passes, covering: first add creates ledger + returns id 001; second distinct add returns id 002; identical claim+command re-add returns the first id without appending; sanitization of `|` and newlines; 300-char output truncation; `list` on missing ledger exits 0 empty; `next-id` correctness; missing-args exit 1.
- [ ] `bash tests/lib/grounding-lint.test.sh` passes, covering: exit 0 on `- none` artifact; **exit 0 on a Grounding section byte-identical to the artifact-template block (4-line HTML comment + `- none`)**; exit 0 on artifact with resolving EVID refs + well-formed ASSUMPTION **including one whose verify command contains a literal `|`**; exit 1 for each FLAG class in the pinned interface (missing section, malformed bullet, unresolved EVID ref, `bash -n`-failing verify cmd, whole-word UNVERIFIED inside the section, none+evidence contradiction); **whole-word UNVERIFIED OUTSIDE the section does NOT flag**; FLAG lines carry line numbers; missing artifact exits 1.
- [ ] `bash tests/all-tests-registered.test.sh` passes (both suites registered in `tests/run-all.sh`).

**Steps (TDD):**
- [ ] Step 1: Write both failing test suites (mirror tests/lib/acceptance-lint.test.sh harness: tmp dir fixtures, PASS/FAIL counters, exit code)
- [ ] Step 2: Run them, expect FAIL
- [ ] Step 3: Implement `lib/evidence.sh`, then `lib/grounding-lint.sh` per pinned interfaces
- [ ] Step 4: Run suites, expect PASS; register both in tests/run-all.sh next to `lib/acceptance-lint`
- [ ] Step 5: Run the Verify command

### task-002: grounding-protocol.md + template Grounding sections

**Goal:** Write the shared probe-before-assert contract and add the `## Grounding` section to both artifact templates.

**Files:** `skills/shared/grounding-protocol.md`, `skills/shared/artifact-templates/SPEC.md.template`, `skills/shared/artifact-templates/PLAN.md.template`

**read_first:** `docs/loop-spec/features/grounded-claims/SPEC.md` (Goals + Boundaries), `skills/shared/autonomous-mode.md` (tone/format of shared contracts), `skills/shared/artifact-templates/SPEC.md.template`

**Verify:** `grep -c '## Grounding' skills/shared/grounding-protocol.md skills/shared/artifact-templates/SPEC.md.template skills/shared/artifact-templates/PLAN.md.template | grep -v ':0'` -> 3 lines

**Acceptance criteria:**
- [ ] `skills/shared/grounding-protocol.md` defines: claim taxonomy (codebase -> cite file:line or graphify output; external-system -> read-only probe + `EVID-NNN` ledger citation; ecosystem/library -> local version/docs probe or ASSUMPTION; user-stated -> transcript); the probe-before-assert rule with read-only example probes (`bq show`, `bq query --dry_run`, `gcloud describe`, `aws ... describe`, `psql -c '\d'`, `curl -s`, `<tool> --version`); the explicit prohibition on mutating probes; the `ASSUMPTION: <claim> | verify: <command>` fallback; the ledger line format and `lib/evidence.sh add` call shape; the rule that the LEAD runs probes (teammates have no Bash) and hands evidence down; the autonomous-mode rule (unverifiable -> recorded assumption, never a user question).
- [ ] Both templates carry the exact `## Grounding` section from "Pinned interfaces" (placed between `## Out of scope` and `## Open questions` in SPEC.md.template; placed LAST, after `## Rollback plan`, in PLAN.md.template — matching the section order of the shipped exemplars in docs/loop-spec/features/grounded-claims/).
- [ ] The protocol doc defines `UNVERIFIED` as the writer's explicit placeholder when a load-bearing external fact can neither be evidenced nor framed as a testable `ASSUMPTION` — instructing writers to prefer `NEEDS_CONTEXT` and stating the gate rejects any `UNVERIFIED` left inside `## Grounding`.
- [ ] Protocol doc contains the literal strings `## Grounding`, `EVID-`, `evidence.sh" add`-compatible call example (`bash "${CLAUDE_SKILL_DIR}/../../lib/evidence.sh" add ...`), and `read-only`.

**Steps:**
- [ ] Step 1: Write skills/shared/grounding-protocol.md
- [ ] Step 2: Add the section to both templates
- [ ] Step 3: Run the Verify command

### task-003: agent definitions + challenger team prompt

**Goal:** Make writers require evidence citations and the challenger hunt ungrounded claims with the fixed marker.

**Files:** `agents/spec-writer.md`, `agents/planner.md`, `agents/challenger.md`, `skills/shared/team-prompts/challenger.md`

**read_first:** `skills/shared/grounding-protocol.md`, `agents/spec-writer.md`, `agents/challenger.md`, `skills/shared/team-prompts/challenger.md`

**Verify:** `bash tests/validate-agents.sh && bash tests/validate-agents.test.sh && for f in agents/challenger.md skills/shared/team-prompts/challenger.md; do grep -q 'UNGROUNDED:' "$f" || exit 1; done` -> validators pass, marker present in BOTH files

**Acceptance criteria:**
- [ ] `agents/spec-writer.md`: "Required content" list gains "Populated `## Grounding` section per skills/shared/grounding-protocol.md (missing or malformed = defect)"; "Engineering principles" gains probe-evidence rule: never assert an external-system fact from memory — cite the `EVID-NNN` the orchestrator provides, or write `ASSUMPTION: ... | verify: ...`; if a load-bearing external fact has neither evidence nor a viable assumption framing, return `NEEDS_CONTEXT` naming the probe to run.
- [ ] `agents/planner.md`: same principle adapted to PLAN.md; PLAN.md must carry `## Grounding` (copied/extended from SPEC, with any new planning-time external facts added), listed alongside the existing gates in the self-check.
- [ ] `agents/challenger.md`: new checked category **Ungrounded external claims** — any statement asserting capability/limitation/schema/config of an external system without an `EVID-NNN` citation or `ASSUMPTION` marker; each finding emitted as a line starting `UNGROUNDED: "<verbatim quote>"` with a suggested read-only probe.
- [ ] `skills/shared/team-prompts/challenger.md`: Per-Round Protocol issue grouping gains the **Ungrounded claim** class with the same `UNGROUNDED:` line format, and the Rules section states suggested probes must be read-only.
- [ ] No tools added to any agent frontmatter (diff shows no `tools:` changes).

**Steps:**
- [ ] Step 1: Edit the two writer agents
- [ ] Step 2: Edit challenger agent + team prompt
- [ ] Step 3: Run the Verify command

### task-004: skill wiring (spec, discuss, plan)

**Goal:** Wire probes, the ledger, and the lint gate into the three design-phase skills.

**Files:** `skills/spec/SKILL.md`, `skills/discuss/SKILL.md`, `skills/plan/SKILL.md`

**read_first:** `skills/shared/grounding-protocol.md`, `skills/discuss/SKILL.md` (Steps 1, 3, 5, 6), `skills/plan/SKILL.md:362-434` (Steps 4b-6), `skills/spec/SKILL.md:112-135` (Step 1 scout), `lib/grounding-lint.sh`

**Verify:** `bash tests/lib/skill-references.test.sh && for f in skills/discuss/SKILL.md skills/plan/SKILL.md; do grep -q 'grounding-lint.sh"' "$f" || exit 1; done` -> passes, reference present in BOTH files

**Acceptance criteria:**
- [ ] `skills/spec/SKILL.md` Step 1 scout gains an **External-reality scout** block after the code-graph block: enumerate external systems named in the ask; before treating any factual premise about them as fact, run the cheapest READ-ONLY probe and record it via `bash "${CLAUDE_SKILL_DIR}/../../lib/evidence.sh" add "docs/loop-spec/features/{slug}/EVIDENCE.md" "<claim>" "<command>" "<output>"`; unverifiable (no CLI/creds/offline) -> record `ASSUMPTION` per protocol and (autonomous styles) `decisions.sh" add` — never ask the user; Researcher-round questions must state probed facts with their `EVID-NNN`, never memory-asserted facts. References `skills/shared/grounding-protocol.md`.
- [ ] `skills/discuss/SKILL.md` Step 1 gains the same probe-before-assert instruction (after the code-graph grounding paragraph); Step 3 spec-writer brief adds `evidence_path: docs/loop-spec/features/{slug}/EVIDENCE.md` and one sentence pointing at the protocol; Step 5 reconciliation table gains a row: challenger `UNGROUNDED:` finding -> lead runs the suggested read-only probe itself, appends via `lib/evidence.sh" add`, and puts the `EVID-NNN` + output excerpt into the fix-list item; new **Step 5.75 - Grounding gate** before Step 6: run `bash "${CLAUDE_SKILL_DIR}/../../lib/grounding-lint.sh" "docs/loop-spec/features/{slug}/SPEC.md"`, exit 1 BLOCKS -> BEFORE incrementing, check the cap exactly as Step 5 does (`perGateUsed["discuss.grounding"] >= retryBudget.perGate`, absent key reads as 0 -> pause/escalate per the existing budget rules), then re-dispatch spec-writer-1 with the FLAG lines (increment `retryBudget.perGateUsed["discuss.grounding"]`, `perPhaseUsed.discuss`, `globalUsed`; re-run the lint after revision, no full debate re-run for lint-only failures); Step 6 `git add` includes `docs/loop-spec/features/{slug}/EVIDENCE.md` when present.
- [ ] `skills/plan/SKILL.md`: planner-1 brief (Step 2 dispatch) carries the same `evidence_path` + protocol pointer; the plan critique's fix-list synthesis (Step 5) gains the SAME `UNGROUNDED:` handling row as discuss Step 5 (lead runs the suggested read-only probe, appends via `lib/evidence.sh" add`, feeds `EVID-NNN` + output excerpt into the planner re-dispatch); Step 5.5 gains a third check after criteria-coverage: `bash "${CLAUDE_SKILL_DIR}/../../lib/grounding-lint.sh" "$plan_path"` with exit 1 handled exactly like decision-coverage (BLOCK, re-dispatch planner-1 with FLAG lines, same retry counters); Step 6 commit includes `EVIDENCE.md` when changed.
- [ ] All new lib references use the `${CLAUDE_SKILL_DIR}/../../lib/` form; no `${CLAUDE_PLUGIN_ROOT}` anywhere in the diff.
- [ ] No changes to EXECUTE/VERIFY/ITERATE skills.

**Steps:**
- [ ] Step 1: Edit skills/spec/SKILL.md Step 1
- [ ] Step 2: Edit skills/discuss/SKILL.md (Steps 1, 3, 5, new 5.75, 6)
- [ ] Step 3: Edit skills/plan/SKILL.md (brief, Step 5.5, Step 6)
- [ ] Step 4: Run the Verify command

### task-005: contract-strings pins + changelog + version + README

**Goal:** Pin the new string contracts and ship the release bookkeeping.

**Files:** `tests/contract-strings.test.sh`, `CHANGELOG.md`, `.claude-plugin/plugin.json`, `README.md`

**read_first:** `tests/contract-strings.test.sh`, `CHANGELOG.md:1-40`, `README.md` (philosophy/skills sections)

**Verify:** `bash tests/run-all.sh` -> all suites pass

**Acceptance criteria:**
- [ ] `tests/contract-strings.test.sh` checks[] gains entries pinning: `skills/discuss/SKILL.md` + `skills/plan/SKILL.md` carry `grounding-lint.sh"`; `skills/spec/SKILL.md` + `skills/discuss/SKILL.md` + `skills/plan/SKILL.md` carry `evidence.sh" add`; `agents/challenger.md` + `skills/shared/team-prompts/challenger.md` + `skills/discuss/SKILL.md` + `skills/plan/SKILL.md` carry `UNGROUNDED:`; `lib/evidence.sh` + `lib/grounding-lint.sh` carry `EVID-`; `skills/shared/grounding-protocol.md` + `lib/grounding-lint.sh` carry `## Grounding`. **Format note: copy an existing `decisions.sh\" add` row verbatim and swap the strings — the inner `"` is backslash-escaped and the file/string separator is a LITERAL TAB character, not spaces; getting either wrong silently breaks the bash array element.**
- [ ] CHANGELOG.md gains a 2.7.0 entry describing the grounded-claims protocol; plugin.json version is `2.7.0` and its description mentions the grounded-claims / probe-before-assert evidence gate.
- [ ] README.md documents the grounding protocol briefly (what runs, why probes appear during design phases, the EVIDENCE.md artifact).
- [ ] `bash tests/run-all.sh` fully green.

**Steps:**
- [ ] Step 1: Add contract-strings entries, run that suite, expect PASS
- [ ] Step 2: CHANGELOG + version bump + README
- [ ] Step 3: Run the Verify command

## User decisions (already made)

- Decision: enforce grounding with a deterministic lint gate + a committed evidence ledger + a challenger claim-audit, not with more prompt prose. Rationale: prose guidance already existed and failed; the repo's proven pattern is deterministic scripts wired into gates (decision-coverage, criteria-coverage, acceptance-lint). Alternatives considered: prompt-only reinforcement (rejected — it is the thing that failed); a regex hook that blocks capability-language ("cannot", "not supported") in artifacts (rejected — hopelessly false-positive prone as a blocker; semantic detection belongs to the challenger, structural enforcement to the lint).
- Decision: the lead/orchestrator runs all probes; teammates cite evidence they are handed. Rationale: spec-writer, planner, challenger, and advocate have no Bash tool by design (write-scope containment); centralizing probes in the lead preserves that boundary and keeps probes under the session's permission mode. Alternatives considered: granting Bash to spec-writer/planner (rejected — widens the blast surface the agent tool allow-lists exist to contain).
- Decision: probes are read-only, always. Rationale: design phases must never mutate external systems; a probe that writes is an action, not evidence. Alternatives considered: none viable.
- Decision: an unverifiable claim is written as `ASSUMPTION: <claim> | verify: <command>` — never as fact — and in autonomous styles this never blocks on a user question. Rationale: the goal is grounding "autonomously, without user prompting"; this matches the existing autonomous-mode contract (self-answer, record, proceed). Alternatives considered: escalating unverifiable claims to the user (rejected for auto/review-only styles — violates the no-block contract; step/interactive styles may still surface them conversationally).
- Decision: the evidence ledger lives at `docs/loop-spec/features/{slug}/EVIDENCE.md` and is committed alongside SPEC.md/PLAN.md. Rationale: the audit trail is the point — a reviewer must be able to see which probe backed which claim after the fact; `.loop-spec/features/*` transcripts are gitignored per-machine churn, artifacts under `docs/` are the committed record. Alternatives considered: `.loop-spec/features/{slug}/evidence.md` (rejected — gitignored, trail dies with the machine).
- Decision: the machine-readable challenger marker is the fixed prefix `UNGROUNDED:` followed by a verbatim quote. Rationale: the lead needs a deterministic way to extract grounding findings from free-prose critique; fixed string contracts are the repo's existing coupling mechanism (contract-strings.test.sh pins both sides). Alternatives considered: structured JSON critique output (rejected — bigger change to the debate protocol than the feature needs).

## Spec coverage

- `lib/evidence.sh add <ledger> <claim> <command> <output>` appends a well-formed entry, assigns sequential `EVID-NNN` ids, is idempotent on identical claim+command (returns the existing id), and `list`/`next-id` behave; proven by `bash tests/lib/evidence.test.sh`. -> task-001
- `lib/grounding-lint.sh <artifact> [ledger]` strips complete (multi-line) `<!-- ... -->` comment blocks first and validates only `- `-prefixed lines inside the `## Grounding` section; it exits 1 (with `FLAG <artifact>:<lineno>:` lines) on: missing `## Grounding` section; a malformed grounding bullet; an `EVID-NNN` reference anywhere in the artifact with no ledger entry; an `ASSUMPTION` bullet whose `verify:` command (split on the LAST ` | verify: `) is absent or fails `bash -n`; a whole-word `UNVERIFIED` inside the `## Grounding` section; `- none` mixed with evidence bullets. Exits 0 on a well-formed artifact including the bare `- none` form AND on a section that is byte-identical to the artifact-template block (4-line comment + `- none`); proven by `bash tests/lib/grounding-lint.test.sh` (fixtures include the template block verbatim and a `|` inside a verify command). -> task-001
- `skills/shared/artifact-templates/SPEC.md.template` and `PLAN.md.template` contain a `## Grounding` section. -> task-002
- `skills/shared/grounding-protocol.md` exists and defines the claim taxonomy (codebase / external-system / ecosystem / user-stated), the probe-before-assert rule, read-only probe examples, the `ASSUMPTION: ... | verify: ...` fallback, and the ledger format. -> task-002
- `agents/spec-writer.md` and `agents/planner.md` require every load-bearing external-system fact to cite an `EVID-NNN` ledger entry or be written as an explicit `ASSUMPTION`, and list a missing/defective `## Grounding` section as an artifact defect. -> task-003
- `agents/challenger.md` and `skills/shared/team-prompts/challenger.md` define the Ungrounded-claim issue class with the `UNGROUNDED: "<verbatim quote>"` output marker and a suggested read-only probe per finding. -> task-003
- `skills/discuss/SKILL.md` (a) instructs probe-before-assert during the Step 1 loop, (b) passes the evidence ledger path in the spec-writer brief, (c) maps `UNGROUNDED:` findings to lead-run probes + `lib/evidence.sh add` + writer re-dispatch in Step 5, and (d) runs `lib/grounding-lint.sh` as a blocking gate before the Step 6 commit, re-dispatching on exit 1 under the existing retry budgets; the Step 6 commit includes `EVIDENCE.md` when present. -> task-004
- `skills/plan/SKILL.md` runs `lib/grounding-lint.sh` on PLAN.md in the Step 5.5 gate cluster with the same blocking/re-dispatch handling, the planner brief carries the ledger path, and the plan critique's fix-list synthesis maps challenger `UNGROUNDED:` findings to lead-run read-only probes + `lib/evidence.sh add` + planner re-dispatch, exactly as DISCUSS Step 5 does. -> task-004
- `skills/spec/SKILL.md` Step 1 scout enumerates external systems named in the ask and probes factual premises (read-only) before treating them as fact, with the autonomous-mode fallback (unverifiable -> recorded `ASSUMPTION`, no user question). -> task-004
- `tests/contract-strings.test.sh` pins both sides of the new couplings: `grounding-lint.sh"` in discuss+plan skills, `evidence.sh" add` in spec+discuss+plan skills, `UNGROUNDED:` in challenger agent + team prompt + discuss skill + plan skill, `EVID-` in `lib/evidence.sh` + `lib/grounding-lint.sh`. -> task-005
- `bash tests/run-all.sh` passes with the two new suites registered. -> task-001, task-005

## Test strategy

Offline-only. task-001 ships two TDD unit suites (tmp-dir fixtures, no network, no
graphify) registered in run-all; task-003/004 rely on the existing validators
(validate-agents, skill-references); task-005 closes with the full
`bash tests/run-all.sh`. Every wave commit keeps run-all green.

## Rollback plan

Each wave is one commit on `feat/grounded-claims`; revert the branch (or
`git revert` individual wave commits — waves touch disjoint files). No data
migrations; the new gate only activates for features whose artifacts contain the
new section, and old specs are out of scope, so reverting cannot strand state.

## Grounding

- none (plan touches only repo-internal files; premises cite repo paths/lines
  verified during planning)
