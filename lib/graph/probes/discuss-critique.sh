#!/usr/bin/env bash
# Route probe: should DISCUSS run the spec-critique subgraph?
#
# Why: the default new-feature path already gated SPEC.md to no unresolved intent questions,
# then paid a second author (spec-writer) and a second critic (plus, formerly,
# an advocate debate) for the same artifact. Skipping that critique is a
# declared graph route, not a model judgment: the probe answers from
# feature.json + SPEC.md frontmatter + the security signal. The DISCUSS skill
# runs the same probe so the skill body and graph/cycle.graph.json agree.
#
# Skip (gate=skip) when ALL of these hold, in this order of reasons:
#   1. maintenance profile and no security signal in SPEC.md (same lightening
#      the discuss node itself already takes via short-path.sh).
#   2. SPEC.md is already gated: unresolved_questions is empty AND no security signal AND this is not
#      an ITERATE re-entry (iterate.feedback non-null always runs) AND the gate
#      was independently answered: an autonomous run with no supervisor selects
#      its own recommended answers and the critic is the only independent read the spec
#      gets. Two live runs skipped it that way.
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
set -euo pipefail

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
    --feature-dir) feature_dir="${2:-}"; shift 2 || { echo "discuss-critique.sh: $1 needs a value" >&2; exit 2; } ;;
    *) echo "usage: discuss-critique.sh --feature-dir DIR | --answers" >&2; exit 2 ;;
  esac
done
[[ -n "$feature_dir" ]] || { echo "usage: discuss-critique.sh --feature-dir DIR | --answers" >&2; exit 2; }

feature_json="$feature_dir/feature.json"
[[ -f "$feature_json" ]] || run "no feature.json in $feature_dir"

profile="$(bash "$SCRIPT_DIR/../../feature-read.sh" "$feature_dir" -r --filter '.executionProfile // "standard"' 2>/dev/null)" \
  || run "feature.json could not be read"
if [[ "$profile" == "compact" ]]; then
  echo 'gate=compact reason=compact gate plan owns spec critique'
  exit 0
fi

# ITERATE re-entry revises a spec that was already gated; the old frontmatter
# must not skip the critic that is supposed to catch the gap.
feedback="$(bash "$SCRIPT_DIR/../../feature-read.sh" "$feature_dir" -c --filter '.iterate.feedback // null' 2>/dev/null)" \
  || run "feature.json iterate.feedback could not be read"
[[ "$feedback" == "null" ]] || run "iterate re-entry (feedback present)"

repo_root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null || true)"
spec_path="$(bash "$SCRIPT_DIR/../../feature-read.sh" "$feature_dir" -r --filter '.artifacts.spec // empty' 2>/dev/null)" || spec_path=""
if [[ -n "$spec_path" && "$spec_path" != /* && -n "$repo_root" ]]; then
  spec_path="$repo_root/$spec_path"
fi
if [[ -z "$spec_path" || ! -f "$spec_path" ]]; then
  slug="$(bash "$SCRIPT_DIR/../../feature-read.sh" "$feature_dir" -r --filter '.slug // empty' 2>/dev/null)" || slug=""
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

oracle="$(bash "$SCRIPT_DIR/../../supervisor/oracle.sh" mode --feature-dir "$feature_dir" 2>/dev/null)" \
  || run "oracle probe could not run"
case "$oracle" in
  # No `=` and no comma in the reason: the driver splits a mode line on spaces and `=`
  # to build its JSON, and a reason that carried `oracle=self` became a field.
  oracle=self*) run "self-answered questions; autonomous run with no supervisor; the critic is the spec's only independent read" ;;
esac

gate_status="$(python3 - "$spec_path" "$SCRIPT_DIR/../.." <<'PY'
from __future__ import print_function
import re, sys
path = sys.argv[1]
try:
    text = open(path, encoding="utf-8").read()
except Exception:
    print("unreadable")
    sys.exit(0)
sys.path.insert(0, sys.argv[2])
from spec_questions import read_questions
try:
    questions = read_questions(text)
except ValueError:
    print("invalid-questions")
    sys.exit(0)
if questions is not None:
    print("gated" if not questions else "unresolved-questions")
    sys.exit(0)

PY
)" || run "SPEC.md frontmatter could not be parsed"

case "$gate_status" in
  gated) skip "spec already gated: no unresolved questions, no security signal" ;;
  *) run "spec not already gated (${gate_status})" ;;
esac
