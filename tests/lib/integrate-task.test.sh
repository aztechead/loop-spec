#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/lib/integrate-task.sh"
PASS=0
FAIL=0
FIXTURES=()

pass() { printf 'PASS: %s\n' "$1"; ((PASS++)) || true; }
fail() { printf 'FAIL: %s\n' "$1"; ((FAIL++)) || true; }
check() {
  local name="$1" expected="$2" actual="$3"
  [[ "$actual" == "$expected" ]] && pass "$name" || fail "$name (expected '$expected', got '$actual')"
}
cleanup() { rm -rf "${FIXTURES[@]:-}"; }
trap cleanup EXIT

make_fixture() {
  REPO="$(mktemp -d)"
  WT="$(mktemp -d)"
  rmdir "$WT"
  FIXTURES+=("$REPO" "$WT")
  git -C "$REPO" init -q -b feat/demo
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  printf 'base\n' > "$REPO/base.txt"
  git -C "$REPO" add base.txt
  git -C "$REPO" commit -qm base
  git -C "$REPO" worktree add -q -b task/one "$WT" feat/demo
  printf 'task\n' > "$WT/task.txt"
  git -C "$WT" add task.txt
  git -C "$WT" commit -qm task
  FEATURE_BEFORE="$(git -C "$REPO" rev-parse HEAD)"
  TASK_BEFORE="$(git -C "$WT" rev-parse HEAD)"
}

run_helper() {
  RC=0
  OUT="$(bash "$SCRIPT" --feature-root "$REPO" --feature-branch feat/demo \
    --task-worktree "$WT" --task-branch task/one "$@")" || RC=$?
}

make_fixture
run_helper --verify 'test -f task.txt' --cleanup
check "fast-forward succeeds" success "$(jq -r .status <<<"$OUT")"
check "success publishes candidate" true "$(jq -r .published <<<"$OUT")"
check "successful cleanup removes worktree" no "$([[ -e "$WT" ]] && printf yes || printf no)"
check "successful cleanup removes branch" no "$(git -C "$REPO" show-ref --verify --quiet refs/heads/task/one && printf yes || printf no)"

make_fixture
printf 'feature\n' > "$REPO/feature.txt"
git -C "$REPO" add feature.txt
git -C "$REPO" commit -qm feature
FEATURE_BEFORE="$(git -C "$REPO" rev-parse HEAD)"
run_helper --verify 'test -f feature.txt && test -f task.txt && test "$(git rev-parse HEAD^)" = "$(git rev-parse refs/heads/feat/demo)"'
check "divergent task rebases once and publishes" true "$(jq -r .rebased <<<"$OUT")"
check "feature lands on verified candidate" "$(jq -r .candidate <<<"$OUT")" "$(git -C "$REPO" rev-parse feat/demo)"

make_fixture
printf 'dirty\n' >> "$WT/task.txt"
run_helper --verify true
check "dirty task rejected" check-dirty-worktree "$(jq -r .reason <<<"$OUT")"
check "dirty task rejection does not rebase" "$TASK_BEFORE" "$(git -C "$WT" rev-parse HEAD)"
check "dirty task rejection leaves feature" "$FEATURE_BEFORE" "$(git -C "$REPO" rev-parse HEAD)"

make_fixture
mkdir -p "$REPO/.loop" "$WT/.loop-spec/results"
printf '{}\n' > "$REPO/.loop/fleet-result.json"
printf '{}\n' > "$WT/.loop-spec/results/task.json"
run_helper --verify 'test -f task.txt'
check "known runtime files do not block" success "$(jq -r .status <<<"$OUT")"

make_fixture
run_helper --verify false --cleanup
check "verify failure is structured" verify-failed "$(jq -r .reason <<<"$OUT")"
check "verify failure leaves feature unchanged" "$FEATURE_BEFORE" "$(git -C "$REPO" rev-parse HEAD)"
check "verify failure preserves task worktree" yes "$([[ -d "$WT" ]] && printf yes || printf no)"
check "verify failure preserves task branch" yes "$(git -C "$REPO" show-ref --verify --quiet refs/heads/task/one && printf yes || printf no)"

make_fixture
run_helper --verify 'printf dirt > generated.txt'
check "verify-created dirt has stable reason" check-dirty-worktree "$(jq -r .reason <<<"$OUT")"
check "verify-created dirt is not reset" yes "$([[ -f "$WT/generated.txt" ]] && printf yes || printf no)"
check "verify-created dirt prevents publication" "$FEATURE_BEFORE" "$(git -C "$REPO" rev-parse HEAD)"

make_fixture
printf 'feature\n' > "$REPO/shared.txt"
git -C "$REPO" add shared.txt
git -C "$REPO" commit -qm feature
FEATURE_BEFORE="$(git -C "$REPO" rev-parse HEAD)"
printf 'task\n' > "$WT/shared.txt"
git -C "$WT" add shared.txt
git -C "$WT" commit -qm conflict
TASK_BEFORE="$(git -C "$WT" rev-parse HEAD)"
run_helper --verify true
check "conflict reports rebase-conflict" rebase-conflict "$(jq -r .reason <<<"$OUT")"
check "conflict abort restores task head" "$TASK_BEFORE" "$(git -C "$WT" rev-parse HEAD)"
check "conflict leaves feature unchanged" "$FEATURE_BEFORE" "$(git -C "$REPO" rev-parse HEAD)"
check "conflict leaves no rebase state" no "$([[ -d "$(git -C "$WT" rev-parse --git-path rebase-merge)" ]] && printf yes || printf no)"

make_fixture
INDEX="$(git -C "$WT" rev-parse --git-path index)"
cp "$INDEX" "$INDEX.saved"
printf corrupt > "$INDEX"
run_helper --verify true
check "failed status probe fails closed" check-dirty-worktree "$(jq -r .reason <<<"$OUT")"
check "failed task status is identified" task-status-failed "$(jq -r .detail <<<"$OUT")"
mv "$INDEX.saved" "$INDEX"

make_fixture
FEATURE_INDEX="$(git -C "$REPO" rev-parse --absolute-git-dir)/index"
cp "$FEATURE_INDEX" "$FEATURE_INDEX.saved"
run_helper --verify "printf corrupt > '$FEATURE_INDEX'"
check "failed feature status probe fails closed" check-dirty-worktree "$(jq -r .reason <<<"$OUT")"
check "failed feature status is identified" feature-status-failed "$(jq -r .detail <<<"$OUT")"
check "failed feature status prevents publication" "$FEATURE_BEFORE" "$(git -C "$WT" rev-parse feat/demo)"
mv "$FEATURE_INDEX.saved" "$FEATURE_INDEX"

make_fixture
printf 'feature dirt\n' > "$REPO/untracked.txt"
run_helper --verify true
check "dirty feature rejected before publication" feature-dirty "$(jq -r .detail <<<"$OUT")"
check "dirty feature remains unchanged" "$FEATURE_BEFORE" "$(git -C "$REPO" rev-parse HEAD)"

make_fixture
run_helper --prepare 'test "$LOOP_SPEC_INTEGRATION_CANDIDATE" = "$(git rev-parse HEAD)"' \
  --verify 'test "$LOOP_SPEC_INTEGRATION_CANDIDATE" = "$(git rev-parse HEAD)"' --preflight-only
check "preflight verifies exact candidate" ready "$(jq -r .reason <<<"$OUT")"
check "preflight does not publish" "$FEATURE_BEFORE" "$(git -C "$REPO" rev-parse HEAD)"

make_fixture
run_helper --verify "printf dirt > '$REPO/preflight-dirt.txt'" --preflight-only
check "preflight rejects feature dirt" check-dirty-worktree "$(jq -r .reason <<<"$OUT")"
check "preflight identifies dirty feature" feature-dirty "$(jq -r .detail <<<"$OUT")"
check "dirty preflight returns no publication" false "$(jq -r .published <<<"$OUT")"

make_fixture
run_helper --verify "git -C '$REPO' update-ref refs/heads/feat/demo '$TASK_BEFORE'" --preflight-only
check "preflight rejects feature ref movement" feature-moved "$(jq -r .reason <<<"$OUT")"
check "preflight identifies changed feature ref" feature-ref-changed "$(jq -r .detail <<<"$OUT")"
check "moved feature returns immutable candidate" "$TASK_BEFORE" "$(jq -r .candidate <<<"$OUT")"

make_fixture
run_helper --verify 'moved=$(printf moved | git commit-tree "$LOOP_SPEC_INTEGRATION_CANDIDATE^{tree}" -p "$LOOP_SPEC_INTEGRATION_CANDIDATE") && git update-ref refs/heads/task/one "$moved" && git checkout --detach -q "$LOOP_SPEC_INTEGRATION_CANDIDATE"' --preflight-only
check "preflight rejects task branch movement" candidate-changed "$(jq -r .reason <<<"$OUT")"
check "preflight identifies moved task ref" task-ref-changed "$(jq -r .detail <<<"$OUT")"
check "moved task keeps immutable candidate" "$TASK_BEFORE" "$(jq -r .candidate <<<"$OUT")"

make_fixture
git -C "$WT" reset -q --hard feat/demo
run_helper --verify true
check "zero commit rejected" zero-commit "$(jq -r .reason <<<"$OUT")"

make_fixture
mkdir -p "$WT/.loop-spec/results"
printf '{}\n' > "$WT/.loop-spec/results/task.json"
run_helper --verify 'test -f task.txt' --cleanup
check "cleanup refuses untracked runtime files" cleanup-failed "$(jq -r .reason <<<"$OUT")"
check "cleanup names porcelain refuse" 1 "$(jq -r .detail <<<"$OUT" | grep -c 'worktree-remove-refused:' || true)"
check "published despite cleanup refuse" true "$(jq -r .published <<<"$OUT")"
check "refused cleanup leaves worktree" yes "$([[ -d "$WT" ]] && printf yes || printf no)"

check "helper avoids newer path-format option" 0 "$(grep -c -- '--path-format' "$SCRIPT" || true)"

check "JSON shape is stable" 'candidate,cleanedUp,detail,featureBefore,featureBranch,published,reason,rebased,schema,status,taskBranch' \
  "$(jq -r 'keys | sort | join(",")' <<<"$OUT")"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
