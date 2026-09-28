# Plan: close the 6.9.x report items still open on v7 (rev 4)

For the auditor of this change. Base `v7` @ `1ea45a9` (7.0.7); target 7.1.0. `P/` =
`skills/loop-spec/program/loop_spec/`, `R/` = `skills/loop-spec/roles/`. Rev 1's audit is
`6x-reports-plan-audit.md`; each item below names the audit finding it answers (A-W1.3 = W1
finding 3). Design rule for every item: the program observes facts and checks postconditions;
roles judge with those facts as inputs; nothing is ported from 6.9's shell.

## Rev 4 changes (answer the rev-3 audit; supersede R3-0, R3-5, R3-6, R3-13 where named)

R4-1 (blocking U1) Compatibility is checked before any run-state work. One function
`controller.check_compatible(store)`: for each repo baseline under `baseline.repos` (and a
legacy flat baseline via `baseline.repo_baseline_dict`'s rule), a `normalizationVersion` that is
present and differs from `NORMALIZATION_VERSION` raises the R3-0 error; `baseline is None` or a
repo with no baseline passes (never defaulted to v1). Called by `cli.py` immediately after it
opens a run's `StateStore` and before ANY other call, for every command that operates on an
existing run: `submit` (before `steps.submit` / `route_submission`), `answer` (before
`questions.answer` persists), `cycle`/`micro`/`debug`/`revise` resuming by slug or request,
and `phase`/entry commands (before `_enter`'s state mutation); `continue_run` keeps a defensive
call. Tests: the real CLI submit sequence on a v1-baseline run raises before any executeRuns
write or merge (state.json digest unchanged); `answer` on such a run leaves no answer recorded;
a baseline-free run continues normally.

R4-1a (rev-4 audit correction 1) Guard placement, exact: (i) `controller.run_entry`'s explicit
phase-entry branch calls `check_compatible` right after it opens the store (controller ~83) and
before the preconditions and phase mutation/save; (ii) the request-based and adopted-PR resume
branches (controller ~113-116 and ~213-216) open the store and call `check_compatible` BEFORE
clearing the result pointer (the pointer cleanup moves after the check); (iii) `cli.py`
`_open_store` calls it for `submit` and `answer` before `steps.submit` / `questions.answer`;
(iv) `continue_run` keeps the defensive call. The literal `phase` command opens no run store and
needs none.

R4-2 (blocking) Summary regex with separator whitespace:
`^[=\s-]*\d+ \w+(?:\s*[,|]\s*\d+ \w+)*(?: in <TIME>)?[=\s-]*$`. Positive fixtures, exactly:
`9 failed | 690 passed`, `== 3 failed, 12 passed in 0.41s ==` (after <TIME>),
`FAILED (failures=1, errors=2)`, `Tests: 9 total` (and `Tests:       2 failed, 7 passed, 9 total`).
Negative fixtures: `AssertionError: expected 1 errors` vs `... 2 errors` stay distinct;
`mod.py:3:1: F401 ...` untouched.

R4-3 R3-5 wording branch: `_handle_rewind` picks the "criteria failing" text only when one of
`rem["criteria"]` has a verdict whose `verdict == "fail"` in that rewind; otherwise the
source-neutral "VERIFY remediation <id>: <title> at <head12>; files: ..." text.

R4-4 Collector checkouts use a fresh suffix per execution (`check-<repo>-<head12>-<uuid8>`),
removed in `finally`; an interrupted one is never reused (G3-2).

R4-5 E7 wording (`external.POSTCONDITION_TEXT` E7 and phase-interface E7): the "at least one
parsed identity" part of featureAdded's meaningful success applies to test runners, not the
diagnostics parser. The V10 row also appears in the `passed` Requires cell.

R4-6 L1 evidence (G3-1): inspect `state.checkRuns[repo][command]` (head, planRevision,
baselineCapturedAt, verdict `no-regression`) and the accepted VERIFY `passed` under V10; the
rev-2 "VERIFY product checks rows / V9" line is void.

Not in scope, reported as a follow-up: `verify._verify_checkout` is keyed by head only, so two
workspace repos at one SHA share the verifier checkout (pre-existing; collector checkouts are
repo-scoped by R4-4).

## Rev 3 changes (supersede the rev-2 text they name; rev-2 audit ids N-*)

R3-0 Upgrade boundary (answers N-W3.1, N-W3.2, A-W1.6 and A-W3.2 residue, N-T.1 item 3/8).
A run is never resumed across a change in comparison semantics. `NORMALIZATION_VERSION` (bumped
to 2 by W3, covering the new diagnostics parser too) is recorded on each baseline already;
`controller.continue_run` (the one resume entry) refuses, before driving any phase, a run whose
stored baseline `normalizationVersion` differs from the program's: `LoopSpecError("this run's
baseline was captured by comparison rules vA; this program uses vB", repair="finish the run on
the loop-spec version that started it, or start a new run")`. So no executeRuns / verifyRuns /
checkRuns / critic-fact migration exists or is needed; W3.2's "version guard in
compare_to_baseline" stays as a defensive assertion (returns `baseline-error`) and W3.3's
PLAN-exit recapture is DROPPED. Rev 2's sentence "evidence_matches compares identities only"
is withdrawn (it also compares exit status and an optional normalized digest). Checks are
optional in PLAN, so a run started on 7.0.x has no checks and no check gate applies to it.

R3-1 Check gate id and routes (N-W1.1). The gate is a new id **V10**; V9 is untouched.
Updated together: `postconditions` method `_v10`, `ROUTES["verify"]["passed"]`,
`external.PHASE_POSTCONDITIONS`, `external.POSTCONDITION_TEXT` (V10, and the P3/P6 strings
extended for checks), phase-interface rows P3, P6, V10, and the `implementation gap` row gains
"or a program check run regressed (a remediation per regressed check)".

R3-2 One program-owned check collector (N-W1.2, N-W1.3; replaces W1.7's "_init" placement and
drops the VERIFY product `checks` field). `controller._ensure_check_runs(store, paths)`: for each
repo with plan checks, at that repo's verified head, for each check command: reuse
`store.state["checkRuns"][repo][command]` only when its `head`, `planRevision` and baseline
`capturedAt` all match; otherwise run it in a disposable `clean_checkout` named
`check-<repo>-<head12>-<n>` with the plan's `prepare` run first, removed after (never the
verifier's reusable checkout), compare to the repo's baseline entry, store
`{head, planRevision, baselineCapturedAt, run, comparison}`. Called (a) by default VERIFY
`_init` before the verifier prompt so `checkRuns` are verifier input facts and product assembly
builds remediations from them, and (b) by the controller before VERIFY's boundary check for
every implementation (default or external). V10 reads only these records: for exit `passed`,
every plan check of every touched repo has a record at the current head/planRevision/baseline
with verdict `no-regression`. External VERIFY that claims `passed` over a regressed check is
rejected by V10 with the check named; its implementer must return `implementation gap`.

R3-3 Check baseline validity and duplicates (N-W1.4). P3 (baseline part) requires for every
check: an entry in its repo's baseline, `status == "ran"`, non-null run, no `errorClass`, exit
status != 127 (the same rule as a non-featureAdded verify). P6 rejects duplicate
`(repo, command)` pairs in `checks` and a check equal to a featureAdded verify command in the
same repo (moved from P3 to P6 so it runs before capture).

R3-4 Facts from the right tree (N-W1.5). `repo_checks_probe(repo_path, sha)` reads manifests
from git objects (`git ls-tree -r --name-only <sha>` + `git show <sha>:<path>`), never the
working tree: PLAN and DEBUG at the repo's `baseSha`, REVISE at the adoption `headSha` for the
adopted repo (base for others). Each fact carries `{tool, source, sha}`. PLAN, REVISE and DEBUG
inputs all gain `repos: {name: {path, baseSha}}`.

R3-5 Check remediation mapping and wording (N-W1.6). A check remediation is
`{"id": "R-<n>", "title": "check <command> regressed: <first 3 diagnostics>", "files": [paths of
the new diagnostics], "repo", "criteria": owner's criteria, "verify": "", ...}`; EXECUTE's
existing mapper (repo + criteria, narrowed by files) picks the owner(s); several owners are
acceptable (each reopens). `execute._handle_rewind`'s no-failed-criterion reason becomes
source-neutral: "VERIFY remediation <id>: <title> at <head12>; files: ..." (LF-64's Critical
text keeps its finding id inside the title, so it loses nothing).

R3-6 Summary-only count normalization (N-W3.3; replaces W3.1's regexes). A line's counts are
replaced only when the WHOLE line matches one supported summary form:
`^[=\s-]*\d+ \w+(?:[,|] \d+ \w+)*(?: in <TIME>)?[=\s-]*$` (pytest/vitest banners, after the
existing <TIME> substitution), `^FAILED \((?:\w+=\d+(?:, )?)+\)$` (unittest),
`^Tests?:\s+.*\b\d+ total$` (jest). Any other line keeps its digits. Negative tests: two
assertion lines differing only in a count stay distinct; diagnostics messages are not touched.

R3-7 W4 observation guards (N-W4.1). The failing-criterion observation runs only when: the
verdict's evidence is non-null, its command passes `shell_syntax`, its repo is a run repo equal
to the pass record's repo, the criterion is not a resolved evidence exception (checked before
any command runs), the requirements revision equals the pass record's, and the pass sha is an
ancestor of the program's verified head for that repo. It runs at the program's head, never the
claimed sha. Any unmet condition skips the hint with an event
`failure_observation_skipped {criterion, why}`; it never rejects or blocks VERIFY.

R3-8 One observed head per repo in DELIVER (N-W5.1, N-W5.2, N-W5.3).
- Paths: protected = `git diff --name-only -z --no-renames <base> <verified>`; extension =
  `git log -z --no-renames -m --name-only --format=%x01%H%x02%s <verified>..<head>` parsed on
  NUL/\x01/\x02; fnmatch on the raw repo-relative path. The guarantee stated in docs: accepted
  commits never touch a path the verified change (base..verified, final tree) changes, and every
  path they touch, in any commit, matches the allowlist.
- D1 computes the repo's observed head O: `deliveredSha` when the remote head equals it, else
  the recomputed extension head when accepted; the product row's `acceptedRemote` must equal the
  recomputed facts exactly (head, commits, paths). D2 requires PR headRefOid == O (not "either").
- deliver.run records an accepted extension in publication history immediately after accepting
  it, before `_reconcile_pr`. History records gain `observed: true` for push-skipped entries;
  failed-row wording says "observed <sha> on the remote (no push)" vs "pushed <sha>";
  `schemas/deliver.json` `publishedSha` description updated to "pushed or observed".

R3-9 PR body edit contract (N-W6.1). `_reconcile_pr` returns `(pr, error, caveats)`; only lookup,
create and view failures are `error`; a failed `gh pr edit` is a caveat and the PR is kept. The
critic section renders only when `state["critic"]["planRevision"]` equals the accepted plan
revision.

R3-10 W2 formatter (rev-2 audit W2 note). One pure `baseline.describe_failure(comparison, run,
limit=20) -> list[str]`: parsed identities when the run has a parser and `new_identities` are
identities; `fingerprint_lines` for fallback hashes; `tail` otherwise. Used by the retry reason
and the check remediation title; routing functions only call it.

R3-11 Docs (N-W7.1): also inventory :153 (`commitArtifacts`), :199 and :249 (prepare is PLAN's),
:246 (exact-SHA delivery + opt-in extension); ROADMAP PLAN and VERIFY rows (checks; V10) and the
featureAdded meaningful-success bullet (test runners only).

R3-12 Tests (N-T.1), added to the rev-2 list: V9 behavior unchanged; V10 via controller for an
external VERIFY product; resume refused on a v1 baseline (R3-0); check-only plan amendment gets
fresh check runs (planRevision key); adopted task not reimplemented while its repo's checks run;
check run at a merge-commit head and after a committing close-out; two workspace repos at one
SHA get separate check checkouts; check baseline missing/127 rejected by P3; duplicate checks
rejected by P6; summary negative fixtures; W4 skip reasons (null evidence, exception, stale
requirements, non-ancestor); D1/D2 with PR at V while remote accepted H -> D2 fails; product
`acceptedRemote` with invented paths -> D1 fails; history persisted when PR create fails after
an accepted extension; NUL path parsing with a space and a rename; PR edit failure keeps the PR.

R3-13 Live evidence (N-T.2). Each live row's evidence dir keeps events.jsonl, result.json,
program-commit.txt, the final state.json, the fixture's config + request text, and the step
prompts/results the row cites (PLAN step instructions with repoChecks, the implementer step,
the VERIFY product). L2 is recorded as "not demonstrated" and stopped if: `gh pr checks` exits 0,
DELIVER never reaches the blocked question, or an earlier phase blocks on evidence. Manual
answers are question-scoped (`--scope question`), never `run`.

## W1. Repo checks (lint / typecheck / format check)

Redesigned after A-W1.6/7/8: the authoritative gate is ONE program-run check pass at the
verified head in VERIFY (covers merge commits, close-outs, adopted tasks, check-only plan
changes, legacy state: it is keyed by head and always recomputed for the current plan). Checks
at task integration stay, as early feedback only (no postcondition reads them).

1. Probe delivery (A-W1.1). `P/probes.py`: `repo_checks_probe(root) -> list[{"tool", "source"}]`
   (`source` = repo-relative file, plus the script name for package.json). Detected from:
   `pyproject.toml` `[tool.ruff]`/`[tool.mypy]`/`[tool.pyright]`, `ruff.toml`, `.ruff.toml`,
   `mypy.ini`, `.mypy.ini`, `pyrightconfig.json`, `tsconfig.json`, `package.json` scripts
   `lint`/`typecheck`/`type-check`/`format:check`. `P/controller` context builder (line ~438):
   `"probes"` stays `{}` for every phase except `plan`, `revise` and `debug` compact-plan
   producers, which get `{"repoChecks": {<repo name>: [...]}}` computed per `state.repos` path.
   `P/defaults.py` PLAN inputs gain `"repos": {name: {"path"}}` (A-W1.1, the planner prompt
   already names `inputs.repos`). `P/revise.py` and `P/debug.py` role inputs gain the same
   `probes.repoChecks`. `plan_probes` (unwired today) is NOT wired in this change; reported as
   a follow-up.
2. Schemas (A-W1.2, A-W1.3). `checks` is OPTIONAL everywhere (absent == `[]`), so an old accepted
   product, a pending result and its `plan_revision` hash are unchanged. Item shape
   `{"repo": nonempty string, "command": nonempty string}`, `additionalProperties: false`.
   Files: `P/schemas/plan.json`, `R/planner/schema.json`, `P/schemas/revise.json` +
   `R/reviser/schema.json` (their plan object), `P/schemas/debug.json` + `R/debugger/schema.json`.
   SKILLs: planner (step on checks + example `"checks": []`), reviser and debugger (one line:
   carry the prior plan's checks / name configured checks; example gains `"checks": []`).
3. Validation before capture (A-W1.4, A-W1.5). P6 also rejects a check whose repo is not a run
   repo or names a repo no task uses ("a check runs in a repo a task changes"). Single-repo
   alias normalization (controller ~563) also rewrites `checks[].repo`. P3 form check covers
   check commands. P3 rejects a check command that equals a `featureAdded` task's verify
   command in the same repo ("use a different command for the check").
4. Diagnostics parser (A-W1.9), narrow and tested: `detect_runner` -> `"diagnostics"` for argv
   tool basenames `ruff`, `mypy`, `tsc`, `flake8` (after `uv run`/`npx`/`python -m` prefixes, the
   same scan as today). `parse_diagnostics`: `path:line[:col]: message` (ruff concise, mypy,
   flake8), `path(line,col): message` (tsc --pretty false), `Would reformat: path`
   (ruff format --check). Identity `"<path>: <message>"`, path with the run root stripped,
   message through `_normalize_line`. Registered in `PARSERS`; `_TESTS_RAN_PATTERNS` entry that
   never matches; `compare_to_baseline`'s featureAdded "no test ran" rule applies only to test
   runners (not `diagnostics`). Any other check command (e.g. `npm run lint`) uses today's
   fingerprint fallback. Documented in planner SKILL and ROADMAP §11.
5. Baseline. `controller._capture_plan_baseline` adds each check as `(command, None, None)`
   to its repo's list (after tasks' commands; collisions already rejected by 3).
   `_critic_baseline_facts` adds one fact per check (`{"check": command, "repo", ...same run
   fields}`) so the critic judges check baselines too (A-W1.9).
6. Early feedback at integration. `P/execute.py` integration, after the verify comparison
   branch (so close-outs too, A-W1.7): run each check of the task's repo at `run_cwd`/`task_head`,
   compare with its baseline entry; a regression routes through `_route_verify_comparison`
   (implementer retry with the diagnostics, W2); `baseline-error` -> plan gap as today. Stored
   `executeRuns[task]["checks"][command]`, read by nothing but the retry and the event log.
   Implementer inputs gain `checks` (its repo's commands); implementer SKILL: run them with the
   task's verify before committing; fix what the change introduced, leave pre-existing ones.
7. Authoritative gate in VERIFY (A-W1.6/7/8). In `P/verify.py` `_init` (where heads/checkouts
   are set up), for each touched repo, run each plan check at the verified head in the existing
   verify checkout (prepare already applied there), compare with the baseline, store
   `verify_state["checkRuns"][repo][command] = {head, run, comparison}` (recomputed whenever
   module state is re-initialized for new heads, which is the existing trigger). Verifier inputs
   gain `checkRuns` (read-only facts). Product assembly: each regressed check becomes a
   remediation task exactly like LF-64's Critical-finding remediation (owner = plan task whose
   `files` contain the first diagnostic's path, else the repo's last task; `criteria` = owner's;
   title `fix check <command>: <first diagnostics>`), exit `implementation gap`. VERIFY product
   gains `checks: [{repo, command, head, verdict}]` (schema `P/schemas/verify.json`).
   New V-postcondition V9 (phase-interface doc + `external.POSTCONDITION_TEXT` +
   `postconditions.ROUTES` for `passed`): every plan check of every touched repo has a program
   check run at that repo's verified head with verdict `no-regression`, and the product's
   `checks` rows equal those program records. `baseline-error` for a check -> exit `plan gap`.
8. Docs: phase-interface P3/P6/V9 rows; ROADMAP §11 bullet 1 ("plus the repo checks the PLAN
   product names from the program's repoChecks facts") and the prepare bullet (prepare comes
   from the PLAN product, A-W7.2); migration-inventory :184, :251, :399 reworded per A-W7.2.

## W2. Retry reason carries the failures

1. `CommandRun` gains `fingerprint_lines: dict[str, str]` (hash of the FULL normalized line ->
   display text cut at 300 chars; at most 50, the rest counted in `omitted_lines: int`) and
   `tail: list[str]` (last 20 normalized nonempty lines, 300 chars each). Both serialized in
   `to_dict`, defaulted (`{}`, `0`, `[]`) in `from_dict` for old state, dataclass defaults set.
2. `_route_verify_comparison(execute_state, task_id, task_state, comparison, run, label)`:
   reason = `"<label> <command>: <verdict>: <detail>"` then up to 20 lines: parsed identities,
   else `fingerprint_lines` for the new hashes, else `tail` (covers mustFlip, featureAdded
   nonzero, incomplete runs; A-W2.2); "(N more not shown)" when capped. Same helper builds the
   VERIFY check remediation title text.

## W3. Fallback fingerprints strip summary counts

1. `_SUMMARY_COUNT = re.compile(r"\b\d+\s+(passed|failed|errors?|skipped|warnings?|deselected|xfailed|xpassed|tests?)\b", re.I)`
   -> `<N> \1`; `_KEYED_COUNT = re.compile(r"\b(failures|errors|skipped|total|tests)(=|:\s*)\d+\b", re.I)`
   -> `\1\2<N>`. Supported and tested shapes: `9 failed | 690 passed`, `== 3 failed, 12 passed in 0.4s ==`,
   `FAILED (failures=1, errors=2)`, `Tests: 9 total`. Nothing else numeric changes (A-W3.3).
   `NORMALIZATION_VERSION = 2`.
2. Version guard wherever fingerprints decide (A-W3.1): in `compare_to_baseline`, before the
   incomplete-run fingerprint equality and before the fallback set difference, a version
   mismatch returns `baseline-error` ("baseline normalization vA, candidate vB").
3. Recovery (A-W3.2): `baseline-error` already routes to plan gap. The PLAN-exit capture trigger
   (controller ~850) also recaptures when any repo baseline's `normalizationVersion` differs
   from `NORMALIZATION_VERSION`, so an unchanged plan re-entry refreshes it at the same base
   SHAs; critic facts are recomputed from the new baseline by the existing identity check.
   `evidence_matches` compares identities only (checked), so VERIFY reruns are unaffected.

## W4. Self-inflicted regression provenance (fact for the implementer)

1. Pass history (A-W4.2). In `_record_accepted_product` for VERIFY exit `passed` only (the one
   exit whose reruns the program ran and matched), for each `pass` verdict with a matched
   `verifyRuns` record that is not an evidence exception: `criterionPasses[c] = {repo, sha,
   command, requirementsRevision, attemptId}`.
2. Failure observation (A-W4.1). `controller`, VERIFY exit `implementation gap`: for each
   `fail` verdict whose criterion has a `criterionPasses` record for the current requirements
   revision and the same repo, not an evidence exception, whose pass sha is an ancestor of the
   verified head: the program runs the verdict's evidence command at the head in a clean
   checkout (the same helper `_run_verify_reruns` uses) and stores
   `failureObservations[c] = {repo, sha, command, attemptId, runner, failureIdentities}`.
   Nothing else is re-run on this exit.
3. Provenance (A-W4.3). `execute._handle_rewind`: for remediation of `c` with an observation
   whose `attemptId` == the rewind's attempt and `sha` == the repo's feature head: failing
   paths by parser (`pytest`: text before `::`; `vitest`/`jest`: text before ` > ` when it ends
   in a test-file suffix; others unsupported -> no hint), repo-relative;
   `added = repo.files_added_by(repo, pass_sha, head)`; intersection non-empty -> reason gains:
   "Fact: <files> were added after <c> last passed at <sha12> and now fail. Decide whether the
   test or the implementation contradicts the approved criteria; change the test only where it
   contradicts an approved criterion, never weaken an assertion a criterion requires, and say
   which you changed." `task_state["provenance"]`, event `failing_test_added_after_pass`.
4. Implementer SKILL: one line for that fact. ROADMAP §10 sentence rewritten to this exact
   mechanism; inventory :279 wording kept (it points at §10). The live record will say the
   judgment half is not shown live (A-T.4).

## W5. DELIVER accepts disjoint remote commits (opt-in)

1. Config `deliver.acceptRemotePaths`: `load_config` validates list of nonempty strings
   (`LoopSpecError` + repair otherwise). fnmatch against repo-relative paths, same list for every
   repo of a workspace. Absent/`[]` = today exactly. README config table gains the key.
2. `P/repo.py` `remote_extension(repo, branch, verified, base, globs) -> dict`:
   `{"state": "absent"|"equal"|"diverged"|"extension"|"error", "head", "commits":
   [{sha, subject, paths}], "paths", "refused": [...], "why"}`. `git fetch origin
   refs/heads/<branch>` (FETCH_HEAD only); fetch failure (other than missing ref) -> `error`.
   Extension paths = every commit in `verified..head`, `git log --format=%H%x00%s --name-only
   --no-renames -m`, so a path touched then restored and both rename sides count (A-W5.3).
   Refused paths = paths outside the globs, plus paths in `git diff --name-only base..verified`.
3. `P/deliver.run` per repo: `deliveredSha` is ALWAYS the verified SHA (A-W5.1). Before push:
   `error` -> failed row; `extension` + no refused -> skip the push, row `acceptedRemote =
   {head, commits, paths}`, caveat "accepted remote commits ... under deliver.acceptRemotePaths;
   no push needed"; `extension` + refused -> failed row naming the refused paths + repair (allow
   only paths the verified diff never touches, or remove those commits; never force);
   `diverged`/`absent`/`equal` -> today's push. After `_reconcile_pr`: `pr.headSha != verified`
   -> recompute; accepted only when the fetched extension head == `pr.headSha` (A-W5.4), else
   failed row "PR head <x> ...". A non-fast-forward push re-checks once (bot pushed between
   fetch and push); still failing -> failed row as today.
4. History (A-W5.5): `_record_published` stores `acceptedRemote`; `_published` carries it into a
   later failed row as "previously accepted remote commits ..." (historical, not re-validated).
5. D1: `deliveredSha == EXECUTE head` always; then remote head == deliveredSha, or
   `acceptedRemote.head` == remote head and `remote_extension` recomputed now is an extension
   with no refused paths and that head. D2: open, head ref, base as today; `headRefOid` ==
   deliveredSha or == the D1-validated `acceptedRemote.head`. `P/schemas/deliver.json` row gains
   optional `acceptedRemote` (`head` sha string, `commits` array of `{sha, subject, paths}`,
   `paths` array; `additionalProperties: false`).
6. Docs: phase-interface D1/D2, `external.POSTCONDITION_TEXT` D1/D2, ROADMAP DELIVER row (~:150)
   and §4 wording distinguishing verified SHA from observed remote/PR head (A-W5.6).

## W6. Rejected Critical critic findings in the PR body

1. `render.pr_body`: `### Plan critic` with each Critical finding of the current accepted plan's
   critic record (`state["critic"]["findings"]`, disposition `rejected`) and its reason; scope is
   the current plan (A-W6.2), stated in the section's first line.
2. Existing PRs (A-W6.1): `_reconcile_pr`, when the PR already exists, runs
   `gh pr edit <n> --body-file <tmp>`; a failure is a caveat on the row, never a failed delivery.

## W7. Docs and release

- migration-inventory :403 `ARTIFACTS_IN_PR` -> removed (R§12; `commitArtifacts` removed on the
  7.0 audit's R8); :184/:251/:399 per W1.8.
- ROADMAP §11 last bullet -> the comparison verdicts the code emits and the already-satisfied /
  zero-commit handling as implemented (execute.py 1241-1265).
- Version 7.1.0 in `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, README
  `Current version:`, every `skills/*/manifest.toml`; CHANGELOG entry (A-W7.1).

## Tests (program seams only; no cycle simulation; ~one per behavior)

W1: probe facts per repo reach PLAN/revise/debug inputs; schemas accept `checks`, reject extra
item keys, accept absence; old product revision unchanged; P6 unknown/taskless check repo; P3
check/featureAdded collision; parse_diagnostics on ruff concise, mypy, tsc, Would reformat;
featureAdded with diagnostics runner not failed for "no test ran"; integration check regression
retries with the diagnostic in the reason (close-out included); VERIFY check regression becomes
a remediation + implementation gap; V9 rejects `passed` with a missing/regressed check run.
W2: fallback lines, tail for empty identities, cap count, from_dict of old run.
W3: four summary shapes stable; version mismatch -> baseline-error in both branches; stale
version recaptured at PLAN exit.
W4: pass recorded only on `passed`; observation only for criteria with a pass; provenance text
when the failing pytest file was added after the pass; no hint for go/cargo identities or a
changed requirements revision.
W5: remote_extension states (absent/equal/diverged/extension/error), refused path (verified
path, non-glob path, touched-then-restored), strict default; D1 keeps deliveredSha==head; D2
with acceptedRemote; history carried into a failed row; config validation.
W6: renderer section; existing PR body edited (gh stub at the run_gh seam).

## Live runs (plugin clone frozen at the commit under test; recorded in live-runs-7.0.md with
run tag, session id, commit, evidence dir with events.jsonl + result.json + program-commit.txt,
attestation levels, terminal result)

L1 checks (local fixture `checks-cli`: uv, ruff + mypy strict configured, unique seed
`f14c1b0`, local bare remote; headless default policy). Must show, from recorded prompts and
state: PLAN step prompt contains `repoChecks` with ruff and mypy; PLAN product `checks` names
them; baseline has their entries; implementer prompt carries `checks`; `executeRuns` has check
comparisons; VERIFY product `checks` rows `no-regression` and V9 passed. Terminal: `escalated`
at DELIVER by policy (local remote). Stop condition: if PLAN names no checks, record that and
treat it as a planner-prompt defect, not a pass.
L2 DELIVER extension on GitHub `loop-spec-live-7`, two separate runs on fresh branches (A-T.3),
lead headless WITHOUT `--answer-policy default` so questions stop the run for the operator
(A-T.2); the operator answers SPEC approval by hand. Config
`{"deliver": {"readiness": "checks", "acceptRemotePaths": ["CHANGELOG.md"]}}`; first confirm by
hand that `gh pr checks` exits nonzero on a PR in that repo with no CI. DELIVER's first product
fails D3 and is retried until the blocked question; while stopped the operator pushes the "bot"
commit on the PR branch and removes `readiness` from the config, then answers
fix-and-re-enter and resumes.
  L2a (positive): bot commit changes only CHANGELOG.md -> expect no push, row `acceptedRemote`,
  D1/D2 pass, `delivered`, terminal `converged`.
  L2b (negative): bot commit changes a verified file -> expect a failed row naming that path,
  `delivery blocked`, operator answers stop -> terminal `escalated`.
W2/W3/W6 and W4's provenance are program paths shown by unit tests; W4's judgment half is not
shown live, and the live record says so.
