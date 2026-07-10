#!/usr/bin/env bash
# sentinel-sources.sh - Work-source adapters for the sentinel (ROADMAP-3.0 A1).
#
# One subcommand per source, each emitting a normalized JSON array of candidate
# work items on stdout:
#   [{"source": "...", "id": "...", "title": "...", "body": "...",
#     "url": "...|null", "kind": "bug|gap|chore|unknown", "updatedAt": "ISO|null"}]
#
# The adapter list IS the seam (ROADMAP-3.0): new sources are new subcommands
# emitting the same shape; the triage policy (lib/sentinel-triage.sh) never
# learns source internals. Jira/Slack/email adapters are deliberately absent —
# they arrive through /loop-spec:intake today.
#
# Usage:
#   sentinel-sources.sh gh-issues   [--label loop-spec] [--repo <o/r>] [--fixture <file>]
#       Open issues carrying <label>, minus anything already claimed by a
#       lifecycle label (loop-spec:in-progress/done/failed — same skip rule as
#       lib/issue-intake.sh). Fixture shape = gh issue list --json
#       number,title,body,url,updatedAt,labels output.
#   sentinel-sources.sh ci-failures [--branch <name>] [--repo <o/r>] [--fixture <file>]
#       Failed workflow runs on <branch> (default: the repo's default branch),
#       most recent run per workflow. Body carries the failing log tail when
#       live (gh run view --log-failed); fixtures skip the log fetch. Fixture
#       shape = gh run list --json databaseId,workflowName,displayTitle,url,
#       updatedAt,headBranch output.
#   sentinel-sources.sh backlog
#       Unchecked .loop-spec/BACKLOG.md entries via lib/backlog.sh list --json.
#   sentinel-sources.sh assessment  [--file <path>] [--top <n>] [--max-age-days <n>]
#       Top-N rows of ASSESSMENT.md's "Cross-repo ranked findings" table when
#       the report is fresher than --max-age-days (default 30; stale or absent
#       report -> []). Default file: docs/loop-spec/assessment/ASSESSMENT.md.
#   sentinel-sources.sh list
#       Print the adapter names, one per line (the seam, enumerable).
#
# kind mapping (deterministic; triage weighs bug > gap > chore, routes unknown
# to needs-human):
#   gh-issues:   label bug -> bug; enhancement/feature -> gap; chore -> chore;
#                anything else -> unknown (a human labeled it, a script must
#                not guess the class)
#   ci-failures: always bug (a red default branch is a defect by definition)
#   backlog:     iterate-gap/verify-deferred -> gap; manual -> chore
#   assessment:  CRITICAL/HIGH -> bug; MEDIUM -> gap; LOW -> chore
#
# Exit codes: 0 success (possibly []), 2 bad invocation / missing prerequisite.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_die2() { echo "sentinel-sources.sh: $*" >&2; exit 2; }

_hash8() {
  python3 -c '
import hashlib, re, sys
t = re.sub(r"[^a-z0-9]+", " ", sys.argv[1].lower()).strip()
print(hashlib.sha256(t.encode()).hexdigest()[:8])
' "$1"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  list)
    printf '%s\n' gh-issues ci-failures backlog assessment
    exit 0
    ;;

  gh-issues)
    LABEL="loop-spec"; REPO=""; FIXTURE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --label) LABEL="${2:-}"; shift 2 || shift ;;
        --repo) REPO="${2:-}"; shift 2 || shift ;;
        --fixture) FIXTURE="${2:-}"; shift 2 || shift ;;
        *) _die2 "unknown flag '$1' for gh-issues" ;;
      esac
    done
    if [[ -n "$FIXTURE" ]]; then
      [[ -f "$FIXTURE" ]] || _die2 "fixture not found: $FIXTURE"
      raw="$(jq -c . "$FIXTURE" 2>/dev/null)" || _die2 "fixture is not valid JSON: $FIXTURE"
    else
      command -v gh >/dev/null 2>&1 || _die2 "'gh' not on PATH (gh-issues adapter needs it)"
      repo_args=()
      [[ -n "$REPO" ]] && repo_args=(--repo "$REPO")
      raw="$(gh issue list ${repo_args[@]+"${repo_args[@]}"} --label "$LABEL" --state open \
             --json number,title,body,url,updatedAt,labels --limit 50 2>/dev/null)" \
        || _die2 "gh issue list failed"
    fi
    jq -c '[.[]
      | select(([.labels[]?.name]
          | any(. == "loop-spec:in-progress" or . == "loop-spec:done" or . == "loop-spec:failed")) | not)
      | {
          source: "gh-issues",
          id: ("gh-" + (.number | tostring)),
          title: (.title // ""),
          body: (.body // ""),
          url: (.url // null),
          kind: ([.labels[]?.name] as $l
                 | if ($l | any(. == "bug")) then "bug"
                   elif ($l | any(. == "enhancement" or . == "feature")) then "gap"
                   elif ($l | any(. == "chore")) then "chore"
                   else "unknown" end),
          updatedAt: (.updatedAt // null)
        }]' <<<"$raw"
    ;;

  ci-failures)
    BRANCH=""; REPO=""; FIXTURE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --branch) BRANCH="${2:-}"; shift 2 || shift ;;
        --repo) REPO="${2:-}"; shift 2 || shift ;;
        --fixture) FIXTURE="${2:-}"; shift 2 || shift ;;
        *) _die2 "unknown flag '$1' for ci-failures" ;;
      esac
    done
    if [[ -z "$BRANCH" ]]; then
      # Default branch: origin/HEAD when a remote exists, else "main".
      BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
      BRANCH="${BRANCH:-main}"
    fi
    if [[ -n "$FIXTURE" ]]; then
      [[ -f "$FIXTURE" ]] || _die2 "fixture not found: $FIXTURE"
      raw="$(jq -c . "$FIXTURE" 2>/dev/null)" || _die2 "fixture is not valid JSON: $FIXTURE"
    else
      command -v gh >/dev/null 2>&1 || _die2 "'gh' not on PATH (ci-failures adapter needs it)"
      repo_args=()
      [[ -n "$REPO" ]] && repo_args=(--repo "$REPO")
      raw="$(gh run list ${repo_args[@]+"${repo_args[@]}"} --status failure \
             --json databaseId,workflowName,displayTitle,url,updatedAt,headBranch \
             --limit 20 2>/dev/null)" \
        || _die2 "gh run list failed"
    fi
    # Most recent failure per workflow on the watched branch.
    runs="$(jq -c --arg branch "$BRANCH" '
      [.[] | select(.headBranch == $branch)]
      | group_by(.workflowName)
      | map(sort_by(.updatedAt) | last)' <<<"$raw")"
    # Live mode enriches the body with the failing log tail; fixtures skip it
    # (the tail is context for the eventual spec draft, not a triage input).
    items="[]"
    while IFS= read -r run; do
      [[ -n "$run" ]] || continue
      body="$(jq -r '"workflow \(.workflowName) failing on \(.headBranch): \(.displayTitle)"' <<<"$run")"
      if [[ -z "$FIXTURE" ]]; then
        run_id="$(jq -r '.databaseId' <<<"$run")"
        log_tail="$(gh run view "$run_id" --log-failed 2>/dev/null | tail -n 40 || true)"
        [[ -n "$log_tail" ]] && body="$body

failing log tail:
$log_tail"
      fi
      item="$(jq -c --arg body "$body" '{
        source: "ci-failures",
        id: ("ci-" + (.workflowName | ascii_downcase | gsub("[^a-z0-9]+"; "-"))),
        title: ("CI failure: \(.workflowName) — \(.displayTitle)"),
        body: $body,
        url: (.url // null),
        kind: "bug",
        updatedAt: (.updatedAt // null)
      }' <<<"$run")"
      items="$(jq -c --argjson i "$item" '. + [$i]' <<<"$items")"
    done < <(jq -c '.[]' <<<"$runs")
    printf '%s\n' "$items"
    ;;

  backlog)
    entries="$(bash "$SCRIPT_DIR/backlog.sh" list --json)"
    jq -c '[.[] | {
      source: "backlog",
      id: ("backlog-" + (.id // (.text | @base64) | .[0:24])),
      title: .text,
      body: ("backlog entry (\(.date) \(.slug) \(.type)): \(.text)"),
      url: null,
      kind: (if .type == "iterate-gap" or .type == "verify-deferred" then "gap"
             elif .type == "manual" then "chore"
             else "unknown" end),
      updatedAt: (if .date == "" then null else .date + "T00:00:00Z" end)
    }]' <<<"$entries"
    ;;

  assessment)
    FILE="${CLAUDE_PROJECT_DIR:-.}/docs/loop-spec/assessment/ASSESSMENT.md"
    TOP=5; MAX_AGE_DAYS=30
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --file) FILE="${2:-}"; shift 2 || shift ;;
        --top) TOP="${2:-5}"; shift 2 || shift ;;
        --max-age-days) MAX_AGE_DAYS="${2:-30}"; shift 2 || shift ;;
        *) _die2 "unknown flag '$1' for assessment" ;;
      esac
    done
    [[ "$TOP" =~ ^[0-9]+$ ]] || _die2 "--top must be a number (got '$TOP')"
    [[ "$MAX_AGE_DAYS" =~ ^[0-9]+$ ]] || _die2 "--max-age-days must be a number (got '$MAX_AGE_DAYS')"
    if [[ ! -f "$FILE" ]]; then
      echo "[]"; exit 0
    fi
    # Staleness bound: a months-old assessment describes a codebase that no
    # longer exists; better no candidates than confidently stale ones.
    generated="$(grep -m1 '^Generated: ' "$FILE" | sed 's/^Generated: //' || true)"
    fresh=0
    if [[ -n "$generated" ]]; then
      fresh="$(python3 -c '
import sys
from datetime import datetime, timezone
try:
    g = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
    if g.tzinfo is None:
        g = g.replace(tzinfo=timezone.utc)
    age_days = (datetime.now(timezone.utc) - g).days
    print(1 if age_days <= int(sys.argv[2]) else 0)
except Exception:
    print(0)
' "$generated" "$MAX_AGE_DAYS")"
    fi
    if [[ "$fresh" != "1" ]]; then
      echo "[]"; exit 0
    fi
    # Parse the "Cross-repo ranked findings" table:
    # | Rank | Repo | File | Line | Severity | Finding |
    python3 - "$FILE" "$TOP" "$generated" <<'PYEOF'
import json, re, sys

path, top, generated = sys.argv[1], int(sys.argv[2]), sys.argv[3]
items = []
in_section = False
with open(path, encoding="utf-8") as f:
    for line in f:
        if line.startswith("## "):
            in_section = line.strip() == "## Cross-repo ranked findings"
            continue
        if not in_section or not line.strip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 6 or cells[0] in ("Rank", "...") or set(cells[0]) <= {"-", " "}:
            continue
        rank, repo, fpath, lineno, severity, finding = cells[:6]
        if not rank.isdigit():
            continue
        sev = severity.upper()
        kind = {"CRITICAL": "bug", "HIGH": "bug", "MEDIUM": "gap", "LOW": "chore"}.get(sev, "unknown")
        import hashlib
        norm = re.sub(r"[^a-z0-9]+", " ", f"{repo} {fpath} {lineno} {finding}".lower()).strip()
        h = hashlib.sha256(norm.encode()).hexdigest()[:8]
        items.append({
            "source": "assessment",
            "id": f"assess-{h}",
            "title": f"[{sev}] {repo}/{fpath}:{lineno} — {finding}",
            "body": f"assessment finding ({sev}) in {repo}/{fpath}:{lineno}: {finding}",
            "url": None,
            "kind": kind,
            "updatedAt": generated or None,
        })
        if len(items) >= top:
            break
print(json.dumps(items))
PYEOF
    ;;

  *)
    _die2 "unknown subcommand '${cmd:-}' (gh-issues|ci-failures|backlog|assessment|list)"
    ;;
esac
