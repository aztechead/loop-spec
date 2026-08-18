#!/usr/bin/env bash
# Test suite for lib/doc-tells.sh
#
# The lint's contract runs both ways: it must catch the three defects a reader
# actually trips over, and it must stay quiet on the four things that look
# identical in the text and are not defects -- an example path from another
# project, state the software writes at runtime, a path named because it is gone,
# and a placeholder the prose already explains. The negative cases below are the
# ones a survey of this repo's own 169 documents turned up.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT="$REPO_ROOT/lib/doc-tells.sh"
WORK="${TMPDIR:-/tmp}/doc-tells-test-$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

check() {
  local name="$1" want_exit="$2" pattern="$3"; shift 3
  local out rc
  out="$(cd "$WORK" && bash "$LINT" "$@" 2>&1)"; rc=$?
  if [[ "$rc" -eq "$want_exit" ]] && grep -qE "$pattern" <<<"$out"; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name (exit $rc, wanted $want_exit; looked for /$pattern/)"
    echo "$out" | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

echo "=== doc-tells.sh tests ==="

# A repository, because stale-ref answers "does this project keep files like that
# here?" from what git tracks -- not from the filesystem alone.
mkdir -p "$WORK/lib" "$WORK/docs" "$WORK/.state"
cd "$WORK"
git init -q .
git config user.email "test@example.com"
git config user.name "Test"
printf '#!/usr/bin/env bash\necho hi\n' > lib/real.sh
printf '# Target\n\nA real document.\n' > docs/target.md
git add lib/real.sh docs/target.md
git commit -qm "seed"

# --- the three tells fire ---
cat > "$WORK/docs/bad.md" <<'EOF'
# Runbook

Rotate the key, then follow [the escalation guide](./escalation.md).

The scan lives in `lib/gone.sh` and writes its report beside it.

```bash
curl -H "Authorization: Bearer <api-token>" https://example.com/rotate
```
EOF

check "a: a relative link with no target is caught" 1 "tell=dead-link" scan docs/bad.md
check "b: a path the tree no longer holds is caught" 1 "tell=stale-ref: lib/gone.sh" scan docs/bad.md
check "c: a command placeholder the prose never explains is caught" 1 \
  "tell=undefined-placeholder: <api-token>" scan docs/bad.md
check "d: findings carry file and line" 1 "docs/bad.md:[0-9]+: tell=" scan docs/bad.md
check "e: the count names the files it read" 1 "doc-tells: 3 finding\(s\) \(1 file" scan docs/bad.md

# --- references that resolve stay quiet ---
cat > "$WORK/docs/good.md" <<'EOF'
# Guide

Read [the target](./target.md), the [project site](https://example.com/docs), and
the [section below](#detail) before you start. The entry point is `lib/real.sh`.

## Detail

Set the API token first, then run:

```bash
curl -H "Authorization: Bearer <api-token>" https://example.com/rotate
```
EOF

check "f: a link that resolves, a URL, and an anchor are all quiet" 0 "doc-tells: clean" scan docs/good.md

# --- the four shapes that look like defects and are not ---
cat > "$WORK/docs/quiet.md" <<'EOF'
# Notes

Runtime state lands in `.state/runtime.json`, which no run has created yet.

A Rails project keeps its model in `app/models/user.rb`; this one does not.

The old `lib/state-write.sh` was removed in 2.9 and `lib/real.sh` replaced it.

Feature artifacts live under `docs/{slug}/SPEC.md`, one directory per feature.

The example below is illustration, not an instruction:

```text
see lib/missing-example.sh for the shape
```

```json
{"token": "<api-token>"}
```
EOF

check "g: runtime state, foreign examples, absence, and templates stay quiet" 0 \
  "doc-tells: clean" scan docs/quiet.md

cat > "$WORK/docs/generic.md" <<'EOF'
# Copy the config

```bash
cp <file> ./config.yml
```
EOF

check "h: a placeholder with no distinctive word is not guessed at" 0 "doc-tells: clean" scan docs/generic.md

# --- scope: what the probe declines to read ---
printf '# Changelog\n\n- 1.0.0 removed `lib/gone.sh`, added `lib/other.sh`.\n' > "$WORK/CHANGELOG.md"
check "i: a changelog is history, not rot" 0 "1 skipped" scan CHANGELOG.md
check "j: a non-markdown file is skipped, not read" 0 "1 skipped" scan lib/real.sh

# --- diff mode reports only what the change introduced ---
git add docs/bad.md docs/good.md docs/quiet.md docs/generic.md CHANGELOG.md
git commit -qm "docs with one pre-existing dead link"
BASE="$(git rev-parse HEAD)"
printf '\nThe new report is written by `lib/report.sh` after every run.\n' >> docs/good.md
git add docs/good.md
git commit -qm "add a stale reference"

check "k: diff mode flags the line the change added" 1 "tell=stale-ref: lib/report.sh" diff "$BASE"
check "l: diff mode leaves the pre-existing findings alone" 1 "doc-tells: 1 finding" diff "$BASE"
check "m: diff mode accepts an explicit head ref" 1 "tell=stale-ref: lib/report.sh" diff "$BASE" HEAD
check "n: an unchanged range is clean" 0 "doc-tells: clean" diff HEAD

# --- outside a repository the tree-dependent check stands down ---
mkdir -p "$WORK/loose"
printf '# Loose\n\nThe scanner is `lib/gone.sh`.\n' > "$WORK/loose/doc.md"
(
  cd "$WORK/loose" || exit 1
  out="$(bash "$LINT" scan doc.md 2>&1)"; rc=$?
  # git rev-parse walks upward, so this only proves the check does not crash when
  # the answer is unknown; the repo-less path is the same code with no root.
  if [[ "$rc" -eq 0 || "$rc" -eq 1 ]] && grep -qE "doc-tells: (clean|[0-9]+ finding)" <<<"$out"; then
    exit 0
  fi
  echo "$out" | sed 's/^/      /'
  exit 1
) && { echo "PASS: o: a document in a nested directory still answers"; PASS=$((PASS+1)); } \
  || { echo "FAIL: o: a document in a nested directory still answers"; FAIL=$((FAIL+1)); }

# --- usage ---
check "p: bad mode exits 2" 2 "usage: doc-tells.sh" bogus docs/good.md
check "q: scan with no file exits 2" 2 "usage: doc-tells.sh scan" scan
check "r: an unreadable file exits 2" 2 "cannot read" scan docs/absent.md

if [[ -x "$LINT" ]]; then
  echo "PASS: s: lint is executable"; PASS=$((PASS+1))
else
  echo "FAIL: s: lint is not executable"; FAIL=$((FAIL+1))
fi

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS: doc-tells.sh catches the three defects and stays quiet on the four look-alikes"
