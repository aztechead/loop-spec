#!/usr/bin/env bash
# oneshot-exit-gate.sh - ONESHOT's exit: an escalated spec closes with nothing to
# check; otherwise the change is scanned and VERIFICATION.md proves every criterion.
#
# Why: the oneshot route (docs/loop-spec/orchestrator-port-plan.md, WP1) folds
# EXECUTE's scans and VERIFY's record into one phase, so its exit has two readings that
# phase-exit.sh's data cannot key on: `route: full` lives in SPEC.md's frontmatter, not
# feature.json. This script reads it once. The `oneshot` node of graph/cycle.graph.json
# lists it as a gate; lib/graph/probes/oneshot.sh --after then routes the escalated
# run to DISCUSS and the finished one to DELIVER.
#
# Usage: oneshot-exit-gate.sh <feature-dir>
# Output: `FLAG [<gate>] <finding>` lines; exit 1 when any, 0 when clean, 2 bad call.
# Gates on a finished run: placeholder scan and test-tamper scan over the diff since
# baseSha (the same bodies VERIFY's gate nodes run; per repo in workspace mode), every
# footprint file in that diff (an untouched non-test file is dropped with a
# `NOTE [footprint]` line, never a flag), no file in that diff outside the footprint
# (one is the fourth file the route does not allow: the gate writes `route: full` into
# SPEC.md with the file named and the run takes the full path), the frozen Intent block
# unchanged since SPEC committed it, a recorded code-reviewer dispatch, artifact-lint
# verification, verification-grounding-lint, review-triage-lint over the findings, and
# the converged floor (every Good Enough row PASS).
# An escalated run (`route: full` in the frontmatter) still gets the two scans and the
# three verification lints when VERIFICATION.md exists; only the footprint, intent,
# review, and floor checks are the oneshot's own. A SPEC.md the probe cannot read as
# either shape is a flag, never a pass: a gate that passes on an unreadable input is
# the failure class the determinism audit exists to remove (orchestrator-port-followup.md, F6).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/exit-gate-prelude.sh" "${1:-}"
spec="$(fget '.artifacts.spec // ""')"; [[ -n "$spec" ]] || spec="$docs/SPEC.md"

answer="$(bash "$SCRIPT_DIR/graph/probes/oneshot.sh" --feature-dir "$feature_dir" --after 2>/dev/null)"
escalated=0
case "$answer" in
  "route=full reason=SPEC.md frontmatter says route: full"*) escalated=1 ;;
  route=full*) flag "[oneshot] $spec is not readable as a oneshot or an escalated spec (${answer#route=full reason=}): restore the frontmatter the SPEC exit accepted"; escalated=1 ;;
  route=oneshot*) ;;
  *) echo "FLAG [oneshot] lib/graph/probes/oneshot.sh --after returned an error for $spec (route line expected)"; exit 1 ;;
esac

run_gate placeholder lib feature-scan-each "$SCRIPT_DIR/placeholder-scan.sh" --feature-dir "$feature_dir"
run_gate tamper lib feature-scan-each "$SCRIPT_DIR/test-tamper-scan.sh" --feature-dir "$feature_dir"
# The footprint is a promise: every file it names is in the diff. The first wc-json run
# on the route named the test file, never touched it, and shipped without the test the
# spec's own footprint had committed to. A file the diff never touched is read three
# ways: an Implementation notes bullet that says `unchanged` or `read-only` is the
# spec's own word; a test module with no such bullet stays a flag (the promise that
# mattered); any other file is dropped from the footprint here, with a note under
# Implementation notes, because a bounce to the lead for a file nobody changed was one
# of six format REDO rounds on the dda2cca bug fix (orchestrator-port-followup.md, F4).
base_sha="$(fget '.baseSha // ""')"
drop_from_footprint() {
  python3 - "$spec" "$1" "$2" <<'PY'
import re, sys
path, f, sha = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^  - %s\n" % re.escape(f), "", text, count=1, flags=re.M)
text = re.sub(r"^(footprint: *\[)([^\]]*)(\])", lambda m: m.group(1) + ", ".join(p for p in re.split(r"\s*,\s*", m.group(2)) if p and p != f) + m.group(3), text, count=1, flags=re.M)
note = "- %s: unchanged; dropped from the footprint by lib/oneshot-exit-gate.sh (not in the diff since %s)\n" % (f, sha[:12])
text = text.replace("## Implementation notes\n\n", "## Implementation notes\n\n" + note, 1)
open(path, "w", encoding="utf-8").write(text)
PY
}
# In workspace mode every repo is diffed against its own baseSha and the paths are
# workspace-root relative, the way VERIFICATION.md writes them.
changed=""
if [[ -n "$ws_root" ]]; then
  while IFS=$'\t' read -r rpath rsha; do
    [[ -n "$rpath" && -n "$rsha" ]] || continue
    changed+="$(git -C "$root/$rpath" diff --name-only "$rsha" HEAD -- 2>/dev/null | sed "s|^|${rpath%/}/|")"$'\n'
  done < <(fget '.workspace.repos[]? | [.path, .baseSha] | @tsv')
  base_sha="per-repo baseSha"
elif [[ -n "$base_sha" ]]; then
  changed="$(git diff --name-only "$base_sha" HEAD -- 2>/dev/null || true)"
fi
footprint=()
while IFS= read -r f; do [[ -n "$f" ]] && footprint+=("$f"); done \
  < <(sed -n '/^footprint:/,/^[^ ]/p' "$spec" | sed -n 's/^  - //p; s/^footprint: *\[\(.*\)\]$/\1/p' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sed '/^$/d')
# The other direction: a changed file the footprint does not name is the fourth file,
# and the route is over. The gate escalates the run itself, with the file named, so the
# --after probe routes to DISCUSS and nothing ships past the footprint unchecked.
if (( ! escalated )); then
  outside=""
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ "$f" == docs/loop-spec/* || "$f" == .loop-spec/* || "$f" == */docs/loop-spec/* || "$f" == */.loop-spec/* ]] && continue
    printf '%s\n' "${footprint[@]+"${footprint[@]}"}" | grep -qxF "$f" && continue
    outside+="$f "
  done <<<"$changed"
  if [[ -n "$outside" ]]; then
    python3 - "$spec" "$outside" <<'PY'
import re, sys
path, files = sys.argv[1], sys.argv[2].strip()
text = open(path, encoding="utf-8").read()
if not re.search(r"^route: *full\s*$", text, flags=re.M):
    text = re.sub(r"^---\n(.*?)^---\n", lambda m: "---\n" + m.group(1) + "route: full\n---\n", text, count=1, flags=re.M | re.S)
note = "- escalated by lib/oneshot-exit-gate.sh: the diff touches %s, outside the footprint; the run takes the full path\n" % files
text = text.replace("## Implementation notes\n\n", "## Implementation notes\n\n" + note, 1)
open(path, "w", encoding="utf-8").write(text)
PY
    echo "NOTE [footprint] the diff touches ${outside% } outside SPEC.md's footprint: route: full written to $spec; the run continues on the full path (DISCUSS)"
    escalated=1
  fi
fi
if (( ! escalated )) && [[ -n "$base_sha" ]]; then
  notes="$(sed -n '/^## Implementation notes$/,/^## /p' "$spec")"
  for f in "${footprint[@]+"${footprint[@]}"}"; do
    [[ -n "$f" ]] || continue
    grep -qxF "$f" <<<"$changed" && continue
    grep -Eq "^- ${f//./\\.}: .*(unchanged|read-only)" <<<"$notes" && continue
    b="$(basename "$f")"
    if [[ "$f" == tests/* || "$f" == */tests/* || "$f" == test/* || "$b" == test_* || "$b" == *_test.* || "$b" == *.test.* ]]; then
      flag "[footprint] $f is in SPEC.md's footprint but not in the diff since $base_sha: make the change there, or say it stays unchanged in a line under Implementation notes (- $f: unchanged, because ...)"
    else
      drop_from_footprint "$f" "$base_sha"
      echo "NOTE [footprint] $f was not in the diff since $base_sha: dropped from SPEC.md's footprint with a line under Implementation notes"
    fi
  done
fi
if (( ! escalated )); then
  # The Intent block is the ask and it is frozen: ONESHOT changes code to meet it, never
  # the block to meet the code. A changed ask is an escalation (route: full), not an edit.
  intent_block() { sed -n '/^<!-- intent: frozen/,/^<!-- \/intent -->$/p'; }
  rel="${spec#"$root/"}"
  committed="$(git show "HEAD:$rel" 2>/dev/null | intent_block)"
  if [[ -n "$committed" && "$committed" != "$(intent_block < "$spec")" ]]; then
    flag "[intent] the frozen Intent block of $rel changed since its commit: restore it (git show HEAD:$rel); when the ask itself is wrong, escalate with route: full instead"
  fi
  # One review pass, and it happened: the dispatch event the skill emits when it launches
  # the reviewer (skills/shared/dispatch.md). The first slugify run on the route wrote
  # "No findings" under Code review with nobody dispatched.
  if ! jq -e 'select(.event == "dispatch" and .phase == "oneshot" and ((.data.role // "") | test("code-reviewer")))' \
      "$feature_dir/events.jsonl" >/dev/null 2>&1; then
    flag "[review] no code-reviewer dispatch recorded for oneshot in $feature_dir/events.jsonl: dispatch loop-spec:code-reviewer once and emit the dispatch event (skills/oneshot/SKILL.md, One review pass)"
  fi
fi
if [[ -f "$docs/VERIFICATION.md" ]]; then
  run_gate artifact-lint lib artifact-lint verification "$docs/VERIFICATION.md"
  run_gate verification-grounding lib verification-grounding-lint "$docs/VERIFICATION.md" --repo "$root" --spec "$spec"
  run_gate review-triage lib review-triage-lint "$docs/VERIFICATION.md"
  (( escalated )) || run_gate converged-floor lib converged-floor "$spec" "$docs/VERIFICATION.md"
elif (( ! escalated )); then
  flag "[verification] $docs/VERIFICATION.md missing: ONESHOT writes it after the criteria pass (skills/oneshot/SKILL.md, Verify)"
fi
(( flags == 0 )) || exit 1
exit 0
