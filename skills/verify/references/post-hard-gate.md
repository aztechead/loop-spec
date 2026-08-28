# VERIFY post-HARD-GATE passes (reference)

Extracted verbatim from `skills/verify/SKILL.md` Steps 7.5–7.8; the SKILL stub points
here. Apply as written after both Step 7 gates pass.

Contents: Step 7.5 live-run probes · 7.6 verification-gap · 7.65 plain-language ·
7.66 docs-for-humans · 7.7 project review layers · 7.8 reviewer's guide.

### Step 7.5 - Live-run verify rung (opt-in per repo; ROADMAP-3.0 C1)

Probe-before-assert extended past the suite: when the repo has configured a `verifyCommands` block in `.loop-spec/workflow.json`, launch the app, wait for readiness, and run the acceptance probes — the loop ends at "observed working", not "suite green". Runs ONLY after both Step 7 gates passed (a live probe against known-failing code wastes the launch).

```bash
LIVE_JSON="$(bash "${CLAUDE_SKILL_DIR}/../../lib/verify-live.sh" run \
  --evidence "docs/loop-spec/features/${slug}/EVIDENCE.md")"; LIVE_EC=$?
```

- **Unconfigured** (`configured: false`, exit 0): suite-only VERIFY, unchanged. NEVER guess a launch command here. If the user has not been offered configuration before, `bash "${CLAUDE_SKILL_DIR}/../../lib/verify-live.sh" detect .` may SUGGEST one — in interactive styles offer it once; in autonomous mode record a `decisions.sh` entry that the rung stayed off (suggestion included when detect found one) and move on.
- **Exit 0 with `allPass: true`:** append a "## Live verification" section to VERIFICATION.md listing each probe with its `EVID-NNN` id (the verifier cites evidence ids, never bare claims — the probe outputs are already in the EVIDENCE.md ledger).
- **Exit 1** (never became ready, or a probe failed): emit the `'{"class":"live-probe"}'` failure event, generate one remediation task per failed probe (`subject = "Fix: live probe failed — {probe cmd}"`, `verifyCommand` = the probe), and run the **Remediation teardown** (gate: `live-verify`).

### Step 7.6 - Verification-gap pass

Asks the one question the gates above do not: if the behavior this change produces broke where it is actually used, would any verification fail? Step 1.5 defends the tests that already exist; Step 3 checks that criteria carry verify commands; neither traces NEW behavior out to the sites that observe it.

Ground it in the probe before dispatching, so the reviewer reasons from a measured symbol search rather than recalling one:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/verification-gap-scan.sh" "$baseSha" HEAD || true
```

Exit 1 means no definition changed in a non-test file — record that and skip the pass. Otherwise dispatch one reviewer carrying `${CLAUDE_SKILL_DIR}/../../skills/shared/review-prompts/verification-gap.md` verbatim plus the probe output, on the same maker≠checker terms as Step 6 (never the agent that wrote the code).

Findings are **advisory in this release**: record them in VERIFICATION.md under `## Verification gaps` and append each to `.loop-spec/BACKLOG.md`. They do not block delivery. A gap class this new blocking a verified change would cost more than it catches until the false-positive rate is measured on real runs; promoting it to blocking is a tuning decision backed by telemetry, not a default.

### Step 7.65 - Plain-language pass (advisory)

Checks the prose this cycle produced against `skills/shared/plain-language.md` (the
contract, including which rules are machine-checked and which never will be).
Deterministic, never a model judgment:

```bash
lint="${CLAUDE_SKILL_DIR}/../../lib/plain-language-lint.sh"
bash "$lint" prose docs/loop-spec/features/"$slug"/*.md --max-flags 40 || true
bash "$lint" comments $(git diff --name-only "$baseSha" HEAD -- '*.sh' '*.py') --max-flags 20 || true
```

Findings are **advisory and stay advisory until the false-positive rate is measured**
(the linter flags roughly one line in six on this repo's own artifacts). Record the
counts per check in VERIFICATION.md under `## Plain language` and append only the flags
a human agrees with to `.loop-spec/BACKLOG.md` — never the raw list. A clean run is not
evidence the prose is good.

### Step 7.66 - Docs-for-humans pass

Asks whether the markdown this change leaves behind can be maintained and operated by a
person. `skills/shared/human-docs.md` is the contract; `lib/doc-tells.sh` is the corner of it
that is decidable from the text and the tree.

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/doc-tells.sh" diff "$baseSha" HEAD
```

Exit 0 means the documents this change touched carry no relative link without a target, no
inline-code path the tree no longer holds, and no shell command holding a placeholder the
prose never explains. Exit 1 lists each with `file:line` and is a gate failure: fix them
here and re-run until clean. Do not append `|| true` — that swallows the only signal this
pass has.

These findings are **fixable, not advisory**: every one names a file, a line, and a one-line
edit, so fix them here and re-run until clean rather than backlogging them. The escape hatch
is narrow and recorded: a finding that is one of the misfires the contract documents (a design
artifact naming a file this change deliberately does not create, a frozen record) is written
into VERIFICATION.md under `## Docs for humans` with the reason and does not block. Never
suppress the check itself.

The judgment half belongs to the code-reviewer (Step 6, pass 8.5): which document the change
made false, and whether a procedure a person must follow states its prerequisites, its
expected output, and what to do when a step fails.

### Step 7.7 - Project review layers (opt-in per repo)

Any layer the project declared in `.loop-spec/extensions.json` runs here, after the built-in gates:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/extension-points.sh" layers verify
```

Each emitted line names a layer and its `promptFile`. Dispatch one reviewer per layer with that file's contents, and record findings alongside the verification-gap findings. Extensions ADD only: a declared layer can never disable, reorder, or shadow a built-in gate, and `extension-points.sh validate` refuses a layer claiming a built-in gate id. No output, a missing file, or a malformed file means no extra layers and no error — this path fails open.

### Step 7.8 - Write the reviewer's guide

The change is verified; now make it reviewable. Follow `skills/walkthrough/SKILL.md` in `--write` mode to produce `docs/loop-spec/features/{slug}/REVIEW-ORDER.md`, then lint it:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/review-trail.sh" lint \
  "docs/loop-spec/features/${slug}/REVIEW-ORDER.md" "$baseSha" HEAD
```

Fix every finding and re-run until clean. Record the artifact path in `feature.json` as `artifacts.reviewOrder` so DELIVER inlines it into the PR body.

This never gates delivery. If the trail cannot be produced or will not lint after a reasonable attempt, note it in VERIFICATION.md and continue — a verified change held back over prose costs the reviewer more time than the guide saves.
