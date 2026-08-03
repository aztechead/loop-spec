#!/usr/bin/env bash
# Tests for lib/deferral-lint.sh -- no self-authored deferral on completion surfaces.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/deferral-lint.sh"
PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/deferral-lint-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# --- text surface ---

# Clean completion report -> ok.
printf 'All acceptance criteria pass. PR opened.\n' | bash "$LIB" text - >/dev/null 2>&1
check "clean report ok (exit 0)" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# The canonical sin: "Deferred items:" in a done report -> flagged.
printf 'Done!\nDeferred items: flaky test cleanup\n' | bash "$LIB" text - >/dev/null 2>&1
check "'Deferred items' flagged (exit 1)" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# Follow-up phrasing -> flagged.
printf 'Shipped.\nFollow-ups: tighten validation later.\n' | bash "$LIB" text - >/dev/null 2>&1
check "follow-ups flagged" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# Future-work phrasing -> flagged.
printf 'Complete.\nFuture work: add caching.\n' | bash "$LIB" text - >/dev/null 2>&1
check "future work flagged" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# Reported wording is not a declaration of current feature scope.
printf 'The refactor lands in a later PR.\n' | bash "$LIB" text - >/dev/null 2>&1
check "reported later PR wording allowed" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Gate-marked lines are exempt.
printf 'iterate-budget-spent: gap X deferred to backlog after limit\n' | bash "$LIB" text - >/dev/null 2>&1
check "iterate-budget-spent line exempt" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"
printf 'iterate-terminal: two limits spent; deferred permanently\n' | bash "$LIB" text - >/dev/null 2>&1
check "iterate-terminal line exempt" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"
printf 'Minor finding backlogged as verify-deferred entry\n' | bash "$LIB" text - >/dev/null 2>&1
check "verify-deferred line exempt" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"
printf 'code review: PASS_WITH_MINOR, minors backlogged\n' | bash "$LIB" text - >/dev/null 2>&1
check "PASS_WITH_MINOR line exempt" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Word boundaries: benign words containing the stems do not match.
printf 'The referred doctor followed up on nothing here.\n' | bash "$LIB" text - >/dev/null 2>&1
check "'referred' does not match defer stem" "$([[ $? -eq 1 ]] && echo 0 || echo 1)"
printf 'Difference between the two branches is zero.\n' | bash "$LIB" text - >/dev/null 2>&1
check "'difference' benign" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Inline code spans are not prose: a slug/path containing a vocabulary word is exempt.
printf 'Artifacts: `docs/loop-spec/features/defer-token-refresh/SPEC.md`\n' | bash "$LIB" text - >/dev/null 2>&1
check "backticked path exempt" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Fenced code blocks are skipped entirely.
printf '```bash\nbacklog.sh add slug verify-deferred "deferred item"\n```\nAll shipped.\n' | bash "$LIB" text - >/dev/null 2>&1
check "fenced block exempt" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Context/polarity: this is the user-reported false-positive surface. These
# statements may name the terminology without declaring that feature scope was lost.
printf 'No follow-up action required.\n' | bash "$LIB" text - >/dev/null 2>&1
check "negated follow-up allowed" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"
printf '#### Minor (deferred)\n\nnone\n' | bash "$LIB" text - >/dev/null 2>&1
check "template heading with none allowed" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"
printf '> Deferred items: this quoted report describes an old run.\n' | bash "$LIB" text - >/dev/null 2>&1
check "quoted reported usage allowed" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"
printf 'This maintainer report explains how the deferral guard matched a word.\n' | bash "$LIB" text - >/dev/null 2>&1
check "tooling report allowed" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# A real scope declaration still cannot ship, whether it is a key/value line,
# an explicit section, or a direct first-person commitment.
printf 'Deferred scope: retry timeout handling\n' | bash "$LIB" text - >/dev/null 2>&1
check "deferred scope declaration flagged" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"
printf '## Follow-ups\n\n- add the second provider\n' | bash "$LIB" text - >/dev/null 2>&1
check "follow-up section with item flagged" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"
printf '## Deferred scope\n\nNone\n' | bash "$LIB" text - >/dev/null 2>&1
check "deferred scope section with none allowed" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"
printf 'We will defer the retry timeout to a later change.\n' | bash "$LIB" text - >/dev/null 2>&1
check "first-person future deferral flagged" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"
printf 'Deferred scope: retry timeout handling (not a verify-deferred item).\n' | bash "$LIB" text - >/dev/null 2>&1
check "marker word cannot exempt a model declaration" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# FLAG output reports the matched term and line.
out="$(printf 'ok\nDeferred items: x\n' | bash "$LIB" text - 2>/dev/null)"
check "flag names the term" "$(echo "$out" | grep -qi "deferred" && echo 1 || echo 0)"
check "flag carries the line number" "$(echo "$out" | grep -q ':2:' && echo 1 || echo 0)"

# Final one-line answer with reason (ANSWER + REASON contract).
check "final answer line present" "$(echo "$out" | grep -q '^deferral-lint: 1 flag(s)' && echo 1 || echo 0)"

# File path input works.
printf 'Remaining work: wire up the second provider.\n' > "$tmp/report.md"
bash "$LIB" text "$tmp/report.md" >/dev/null 2>&1
check "file input flagged" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# Unreadable file -> fail safe (exit 1).
bash "$LIB" text "$tmp/does-not-exist.md" >/dev/null 2>&1
check "unreadable input fails safe" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# --- warnings surface ---

# Gate-prefixed warning may speak deferral language.
printf '{"warnings":["iterate-budget-spent: gap deferred after 3 rounds"]}' > "$tmp/f1.json"
bash "$LIB" warnings "$tmp/f1.json" >/dev/null 2>&1
check "gate-prefixed warning ok" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Warnings are diagnostics, not a declaration that feature scope was dropped.
printf '{"warnings":["decided to defer the cleanup to keep the diff small"]}' > "$tmp/f2.json"
bash "$LIB" warnings "$tmp/f2.json" >/dev/null 2>&1
check "free-form deferral warning allowed" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"
printf '{"warnings":["VERIFY Step 9: codebase-map refresh deferred; feature verification passed"]}' > "$tmp/f2b.json"
bash "$LIB" warnings "$tmp/f2b.json" >/dev/null 2>&1
check "map refresh warning allowed" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Non-deferral free-form warning stays legal (warnings are an audit trail).
printf '{"warnings":["map-codebase refresh failed; continued without it"]}' > "$tmp/f3.json"
bash "$LIB" warnings "$tmp/f3.json" >/dev/null 2>&1
check "benign warning ok" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Empty/missing warnings -> ok.
printf '{"slug":"x"}' > "$tmp/f4.json"
bash "$LIB" warnings "$tmp/f4.json" >/dev/null 2>&1
check "missing warnings ok" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Malformed JSON -> fail safe.
printf 'not json' > "$tmp/f5.json"
bash "$LIB" warnings "$tmp/f5.json" >/dev/null 2>&1
check "malformed feature.json fails safe" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# --- completeness assertions are not deferrals -----------------------------------
# This gate is TERMINAL at DELIVER: lib/deliver.sh exits 3 with no rewrite loop, and
# its only override is an env var an unattended run has nobody to set. A false
# positive on ordinary completion prose therefore fails a feature that shipped
# everything, and reports it as a scope violation.
ok_text() {
  printf '%s\n' "$2" > "$tmp/ok.md"
  bash "$LIB" text "$tmp/ok.md" >/dev/null 2>&1
  check "$1" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"
}
flag_text() {
  printf '%s\n' "$2" > "$tmp/flag.md"
  bash "$LIB" text "$tmp/flag.md" >/dev/null 2>&1
  check "$1" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"
}

ok_text "zero remaining gaps is a completeness claim" \
  "0 remaining gaps; every acceptance criterion is met."
ok_text "no remaining work is a completeness claim" \
  "No remaining work: the spec ships in full."
ok_text "remaining tasks: none is a completeness claim" \
  "remaining tasks: none"
ok_text "past-tense defect description with a repair clause" \
  "Config validation was not implemented for the OpenCode harness; this PR adds it."

# Only structured declarations trip the terminal gate. Generic status prose is
# handled by the actual acceptance/verification mechanisms, not a word blacklist.
ok_text "unstructured remaining-tasks prose allowed" \
  "There are 3 remaining tasks we will pick up next sprint."
ok_text "bare not-implemented report allowed" \
  "Rate limiting is not implemented."
ok_text "reported not-yet-implemented wording allowed" \
  "Auth is not yet implemented; tracking separately."
flag_text "explicit deferral still flags" \
  "Deferred the retry logic to a future PR."
flag_text "remaining work with a real count still flags" \
  "Remaining work: wire up the second provider."

# --- invocation ---
bash "$LIB" bogus x >/dev/null 2>&1
check "bad subcommand exits 2" "$([[ $? -eq 2 ]] && echo 1 || echo 0)"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
