---
name: revise
description: Close the PR-review round trip - ingest human review feedback on an open loop-spec PR (inline review comments, reviews, discussion comments), classify each actionable item with the iterate gap taxonomy (execute/plan/spec), fix execute-class items on the PR branch via the EXECUTE remediation machinery, push, and post one summary comment mapping feedback to commits. Autonomous-mode aware.
argument-hint: '<pr-number | pr-url> [autonomous]'
---

# Revise Skill

Invoked as `/loop-spec:revise <pr# | url> [autonomous]`.

The cycle ends at PR-open; human review comments arrive after. This skill is the
machine path for consuming them — the last manual seam in the lifecycle. It is
standalone (no running cycle required) and reuses existing machinery: comment
fetching via `lib/pr-comments.sh`, gap classification from the iterate taxonomy,
fixes via the EXECUTE remediation-task contract, telemetry via `lib/events.sh`.

**Autonomous mode** (inline `autonomous` token or `LOOP_SPEC_AUTONOMOUS=1`):
no questions — the recommended classification is applied and recorded. Interactive
mode asks exactly ONE confirmation (the classification table) before acting.

## Hard rules

- **Checkout isolation follows `LOOP_SPEC_WORKTREES`.** Default mode never switches
  the user's checkout: all work happens in a dedicated worktree whose location comes
  from `lib/worktree-base.sh` (`.loop-spec/worktrees/{slug}-revise` unless that base
  cannot hold a checkout or `LOOP_SPEC_WORKTREE_DIR` says otherwise). If the PR
  branch is already checked out in this repo, `revise-branch.sh` goes in-place
  instead of failing `git worktree add`; if it is checked out in another worktree,
  that path is reused. `owned` in the helper JSON is true only when this run
  created a worktree — Step 10 must not `git worktree remove` the caller's
  checkout. With `LOOP_SPEC_WORKTREES=0`, the checkout
  must be clean and dedicated to this run; revise checks out the PR branch in place,
  creates no worktree, and leaves that branch checked out.
- **Never force-push or reset a branch.** A local branch merely ahead of origin is
  reconciled by an ordinary fast-forward `git push`; a local branch behind origin is
  fast-forwarded in the revision root. Only histories with unique commits on both
  sides are a divergence, and that remains the user's call.
- **Answer, don't guess.** A comment that is a pure question (no change request)
  gets a reply in the summary comment, not a code change.

## Procedure

### Step 1 - Preconditions and PR resolution

```bash
command -v gh >/dev/null || # abort: "revise requires gh on PATH"
git remote get-url origin >/dev/null 2>&1 || # abort: "revise requires an origin remote"
pr_json="$(gh pr view "<arg>" --json number,url,title,state,headRefName,baseRefName)"
```

Abort unless `state == "OPEN"`. Derive:
- `branch = .headRefName`, `pr = .number`
- `slug`: strip a leading `feat/` from `branch`; otherwise sanitize the branch
  name (non-alphanumerics → `-`).

### Step 2 - Resolve identity only (no state writes)

Derive `fdir = .loop-spec/features/{slug}`, but do **not** create it, restore a
backup, change `currentPhase`, emit events, or otherwise write `.loop-spec/*` yet.
The branch must first be proven safe. This ordering prevents a failed revise
precondition from recreating runtime state on the delivered PR branch.

### Step 3 - Reconcile and prepare the execution root before writing state

Use the deterministic helper. It fetches first, distinguishes a safe local-ahead
branch from a true divergence, never uses `checkout -B` or force-push, and returns
the root only after the branch is safe:

```bash
repo_root="$(git rev-parse --show-toplevel)"
case "${LOOP_SPEC_WORKTREES:-1}" in
  1)
    # Resolved, not hard-coded: default remains .loop-spec/worktrees/{slug}-revise
    # and relocates when that base cannot hold a checkout.
    requested_root="$(bash "${CLAUDE_SKILL_DIR}/../../lib/worktree-base.sh" \
      resolve "$repo_root" task "{slug}-revise" | jq -r '.path')"
    prep="$(bash "${CLAUDE_SKILL_DIR}/../../lib/revise-branch.sh" \
      prepare "$repo_root" "$branch" 1 "$requested_root")"
    ;;
  0)
    # The helper requires this checkout to be clean before it can switch branches.
    prep="$(bash "${CLAUDE_SKILL_DIR}/../../lib/revise-branch.sh" \
      prepare "$repo_root" "$branch" 0)"
    ;;
  *)
    # abort: "LOOP_SPEC_WORKTREES must be 0 or 1"
    ;;
esac
revision_root="$(jq -r '.revisionRoot' <<<"$prep")"
sync="$(jq -r '.sync' <<<"$prep")" # already-current | pushed-local-ahead | fast-forwarded-remote
isolation="$(jq -r '.isolation' <<<"$prep")" # worktree | in-place
owned="$(jq -r '.owned' <<<"$prep")" # true only when this run created the worktree
```

On a true divergence the helper exits 3 before it checks out a branch or touches
`.loop-spec`; report its message verbatim. A local branch with unpushed commits is
not a divergence when `origin/$branch` is its ancestor: it is pushed normally, then
revision proceeds. A remote-ahead local branch is fast-forwarded only (`merge
--ff-only`) inside the selected revision root.

### Step 3.5 - Feature runtime state (only after preparation succeeds)

Now set `fdir="$revision_root/.loop-spec/features/$slug"`. Do **not** reconstruct
`feature.json` by hand — a missing file is a gitignored-state miss on a fresh
clone, not a prompt for jq. The helper isolates the runtime directory, reuses an
existing record (phase → revise, fills `commands.test` if empty), or writes a
schema-7 skeleton:

```bash
state="$(bash "${CLAUDE_SKILL_DIR}/../../lib/revise-state.sh" ensure \
  "$revision_root" "$slug" \
  --branch "$branch" --base-branch "<baseRefName>" --title "<PR title>" \
  --autonomous <0|1>)"
fdir="$(jq -r '.featureDir' <<<"$state")"
```

Emit `phase_start` only now:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit "$fdir" phase_start --phase revise || true
```

`feature.json`, its `.bak`, event ledger, and every other `.loop-spec` runtime file
remain local state. `revise-state` ignores newly created state and marks legacy
tracked state skip-worktree in the revision checkout. Never stage it manually. Every
revise code commit names its reviewed source/test paths explicitly; the only revise
artifact that may be committed is the explicit
`docs/loop-spec/features/{slug}/REVISION.md` path in Step 8.

### Step 4 - Fetch and triage feedback

```bash
items="$(bash "${CLAUDE_SKILL_DIR}/../../lib/pr-comments.sh" fetch "$pr")"
```

Triage every item using the probe fields, not a model judgment about the author:

```bash
actionable="$(jq -c '[.[] | select(.skip | not)]' <<<"$items")"
```

- **skip** (already flagged as `.skip == true`): self-comments from a prior revise
  run (marker `<!-- loop-spec:revise -->`), bare approvals ("LGTM"), CI/dependabot
  issue-comment chatter, and non-allowlisted bot issue comments. A **REVIEW** with
  `CHANGES_REQUESTED` (even an empty body) and every inline `review_comment` are
  kept even when `login` ends in `[bot]` — that is how GitHub's code-review agent
  reaches revise. `LOOP_SPEC_REVIEW_BOT_ALLOWLIST` (comma-separated logins) forces
  keep except for the self-marker and bare approvals.
- **question**: asks for information, requests no change → queue a reply.
- **actionable**: everything else in `$actionable` → classify with the iterate gap taxonomy
  (`skills/iterate/SKILL.md`): `execute` (implementation fix at file/line —
  the overwhelming default for review comments), `plan` (the request implies
  missing/mis-decomposed work beyond a local fix), `spec` (the request changes
  scope or requirements).

### Step 5 - Confirmation gate (interactive only)

Present one table: `# | author | file:line | excerpt | class | planned action`.
- Interactive: one AskUserQuestion — proceed / adjust classes / drop items.
- Autonomous: skip the question; record each classification as an assumed
  decision in `REVISION.md` (Step 8).

### Step 6 - Apply execute-class items

Convert each execute-class item to a FULL-SHAPE remediation task (the EXECUTE
re-entry contract — same normalization it already enforces):

```json
{"id": "revise-<comment-id>", "subject": "PR-review fix: <excerpt>",
 "files": ["<comment path or []>"], "blockedBy": [],
 "acceptanceCriteria": ["review comment <url> is addressed: <requested change>"],
 "verifyCommand": "<feature.commands.test>", "readFirst": ["<comment path>"],
 "specPath": null, "brief": "<full comment body + surrounding context>"}
```

Append them via `lib/feature-write.sh append "$fdir" pendingRemediationTasks <task>`,
then invoke `Skill(loop-spec:execute)` with `revision_root` as the feature execution
root. EXECUTE's own dispatch, spec-compliance gate, retry, and
dispatch-telemetry contracts apply unchanged. After it returns, run the test
command once in `revision_root` and confirm each item's acceptance criterion.

### Step 7 - plan/spec-class items are NOT silently fixed

A plan- or spec-class request is a scope change riding in a review comment.
v1 deliberately does not redesign inside revise: append each to
`.loop-spec/BACKLOG.md` (`lib/backlog.sh add`) with the comment URL, and answer
the comment in the summary (Step 9) with the backlog entry + the recommended
follow-up (`/loop-spec:cycle <refined description>`). This mirrors the iterate
limit-spent contract: gaps are recorded loudly, never absorbed silently.

### Step 8 - Push + artifacts

```bash
git -C "$revision_root" push origin "$branch"   # never --force
```

Write `docs/loop-spec/features/{slug}/REVISION.md` (append one section per
revise run): PR, date, items table with class + outcome (commit SHA / replied /
backlogged), assumed decisions when autonomous. Commit **only this explicit path**
on the PR branch; do not use `git add -A`, and never include `.loop-spec/*` runtime
state in a revise commit.
Emit `phase_end` and refresh the result contract:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit "$fdir" phase_end --phase revise --data '{"next":"done"}' || true
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" write "$fdir" --status completed \
  --pr-url "<pr url>" \
  --summary "Processed <count> review items: <fixed count> fixed, <answered count> answered, <backlogged count> classified as scope changes." || true
```

### Step 9 - One summary comment

Post exactly one comment (marker first line so a later run can skip it):

```bash
gh pr comment "$pr" --body "<!-- loop-spec:revise -->
## loop-spec revise summary
| feedback | class | outcome |
|---|---|---|
| <author> <file:line> <excerpt> | execute | fixed in <sha> |
| <author> <excerpt> | question | <answer> |
| <author> <excerpt> | plan | backlogged: <entry> — recommend <follow-up> |
"
```

### Step 10 - Cleanup

Remove a revise worktree only when `owned == true` (`git worktree remove` that
`revisionRoot`, keep the branch). `isolation == "in-place"` or `owned == false`
means this run used the caller's checkout or a worktree that already held the
branch — leave it. In no-worktree mode there is nothing to remove; leave the
in-place PR branch checked out. Print the PR URL and the per-item outcome table.

## Failure behavior

Any abort (diverged branch, gh failure, EXECUTE escalation) leaves the execution
root in place, reports the exact step and error verbatim, and posts NO comment —
a partial revise must never present itself on the PR as a complete one.
