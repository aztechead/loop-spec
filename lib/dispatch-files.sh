#!/usr/bin/env bash
# dispatch-files.sh - Write per-task briefs and review packages as files.
#
# Why: a pasted diff parks in the controller's context for the rest of the
# session, and a reviewer without a file rebuilds git diff by hand. Superpowers
# v6.0.0 measured that as the largest reviewer cost. Exact values live in the
# brief file; dispatch prompts carry the path.
#
# The brief is the implementer's whole context. A live run
# (the 2026-09-07 tf-meldn runs) had every subagent read SPEC, PLAN, PATTERNS
# and EVIDENCE in full (about 100KB) to find the three rules that bound it, and re-probe
# the toolchain the lead had already probed. So the brief now carries the slices:
# PLAN.md's `## Global constraints` verbatim, the EVIDENCE.md rows the task cites by
# EVID id, and dispatch/environment.txt (tool versions the lead recorded; see
# lib/execute-prepare.sh). The prompt template tells the implementer not to open the
# artifacts.
#
# Usage:
#   dispatch-files.sh brief --feature-dir <dir> --task-id <id> [--out <file>]
#   dispatch-files.sh package --repo <root> --base <sha> --head <sha> [--out <file>]
#   dispatch-files.sh report-path --feature-dir <dir> --task-id <id>
#
# Exit codes:
#   0  wrote the file / printed the path
#   2  usage, missing task, bad SHA, or BASE is HEAD~1/HEAD^
set -euo pipefail

cmd="${1:-}"
shift || true

FEATURE_DIR=""
TASK_ID=""
OUT=""
REPO=""
BASE=""
HEAD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) FEATURE_DIR="${2:-}"; shift 2 ;;
    --task-id) TASK_ID="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --head) HEAD="${2:-}"; shift 2 ;;
    *) echo "dispatch-files.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

dispatch_dir() {
  mkdir -p "$FEATURE_DIR/dispatch"
  printf '%s\n' "$FEATURE_DIR/dispatch"
}

case "$cmd" in
  brief)
    [[ -n "$FEATURE_DIR" && -n "$TASK_ID" ]] \
      || { echo "usage: dispatch-files.sh brief --feature-dir <dir> --task-id <id> [--out <file>]" >&2; exit 2; }
    [[ -d "$FEATURE_DIR" ]] || { echo "dispatch-files.sh: no feature dir $FEATURE_DIR" >&2; exit 2; }
    if [[ -z "$OUT" ]]; then
      OUT="$(dispatch_dir)/${TASK_ID}-brief.md"
    fi
    tasks="$FEATURE_DIR/tasks.json"
    [[ -f "$tasks" ]] || { echo "dispatch-files.sh: missing $tasks" >&2; exit 2; }
    # A merged chain or batch (lib/task-batch.sh) lives only in the collapsed list.
    task_json=""
    [[ -f "$FEATURE_DIR/dispatch/tasks-collapsed.json" ]] \
      && task_json="$(jq -c --arg id "$TASK_ID" '.[] | select(.id == $id)' "$FEATURE_DIR/dispatch/tasks-collapsed.json" 2>/dev/null || true)"
    [[ -n "$task_json" ]] || task_json="$(jq -c --arg id "$TASK_ID" '.[] | select(.id == $id)' "$tasks")"
    [[ -n "$task_json" ]] || { echo "dispatch-files.sh: task $TASK_ID not in $tasks" >&2; exit 2; }
    # Slices: the docs dir is feature.json's artifacts.plan parent, else the conventional path.
    docs_dir=""
    if [[ -f "$FEATURE_DIR/feature.json" ]]; then
      plan_rel="$(jq -r '.artifacts.plan // ""' "$FEATURE_DIR/feature.json")"
      root="$(git -C "$FEATURE_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
      [[ -n "$plan_rel" && -n "$root" ]] && docs_dir="$(dirname "$root/$plan_rel")"
      [[ -n "$docs_dir" && -d "$docs_dir" ]] || docs_dir="${root:-$FEATURE_DIR/../../..}/docs/loop-spec/features/$(basename "$FEATURE_DIR")"
    fi
    constraints="- none"
    [[ -n "$docs_dir" && -f "$docs_dir/PLAN.md" ]] && constraints="$(awk '/^## Global constraints/{on=1; next} on && /^## /{exit} on && !/^<!--/ && !/^ *-->$/ && NF' "$docs_dir/PLAN.md")"
    [[ -n "$constraints" ]] || constraints="- none"
    cited=""
    ids="$(grep -o 'EVID-[0-9][0-9]*' <<<"$task_json" | sort -u || true)"
    if [[ -n "$ids" && -n "$docs_dir" && -f "$docs_dir/EVIDENCE.md" ]]; then
      cited="$(grep -F -f <(printf '%s\n' $ids | sed 's/$/ |/') "$docs_dir/EVIDENCE.md" | grep '^- EVID-' || true)"
    fi
    environment=""
    [[ -f "$FEATURE_DIR/dispatch/environment.txt" ]] && environment="$(cat "$FEATURE_DIR/dispatch/environment.txt")"
    jq -r --arg id "$TASK_ID" --arg constraints "$constraints" --arg cited "$cited" --arg environment "$environment" '
      "# Task brief: \($id)",
      "",
      "**Subject:** \(.subject // .brief // "")",
      "",
      "## Files",
      ((.files // []) | if length == 0 then "- none" else map("- \(.)") | .[] end),
      "",
      "## Interfaces",
      (if .interfaces then
         # consumes/produces are a string or an array of strings (artifact-lint);
         # an implementer reads prose, so an array joins rather than printing JSON.
         "- Consumes: \(.interfaces.consumes | if type == "array" then join(", ") else (. // "none") end)",
         "- Produces: \(.interfaces.produces | if type == "array" then join(", ") else (. // "none") end)"
       elif .Interfaces then
         .Interfaces
       else
         "- none"
       end),
      "",
      "## Verify",
      (.verifyCommand // "true"),
      "",
      "## Acceptance criteria",
      ((.acceptanceCriteria // []) | if length == 0 then "- none" else to_entries[] | "\(.key + 1). \(.value)" end),
      "",
      "## Brief",
      (.brief // .subject // ""),
      "",
      "## Global constraints (PLAN.md, verbatim; every one binds)",
      $constraints,
      "",
      (if $cited != "" then "## Evidence this task cites (EVIDENCE.md rows; do not re-probe)\n\($cited)\n" else empty end),
      (if $environment != "" then "## Environment (probed by the lead; do not re-check versions or auth)\n\($environment)\n" else empty end),
      "## Context rule",
      "Everything that binds this task is in this brief and the files listed. Do not read SPEC.md, PLAN.md, PATTERNS.md, or EVIDENCE.md; ask the lead if a value is missing.",
      "",
      (if .batchGroup then "## Batch group\n\(.batchGroup)\n" else empty end),
      (if .memberIds then "## Batch members\n\(.memberIds | map("- \(.)") | join("\n"))\n" else empty end)
    ' <<<"$task_json" > "$OUT"
    echo "$OUT"
    ;;
  report-path)
    [[ -n "$FEATURE_DIR" && -n "$TASK_ID" ]] \
      || { echo "usage: dispatch-files.sh report-path --feature-dir <dir> --task-id <id>" >&2; exit 2; }
    dir="$(dispatch_dir)"
    echo "$dir/${TASK_ID}-report.md"
    ;;
  package)
    [[ -n "$REPO" && -n "$BASE" && -n "$HEAD" ]] \
      || { echo "usage: dispatch-files.sh package --repo <root> --base <sha> --head <sha> [--out <file>]" >&2; exit 2; }
    case "$BASE" in
      HEAD~1|HEAD^|HEAD~)
        echo "dispatch-files.sh: BASE must be a recorded SHA, not $BASE (truncates multi-commit tasks)" >&2
        exit 2
        ;;
    esac
    [[ -d "$REPO" ]] || { echo "dispatch-files.sh: no repo $REPO" >&2; exit 2; }
    git -C "$REPO" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null \
      || { echo "dispatch-files.sh: bad BASE: $BASE" >&2; exit 2; }
    git -C "$REPO" rev-parse --verify --quiet "$HEAD^{commit}" >/dev/null \
      || { echo "dispatch-files.sh: bad HEAD: $HEAD" >&2; exit 2; }
    base_full="$(git -C "$REPO" rev-parse "$BASE")"
    head_full="$(git -C "$REPO" rev-parse "$HEAD")"
    if [[ -z "$OUT" ]]; then
      short_b="$(git -C "$REPO" rev-parse --short "$BASE")"
      short_h="$(git -C "$REPO" rev-parse --short "$HEAD")"
      OUT="${TMPDIR:-/tmp}/review-${short_b}..${short_h}.diff"
    fi
    mkdir -p "$(dirname "$OUT")"
    {
      echo "# Review package: ${base_full}..${head_full}"
      echo
      echo "## Commits"
      git -C "$REPO" log --oneline "${BASE}..${HEAD}"
      echo
      echo "## Files changed"
      git -C "$REPO" diff --stat "${BASE}..${HEAD}"
      echo
      echo "## Diff"
      git -C "$REPO" diff -U10 "${BASE}..${HEAD}"
    } > "$OUT"
    echo "$OUT"
    ;;
  *)
    echo "usage: dispatch-files.sh brief|package|report-path" >&2
    exit 2
    ;;
esac
