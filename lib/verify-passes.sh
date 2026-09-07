#!/usr/bin/env bash
# verify-passes.sh - VERIFY's advisory passes after both gates, in one call.
#
# Why: the live run, the verification-gap scan, the plain-language probes, the docs
# lint, the project's review layers, and the reviewer's-guide lint were six lead calls
# whose only judgment is what to write down afterwards (evals/findings-2026-09-06.md,
# finding 7). This runs them and hands the lead their findings as one object; the lead
# records them in VERIFICATION.md and dispatches the reviewers the findings call for.
#
# Usage:
#   verify-passes.sh run --feature-dir DIR
#
# Output (one JSON object):
#   {live:{configured, rc, result},           lib/verify-live.sh run; rc 1 = a probe failed (class live-probe)
#    gaps:{rc, lines[]},                       lib/verification-gap-scan.sh; rc 1 = nothing to scan
#    plainLanguage:{prose:{rc,flags[]}, comments:{rc,flags[]}},
#    docTells:{rc, lines[]},                   lib/doc-tells.sh diff; rc 1 = fixable findings
#    layers:[...],                              lib/extension-points.sh layers verify
#    reviewTrail:{present, rc, findings[]}}    lib/review-trail.sh lint when REVIEW-ORDER.md exists
#
# Exit: 0 always with the object (every pass is advisory; a failed live probe is in .live.rc); 2 bad invocation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib() { bash "$SCRIPT_DIR/$1.sh" "${@:2}"; }

[[ "${1:-}" == "run" ]] || { echo "usage: verify-passes.sh run --feature-dir DIR" >&2; exit 2; }
shift
feature_dir=""
while [[ $# -gt 0 ]]; do case "$1" in --feature-dir) feature_dir="${2:-}"; shift 2 ;; *) echo "verify-passes: unknown argument '$1'" >&2; exit 2 ;; esac; done
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] || { echo "usage: verify-passes.sh run --feature-dir DIR" >&2; exit 2; }
feature_dir="$(cd "$feature_dir" && pwd -P)"
fj="$feature_dir/feature.json"
fget() { jq -r "$1" "$fj"; }
slug="$(fget '.slug')"; base="$(fget '.baseSha // ""')"
root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null || pwd)"
docs="$root/docs/loop-spec/features/$slug"
cd "$root"

lines_json() { jq -R . | jq -cs .; }

live_rc=0; live_out="$(lib verify-live run --evidence "$docs/EVIDENCE.md" 2>/dev/null)" || live_rc=$?
live_json="$(jq -c . <<<"$live_out" 2>/dev/null || echo null)"
live="$(jq -cn --argjson rc "$live_rc" --argjson r "$live_json" '{configured:($r.configured // false), rc:$rc, result:$r}')"

gaps='{"rc":1,"lines":[]}'
if [[ -n "$base" ]]; then
  grc=0; gout="$(lib verification-gap-scan "$base" HEAD 2>/dev/null)" || grc=$?
  gaps="$(jq -cn --argjson rc "$grc" --argjson l "$(printf '%s' "$gout" | lines_json)" '{rc:$rc, lines:$l}')"
fi

prc=0; pout="$(lib plain-language-lint prose "$docs"/*.md --max-flags 40 2>/dev/null)" || prc=$?
changed_code=""
[[ -n "$base" ]] && changed_code="$(git diff --name-only "$base" HEAD -- '*.sh' '*.py' 2>/dev/null | while IFS= read -r f; do [[ -f "$f" ]] && printf '%s\n' "$f"; done)"
crc=0; cout=""
if [[ -n "$changed_code" ]]; then cout="$(printf '%s\n' "$changed_code" | xargs bash "$SCRIPT_DIR/plain-language-lint.sh" comments --max-flags 40 2>/dev/null)" || crc=$?; fi
plain="$(jq -cn --argjson prc "$prc" --argjson pf "$(grep '^FLAG' <<<"$pout" | lines_json)" --argjson crc "$crc" --argjson cf "$(grep '^FLAG' <<<"$cout" | lines_json)" \
  '{prose:{rc:$prc, flags:$pf}, comments:{rc:$crc, flags:$cf}}')"

doc='{"rc":0,"lines":[]}'
if [[ -n "$base" ]]; then
  drc=0; dout="$(lib doc-tells diff "$base" HEAD 2>/dev/null)" || drc=$?
  doc="$(jq -cn --argjson rc "$drc" --argjson l "$(grep -vE '^doc-tells:' <<<"$dout" | grep . | lines_json)" '{rc:$rc, lines:$l}')"
fi

layers="$(lib extension-points layers verify 2>/dev/null | lines_json)"

trail='{"present":false,"rc":0,"findings":[]}'
if [[ -f "$docs/REVIEW-ORDER.md" && -n "$base" ]]; then
  trc=0; tout="$(lib review-trail lint "$docs/REVIEW-ORDER.md" "$base" HEAD 2>/dev/null)" || trc=$?
  trail="$(jq -cn --argjson rc "$trc" --argjson f "$(grep '^finding=' <<<"$tout" | lines_json)" '{present:true, rc:$rc, findings:$f}')"
fi

jq -cn --argjson live "$live" --argjson gaps "$gaps" --argjson plain "$plain" --argjson doc "$doc" --argjson layers "$layers" --argjson trail "$trail" \
  '{live:$live, gaps:$gaps, plainLanguage:$plain, docTells:$doc, layers:$layers, reviewTrail:$trail}'
