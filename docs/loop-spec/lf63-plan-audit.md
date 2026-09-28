# LF-63 plan audit

Reviewed the supplied handoff plan and iterate._judge_request, compose_prompt,
steps.issue and ITERATE re-entry at 788c6de.

**Go to implementation.** Hoisting each repository diff into its own raw string
section is the right narrow correction. A nested JSON string encodes the entire
diff onto one physical line; changing the field layout avoids that without changing
JSON semantics or the LF-61 scheduling/receipt contract.

## Implementation details to preserve

- Base the single-repo/workspace naming decision on the run's repository count,
  not merely the number of touched repositories. In a two-repo workspace where only
  one repo changed, keep diff:<repo> so its ownership remains explicit. Retain the
  existing per-repo base..head range and do not mix different repos' diffs.
- Add only touched-repo sections; an unchanged run must still issue a valid judge
  request with no diff section. Keep request, spec, verification, budget, prior gaps,
  and close-out inputs present. Use deterministic repository ordering.
- Keep line contents/indentation intact. compose_prompt's existing boundary newline
  trimming is sufficient; do not wrap, summarize or alter diff lines for the budget.
- The existing _DIFF_CAP truncation is unchanged by this patch. Record that limit
  accurately: complete receipt of the issued prompt does not mean complete receipt
  of a repository diff that was truncated before composition. Do not describe this
  fix as removing all large-diff limits.
- Mention the diffs -> diff/diff:<repo> input-layout change for bound iterate-judge
  skills. The built-in role need not change if it does not name the old key, but
  external bindings may have depended on it. No generic nested-string hoister needed.

The sweep's 'other nested strings are short' is an observation, not an enforced
invariant—PR comments, specs and verdict text can grow. Keep LF-61's loud preparation
failure; do not expand LF-63 to redesign all those products.

## Validation and resume

The proposed generated 1,300-line request + real steps.issue test, workspace sections,
and existing ITERATE tests are appropriate deterministic module checks. Add two-repo
workspace with only one changed repo and zero changed repos. Assert the rendered diff
payload remains equal apart from the established section-boundary framing and that
all scheduled lines remain within budget.

The source supports resuming the reported preparation failure: steps.issue schedules
before it writes the step record, and iterate.step rebuilds _judge_request when judge
is None. Before resume, confirm no open judge step/result exists in that particular
run. Refresh the plugin checkout only while no process is using it. Never replace an
issued step's saved prompt to obtain attestation.

Archive the exact commit boundary: SPEC through VERIFY ran on c68fae2; the resumed
ITERATE/DELIVER portion runs on the LF-63 build. That can establish the large-read
transport gate across the staged run, but is not a fresh whole-cycle test of every
change in the newer build. Record the terminal outcome and manual critic answer.
Then run the separate LF-60 refusal/opt-in gate; neither result substitutes for live
LF-62 policy answering when a second-pass finding actually occurs.

No code, live-run state, commits or remote changes were made in this audit. The plan
was reviewed statically; no new live run or LF-63 implementation test exists yet.
