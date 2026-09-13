#!/usr/bin/env bash
# Route probe: may this run take the oneshot route (SPEC -> ONESHOT -> DELIVER)?
#
# Why: every run walked DISCUSS, PLAN, EXECUTE, VERIFY, and ITERATE, so a two-line bug
# fix paid the whole cycle (the 6.4.0 haiku slugify-bug run: 1.99 USD, 16 minutes, 384
# artifact lines for 2 lines of code). The route is the cycle's single largest lever
# (the port plan, WP1), and it is decided here, from facts
# SPEC wrote, never by the model picking a phase.
#
# Three inputs, all deterministic, and ALL must hold for `route=oneshot`:
#   1. SPEC.md's frontmatter `footprint:` names 1 to 3 files the change touches.
#   2. `unresolved_questions` is empty.
#   3. `lib/security-signal.sh` finds nothing in SPEC.md or the footprint files that
#      exist: a change that touches a security surface takes the full path even when
#      the spec never says so.
# Escalation is one direction: the spec writer or the ONESHOT phase writes `route: full`
# into the frontmatter and the answer is `route=full`; nothing demotes a full run to
# oneshot. `LOOP_SPEC_ROUTE=full` is the operator's override (lengthen only).
#
# Usage:
#   oneshot.sh --feature-dir DIR [--after]
#   oneshot.sh --feature-dir DIR --candidate
#   oneshot.sh --answers
# `--after` is the reading the graph takes when the ONESHOT phase returns: only the
# escalation key counts, because the phase's own edits to the footprint files are not
# a reason to redo its work on the full path.
# `--candidate` is the reading SPEC takes before its interview, with no SPEC.md yet:
# inputs 1 and 3 over the footprint the scout wrote to disk (`lib/footprint.sh list`,
# the cited files minus the read-only ones). The lead never types the files the probe
# reads (the port principles, rule 1). `route=oneshot`
# selects the lite spec path (skills/spec/SKILL.md, "The oneshot candidate"); the graph's
# own reading after SPEC still decides the route, from the spec as written.
#
# Exit: 0 with one `route=<oneshot|full> reason=<text>` line. Anything undeterminable
# answers `route=full`: the long path is the safe direction.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECURITY_SIGNAL="$SCRIPT_DIR/../../security-signal.sh"
FOOTPRINT_MAX=3

if [[ "${1:-}" == "--answers" ]]; then
  printf 'route=oneshot\nroute=full\n'
  exit 0
fi

full() {
  printf 'route=full reason=%s\n' "$1"
  exit 0
}

feature_dir="" after=0 candidate=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; shift 2 || { echo "oneshot.sh: $1 needs a value" >&2; exit 2; } ;;
    --after) after=1; shift ;;
    --candidate) candidate=1; shift ;;
    *) echo "usage: oneshot.sh --feature-dir DIR [--after | --candidate] | --answers" >&2; exit 2 ;;
  esac
done
[[ -n "$feature_dir" ]] || { echo "usage: oneshot.sh --feature-dir DIR [--after | --candidate] | --answers" >&2; exit 2; }

case "${LOOP_SPEC_ROUTE:-}" in
  "") ;;
  full) full "LOOP_SPEC_ROUTE=full (operator override)" ;;
  *) full "LOOP_SPEC_ROUTE=${LOOP_SPEC_ROUTE} is not an override this probe honors (an operator can lengthen the path, never shorten it)" ;;
esac

feature_json="$feature_dir/feature.json"
[[ -f "$feature_json" ]] || full "no feature.json in $feature_dir"
slug="$(bash "$SCRIPT_DIR/../../feature-read.sh" "$feature_dir" -r --filter '.slug // ""' 2>/dev/null)" || full "feature.json could not be read"
[[ -n "$slug" ]] || full "feature.json has no slug"
ws_root="$(bash "$SCRIPT_DIR/../../feature-read.sh" "$feature_dir" -r --filter 'if (.workspace != null and (.workspace.mode // "") != "single") then .workspace.root else "" end' 2>/dev/null)" || full "feature.json could not be read (workspace field)"
if [[ -n "$ws_root" ]]; then root="$ws_root"; else root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null)" || full "$feature_dir is not inside a git repository"; fi
spec="$(bash "$SCRIPT_DIR/../../feature-read.sh" "$feature_dir" -r --filter '.artifacts.spec // ""' 2>/dev/null)" || spec=""
[[ -n "$spec" ]] || spec="docs/loop-spec/features/$slug/SPEC.md"
[[ "$spec" == /* ]] || spec="$root/$spec"

# The footprint's own reading: count, shape, and the security signal, no spec yet.
security_signal() {
  local rc=0 out
  [[ -x "$SECURITY_SIGNAL" ]] || full "security-signal.sh is not executable"
  out="$(bash "$SECURITY_SIGNAL" first "$@" 2>/dev/null)" || rc=$?
  case "$rc" in
    0) full "security signal in SPEC.md or the footprint (${out})" ;;
    1) ;;
    *) full "security-signal scan could not run (exit ${rc})" ;;
  esac
}
# Count and shape first, in this shell, so `full` ends the probe; then the files that
# exist, for the scan (a greenfield footprint names files it will create).
footprint_shape() {
  local p
  (( $# >= 1 )) || full "footprint names no file"
  (( $# <= FOOTPRINT_MAX )) || full "footprint names $# files (oneshot allows at most $FOOTPRINT_MAX)"
  for p in "$@"; do
    [[ "$p" == /* ]] && full "footprint path $p is absolute (repository-relative paths only)"
  done
  return 0
}
footprint_existing() {
  local p
  for p in "$@"; do [[ -f "$root/$p" ]] && printf '%s\n' "$root/$p"; done
  return 0
}
if (( candidate )); then
  candidates=()
  while IFS= read -r p; do [[ -n "$p" ]] && candidates+=("$p"); done < <(bash "$SCRIPT_DIR/../../footprint.sh" list "$feature_dir")
  (( ${#candidates[@]} )) || full "the scout cited no file (lib/footprint.sh cite writes the footprint the probe reads)"
  footprint_shape "${candidates[@]}"
  targets=()
  while IFS= read -r t; do [[ -n "$t" ]] && targets+=("$t"); done < <(footprint_existing "${candidates[@]}")
  (( ${#targets[@]} )) && security_signal "${targets[@]}"
  printf 'route=oneshot reason=candidate footprint of %d file(s) from the scout record with no security signal (the question gate is read after SPEC)\n' "${#candidates[@]}"
  exit 0
fi
[[ -f "$spec" ]] || full "no SPEC.md at $spec"

# The frontmatter facts, one per line: route=, gate=, unresolved=<count>, footprint=<path>.
facts="$(python3 - "$spec" "$SCRIPT_DIR/../.." <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")
if not lines or lines[0].strip() != "---":
    print("frontmatter=missing"); sys.exit(0)
try:
    end = lines.index("---", 1)
except ValueError:
    print("frontmatter=unterminated"); sys.exit(0)
body = lines[1:end]
route = gate = None
unresolved = footprint = None
section = None
for raw in body:
    line = raw.rstrip()
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    indent = len(line) - len(line.lstrip())
    text = line.strip()
    m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$", text)
    if m and (indent == 0):
        key, val = m.group(1), m.group(2).strip()
        if indent == 0:
            section = key if val == "" else None
        if key == "route" and indent == 0:
            route = val.strip("'\"")
        elif key == "footprint" and indent == 0:
            footprint = [] if val == "" else [p.strip("'\"") for p in re.findall(r"[^\[\],\s'\"]+", val)]
            section = "footprint" if val == "" else None
        continue
    if text.startswith("- ") and section == "footprint" and footprint is not None:
        footprint.append(text[2:].strip().strip("'\""))
sys.path.insert(0, sys.argv[2])
from spec_questions import read_questions
try:
    questions = read_questions("\n".join(lines))
except ValueError:
    print("frontmatter=invalid-questions"); sys.exit(0)
if questions is not None:
    unresolved = questions
    gate = "true" if not questions else "false"
print("route=%s" % (route or ""))
print("gate=%s" % (gate or ""))
print("unresolved=%s" % ("missing" if unresolved is None else len(unresolved)))
for p in (footprint or []):
    print("footprint=%s" % p)
if footprint is None:
    print("footprint-key=missing")
PY
)" || full "SPEC.md frontmatter could not be read"

grep -q '^frontmatter=' <<<"$facts" && full "SPEC.md frontmatter $(sed -n 's/^frontmatter=//p' <<<"$facts")"
route_key="$(sed -n 's/^route=//p' <<<"$facts")"
case "$route_key" in
  full) full "SPEC.md frontmatter says route: full (escalated)" ;;
  ""|oneshot) ;;
  *) full "SPEC.md frontmatter route: $route_key is not oneshot or full" ;;
esac
if (( after )); then
  echo "route=oneshot reason=ONESHOT returned without escalating (route: full absent from SPEC.md)"
  exit 0
fi

grep -q '^footprint-key=missing' <<<"$facts" && full "SPEC.md frontmatter has no footprint: list"
[[ "$(sed -n 's/^gate=//p' <<<"$facts")" == "true" ]] || full "unresolved intent questions remain"
unresolved="$(sed -n 's/^unresolved=//p' <<<"$facts")"
[[ "$unresolved" == "0" ]] || full "unresolved_questions is ${unresolved/missing/absent}, not empty"
footprint=()
while IFS= read -r p; do [[ -n "$p" ]] && footprint+=("$p"); done < <(sed -n 's/^footprint=//p' <<<"$facts")
footprint_shape ${footprint[@]+"${footprint[@]}"}
targets=("$spec")
while IFS= read -r t; do [[ -n "$t" ]] && targets+=("$t"); done < <(footprint_existing "${footprint[@]}")
security_signal "${targets[@]}"
printf 'route=oneshot reason=footprint of %d file(s), no unresolved intent question, no security signal\n' "${#footprint[@]}"
