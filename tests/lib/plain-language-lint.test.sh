#!/usr/bin/env bash
# Test suite for lib/plain-language-lint.sh
#
# Every check gets a positive case (a string that must flag) and a near-miss
# negative case (a string that must NOT flag) -- the shape CLAUDE.md's "Probes,
# not judgments" requires: a deterministic probe earns its test both ways, or it
# is not trustworthy enough to report on model-authored prose. This lint is
# advisory only (see the ADVISORY ONLY section of skills/shared/plain-language.md)
# so nothing here asserts it blocks anything -- only its own output/exit contract.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT="$REPO_ROOT/lib/plain-language-lint.sh"
WORK="${TMPDIR:-/tmp}/plain-language-lint-test-$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# must_flag NAME WANT_CHECK MODE ARGS...   (reads stdin if MODE args end in "-")
must_flag() {
  local name="$1" want_check="$2" mode="$3"; shift 3
  local out rc
  out="$(bash "$LINT" "$mode" "$@" 2>&1)"; rc=$?
  if [[ "$rc" -eq 1 ]] && grep -qE "FLAG [^:]+:[0-9]+: ${want_check}:" <<<"$out"; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name (exit $rc, wanted check '$want_check')"
    echo "$out" | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

# must_flag_stdin NAME WANT_CHECK MODE INPUT
must_flag_stdin() {
  local name="$1" want_check="$2" mode="$3" input="$4"
  local out rc
  out="$(printf '%s' "$input" | bash "$LINT" "$mode" - 2>&1)"; rc=$?
  if [[ "$rc" -eq 1 ]] && grep -qE "FLAG [^:]+:[0-9]+: ${want_check}:" <<<"$out"; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name (exit $rc, wanted check '$want_check')"
    echo "$out" | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

# must_be_clean NAME MODE ARGS...
must_be_clean() {
  local name="$1" mode="$2"; shift 2
  local out rc
  out="$(bash "$LINT" "$mode" "$@" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] && grep -q "plain-language-lint: ok" <<<"$out"; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name (exit $rc, wanted clean)"
    echo "$out" | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

# must_be_clean_stdin NAME MODE INPUT
must_be_clean_stdin() {
  local name="$1" mode="$2" input="$3"
  local out rc
  out="$(printf '%s' "$input" | bash "$LINT" "$mode" - 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] && grep -q "plain-language-lint: ok" <<<"$out"; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name (exit $rc, wanted clean)"
    echo "$out" | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

echo "=== plain-language-lint.sh tests ==="

# ---------------------------------------------------------------------------
# long-sentence: 25 words descriptive / 20 words imperative-procedural
# ---------------------------------------------------------------------------

# 26-word descriptive sentence, plain paragraph (not a list, no imperative opener).
cat > "$WORK/long-sentence-descriptive-pos.md" <<'EOF'
# T

The system reads the configuration file from disk and then parses every single
declared field into a typed structure before handing the fully validated result
back to the caller for further processing downstream in the pipeline today.
EOF
must_flag "long-sentence: 26-word descriptive sentence flags" "long-sentence" prose \
  "$WORK/long-sentence-descriptive-pos.md"

# 22-word descriptive sentence: near miss, must stay under the 25-word cap.
cat > "$WORK/long-sentence-descriptive-neg.md" <<'EOF'
# T

The system reads the configuration file from disk and parses each field into
a typed value before returning it to the caller.
EOF
must_be_clean "long-sentence: 22-word descriptive sentence does not flag" prose \
  "$WORK/long-sentence-descriptive-neg.md"

# 24-word sentence inside a list item: list items classify as imperative/procedural
# (20-word cap), so this flags even though it is under the 25-word descriptive cap.
cat > "$WORK/long-sentence-imperative-pos.md" <<'EOF'
# T

- Read the configuration file from disk and parse every declared field into a
  typed structure before returning the validated result to the caller now.
EOF
must_flag "long-sentence: 24-word list item flags at the imperative cap" \
  "long-sentence" prose "$WORK/long-sentence-imperative-pos.md"

# 20-word sentence inside a list item: near miss, at (not over) the 20-word cap.
cat > "$WORK/long-sentence-imperative-neg.md" <<'EOF'
# T

- Read the configuration file from disk and parse each field into a typed
  structure before returning the result to caller.
EOF
must_be_clean "long-sentence: 20-word list item does not flag" prose \
  "$WORK/long-sentence-imperative-neg.md"

# ---------------------------------------------------------------------------
# passive-voice: a form of "be" followed by a past participle
# ---------------------------------------------------------------------------

must_flag_stdin "passive-voice: 'was written by' flags" "passive-voice" text \
  "The final report was written by the review committee."
must_be_clean_stdin "passive-voice: active voice near miss does not flag" text \
  "The review committee wrote the final report."

# ---------------------------------------------------------------------------
# long-word: curated long/short substitution list
# ---------------------------------------------------------------------------

must_flag_stdin "long-word: 'utilize' flags" "long-word" text \
  "We will utilize the existing tool."
must_be_clean_stdin "long-word: 'use' near miss does not flag" text \
  "We will use the existing tool."

# ---------------------------------------------------------------------------
# foreign-phrase: Latin/foreign phrases with everyday equivalents
# ---------------------------------------------------------------------------

must_flag_stdin "foreign-phrase: 'ad hoc' flags" "foreign-phrase" text \
  "The team ran an ad hoc process to cover the gap."
must_be_clean_stdin "foreign-phrase: everyday equivalent does not flag" text \
  "The team ran an improvised process to cover the gap."

# ---------------------------------------------------------------------------
# stock-phrase: tired metaphors and stock phrases (Orwell rule 1)
# ---------------------------------------------------------------------------

must_flag_stdin "stock-phrase: 'at the end of the day' flags" "stock-phrase" text \
  "At the end of the day, ship the change."
must_be_clean_stdin "stock-phrase: plain phrasing does not flag" text \
  "In the end, ship the change."

# ---------------------------------------------------------------------------
# slash-and-or: "/" used as and/or between words
# ---------------------------------------------------------------------------

must_flag_stdin "slash-and-or: 'and/or' flags" "slash-and-or" text \
  "Ship it and/or delay it depending on the review."
must_be_clean_stdin "slash-and-or: spelled-out 'or' does not flag" text \
  "Ship it or delay it depending on the review."

# ---------------------------------------------------------------------------
# long-paragraph: more than 6 sentences in one prose paragraph
# ---------------------------------------------------------------------------

cat > "$WORK/long-paragraph-pos.md" <<'EOF'
# T

Cats sleep. Dogs bark. Birds fly. Fish swim. Bees buzz. Ants crawl. Frogs jump.
EOF
must_flag "long-paragraph: 7-sentence paragraph flags" "long-paragraph" prose \
  "$WORK/long-paragraph-pos.md"

cat > "$WORK/long-paragraph-neg.md" <<'EOF'
# T

Cats sleep. Dogs bark. Birds fly. Fish swim. Bees buzz. Ants crawl.
EOF
must_be_clean "long-paragraph: 6-sentence paragraph does not flag" prose \
  "$WORK/long-paragraph-neg.md"

# ---------------------------------------------------------------------------
# gerund-heading: gerund heading an imperative clause
# ---------------------------------------------------------------------------

cat > "$WORK/gerund-heading-pos.md" <<'EOF'
# T

## Installing the plugin

Body text.
EOF
must_flag "gerund-heading: 'Installing the plugin' flags" "gerund-heading" prose \
  "$WORK/gerund-heading-pos.md"

cat > "$WORK/gerund-heading-neg.md" <<'EOF'
# T

## Install the plugin

Body text.
EOF
must_be_clean "gerund-heading: imperative heading does not flag" prose \
  "$WORK/gerund-heading-neg.md"

# A single-word gerund heading is a noun title, not an instruction -- must not flag.
cat > "$WORK/gerund-heading-noun.md" <<'EOF'
# T

## Testing

Body text.
EOF
must_be_clean "gerund-heading: single-word noun heading does not flag" prose \
  "$WORK/gerund-heading-noun.md"

# ---------------------------------------------------------------------------
# Scope exclusions required by the contract: fenced code, tables, link URLs.
# ---------------------------------------------------------------------------

cat > "$WORK/fenced-code.md" <<'EOF'
# T

Some ordinary prose here.

```
utilize this identifier in a fence
```

More ordinary prose here.
EOF
must_be_clean "fenced code block containing 'utilize' does not flag" prose \
  "$WORK/fenced-code.md"

cat > "$WORK/table-row.md" <<'EOF'
# T

| Word | Meaning |
|---|---|
| utilize | use |
EOF
must_be_clean "markdown table row containing 'utilize' does not flag" prose \
  "$WORK/table-row.md"

cat > "$WORK/url-word.md" <<'EOF'
# T

[Read the guide](https://example.com/utilize-the-thing)
EOF
must_be_clean "a URL containing a banned word does not flag" prose \
  "$WORK/url-word.md"

# ---------------------------------------------------------------------------
# comments mode: shell #-comments and python #-comments + docstrings
# ---------------------------------------------------------------------------

cat > "$WORK/comments.sh" <<'EOF'
#!/usr/bin/env bash
# We should utilize a retry loop here, and the config was parsed by the loader.
set -euo pipefail
echo hi
EOF
must_flag "comments mode: shell # comment flags" "long-word" comments "$WORK/comments.sh"

cat > "$WORK/comments_code.sh" <<'EOF'
#!/usr/bin/env bash
# Read the config once at startup.
set -euo pipefail
echo hi
EOF
must_be_clean "comments mode: plain shell comment does not flag" comments \
  "$WORK/comments_code.sh"

cat > "$WORK/docstring.py" <<'EOF'
def run():
    """We should utilize a cache here to avoid repeated reads."""
    return 1
EOF
must_flag "comments mode: python docstring flags" "long-word" comments "$WORK/docstring.py"

# ---------------------------------------------------------------------------
# text mode reads stdin
# ---------------------------------------------------------------------------

must_flag_stdin "text mode: reads stdin and flags" "long-word" text \
  "This PR will utilize the retry loop."

# ---------------------------------------------------------------------------
# --rules: enumerates exactly the checks the script can emit -- no drift
# ---------------------------------------------------------------------------

RULES_OUT="$(bash "$LINT" --rules 2>&1)"
RULES_RC=$?
EXPECTED_RULES="foreign-phrase
gerund-heading
long-paragraph
long-sentence
long-word
passive-voice
slash-and-or
stock-phrase"

if [[ "$RULES_RC" -eq 0 ]] && [[ "$(sort <<<"$RULES_OUT")" == "$EXPECTED_RULES" ]]; then
  echo "PASS: --rules prints exactly the eight documented check names"; PASS=$((PASS+1))
else
  echo "FAIL: --rules output does not match the expected check-name set (exit $RULES_RC)"
  echo "$RULES_OUT" | sed 's/^/      /'
  FAIL=$((FAIL+1))
fi

# Collect every check name that actually fired across the positive fixtures run
# above and assert it is a subset of --rules' output -- if a check starts
# emitting a name --rules does not list, this catches the drift.
ALL_FIRED="$(
  for f in "$WORK"/*.md "$WORK"/*.sh "$WORK"/*.py; do
    [[ -f "$f" ]] || continue
    case "$f" in
      *comments*.sh|*comments*.py) bash "$LINT" comments "$f" 2>/dev/null ;;
      *) bash "$LINT" prose "$f" 2>/dev/null ;;
    esac
  done | grep '^FLAG' | sed -E 's/^FLAG [^:]+:[0-9]+: ([a-z-]+):.*/\1/' | sort -u
)"
MISSING=0
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  grep -qxF "$name" <<<"$RULES_OUT" || MISSING=1
done <<<"$ALL_FIRED"
if [[ "$MISSING" -eq 0 ]]; then
  echo "PASS: every check name observed firing is listed by --rules"; PASS=$((PASS+1))
else
  echo "FAIL: a check fired a name --rules does not list:"
  echo "$ALL_FIRED"
  FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
# usage / exit-code contract
# ---------------------------------------------------------------------------

out="$(bash "$LINT" bogus 2>&1)"; rc=$?
if [[ "$rc" -eq 2 ]] && grep -q "usage: plain-language-lint.sh" <<<"$out"; then
  echo "PASS: bad mode exits 2"; PASS=$((PASS+1))
else
  echo "FAIL: bad mode (exit $rc)"; echo "$out" | sed 's/^/      /'; FAIL=$((FAIL+1))
fi

out="$(bash "$LINT" prose 2>&1)"; rc=$?
if [[ "$rc" -eq 2 ]]; then
  echo "PASS: prose with no file exits 2"; PASS=$((PASS+1))
else
  echo "FAIL: prose with no file (exit $rc)"; echo "$out" | sed 's/^/      /'; FAIL=$((FAIL+1))
fi

out="$(bash "$LINT" text "$WORK/comments.sh" 2>&1)"; rc=$?
if [[ "$rc" -eq 2 ]]; then
  echo "PASS: text mode rejects a non-stdin argument"; PASS=$((PASS+1))
else
  echo "FAIL: text mode with a file arg (exit $rc)"; echo "$out" | sed 's/^/      /'; FAIL=$((FAIL+1))
fi

out="$(bash "$LINT" prose "$WORK/does-not-exist.md" 2>&1)"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -q "unreadable" <<<"$out"; then
  echo "PASS: unreadable file flags and exits 1 (fail safe)"; PASS=$((PASS+1))
else
  echo "FAIL: unreadable file (exit $rc)"; echo "$out" | sed 's/^/      /'; FAIL=$((FAIL+1))
fi

: > "$WORK/empty.md"
out="$(bash "$LINT" prose "$WORK/empty.md" 2>&1)"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -q "empty" <<<"$out"; then
  echo "PASS: empty file flags and exits 1 (fail safe)"; PASS=$((PASS+1))
else
  echo "FAIL: empty file (exit $rc)"; echo "$out" | sed 's/^/      /'; FAIL=$((FAIL+1))
fi

# --max-flags caps FLAG lines but the summary still reports the true total.
out="$(bash "$LINT" prose --max-flags 1 "$WORK/long-sentence-descriptive-pos.md" \
  "$WORK/comments.sh" 2>&1)"; rc=$?
flag_lines="$(grep -c '^FLAG' <<<"$out")"
if [[ "$rc" -eq 1 ]] && [[ "$flag_lines" -eq 1 ]] && grep -q "output truncated at 1 of" <<<"$out"; then
  echo "PASS: --max-flags caps FLAG lines and notes the true total"; PASS=$((PASS+1))
else
  echo "FAIL: --max-flags (exit $rc, $flag_lines FLAG lines)"; echo "$out" | sed 's/^/      /'; FAIL=$((FAIL+1))
fi

if [[ -x "$LINT" ]]; then
  echo "PASS: lint is executable"; PASS=$((PASS+1))
else
  echo "FAIL: lint is not executable"; FAIL=$((FAIL+1))
fi

# --- version numbers are not sentence boundaries ---------------------------
# A '.' between digits was splitting sentences, which both mangled the excerpt
# and HID long sentences: the fragments each fell under the cap, so a 33-word
# sentence mentioning 2.29 and 2.35 reported nothing at all.
cat > "$WORK/long-version.md" <<'EOF'
Graphify was a hard requirement from 2.29 to 2.35 and was removed in 2.35 on the evidence because across every single feature that was authored while it was mandatory it produced zero citations and zero refreshes.
EOF
rc=0
out="$(bash "$LINT" prose "$WORK/long-version.md" 2>&1)" || rc=$?  # the linter exits 1 when it flags; that is the expected path here
if grep -q 'long-sentence: 33 words' <<<"$out"; then
  echo "PASS: a version number does not split the sentence"; PASS=$((PASS+1))
else
  echo "FAIL: version-number split still hides the long sentence"; FAIL=$((FAIL+1)); fi
if grep -q '2\.29 to 2\.35' <<<"$out"; then
  echo "PASS: excerpt spans the version numbers"; PASS=$((PASS+1))
else
  echo "FAIL: excerpt truncated at a version number"; FAIL=$((FAIL+1)); fi

# --- the linter's own message must be grammatical --------------------------
# It read "max 20 for a imperative sentence".
cat > "$WORK/imperative.md" <<'EOF'
Read the neighbors before writing a line and match them, naming and error idiom and test structure and layout, because the house convention outranks your defaults here.
EOF
rc=0
out="$(bash "$LINT" prose "$WORK/imperative.md" 2>&1)" || rc=$?  # the linter exits 1 when it flags; that is the expected path here
if grep -q 'for an imperative sentence' <<<"$out"; then
  echo "PASS: article agrees with the sentence kind"; PASS=$((PASS+1))
else
  echo "FAIL: article disagreement in the linter's own message"; FAIL=$((FAIL+1)); fi

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS: plain-language-lint.sh flags every check on a positive case and stays quiet on the matching near miss"
