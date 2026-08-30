#!/usr/bin/env bash
# Route probe: should DISCUSS run the spec-critique subgraph?
#
# Why: the default new-feature path already gated SPEC.md to ambiguity <= 0.20,
# then paid a second author (spec-writer) and a second critic (plus, formerly,
# an advocate debate) for the same artifact. Skipping that critique is a
# declared graph route, not a model judgment: the probe answers from
# feature.json + SPEC.md frontmatter + the security signal. The DISCUSS skill
# runs the same probe so the skill body and graph/cycle.graph.json agree.
#
# Skip (gate=skip) when ALL of these hold, in this order of reasons:
#   1. maintenance profile and no security signal in SPEC.md (same lightening
#      the discuss node itself already takes via short-path.sh).
#   2. SPEC.md is already gated: ambiguity_scores.gate_passed is true AND
#      unresolved_dimensions is empty AND no security signal AND this is not
#      an ITERATE re-entry (iterate.feedback non-null always runs).
# Fail closed: missing/unreadable inputs, a security-signal scan failure, or
# an ungated spec all answer gate=run. An unresolved probe never satisfies a
# skip route (graph-contract.md).
#
# Usage:
#   discuss-critique.sh --feature-dir DIR
#   discuss-critique.sh --answers
#
# Exit: 0 with one `gate=<run|skip|compact> reason=<text>` line. Compact's
# durable gate plan owns this decision, so this legacy probe must not supply a
# second competing answer.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECURITY_SIGNAL="$SCRIPT_DIR/../../security-signal.sh"

if [[ "${1:-}" == "--answers" ]]; then
  printf 'gate=run\ngate=skip\ngate=compact\n'
  exit 0
fi

run() {
  printf 'gate=run reason=%s\n' "$1"
  exit 0
}

skip() {
  printf 'gate=skip reason=%s\n' "$1"
  exit 0
}

feature_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; shift 2 ;;
    *) echo "usage: discuss-critique.sh --feature-dir DIR | --answers" >&2; exit 2 ;;
  esac
done
[[ -n "$feature_dir" ]] || { echo "usage: discuss-critique.sh --feature-dir DIR | --answers" >&2; exit 2; }

feature_json="$feature_dir/feature.json"
[[ -f "$feature_json" ]] || run "no feature.json in $feature_dir"

profile="$(jq -r '.executionProfile // "standard"' "$feature_json" 2>/dev/null)" \
  || run "feature.json could not be read"
if [[ "$profile" == "compact" ]]; then
  echo 'gate=compact reason=compact gate plan owns spec critique'
  exit 0
fi

# ITERATE re-entry revises a spec that was already gated; the old frontmatter
# must not skip the critic that is supposed to catch the gap.
feedback="$(jq -c '.iterate.feedback // null' "$feature_json" 2>/dev/null)" \
  || run "feature.json iterate.feedback could not be read"
[[ "$feedback" == "null" ]] || run "iterate re-entry (feedback present)"

repo_root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null || true)"
spec_path="$(jq -r '.artifacts.spec // empty' "$feature_json" 2>/dev/null)" || spec_path=""
if [[ -n "$spec_path" && "$spec_path" != /* && -n "$repo_root" ]]; then
  spec_path="$repo_root/$spec_path"
fi
if [[ -z "$spec_path" || ! -f "$spec_path" ]]; then
  slug="$(jq -r '.slug // empty' "$feature_json" 2>/dev/null)" || slug=""
  if [[ -n "$repo_root" && -n "$slug" && -f "$repo_root/docs/loop-spec/features/$slug/SPEC.md" ]]; then
    spec_path="$repo_root/docs/loop-spec/features/$slug/SPEC.md"
  fi
fi
[[ -n "$spec_path" && -f "$spec_path" ]] || run "no SPEC.md to judge"

signal_rc=0
signal=""
if [[ -x "$SECURITY_SIGNAL" ]]; then
  signal="$(bash "$SECURITY_SIGNAL" first "$spec_path" 2>/dev/null)" || signal_rc=$?
else
  run "security-signal.sh is not executable"
fi
case "$signal_rc" in
  0) run "security signal in SPEC.md (${signal})" ;;
  1) ;;
  *) run "security-signal scan could not run (exit ${signal_rc})" ;;
esac

[[ "$profile" == "maintenance" ]] && \
  skip "maintenance profile, no security signal"

gate_status="$(python3 - "$spec_path" <<'PY'
from __future__ import print_function
import re, sys
path = sys.argv[1]
try:
    text = open(path, encoding="utf-8").read()
except Exception:
    print("unreadable")
    sys.exit(0)
if not text.startswith("---"):
    print("no-frontmatter")
    sys.exit(0)
end = text.find("\n---", 3)
if end < 0:
    print("unclosed-frontmatter")
    sys.exit(0)
fm = text[4:end]
in_block = False
in_unresolved = False
gate_passed = None
unresolved = None
for line in fm.splitlines():
    if re.match(r"^ambiguity_scores:\s*$", line):
        in_block = True
        continue
    if not in_block:
        continue
    if line.strip() and not line.startswith((" ", "\t")):
        break
    if in_unresolved:
        item = re.match(r"^\s+-\s+(\S+)", line)
        if item:
            unresolved.append(item.group(1).strip("'\""))
            continue
        in_unresolved = False
    m = re.match(r"^\s+gate_passed:\s*(true|false)\s*$", line, re.I)
    if m:
        gate_passed = m.group(1).lower()
        continue
    m = re.match(r"^\s+unresolved_dimensions:\s*\[(.*)\]\s*$", line)
    if m:
        inner = m.group(1).strip()
        if inner == "":
            unresolved = []
        else:
            unresolved = [p.strip().strip("'\"") for p in inner.split(",") if p.strip()]
        continue
    if re.match(r"^\s+unresolved_dimensions:\s*$", line):
        in_unresolved = True
        unresolved = []
        continue
if gate_passed == "true" and unresolved == []:
    print("gated")
elif gate_passed is None and unresolved is None:
    print("no-scores")
else:
    print("ungated")
PY
)" || run "SPEC.md frontmatter could not be parsed"

case "$gate_status" in
  gated) skip "spec already gated: gate_passed, no unresolved dimensions, no security signal" ;;
  *) run "spec not already gated (${gate_status})" ;;
esac
