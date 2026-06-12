#!/usr/bin/env bash
# lib/fragility-scan.sh <repo-path> [--since <date|sha>] [--top <N>]
#
# Deterministic per-file fragility ranking from git history.
# No LLM. Pure git + python3 stdlib.
#
# Output JSON shape:
#   {
#     "repo":        "<absolute repo path>",
#     "generatedAt": "<ISO-8601>",
#     "window":      "<since value or 'all'>",
#     "files": [
#       {
#         "path":         "src/x.py",
#         "commits":      12,
#         "bugfixCommits": 5,
#         "lastTouched":  "2026-01-15T10:00:00+00:00",
#         "score":        0.83
#       },
#       ...
#     ]
#   }
#
# Score formula (each component normalized 0..1 over the scanned set):
#   score = 0.5 * churn_rank + 0.35 * bugfix_density + 0.15 * recency
#
# Files deleted from the repo (not in `git ls-files`) are excluded.
# --top default 50. Empty history -> "files": [].
# Non-repo path -> exit 1 with message.
#
# Exit codes:
#   0  success
#   1  bad invocation or non-repo path
set -euo pipefail

usage() {
  echo "usage: fragility-scan.sh <repo-path> [--since <date|sha>] [--top <N>]" >&2
}

# Parse arguments.
REPO_PATH=""
SINCE=""
TOP=50

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      if [[ -z "${2:-}" ]]; then
        echo "fragility-scan.sh: --since requires an argument" >&2
        usage
        exit 1
      fi
      SINCE="$2"
      shift 2
      ;;
    --top)
      if [[ -z "${2:-}" ]]; then
        echo "fragility-scan.sh: --top requires an argument" >&2
        usage
        exit 1
      fi
      TOP="$2"
      shift 2
      ;;
    -*)
      echo "fragility-scan.sh: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -n "$REPO_PATH" ]]; then
        echo "fragility-scan.sh: unexpected argument: $1" >&2
        usage
        exit 1
      fi
      REPO_PATH="$1"
      shift
      ;;
  esac
done

if [[ -z "$REPO_PATH" ]]; then
  usage
  exit 1
fi

# Resolve to absolute path.
REPO_ABS="$(cd "$REPO_PATH" 2>/dev/null && pwd)" || {
  echo "fragility-scan.sh: path does not exist: $REPO_PATH" >&2
  exit 1
}

# Verify it is a git repo.
if ! git -C "$REPO_ABS" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "fragility-scan.sh: not a git repository: $REPO_ABS" >&2
  exit 1
fi

# Build the --since argument for git log.
WINDOW="all"
if [[ -n "$SINCE" ]]; then
  WINDOW="$SINCE"
fi

# Collect the set of tracked (non-deleted) files into a temp file.
TRACKED_TMP="$(mktemp)"
git -C "$REPO_ABS" ls-files 2>/dev/null > "$TRACKED_TMP" || true

# Write the aggregation script to a temp file so git log can pipe into python3
# without stdin conflict with a heredoc.
PY_TMP="$(mktemp).py"

# Ensure temp files are removed on exit (normal or error).
trap 'rm -f "$TRACKED_TMP" "$PY_TMP"' EXIT

cat > "$PY_TMP" << 'PYEOF'
import sys
import json
import re
from datetime import datetime, timezone

repo_abs    = sys.argv[1]
top_n       = int(sys.argv[2])
window      = sys.argv[3]
tracked_file = sys.argv[4]

with open(tracked_file) as fh:
    tracked = set(line.rstrip('\n') for line in fh if line.strip())

# Bugfix subject patterns.
bugfix_subject = re.compile(
    r'(?i)^fix[(!:]|\bbug\b|\bregression\b|\bhotfix\b'
)

commit_sep = re.compile(r'^---COMMIT---\s+(\S+)\s+(\S+)\s+(.*)$')

# Per-file accumulators.
file_commits      = {}   # path -> int
file_bugfix       = {}   # path -> int
file_last_touched = {}   # path -> datetime

current_date    = None
current_subject = None
in_numstat      = False

def parse_date(s):
    """Parse ISO-strict date string to datetime with tzinfo."""
    # git --date=iso-strict on macOS may emit trailing 'Z' not '+00:00'.
    s2 = s.replace('Z', '+00:00') if s.endswith('Z') else s
    try:
        return datetime.fromisoformat(s2)
    except ValueError:
        pass
    try:
        return datetime.fromisoformat(s[:19]).replace(tzinfo=timezone.utc)
    except ValueError:
        return datetime.now(timezone.utc)

def record_file(path, is_bugfix, date):
    if path not in tracked:
        return
    file_commits[path]  = file_commits.get(path, 0) + 1
    file_bugfix[path]   = file_bugfix.get(path, 0) + (1 if is_bugfix else 0)
    if path not in file_last_touched or date > file_last_touched[path]:
        file_last_touched[path] = date

for raw_line in sys.stdin:
    line = raw_line.rstrip('\n')
    m = commit_sep.match(line)
    if m:
        current_date    = parse_date(m.group(2))
        current_subject = m.group(3)
        in_numstat      = True
        continue
    if not in_numstat:
        continue
    if line.strip() == '':
        continue
    # numstat line: "<added>\t<deleted>\t<path>" or rename notation
    parts = line.split('\t', 2)
    if len(parts) != 3:
        continue
    added_s, deleted_s, path_field = parts
    # Skip binary files (numstat shows '-' for added/deleted).
    if added_s == '-' or deleted_s == '-':
        continue
    # Handle rename notation: "dir/{old => new}" or "old => new"
    rename_m = re.search(r'\{([^}]*) => ([^}]*)\}', path_field)
    if rename_m:
        prefix = path_field[:rename_m.start()]
        suffix = path_field[rename_m.end():]
        path = (prefix + rename_m.group(2) + suffix).strip()
    elif ' => ' in path_field:
        path = path_field.split(' => ', 1)[1].strip()
    else:
        path = path_field.strip()
    if not path:
        continue
    is_bugfix = bool(bugfix_subject.search(current_subject or ''))
    record_file(path, is_bugfix, current_date)

# Scoring: each component normalized 0..1.
paths = list(file_commits.keys())

if not paths:
    result = {
        "repo":        repo_abs,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "window":      window,
        "files":       []
    }
    print(json.dumps(result))
    sys.exit(0)

# Churn rank: rank by commit count descending (rank 0 = most commits -> score 1.0).
sorted_by_churn = sorted(paths, key=lambda p: (-file_commits[p], p))
churn_rank_score = {}
n = len(paths)
for rank, p in enumerate(sorted_by_churn):
    churn_rank_score[p] = 1.0 - (rank / max(n - 1, 1))

# Bugfix density: bugfix_commits / total_commits, normalized to [0,1].
raw_density = {p: file_bugfix[p] / file_commits[p] for p in paths}
max_density = max(raw_density.values()) if raw_density else 1.0
bugfix_density_score = {}
for p in paths:
    bugfix_density_score[p] = (raw_density[p] / max_density) if max_density > 0 else 0.0

# Recency: inverse of age in days, normalized.
# Anchor "now" to the most recent commit date seen in the scanned history so
# the result is deterministic across runs on a fixed repo (no wall-clock drift).
all_dates = list(file_last_touched.values())
anchor = max(
    (dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc) for dt in all_dates),
    default=datetime.now(timezone.utc)
)

def age_days(p):
    dt = file_last_touched[p]
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    delta = anchor - dt
    return max(delta.total_seconds() / 86400.0, 0.0)

ages = {p: age_days(p) for p in paths}
max_age = max(ages.values()) if ages else 1.0
recency_score = {}
for p in paths:
    # Newer = higher score; older = lower score.
    recency_score[p] = 1.0 - (ages[p] / max_age) if max_age > 0 else 1.0

# Composite score.
scores = {}
for p in paths:
    scores[p] = (
        0.50 * churn_rank_score[p]
        + 0.35 * bugfix_density_score[p]
        + 0.15 * recency_score[p]
    )

# Sort: score desc, then path asc for stable tiebreak.
sorted_paths = sorted(paths, key=lambda p: (-scores[p], p))

# Truncate to --top N.
sorted_paths = sorted_paths[:top_n]

# Build output.
files_out = []
for p in sorted_paths:
    lt = file_last_touched[p]
    if lt.tzinfo is None:
        lt = lt.replace(tzinfo=timezone.utc)
    files_out.append({
        "path":         p,
        "commits":      file_commits[p],
        "bugfixCommits": file_bugfix[p],
        "lastTouched":  lt.isoformat(),
        "score":        round(scores[p], 10)
    })

result = {
    "repo":        repo_abs,
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "window":      window,
    "files":       files_out
}
print(json.dumps(result))
PYEOF

# Run one git log --numstat pass, writing to a temp file so that an empty
# repo (no commits yet) does not propagate git's non-zero exit through the
# pipeline. git log exits 128 on a branch with no commits; that is a valid
# state and results in an empty file, which python3 handles as "files: []".
LOG_TMP="$(mktemp)"
trap 'rm -f "$TRACKED_TMP" "$PY_TMP" "$LOG_TMP"' EXIT

SINCE_FLAG=""
[[ -n "$SINCE" ]] && SINCE_FLAG="--since=$SINCE"

git -C "$REPO_ABS" log \
  --numstat \
  --date=iso-strict \
  --pretty=format:"---COMMIT--- %H %ad %s" \
  ${SINCE_FLAG:+"$SINCE_FLAG"} \
  -- \
  > "$LOG_TMP" 2>/dev/null || true

python3 "$PY_TMP" "$REPO_ABS" "$TOP" "$WINDOW" "$TRACKED_TMP" < "$LOG_TMP"
