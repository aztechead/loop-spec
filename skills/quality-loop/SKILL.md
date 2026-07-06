---
name: quality-loop
description: Iterative pre-commit review convergence loop, workspace-aware. Resolves scope from explicit file arguments or modified files across repos, runs deterministic checks first (lint/typecheck plus unresolved-marker scan), then dispatches code-reviewer and security-reviewer in parallel per round, records findings via quality-loop-state.sh, and loops until convergence or the round limit is exhausted.
argument-hint: "[file paths to review]  (optional; defaults to modified files)"
allowed-tools: Bash Read Write Edit Glob Grep Agent AskUserQuestion
---

# quality-loop

Iterative pre-commit review convergence loop. Invoke this skill before committing to catch quality and security issues early. Workspace-aware: works in single-repo or multi-repo workspace setups.

## Inputs

Optional:

- `$ARGUMENTS` -- explicit file paths to review (space- or newline-separated). When provided, these take precedence over git-derived scope.

Environment variables:

- `LOOP_SPEC_QUALITY_LOOP_MAX_ROUNDS` -- maximum review rounds before escalating (default: 3).
- `LOOP_SPEC_QL_STATE` -- override path for the quality-loop state file (default: `.loop-spec/quality-loop.json`).

## Step 0 -- Scope resolution

Determine the set of files to review.

**Explicit args win.** If `$ARGUMENTS` is non-empty, parse the provided paths as the scope. Normalize each to an absolute path. Skip paths that do not exist or that are not regular files. If no valid paths remain after normalization, stop with: "quality-loop: no valid files in explicit argument list."

**Else: git-derived scope.** Run workspace detection:

```bash
WORKSPACE_JSON=$(bash "${CLAUDE_SKILL_DIR}/../../lib/workspace.sh" detect)
WORKSPACE_MODE=$(echo "$WORKSPACE_JSON" | jq -r '.mode')
```

Branch on mode:

- **`none`** -- abort with: "quality-loop: not a git repo and no child repos found. cd into a repo or create `.loop-spec/workspace.json`."
- **`single`** -- collect modified code files from the single repo:
  ```bash
  REPO_ROOT=$(echo "$WORKSPACE_JSON" | jq -r '.root')
  REPOS_JSON=$(echo "$WORKSPACE_JSON" | jq '[{"name": (.root | split("/") | last), "abs": .root}]')
  ```
- **`workspace`** -- collect modified code files from every configured repo:
  ```bash
  WORKSPACE_ROOT=$(echo "$WORKSPACE_JSON" | jq -r '.root')
  REPOS_JSON=$(echo "$WORKSPACE_JSON" | jq --arg root "$WORKSPACE_ROOT" \
    '[.repos[] | {"name": .name, "abs": ($root + "/" + .path)}]')
  ```

For each repo, collect modified code files via `git status --porcelain`:

```bash
for repo in $(echo "$REPOS_JSON" | jq -c '.[]'); do
  REPO_ABS=$(echo "$repo" | jq -r '.abs')
  git -C "$REPO_ABS" status --porcelain \
    | awk '$1 != "D" && $1 != "DD" {print $NF}' \
    | grep -E '\.(py|ts|tsx|js|jsx|go|rs|c|h|cpp|hpp|sh)$' \
    | while read -r rel; do
        echo "${REPO_ABS}/${rel}"
      done
done
```

Filtering rules:
- Include extensions: `.py` `.ts` `.tsx` `.js` `.jsx` `.go` `.rs` `.c` `.h` `.cpp` `.hpp` `.sh`
- Exclude deleted files (`git status --porcelain` status codes `D` and `DD`)
- Include untracked files that match the extension filter (status code `?`)

**Empty scope.** If the resolved file list is empty, print "quality-loop: nothing to review -- no modified code files found." and stop (exit 0).

Persist scope via the state CLI:

```bash
QLSTATE="${CLAUDE_SKILL_DIR}/../../lib/quality-loop-state.sh"
FILE_COUNT=$(bash "$QLSTATE" scope "${SCOPE_FILES[@]}")
echo "quality-loop: scope -- ${FILE_COUNT} file(s) in review"
```

Announce the scope to the user:

```
quality-loop: reviewing N file(s):
  - /abs/path/to/file1.py
  - /abs/path/to/file2.ts
  ...
```

## Step 1 -- Deterministic checks (per round, before persona dispatch)

Run deterministic checks before dispatching any persona agent. The main thread owns fixes from deterministic findings.

### 1a -- Unresolved-marker scan

Scan each in-scope file for unresolved markers:

```bash
grep -wn 'TBD\|FIXME\|XXX' "${SCOPE_FILES[@]}" 2>/dev/null || true
```

Any match is a deterministic finding. Record it as:

```json
{"source": "deterministic", "category": "unresolved-marker", "severity": "HIGH", "claim": "Unresolved marker found: <marker> at <file>:<line>", "line": <N>}
```

Note: `-w` (word boundary) is used to avoid false positives on identifiers like `STBD`, `XXXL`.

### 1b -- Project lint and typecheck

Detect the project's lint, typecheck, and (if scope touches tested code) test commands. Use the same detection logic as the verify skill:

```bash
DETECT_CMD="${CLAUDE_SKILL_DIR}/../../lib/detect-test-cmd.sh"
```

Run detected commands. Capture stdout and stderr. Any non-zero exit is a deterministic finding per failing command. Record each as:

```json
{"source": "deterministic", "category": "lint-typecheck", "severity": "HIGH", "claim": "<command> failed: <first line of output>", "line": null}
```

### 1c -- Fix and retry loop (deterministic inner cap)

If any deterministic findings exist, fix them on the main thread (Edit/Write tools). Then re-run Steps 1a and 1b.

**Inner cap: 3 iterations.** If deterministic checks still fail after 3 inner fix attempts, stop and escalate to the user:

```
quality-loop: ESCALATE -- deterministic checks failed after 3 fix attempts.
Remaining deterministic issues:
  - <category>: <claim> (<file>:<line>)
  ...
Manual intervention required before the review loop can continue.
```

Do not proceed to persona dispatch while deterministic findings remain.

## Step 2 -- Persona pass (review independence protocol)

**REVIEW INDEPENDENCE PROTOCOL -- HARD RULE:** Each Agent call for code-reviewer and security-reviewer receives file contents and paths ONLY. Prompts MUST NOT include:
- Prior-round findings
- Fix summaries or descriptions of changes made
- Any "check whether X was fixed" framing
- References to previous rounds or what was wrong before

Each persona reviews the current state of the files as if it is the first and only review. This independence is non-negotiable: it prevents anchoring bias and ensures findings reflect actual current file state.

Dispatch `loop-spec:code-reviewer` and `loop-spec:security-reviewer` in parallel as one-shot Agent calls.

**Model note:** `quality-loop` runs standalone with no `feature.json`, so there is no `feature.models` map to read. Use the `sonnet` alias hardcoded for both reviewer calls. Keep this in sync with `skills/shared/model-matrix.md`.

### Code-reviewer prompt

```
Agent({
  description: "Quality-loop code review",
  subagent_type: "loop-spec:code-reviewer",
  model: "sonnet",
  prompt: """
You are performing a one-shot code quality review.

Files to review:
{for each file: absolute path + file contents}

Review each file for code quality, correctness, bugs, performance regressions,
missed test coverage, and anti-patterns. Do not reference any prior review
round. Review the files as they currently exist.

Return your findings as a JSON array in your reply with this exact shape:
[
  {
    "source": "code-reviewer",
    "category": "<quality|correctness|performance|test-coverage|anti-pattern|other>",
    "severity": "<CRITICAL|HIGH|MEDIUM|LOW>",
    "claim": "<one-sentence description>",
    "line": <integer or null>
  }
]

Return [] if no issues found. Return only the JSON array -- no surrounding text.
"""
})
```

### Security-reviewer prompt

```
Agent({
  description: "Quality-loop security review",
  subagent_type: "loop-spec:security-reviewer",
  model: "sonnet",
  prompt: """
You are performing a one-shot adversarial security review.

Files to review:
{for each file: absolute path + file contents}

Review each file for security vulnerabilities: injection, authz, secrets,
input handling, unsafe defaults, denial-of-service, data exposure.
Do not reference any prior review round. Review the files as they currently exist.

Return your findings as a JSON array in your reply with this exact shape:
[
  {
    "source": "security-reviewer",
    "category": "<injection|authz|secrets|input-handling|unsafe-defaults|denial-of-service|data-exposure|other>",
    "severity": "<CRITICAL|HIGH|MEDIUM|LOW>",
    "claim": "<one-sentence description of the specific issue and its risk>",
    "line": <integer or null>
  }
]

Return [] if no issues found. Return only the JSON array -- no surrounding text.
"""
})
```

Run both Agent calls in parallel. Collect replies. If a reply cannot be parsed as a JSON array, record a single HIGH finding:

```json
{"source": "deterministic", "category": "reviewer-parse-error", "severity": "HIGH", "claim": "Reviewer reply was not valid JSON; treat as unresolved finding requiring manual review.", "line": null}
```

## Step 3 -- Record round and classify blocking findings

Merge all findings from Step 1 (any remaining after inner fix loop -- should be zero, but record if not) and Step 2 into a combined findings array. Record the round via the state CLI:

```bash
ROUND_NUM=<current round, starting at 1>
COMBINED_FINDINGS_JSON='[...all findings...]'

# Record per file (record the same combined findings for each in-scope file,
# or split by file using the line/path fields if your findings are file-specific).
for file in "${SCOPE_FILES[@]}"; do
  bash "$QLSTATE" record-round "$file" "$ROUND_NUM" "$COMBINED_FINDINGS_JSON"
done
```

Classify blocking vs advisory:

- **Blocking**: any deterministic finding (source == "deterministic"), any code-reviewer finding (source == "code-reviewer"), any security-reviewer finding with severity CRITICAL or HIGH.
- **Advisory only**: security-reviewer findings with severity MEDIUM or LOW.

Print a round summary:

```
quality-loop: round N complete.
  Blocking findings:  X
  Advisory findings:  Y (security MEDIUM/LOW -- not blocking convergence)
```

Print each advisory security finding as informational:

```
  [ADVISORY] security-reviewer <category> <MEDIUM|LOW>: <claim> (<file>:<line>)
```

**Security findings are NEVER self-suppressed.** All findings -- blocking and advisory -- are presented to the user. The skill waits for human review of any security finding before declaring convergence. Do not omit MEDIUM/LOW security findings from output even though they do not block the loop.

## Step 4 -- Systemic check

After recording the round, check for systemic issues (same finding category recurring across the last 2 consecutive rounds):

```bash
for file in "${SCOPE_FILES[@]}"; do
  SYSTEMIC=$(bash "$QLSTATE" systemic "$file")
  if [[ -n "$SYSTEMIC" ]]; then
    SYSTEMIC_CATEGORIES="$SYSTEMIC"
    break
  fi
done
```

If any systemic category is detected, escalate immediately:

```
quality-loop: ESCALATE -- systemic issue detected.
The following finding category recurred in 2 or more consecutive rounds:
  - <category>

This indicates the fix applied did not resolve the underlying issue, or a new
instance was introduced. Manual inspection is required before continuing.

All findings from the current round:
  <full findings list>
```

Stop the loop. Do not increment the round counter or continue looping.

## Step 5 -- Fix blocking findings and loop

If blocking findings exist and no systemic issue was detected and the round limit is not exhausted:

1. Fix blocking findings on the main thread (Edit/Write tools). For each finding, apply the minimal correct fix. Do not refactor beyond what the finding requires.
2. Increment the round counter.
3. Loop back to Step 1 (deterministic checks).

**Round limit:** loop while `ROUND_NUM <= LOOP_SPEC_QUALITY_LOOP_MAX_ROUNDS` (default 3). When the round limit is exhausted before convergence, escalate:

```
quality-loop: ESCALATE -- round limit exhausted (LOOP_SPEC_QUALITY_LOOP_MAX_ROUNDS=N).
Remaining blocking findings:
  - <source> <category> <severity>: <claim> (<file>:<line>)
  ...

Advisory findings (security MEDIUM/LOW):
  - <claim> (<file>:<line>)
  ...

No further automated fix attempts will be made. Please resolve the remaining
findings manually and re-invoke quality-loop, or commit with awareness of
these open issues.
```

Do not mark any file clean on round-limit exhaustion. Stop.

## Step 6 -- Convergence

When a round completes with zero blocking findings across all in-scope files:

Mark each file clean:

```bash
for file in "${SCOPE_FILES[@]}"; do
  bash "$QLSTATE" mark-clean "$file" "$ROUND_NUM"
done
```

Print a convergence summary table:

```
quality-loop: CONVERGED after N round(s).

File                          | Rounds | Advisory findings
------------------------------|--------|------------------
/abs/path/to/file1.py         | N      | 0
/abs/path/to/file2.ts         | N      | 2 (security MEDIUM/LOW)

All blocking findings resolved. Files are ready to commit.
```

If any advisory (MEDIUM/LOW security) findings were recorded, list them again as a reminder:

```
Advisory security findings (not blocking -- review at your discretion):
  [ADVISORY] security-reviewer <category> <MEDIUM|LOW>: <claim> (<file>:<line>)
  ...
```

The skill exits 0. Advisory findings are NOT suppressed from this summary. They are presented for the user's awareness even on convergence.

## What NOT to do

- **Do NOT include prior-round findings in reviewer prompts.** The independence rule is absolute. Adding "check whether X was fixed" or pasting previous findings into a reviewer prompt contaminates the review and defeats the independence protocol.
- **Do NOT suppress security findings.** MEDIUM and LOW security findings must appear in output at every round and in the final summary. They are advisory, not invisible.
- **Do NOT continue the loop after systemic detection.** Systemic categories require human inspection. Looping further wastes effort without resolving the root cause.
- **Do NOT skip the deterministic checks.** Lint, typecheck, and the unresolved-marker grep run every round before persona dispatch. Personas should not see files that still have marker or lint issues.
- **Do NOT use `LOOP_SPEC_QUALITY_LOOP_MAX_ROUNDS` as a hidden variable.** Print its effective value at the start of the loop so the user knows the limit:
  ```
  quality-loop: max rounds = ${LOOP_SPEC_QUALITY_LOOP_MAX_ROUNDS:-3}
  ```
- **Do NOT call mark-clean while blocking findings remain.** The state CLI enforces this (exit 2), but the skill must not attempt it prematurely.
- **Do NOT commit.** This skill does not commit. It prepares files for commit; committing is the user's action.
- **Do NOT read `quality-loop-state.sh` as a library.** Always invoke it as a subprocess: `bash "${CLAUDE_SKILL_DIR}/../../lib/quality-loop-state.sh" <subcommand>`.

## Standalone CLI

```bash
# Review all modified files in scope:
Skill(loop-spec:quality-loop)

# Review specific files only:
Skill(loop-spec:quality-loop) path/to/file1.py path/to/file2.ts

# Increase round limit:
LOOP_SPEC_QUALITY_LOOP_MAX_ROUNDS=5 Skill(loop-spec:quality-loop)
```
