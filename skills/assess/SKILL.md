---
name: assess
description: Standalone, read-only codebase fragility and health assessment. Workspace-aware -- in workspace mode scans every configured repo; in single mode, just the one. Dispatches bounded code-reviewer subagents at the top-N hotspots, then synthesizes docs/loop-spec/assessment/ASSESSMENT.md with per-repo fragility heat maps, reviewer findings, cross-repo ranked findings, and prioritized fix recommendations. Only that one file is written; nothing is committed.
allowed-tools: Bash Read Glob Grep Agent AskUserQuestion Write
---

# assess

Standalone skill for codebase fragility and health assessment. Read-only with respect to source code. Writes one output file: `docs/loop-spec/assessment/ASSESSMENT.md`.

## Inputs

None required. Optional environment variables:

- `LOOP_SPEC_ASSESS_TOP_N` -- number of top-fragility files per repo sent to reviewers (default: 5)
- `LOOP_SPEC_ASSESS_SINCE` -- passed as `--since` to `fragility-scan.sh` to limit the git history window (default: all history)

## Procedure

### Step 1 -- Workspace detection

Run the workspace resolver to determine the scope:

```bash
WORKSPACE_JSON=$(bash "${CLAUDE_SKILL_DIR}/../../lib/workspace.sh" detect)
WORKSPACE_MODE=$(echo "$WORKSPACE_JSON" | jq -r '.mode')
```

Branch on mode:

- **`none`** -- abort with: "assess: not a git repo and no child repos found. cd into a repo or create `.loop-spec/workspace.json`."
- **`single`** -- extract the single repo root:
  ```bash
  REPOS=$(echo "$WORKSPACE_JSON" | jq '[{"name": (.root | split("/") | last), "abs": .root}]')
  ```
- **`workspace`** -- build the repo list from the detected repos, resolving each path to an absolute path:
  ```bash
  WORKSPACE_ROOT=$(echo "$WORKSPACE_JSON" | jq -r '.root')
  REPOS=$(echo "$WORKSPACE_JSON" | jq --arg root "$WORKSPACE_ROOT" \
    '[.repos[] | {"name": .name, "abs": ($root + "/" + .path)}]')
  ```

Announce the scope to the user before proceeding:

```
assess: scope -- {mode} mode, {N} repo(s): {name, ...}
```

### Step 2 -- Fragility scan (per repo)

For each repo in `REPOS`, run `fragility-scan.sh` with `--top 20`:

```bash
TOP_N="${LOOP_SPEC_ASSESS_TOP_N:-5}"
SINCE_FLAG=""
if [[ -n "${LOOP_SPEC_ASSESS_SINCE:-}" ]]; then
  SINCE_FLAG="--since ${LOOP_SPEC_ASSESS_SINCE}"
fi

for repo in $(echo "$REPOS" | jq -c '.[]'); do
  REPO_NAME=$(echo "$repo" | jq -r '.name')
  REPO_ABS=$(echo "$repo" | jq -r '.abs')

  SCAN_JSON=$(bash "${CLAUDE_SKILL_DIR}/../../lib/fragility-scan.sh" \
    "$REPO_ABS" --top 20 ${SINCE_FLAG})

  # Store scan result keyed by repo name for use in subsequent steps.
  # Print a summary table for the user.
done
```

After each scan completes, print a top-10 preview table for the user:

```
Repo: {name}
Rank | File                          | Commits | BugfixCommits | Score
-----|-------------------------------|---------|---------------|------
1    | src/core/session.py           | 24      | 7             | 0.91
...
```

Extract this from the scan JSON:

```bash
echo "$SCAN_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
files = d.get('files', [])[:10]
print(f\"Repo: {d['repo']}\")
print(f\"{'Rank':<5} {'File':<40} {'Commits':<9} {'BugfixCommits':<15} {'Score':<6}\")
print('-' * 80)
for i, f in enumerate(files, 1):
    print(f\"{i:<5} {f['path']:<40} {f['commits']:<9} {f['bugfixCommits']:<15} {f['score']:.2f}\")
"
```

Store all scan results for synthesis in Step 4:

```bash
ALL_SCANS[$REPO_NAME]="$SCAN_JSON"
```

### Step 3 -- Reviewer dispatch (parallel, one-shot)

For each repo, collect the top `LOOP_SPEC_ASSESS_TOP_N` (default 5) files from the scan result and dispatch one `Agent` call per file as parallel, one-shot reviewer subagents.

**Model note:** `assess` runs standalone with no `feature.json`, so there is no `feature.models` map to read. Use the `sonnet` alias hardcoded here. Keep this in sync with `skills/shared/model-matrix.md`.

For each file in the top-N set:

```bash
FILE_PATH=$(echo "$file_entry" | jq -r '.path')         # repo-relative
FILE_ABS="${REPO_ABS}/${FILE_PATH}"
FILE_SCORE=$(echo "$file_entry" | jq -r '.score')
FILE_COMMITS=$(echo "$file_entry" | jq -r '.commits')
FILE_BUGFIX=$(echo "$file_entry" | jq -r '.bugfixCommits')
FILE_TOUCHED=$(echo "$file_entry" | jq -r '.lastTouched')
```

Dispatch prompt (read-only; ask for JSON findings in the reply):

```
Agent({
  subagent_type: "loop-spec:code-reviewer",
  model: "sonnet",
  prompt: """
You are reviewing a high-fragility file for code quality and correctness issues.

File: {FILE_ABS}
Repo: {REPO_NAME}
Fragility stats:
  - Total commits touching this file: {FILE_COMMITS}
  - Bugfix commits: {FILE_BUGFIX}
  - Last touched: {FILE_TOUCHED}
  - Fragility score (0..1): {FILE_SCORE}

Read the file and return a JSON object in your reply with this exact shape:
{
  "file": "<repo-relative path>",
  "repo": "<repo name>",
  "findings": [
    {
      "line": <integer or null>,
      "severity": "<CRITICAL|HIGH|MEDIUM|LOW>",
      "claim": "<one-sentence description of the issue>"
    }
  ]
}

Return an empty findings array if you find no issues. Do not edit any files.
Do not include any text outside the JSON object in your reply.
"""
})
```

Run all dispatches in parallel across repos and files. Collect each agent reply and parse the JSON findings. If a reply cannot be parsed as JSON, record a single LOW finding: `"claim": "reviewer reply was not valid JSON; manual review needed"`.

Store all findings per repo in `FINDINGS[$REPO_NAME]`.

### Step 4 -- Synthesize ASSESSMENT.md

Collect:

- Scan metadata from each `fragility-scan.sh` result (repo path, `generatedAt`, `window`).
- All per-repo scan file lists (top 20 each).
- All reviewer findings from Step 3.

Create the output directory if it does not exist:

```bash
mkdir -p docs/loop-spec/assessment
```

Write `docs/loop-spec/assessment/ASSESSMENT.md` with the following structure:

---

```
# Codebase Assessment

Generated: {ISO-8601 timestamp}
Mode: {single | workspace}
Repos scanned: {N}
History window: {since value or "all history"}
Top-N reviewer files per repo: {LOOP_SPEC_ASSESS_TOP_N}

> Advisory only -- no gate. This report does not block any workflow.

---

## Scan metadata

| Repo | Root | Generated at | Window |
|------|------|-------------|--------|
| ...  | ...  | ...         | ...    |

---

## Per-repo fragility heat maps

### {repo name}

| Rank | File | Commits | Bugfix commits | Last touched | Score |
|------|------|---------|---------------|-------------|-------|
| 1    | ...  | ...     | ...           | ...         | 0.XX  |
...

(repeat for each repo)

---

## Reviewer findings

| Repo | File | Line | Severity | Finding |
|------|------|------|----------|---------|
| ...  | ...  | ...  | CRITICAL | ...     |
...

(sorted by severity: CRITICAL > HIGH > MEDIUM > LOW; then by fragility score desc within each severity)

---

## Cross-repo ranked findings

All reviewer findings from all repos merged and ranked:
  1. Severity tier (CRITICAL > HIGH > MEDIUM > LOW)
  2. Fragility score of the file (descending)

| Rank | Repo | File | Line | Severity | Finding |
|------|------|------|------|----------|---------|
...

---

## Prioritized fix recommendations

Based on the cross-repo ranked findings, the following changes are highest priority:

1. **{CRITICAL or HIGH finding summary}** -- {repo}/{file}:{line}
   Rationale: {severity} severity finding in a file with fragility score {score}.
...

(Include up to 10 recommendations. MEDIUM/LOW findings listed separately as optional improvements.)

---

> **Advisory, no gate.** This assessment is informational. It does not block
> commits, PRs, or any loop-spec workflow phase. Act on findings at your
> discretion.
```

---

Use `Write` to produce the file. The assessment document is the only file written by this skill.

Severity sort order for all tables: CRITICAL before HIGH before MEDIUM before LOW. Within the same severity tier, sort by the file's fragility score descending.

Python3 helper for sorting findings:

```python
SEVERITY_ORDER = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3}
findings_sorted = sorted(
    all_findings,
    key=lambda f: (SEVERITY_ORDER.get(f["severity"], 99), -f.get("score", 0))
)
```

### Step 5 -- Report

Print to the user:

```
assess: complete.
  Repos scanned:      {N}
  Files ranked:       {total files in scan results}
  Files reviewed:     {total files sent to reviewer}
  Findings:           {total finding count} ({CRITICAL} critical, {HIGH} high, {MEDIUM} medium, {LOW} low)
  Output:             docs/loop-spec/assessment/ASSESSMENT.md

No source files were edited. Nothing was committed.
```

## What NOT to do

- **Do not edit any source file.** The only file written is `docs/loop-spec/assessment/ASSESSMENT.md`.
- **Do not commit.** The skill explicitly does not commit. The assessment doc is intentionally left uncommitted for the user to review and optionally commit separately.
- **Do not run unbounded reviewer dispatch.** The number of files sent to reviewers is always capped by `LOOP_SPEC_ASSESS_TOP_N` (default 5) per repo. Do not dispatch one agent per file from the full 20-file scan list.
- **Do not read `feature.json` or `feature.models`.** This skill runs standalone. The model is hardcoded to the `sonnet` alias as noted in Step 3.
- **Do not abort on a single reviewer failure.** If one Agent call returns unparseable output, record the advisory LOW finding and continue with the remaining results.

## Standalone CLI

```
Skill(loop-spec:assess)
# with custom top-N:
LOOP_SPEC_ASSESS_TOP_N=10 Skill(loop-spec:assess)
# with history window:
LOOP_SPEC_ASSESS_SINCE=2026-01-01 Skill(loop-spec:assess)
```
