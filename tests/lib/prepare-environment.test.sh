#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/prepare-environment.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-prepare-test.$$"
PASS=0
FAIL=0
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

new_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  printf 'seed\n' > "$repo/seed.txt"
  git -C "$repo" add seed.txt
  git -C "$repo" commit -qm seed
}

REPO="$WORK/repo"
new_repo "$REPO"

out="$(bash "$SCRIPT" resolve --root "$REPO")"
check "absent preparation is a no-op" "none:" "$(jq -r '.source + ":" + .command' <<<"$out")"

printf '{}\n' > "$REPO/package.json"
printf '{"lockfileVersion":3}\n' > "$REPO/package-lock.json"
out="$(bash "$SCRIPT" resolve --root "$REPO")"
check "package-lock has an unambiguous frozen install" "detected:npm ci" "$(jq -r '.source + ":" + .command' <<<"$out")"

rm "$REPO/package-lock.json"
printf 'lock data\n' > "$REPO/yarn.lock"
out="$(bash "$SCRIPT" resolve --root "$REPO")"
check "yarn v1 lock uses frozen install" "yarn install --frozen-lockfile" "$(jq -r '.command' <<<"$out")"

printf '{"packageManager":"yarn@4.1.0"}\n' > "$REPO/package.json"
out="$(bash "$SCRIPT" resolve --root "$REPO")"
check "modern yarn uses immutable install" "yarn install --immutable" "$(jq -r '.command' <<<"$out")"

rm "$REPO/yarn.lock"
printf '[project]\nname="demo"\n' > "$REPO/pyproject.toml"
printf 'version = 1\n' > "$REPO/uv.lock"
out="$(bash "$SCRIPT" resolve --root "$REPO")"
check "uv lock uses frozen sync" "uv sync --frozen" "$(jq -r '.command' <<<"$out")"

rm "$REPO/uv.lock"
printf 'package = []\n' > "$REPO/poetry.lock"
out="$(bash "$SCRIPT" resolve --root "$REPO")"
check "poetry lock uses synchronized install" "poetry install --sync --no-interaction" "$(jq -r '.command' <<<"$out")"

rm "$REPO/poetry.lock" "$REPO/pyproject.toml"
printf 'pytest==8.0.0\n' > "$REPO/requirements-dev.txt"
out="$(bash "$SCRIPT" resolve --root "$REPO")"
check "pip requirements use an isolated venv" "python3 -m venv .venv && .venv/bin/python -m pip install -r requirements-dev.txt" "$(jq -r '.command' <<<"$out")"

mkdir -p "$REPO/.loop-spec"
printf '{"prepareCommand":"from-workflow"}\n' > "$REPO/.loop-spec/workflow.json"
out="$(bash "$SCRIPT" resolve --root "$REPO")"
check "workflow prepareCommand is honored" "workflow:from-workflow" "$(jq -r '.source + ":" + .command' <<<"$out")"
out="$(LOOP_SPEC_CMD_PREPARE=from-env bash "$SCRIPT" resolve --root "$REPO")"
check "environment command wins over workflow" "environment:from-env" "$(jq -r '.source + ":" + .command' <<<"$out")"
out="$(LOOP_SPEC_CMD_PREPARE=from-env bash "$SCRIPT" resolve --root "$REPO" --command from-state)"
check "persisted command wins over environment" "explicit:from-state" "$(jq -r '.source + ":" + .command' <<<"$out")"

# Keep fixture configuration from affecting cleanliness checks.
git -C "$REPO" add package.json requirements-dev.txt .loop-spec/workflow.json
git -C "$REPO" commit -qm manifests

out="$(bash "$SCRIPT" run --root "$REPO" --command '')"
check "explicit empty command is a successful no-op" "noop" "$(jq -r '.status' <<<"$out")"

COUNTER="$WORK/count"
export COUNTER
cmd='printf x >> "$COUNTER"'
out="$(bash "$SCRIPT" run --root "$REPO" --command "$cmd")"
check "successful setup is prepared" "prepared" "$(jq -r '.status' <<<"$out")"
first_key="$(jq -r '.key' <<<"$out")"
out="$(bash "$SCRIPT" run --root "$REPO" --command "$cmd")"
check "same key is idempotently skipped" "cached" "$(jq -r '.status' <<<"$out")"
check "cached setup did not run twice" "1" "$(wc -c < "$COUNTER" | tr -d ' ')"

printf 'changed\n' >> "$REPO/package.json"
git -C "$REPO" add package.json
git -C "$REPO" commit -qm manifest-change
out="$(bash "$SCRIPT" run --root "$REPO" --command "$cmd")"
check "manifest changes invalidate preparation key" "1" "$([[ "$(jq -r '.key' <<<"$out")" != "$first_key" ]] && echo 1 || echo 0)"
check "invalidated setup runs again" "2" "$(wc -c < "$COUNTER" | tr -d ' ')"

ec=0
bash "$SCRIPT" run --root "$REPO" --command 'exit 7' >/dev/null 2>&1 || ec=$?
check "setup command failure has a distinct exit" "10" "$ec"

ec=0
out="$(LOOP_SPEC_PREPARE_IDLE_TIMEOUT_SECS=1 bash "$SCRIPT" run --root "$REPO" \
  --command 'sleep 3 # idle-timeout')" || ec=$?
check "silent setup is bounded" "10" "$ec"
check "silent setup keeps structured failure" "setup_failed:idle_timeout:124" \
  "$(jq -r '.status + ":" + .failureKind + ":" + (.exitCode | tostring)' <<<"$out")"

FAKE_BIN="$WORK/fake-bin"
mkdir -p "$FAKE_BIN"
REAL_GIT="$(command -v git)"
export REAL_GIT
printf '%s\n' '#!/usr/bin/env bash' \
  'for arg in "$@"; do [[ "$arg" == "status" ]] && exit 73; done' \
  'exec "$REAL_GIT" "$@"' > "$FAKE_BIN/git"
chmod +x "$FAKE_BIN/git"
ec=0
out="$(PATH="$FAKE_BIN:$PATH" bash "$SCRIPT" run --root "$REPO" --command 'true # unreadable-success')" || ec=$?
check "failed git status is a distinct infrastructure exit" "12" "$ec"
check "failed git status is never accepted as clean" "infrastructure_error" "$(jq -r '.status' <<<"$out")"
ec=0
out="$(PATH="$FAKE_BIN:$PATH" bash "$SCRIPT" run --root "$REPO" --command 'exit 7 # unreadable-failure')" || ec=$?
check "setup failure with unreadable state uses infrastructure exit" "12" "$ec"
check "setup failure preserves unreadable-state outcome" "setup_state_unreadable:7" "$(jq -r '.status + ":" + (.exitCode | tostring)' <<<"$out")"

ec=0
bash "$SCRIPT" run --root "$REPO" --command 'printf dirty > generated.txt' >/dev/null 2>&1 || ec=$?
check "setup-created non-ignored files fail cleanliness" "11" "$ec"
check "dirty output is not cleaned" "1" "$([[ -f "$REPO/generated.txt" ]] && echo 1 || echo 0)"
rm "$REPO/generated.txt"

printf 'ignored.txt\n' > "$REPO/.gitignore"
git -C "$REPO" add .gitignore
git -C "$REPO" commit -qm ignore
out="$(bash "$SCRIPT" run --root "$REPO" --command 'printf local > ignored.txt')"
check "ignored setup output remains allowed" "prepared" "$(jq -r '.status' <<<"$out")"
check "ignored setup output remains present" "1" "$([[ -f "$REPO/ignored.txt" ]] && echo 1 || echo 0)"

SHARE_REPO="$WORK/share-repo"
new_repo "$SHARE_REPO"
printf '{}\n' > "$SHARE_REPO/package.json"
printf '{"lockfileVersion":3}\n' > "$SHARE_REPO/package-lock.json"
printf 'node_modules/\n' > "$SHARE_REPO/.gitignore"
git -C "$SHARE_REPO" add package.json package-lock.json .gitignore
git -C "$SHARE_REPO" commit -qm node-manifest
SHARE_BIN="$WORK/share-bin"
mkdir -p "$SHARE_BIN"
printf '%s\n' '#!/usr/bin/env bash' \
  'mkdir -p node_modules/example' \
  'printf installed > node_modules/example/value' > "$SHARE_BIN/npm"
chmod +x "$SHARE_BIN/npm"
out="$(PATH="$SHARE_BIN:$PATH" bash "$SCRIPT" run --root "$SHARE_REPO" --command 'npm ci')"
check "source dependency tree prepared once" "prepared" "$(jq -r '.status' <<<"$out")"
SHARE_WT="$WORK/share-worktree"
git -C "$SHARE_REPO" worktree add -q -b share-task "$SHARE_WT"
out="$(PATH="$SHARE_BIN:$PATH" bash "$SCRIPT" run --root "$SHARE_WT" \
  --command 'npm ci' --reuse-from "$SHARE_REPO")"
check "task worktree reuses dependency tree" "shared" "$(jq -r '.status' <<<"$out")"
check "task node_modules is a symlink" "1" "$([[ -L "$SHARE_WT/node_modules" ]] && echo 1 || echo 0)"
check "shared dependencies resolve" "installed" "$(<"$SHARE_WT/node_modules/example/value")"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
