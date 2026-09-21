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
#       also writes <id>-contracts.md beside the brief: the shared contracts the task's files call for, rendered from the sources
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
    --feature-dir) FEATURE_DIR="${2:-}"; shift 2 || { echo "dispatch-files: $1 needs a value" >&2; exit 2; } ;;
    --task-id) TASK_ID="${2:-}"; shift 2 || { echo "dispatch-files: $1 needs a value" >&2; exit 2; } ;;
    --out) OUT="${2:-}"; shift 2 || { echo "dispatch-files: $1 needs a value" >&2; exit 2; } ;;
    --repo) REPO="${2:-}"; shift 2 || { echo "dispatch-files: $1 needs a value" >&2; exit 2; } ;;
    --base) BASE="${2:-}"; shift 2 || { echo "dispatch-files: $1 needs a value" >&2; exit 2; } ;;
    --head) HEAD="${2:-}"; shift 2 || { echo "dispatch-files: $1 needs a value" >&2; exit 2; } ;;
    *) echo "dispatch-files.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

dispatch_dir() {
  mkdir -p "$FEATURE_DIR/dispatch"
  printf '%s\n' "$FEATURE_DIR/dispatch"
}

render_sections() {
  local source="$1"; shift
  local title
  title="$(awk 'NR == 1 && /^# / { sub(/^# /, ""); print; found=1; exit } END { if (!found) exit 1 }' "$source")" \
    || { echo "dispatch-files.sh: contract source has no title: $source" >&2; return 2; }
  printf '# %s\n' "$title"
  local heading
  for heading in "$@"; do
    awk -v wanted="$heading" '
      $0 == "## " wanted { on=1; found=1; print; next }
      on && /^## / { exit }
      on { print }
      END { if (!found) exit 7 }
    ' "$source" || {
      local status=$?
      [[ "$status" -eq 7 ]] && echo "dispatch-files.sh: required contract section missing: $source: $heading" >&2
      return 2
    }
  done
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
    if [[ -n "$docs_dir" && -f "$docs_dir/PLAN.md" ]]; then
      constraints="$(awk '/^## Global constraints/{on=1; next} on && /^## /{exit} on{print}' "$docs_dir/PLAN.md" \
        | awk '
          function visible(s, p, q, pre, rest) {
            while (1) {
              if (comment) {
                q = index(s, "-->")
                if (!q) return
                s = substr(s, q + 3)
                comment = 0
              }
              p = index(s, "<!--")
              if (!p) {
                sub(/[[:space:]]+$/, "", s)
                if (s ~ /[^[:space:]]/) print s
                return
              }
              pre = substr(s, 1, p - 1)
              rest = substr(s, p + 4)
              q = index(rest, "-->")
              if (q) {
                s = pre substr(rest, q + 3)
                continue
              }
              sub(/[[:space:]]+$/, "", pre)
              if (pre ~ /[^[:space:]]/) print pre
              comment = 1
              return
            }
          }
          { visible($0) }
          ' )"
    fi
    [[ -n "$constraints" ]] || constraints="- none"
    cited=""
    ids="$(grep -o 'EVID-[0-9][0-9]*' <<<"$task_json" | sort -u || true)"
    if [[ -n "$ids" && -n "$docs_dir" && -f "$docs_dir/EVIDENCE.md" ]]; then
      cited="$(grep -F -f <(printf '%s\n' $ids | sed 's/$/ |/') "$docs_dir/EVIDENCE.md" | grep '^- EVID-' || true)"
    fi
    environment=""
    [[ -f "$FEATURE_DIR/dispatch/environment.txt" ]] && environment="$(cat "$FEATURE_DIR/dispatch/environment.txt")"
    # The contracts this task's files call for, rendered into one file beside the brief.
    # The stanza names eight sources and the implementer opened each with its own Read
    # on every dispatch (6.5.0 cycle here, 56 KB and eight turns per task); a task that
    # touches no markdown never needed the docs contract. Rendered from the sources at
    # dispatch time, so the copy cannot rot.
    shared_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/shared" && pwd)"
    contracts="engineering-directives.md implementer-contract.md execution-discipline.md"
    jq -e '[.files[]? | select(test("\\.(md|markdown|rst)$") | not)] | length > 0' <<<"$task_json" >/dev/null \
      && contracts="$contracts laziness-ladder.md design-for-change.md human-code.md"
    jq -e '[.files[]? | select(test("\\.(md|markdown|mdx|rst)$"))] | length > 0' <<<"$task_json" >/dev/null \
      && contracts="$contracts human-docs.md"
    jq -e '[.files[]? | select(test("(^|/)(tests?|__tests__|spec)/|\\.test\\.|_test\\.|(^|/)test_|\\.spec\\."))] | length > 0' <<<"$task_json" >/dev/null \
      && contracts="$contracts writing-good-tests.md"
    contracts_out="$(dirname "$OUT")/${TASK_ID}-contracts.md"
    for c in $contracts; do
      [[ -f "$shared_dir/$c" ]] \
        || { echo "dispatch-files.sh: contract source missing: $shared_dir/$c" >&2; exit 2; }
    done
    {
      echo "# Contracts for $TASK_ID (rendered from skills/shared at dispatch; the sources bind)"
      for c in $contracts; do
        printf '\n\n---\n\n<!-- source: %s -->\n\n' "$shared_dir/$c"
        case "$c" in
          engineering-directives.md)
            echo "> Rendered sections: Code directives; Version evidence; Test directives. Full diagnostic reference (consult only if a probe needs interpretation): $shared_dir/$c."
            render_sections "$shared_dir/$c" "Code directives" "Version evidence" "Test directives" || exit 2
            ;;
          laziness-ladder.md)
            echo "> Rendered sections: Compact directive (read this file; do not paste it into a prompt); Resolving the probe (<probe_dir>); Companion directives. Full diagnostic reference (consult only if a probe needs interpretation): $shared_dir/$c."
            render_sections "$shared_dir/$c" \
              "Compact directive (read this file; do not paste it into a prompt)" \
              'Resolving the probe (`<probe_dir>`)' "Companion directives" || exit 2
            ;;
          *)
            cat "$shared_dir/$c"
            ;;
        esac
      done
    } > "$contracts_out" || { echo "dispatch-files.sh: cannot write $contracts_out" >&2; exit 2; }
    jq -r --arg id "$TASK_ID" --arg constraints "$constraints" --arg cited "$cited" --arg environment "$environment" --arg contracts_out "$contracts_out" --arg contracts "$contracts" '
      "# Task brief: \($id)",
      "",
      "**Subject:** \(.subject // .brief // "")",
      "",
      (if .goal then "## Goal\n\(.goal)\n" else empty end),
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
      (if .expected then "Expected: \(.expected)" else empty end),
      "",
      "## Acceptance criteria",
      ((.acceptanceCriteria // []) | if length == 0 then "- none" else to_entries[] | "\(.key + 1). \(.value)" end),
      "",
      "## Brief",
      (.brief // .subject // ""),
      (if (.steps // []) | length > 0 then
         "\n## Steps\n" + ((.steps // []) | to_entries | map("- " + .value) | join("\n")) + "\n"
       else empty end),
      "",
      "## Global constraints (PLAN.md, verbatim; every one binds)",
      $constraints,
      "",
      (if $cited != "" then "## Evidence this task cites (EVIDENCE.md rows; do not re-probe)\n\($cited)\n" else empty end),
      (if $environment != "" then "## Environment (probed by the lead; do not re-check versions or auth)\n\($environment)\n" else empty end),
      "## Read first",
      "- \($contracts_out): the engineering contracts these files call for (\($contracts | split(" ") | join(", "))), rendered from skills/shared at dispatch. Read it once instead of opening the sources.",
      "",
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
    if [[ "$base_full" == "$head_full" ]]; then
      echo "dispatch-files.sh: BASE and HEAD resolve to the same commit; refusing an empty review package" >&2
      exit 2
    fi
    if [[ -z "$OUT" ]]; then
      short_b="$(git -C "$REPO" rev-parse --short "$BASE")"
      short_h="$(git -C "$REPO" rev-parse --short "$HEAD")"
      OUT="${TMPDIR:-/tmp}/review-${short_b}..${short_h}.diff"
    fi
    mkdir -p "$(dirname "$OUT")"
    has_code_change=1
    git -C "$REPO" diff --quiet "${BASE}..${HEAD}" -- && has_code_change=0
    {
      echo "# Review package: ${base_full}..${head_full}"
      echo
      echo "## Commits"
      git -C "$REPO" log --oneline "${BASE}..${HEAD}"
      echo
      echo "## Files changed"
      git -C "$REPO" diff --stat "${BASE}..${HEAD}"
      if [[ "$has_code_change" -eq 0 ]]; then
        echo
        echo "## No code changes"
        echo "This package contains a distinct commit with no code diff. Review the commit and verify the current tree against the task brief before accepting it."
      fi
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
