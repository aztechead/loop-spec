#!/usr/bin/env bash
# Every `${CLAUDE_SKILL_DIR}/references/<file>` pointer in a SKILL.md must resolve to an
# existing file. The 500-line restructure moved load-bearing procedure into per-skill
# references/ files; a renamed or deleted reference silently strands the skill at runtime
# (the model reads a pointer to nothing). This lint keeps the pointer layer sound.
#
# Also asserts the inverse: every file under skills/*/references/ is referenced by its
# own SKILL.md at least once (no orphaned reference files).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

# --- forward: every pointer resolves ---
for skill_md in skills/*/SKILL.md; do
  skill_dir="$(dirname "$skill_md")"
  # Extract referenced filenames: ${CLAUDE_SKILL_DIR}/references/<name>.md
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    check "$skill_md -> references/$ref exists" \
      "$([[ -f "$skill_dir/references/$ref" ]] && echo 1 || echo 0)"
  done < <(grep -o '\${CLAUDE_SKILL_DIR}/references/[A-Za-z0-9._-]*\.md' "$skill_md" 2>/dev/null \
             | sed 's|.*/references/||' | sort -u)
done

# --- inverse: no orphaned reference files ---
for ref_file in skills/*/references/*.md; do
  [[ -e "$ref_file" ]] || continue
  skill_dir="$(dirname "$(dirname "$ref_file")")"
  base="$(basename "$ref_file")"
  check "$ref_file referenced by its SKILL.md" \
    "$(grep -qF "references/$base" "$skill_dir/SKILL.md" && echo 1 || echo 0)"
done

# --- sanity: the lint actually saw pointers (guards against a silent regex mismatch) ---
total_ptrs=$(grep -ho '\${CLAUDE_SKILL_DIR}/references/[A-Za-z0-9._-]*\.md' skills/*/SKILL.md 2>/dev/null | wc -l | tr -d ' ')
check "lint saw at least one pointer (found: $total_ptrs)" "$([[ "$total_ptrs" -ge 1 ]] && echo 1 || echo 0)"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
