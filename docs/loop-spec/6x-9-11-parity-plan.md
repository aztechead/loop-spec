# Plan: 6.9.1–6.11.0 parity on v7 (7.2.0)

For the auditor of this change and the implementer after a `go`. The 6.x commits in
`v6.9.0..v6.11.0` (PRs #110, #111, #112) were reviewed item by item against `v7`. Most
are covered by 7.1.0 or cannot occur in 7.x. This plan fixes the rest in v7's own
terms: the program checks facts, roles judge, and nothing copies a 6.x script. Paths are
under `skills/loop-spec/program/loop_spec/` unless given in full.

## Items fixed

G1 (6.9.1 suite gate, confirmed by probe). Fingerprint fallback, `baseline.py`:
- `_SUMMARY_LINES` pytest shape misses the long-run suffix: `== 87 failed, 2611 passed
  in 123.45s (0:02:03) ==` normalizes to `... in <TIME> (0:<LINE>) ...` and keeps its
  counts. Accept an optional ` (<digits>:<LINE>)` / ` (H:MM:SS)` after `<TIME>`.
- jest `Test Suites: 1 failed, 40 passed, 41 total` keeps counts (regex only `Tests?:`).
  Widen to `^(?:Tests?|Test Suites|Snapshots):`.
- `fingerprint_candidates` keeps `tests/error/test_a.py::test_b PASSED` (the id holds a
  failure word). Drop a raw line whose status token (last word, or a leading `ok `/`✓`)
  is a pass token: `PASSED`, `ok`, `✓`, `PASS`.
- `NORMALIZATION_VERSION` 2 -> 3; `controller.check_compatible` already refuses a resume
  across versions (verify it compares against the constant, not a literal).

G2 (6.11.0 lead-facing hints, 5d51bbb). About 19 `LoopSpecError.repair` strings name a
bare `` `loop-spec <sub> ...` ``, which is not on PATH in a consumer repo and lacks the
run's `--state-home` (the stubs pass the plugin data dir, so a bare `status` looks in
`~/.loop-spec` and finds nothing). Fix once at the boundary: `cli.main`'s
`LoopSpecError` handler rewrites each `` `loop-spec <sub>`` in the repair text to
`` `<launcher> <sub> --project-root <root> --state-home <home>`` using this call's
args (launcher = `Path(__file__).resolve().parents[1] / "loop-spec"`, home =
`state_home(args.state_home)`), only for a subcommand that takes those flags. The stub
operator lines (`loop-spec submit ...`, `loop-spec answer ...` in each
`skills/*/SKILL.md`) name the full launcher path with the same two flags, as the lead
lines already do. One test: a repair naming `loop-spec status` comes out with the
launcher path and both flags.

G3 (6.11.0 remediation lines). A failed-verdict remediation's reason
(`execute._handle_rewind`, ~960) carries the verifier's cause and command but not what
the program's own re-run saw. Append up to 20 lines from
`baseline.describe_failure` over `store.state["verifyRuns"][criterion]["rerun"]` (the
program's run, not the verifier's claim), with a Comparison whose new identities are
that run's failure identities (so a parsed run lists ids, an unparsed one its tail),
when that entry exists and its re-run failed. Check remediations already do this.

G4 (6.11.0 cached validation). `controller._run_verify_reruns` reuses a prior re-run on
matching repo, sha and command, but not `prepare`: a plan-gap rewind that changes the
prepare command at an unchanged head reuses a run made under the old prepare. Record
`prepare` in the entry and require it to match.

G5 (6.9.1 PR title). `deliver.pr_title` collapses whitespace (`" ".join(title.split())`)
before the 70-character cut, so a goal with a newline gives a one-line title.

G6 (6.10.0 existing-code lookup). 6.10.0 made the planner record, per concept the
feature adds or changes, whether it reuses, extends, or adds new code, citing
`path:lines`, and made tasks read the cited code. v7 has the probes (`probes.named`,
review-time duplication) and prose ("reuse before you plan a new module"), but no
recorded decision and no check. v7 form:
- PLAN product (`schemas/plan.json`, identical copy `roles/planner/schema.json`) gains
  required `existingCode`: array of `{concept, decision: "reuse"|"extend"|"new", repo,
  cites: [{path, lines: "a-b"}], tasks: [task ids], reason}`. May be empty only when the
  plan adds nothing (the planner says so; not program-checked).
- New postcondition P8 (program facts only): every entry names a repo in state and task
  ids in the plan; a `reuse`/`extend` entry has at least one cite; every cite's path
  exists at that repo's plan SHA (base, or adopted head; same SHA `_phase_probes` uses)
  and its line range is within the file (read with `git show <sha>:<path>`, no working
  tree); a `new` entry has a non-empty `reason` (what was searched). Add to
  `ROUTES["plan"]["ready"]`, `external.POSTCONDITION_TEXT`, `phase-interface-7.0.md`
  (P-table and plan product fields) in the same diff.
- Planner SKILL: a procedure step to fill it (search the repo for each concept; cite
  what exists; `new` only with the search stated). Plan-critic role text: a `new` entry
  whose concept the cited or named code already does is a Critical miss only if it
  would duplicate required behavior; otherwise not its concern.
- Implementer inputs (`execute.py` ~470): `existingCode` entries whose `tasks` include
  the task, so the implementer reads the cited ranges first. Implementer SKILL says so.
- DEBUG and REVISE products embed or produce PLAN tasks: the auditor to confirm whether
  their schemas (`schemas/debug.json`, `schemas/revise.json`) and compaction path feed
  P8; if a compacted PLAN half is checked by P8, those roles must write `existingCode`
  too (possibly empty with the same rules).

## Items not changed (with reason)

- Repo checks forced into `checks` (6.11.0 opt-in integration checks): v7 already runs
  planner-named checks at every integration and at VERIFY (7.1.0); 6.x made them
  opt-in, so a planner choice is the same contract. No new P-row.
- Stuck note on repeated re-announces (c57cdce): `continue_run` is idempotent and every
  loop is bounded by `retry_limit` and T1; a lead that never dispatches is a lead
  failure the stub text already forbids.
- Non-Critical critic residue in the PR body: v7 blocks only on Critical by design
  (ROADMAP 2026-09-22); rejected Criticals are already listed.
- Checkpoint PR title/head, moved SPEC.md, RULES.md paths, pattern-mapper removal,
  nonce, round ceiling, merge-base pre-existing check, `env -i`: the 6.x mechanism does
  not exist in 7.x (program-built products, attested steps, program baseline).

## Version and docs

7.2.0 (P8 is a new postcondition and a product field) in the four version places plus
CHANGELOG. `live-runs-7.0.md` row for one live cycle on a fixture where the request's
concept already exists in the repo (expect a `reuse`/`extend` entry that passes P8).

## Tests (one per behavior)

- test_baseline: long pytest summary, jest `Test Suites:`, PASSED line with failure word.
- test_cli (or test_controller): repair rewrite.
- test_execute: failed-verdict remediation reason carries the re-run's lines.
- test_controller: rerun not reused when prepare changed.
- test_deliver: newline title.
- test_postconditions: P8 pass; cite path missing; line range past EOF; `new` without
  reason; unknown task id.
- Full suite green.

## Questions for the auditor

- Does any code or test compare `NORMALIZATION_VERSION` by literal, or store fingerprints
  that a v3 bump would silently mismatch outside `check_compatible`?
- Which subcommands' parsers take `--project-root`/`--state-home` (so G2 rewrites only
  those)? Any repair string whose `loop-spec` mention is not a command?
- G6: is P8 reachable for debug/revise compaction products, and does `plan.json` have
  `additionalProperties: false` so an old product without `existingCode` fails P1 on
  resume (acceptable, or needs `check_compatible`)?

## Revision 1 (after audit round 1)

All audit findings adopted; where this section and the text above differ, this wins.

- G6 schema: `existingCode` is OPTIONAL in `schemas/plan.json`, `roles/planner/schema.json`,
  and the embedded plan defs `schemas/debug.json` `$defs.plan` and `schemas/revise.json`
  (same shape everywhere; `test_schema.py` debug equality keeps pinning it). Entry:
  `{concept, decision: reuse|extend|new, repo, cites: [{path, lines: "^[0-9]+-[0-9]+$"}],
  tasks: [ids], reason (minLength 1)}`, `additionalProperties: false`. The planner SKILL
  step and its `## Example` (one `reuse` entry) make the planner fill it; the debugger
  and reviser Examples are unchanged.
- P8 (program facts, only over entries present): repo in `state.repos`; every task id is
  in the plan; a `reuse`/`extend` entry has at least one cite; each cite's path resolves
  with `repo_module._git(repo, "show", f"{sha}:{path}")` at the base/adopted SHA (the
  `_phase_probes` rule) or, when `state["execute"]` exists, at that repo's current
  execute head; `a <= b <= line count`. `reason` non-empty is schema (P1), not P8.
  P8 is added to `ROUTES["plan"]["ready"]`, `ROUTES["debug"]["reproduced"]`,
  `external.PHASE_POSTCONDITIONS["plan"]` and `POSTCONDITION_TEXT`, and the
  `phase-interface-7.0.md` P-table plus the "P1 to P7" mentions (rows ~145, ~315).
- Implementer input: `execute._implement_request` (`execute.py:457-478`) adds
  `inputs["existingCode"]` = entries whose `tasks` include the task (omitted when none).
- G1 regexes (applied after `_LINE_NO`/`_TIME`):
  pytest `^[=\s-]*\d+ \w+(?:\s*[,|]\s*\d+ \w+)*(?: in <TIME>(?: \(\d+:<LINE>\))?)?[=\s-]*$`;
  unittest unchanged; jest `^(?:Tests?|Test Suites|Snapshots):\s+.*\b\d+ total$`;
  vitest `^(?:Test Files|Tests)\s+\d+ \w+(?:\s*\|\s*\d+ \w+)*\s*\(\d+\)$`;
  cargo `^test result: \w+\. \d+ passed; \d+ failed;.*$`. Pass lines: drop a raw line,
  ANSI-stripped first, matching `^\s*(?:ok\b|✓|√|PASS\b|--- PASS:)|\bPASSED\b|\.\.\. ok\s*$`
  before `_FAILURE_MARKER`. Fix the comment that claims vitest coverage. Version 3.
- G2: rewrite only when `getattr(args, "project_root", None)` is set;
  `re.sub(r"`loop-spec (status|cycle|micro|debug|revise|spec|plan|execute|verify|iterate|deliver|submit|answer)\b", ...)`
  inserting the launcher, subcommand, `--project-root` and `--state-home`, each
  `shlex.quote`d. Stub operator lines in all 12 stubs use the full launcher line.
- G3: append the re-run's lines only when `rerun["sha"] == feature_head`.
- G4: reuse requires `prior.get("prepare") == prepare` (an old entry without the key
  still reuses when prepare is None).
- Tests add: `test_schema` minimal plan with one `existingCode` entry; the planner
  Example validated by `test_roles`.
