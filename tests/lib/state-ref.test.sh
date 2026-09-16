#!/usr/bin/env bash
# Tests for lib/state-ref.sh: feature state lives on refs/loop-spec/state/<slug>, shared
# by every worktree, and never on the feature branch.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/state-ref.sh"
PASS=0; FAIL=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then echo "PASS: $name"; PASS=$((PASS+1))
  else echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL+1)); fi
}
WORK="$(mktemp -d "${TMPDIR:-/tmp}/state-ref-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
FD="$REPO/.loop-spec/features/demo"; mkdir -p "$FD/gate-logs"
printf '{"slug":"demo","currentPhase":"spec"}\n' > "$FD/feature.json"
printf '# Progress\n' > "$FD/PROGRESS.md"
printf 'log\n' > "$FD/gate-logs/x.md"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

check "ref: names the ref" "refs/loop-spec/state/demo" "$(bash "$LIB" ref demo)"
sha1="$(bash "$LIB" commit "$FD" "state @ discuss")"
check "commit: creates the ref" "$sha1" "$(git -C "$REPO" rev-parse refs/loop-spec/state/demo)"
check "commit: the branch gets no commit" "1" "$(git -C "$REPO" rev-list --count main)"
check "commit: the checkout index is untouched" "" "$(git -C "$REPO" diff --cached --name-only)"
check "commit: top-level files only" "PROGRESS.md feature.json" "$(git -C "$REPO" ls-tree --name-only refs/loop-spec/state/demo | tr '\n' ' ' | sed 's/ $//')"
check "commit: message kept" "state @ discuss" "$(git -C "$REPO" log -1 --format=%s refs/loop-spec/state/demo)"
sha_same="$(bash "$LIB" commit "$FD" "state @ discuss again")"
check "commit: an unchanged tree writes nothing" "$sha1" "$sha_same"
printf '{"slug":"demo","currentPhase":"plan"}\n' > "$FD/feature.json"
mkdir -p "$FD/instruction-snapshots/attempt/skills" "$FD/review-attempts/1"
printf 'captured instructions\n' > "$FD/instruction-snapshots/attempt/skills/SKILL.md"
printf 'review evidence\n' > "$FD/review-attempts/1/VERIFICATION.md"
git -C "$REPO" config filter.upper.clean 'tr a-z A-Z'
printf '*.md filter=upper text eol=crlf\n' > "$REPO/.git/info/attributes"
weird=$'line\nname.md'
printf 'line\nname\n' > "$FD/instruction-snapshots/$weird"
printf 'executable\n' > "$FD/review-attempts/1/tool.sh"
chmod +x "$FD/review-attempts/1/tool.sh"
ln -s tool.sh "$FD/review-attempts/1/link.sh"
printf 'indexed-original\n' > "$REPO/sentinel.txt"
git -C "$REPO" add sentinel.txt
printf 'working-copy-change\n' > "$REPO/sentinel.txt"
REAL_GIT="$(command -v git)"
printf '0\n' > "$WORK/hash-count"
cat > "$WORK/bin/git" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == hash-object ]]; then n=\$(cat "$WORK/hash-count"); printf '%s\n' \$((n + 1)) > "$WORK/hash-count"; break; fi
done
if [[ -f "$WORK/fail-batch" && "\$*" == *"hash-object -w"* && \$# -gt 6 ]]; then exit 1; fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$WORK/bin/git"
PATH="$WORK/bin:$PATH"; export PATH
sha2="$(bash "$LIB" commit "$FD" "state @ plan")"
check "commit: fast path hashes in one call" "2" "$(cat "$WORK/hash-count")"
stored="$(git -C "$REPO" cat-file blob "$sha2:instruction-snapshots/line
name.md")"
check "commit: clean attributes affect stored blob" "LINE
NAME" "$stored"
check "commit: staged index blob is untouched" "indexed-original" "$(git -C "$REPO" show :sentinel.txt)"
check "commit: unstaged working copy is untouched" "working-copy-change" "$(cat "$REPO/sentinel.txt")"
head_before="$(git -C "$REPO" rev-parse HEAD)"
touch "$WORK/fail-batch"
sha_fallback="$(bash "$LIB" commit "$FD" "state @ plan fallback")"
check "commit: batch failure falls back to same snapshot" "$sha2" "$sha_fallback"
check "commit: HEAD remains untouched" "$head_before" "$(git -C "$REPO" rev-parse HEAD)"
check "commit: a change chains onto the parent" "$sha1" "$(git -C "$REPO" rev-parse "$sha2^")"
ref_index="$(mktemp "$WORK/reference-index.XXXXXX")"; rm -f "$ref_index"
while IFS= read -r -d '' path; do
  blob="$(git -C "$REPO" hash-object -w "$path")"
  GIT_INDEX_FILE="$ref_index" git -C "$REPO" update-index --add --cacheinfo "100644,$blob,${path#"$FD/"}"
done < <(
  for path in "$FD"/*; do [[ -f "$path" && ! -L "$path" ]] && printf '%s\0' "$path"; done
  for name in instruction-snapshots review-attempts; do
    [[ -d "$FD/$name" ]] && find "$FD/$name" -type f -print0
  done
)
reference_tree="$(GIT_INDEX_FILE="$ref_index" git -C "$REPO" write-tree)"
rm -f "$ref_index"
check "commit: native batch preserves exact tree" "$(git -C "$REPO" rev-parse "$sha2^{tree}")" "$reference_tree"
check "commit: executable mode normalizes" "100644" "$(git -C "$REPO" ls-tree -r "$sha2" -- 'review-attempts/1/tool.sh' | awk '{print $1}')"
check "commit: symlink is excluded" "0" "$(git -C "$REPO" ls-tree -r --name-only "$sha2" | grep -Fc 'review-attempts/1/link.sh' || true)"
check "show: prints the latest feature.json" '{"slug":"demo","currentPhase":"plan"}' "$(bash "$LIB" show "$REPO" demo)"

# A worktree shares the ref; a recreated worktree restores the directory from it.
git -C "$REPO" worktree add -q "$WORK/wt" -b feat/demo
check "restore: returns the sha" "$sha2" "$(bash "$LIB" restore "$WORK/wt" demo)"
check "restore: writes feature.json into the worktree" "plan" "$(jq -r '.currentPhase' "$WORK/wt/.loop-spec/features/demo/feature.json")"
check "restore: writes PROGRESS.md" "# PROGRESS" "$(cat "$WORK/wt/.loop-spec/features/demo/PROGRESS.md")"
check "restore: keeps nested instruction snapshots" "CAPTURED INSTRUCTIONS" "$(cat "$WORK/wt/.loop-spec/features/demo/instruction-snapshots/attempt/skills/SKILL.md")"
check "restore: keeps review recovery evidence" "REVIEW EVIDENCE" "$(cat "$WORK/wt/.loop-spec/features/demo/review-attempts/1/VERIFICATION.md")"
printf '{"slug":"demo","currentPhase":"execute"}\n' > "$WORK/wt/.loop-spec/features/demo/feature.json"
sha3="$(bash "$LIB" commit "$WORK/wt/.loop-spec/features/demo" "state @ execute")"
check "commit from a worktree: same ref advances" "$sha3" "$(git -C "$REPO" rev-parse refs/loop-spec/state/demo)"

ec=0; bash "$LIB" restore "$REPO" nosuch >/dev/null 2>&1 || ec=$?
check "restore: no ref is exit 1" "1" "$ec"
ec=0; bash "$LIB" commit "$WORK" x >/dev/null 2>&1 || ec=$?
check "commit: a directory without feature.json is exit 1" "1" "$ec"
ec=0; bash "$LIB" bogus >/dev/null 2>&1 || ec=$?
check "bad invocation is exit 2" "2" "$ec"
# The driver's own branch: a feature the driver began and closed through its first
# phase carries the artifact commit and no state commit; the ref holds the state
# (port audit 3, N7, as F10 asked).
DREPO="$WORK/driven"; mkdir -p "$DREPO"
git -C "$DREPO" init -q -b main
printf 'def slugify(s):\n    return s.lower()\n' > "$DREPO/slugify.py"
git -C "$DREPO" add -A && git -C "$DREPO" commit -q -m init
drv() { env -u CLAUDE_CODE_ENTRYPOINT LOOP_SPEC_HARNESS=codex LOOP_SPEC_TEAMS_MODE=none LOOP_SPEC_WORKFLOWS_AVAILABLE=0 LOOP_SPEC_CHECKPOINT_PR=0 LOOP_SPEC_AUTONOMOUS=1 bash "$REPO_ROOT/lib/cycle-driver.sh" "$@"; }
out="$(cd "$DREPO" && drv begin -- "autonomous fix slugify dots" 2>/dev/null)"; DFD="$(jq -r '.featureDir' <<<"$out")"; DSLUG="$(jq -r '.slug' <<<"$out")"
(cd "$DREPO" && drv next --feature-dir "$DFD" >/dev/null 2>&1)
bash "$REPO_ROOT/lib/footprint.sh" cite "$DFD" slugify.py:2 "the lower pass" >/dev/null
(cd "$DREPO" && drv spec skeleton --feature-dir "$DFD" >/dev/null 2>&1)
(cd "$DREPO" && drv spec fill --feature-dir "$DFD" --intent "Dots survive slugify." >/dev/null 2>&1; drv spec fill --feature-dir "$DFD" --file slugify.py --note "strip dots" >/dev/null 2>&1; drv spec fill --feature-dir "$DFD" --command true --expect "it runs" >/dev/null 2>&1; drv spec fill --feature-dir "$DFD" --grounding "slugify.py:2 is the transform" >/dev/null 2>&1)
(cd "$DREPO" && drv next --feature-dir "$DFD" --returned-from spec --note "spec" >/dev/null 2>&1)
check "driven branch: the spec exit committed the artifact" "1" "$(git -C "$DREPO" log --oneline "feat/$DSLUG" | grep -c "spec: $DSLUG")"
check "driven branch: no state commit on the branch" "0" "$(git -C "$DREPO" log --oneline "feat/$DSLUG" | grep -c 'state @')"
check "driven branch: the state ref holds the feature" "$DSLUG" "$(bash "$LIB" show "$DREPO" "$DSLUG" | jq -r '.slug')"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
