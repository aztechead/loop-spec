#!/usr/bin/env bash
# sessions-extension: the headless session layer (extensions/sessions/) launches one CLI
# process per agent node from profile data. Pins the argument order, the child
# environment, worktree seeding, fault classification, the timeout, and that no
# shipped fault pattern matches its own profile line.
#
# tomllib is the layer's runtime floor (python >= 3.11); the suite SKIPS below it, the
# same way tests/adk-extension.test.sh skips without its package.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/extensions/sessions/session_run.py"
WORK="${TMPDIR:-/tmp}/loop-spec-sessions.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/profiles" "$WORK/cwd" "$WORK/seed/.claude" "$WORK/logs"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

if ! python3 -c "import tomllib" >/dev/null 2>&1; then
  echo "sessions-extension: SKIP - python3 is older than 3.11 (no tomllib)"
  echo "Results: 0 passed, 0 failed (skipped)"
  exit 0
fi

# The fake CLI prints its arguments one per line, then the probe variable and its
# cwd, and exits as FAKE_EXIT says after FAKE_SLEEP seconds.
cat > "$WORK/bin/fakecli" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@"
echo "probe=${FAKE_PROBE:-unset}"
echo "cwd=$(pwd -P)"
echo "loop=${LOOP_SPEC_LEAK:-unset} plugin=${CLAUDE_PLUGIN_ROOT:-unset} session=${CLAUDE_CODE_SESSION_ID:-unset}${CLAUDE_CODE_MESSAGING_SOCKET:-}${CLAUDE_CODE_REMOTE_SESSION_ID:-}"
[[ -n "${FAKE_SAY:-}" ]] && echo "$FAKE_SAY"
sleep "${FAKE_SLEEP:-0}"
exit "${FAKE_EXIT:-0}"
SH
chmod +x "$WORK/bin/fakecli"
cat > "$WORK/profiles/fake.toml" <<'TOML'
name = "fake"
binary = "fakecli"
launch_args = ["-p", "--output-format", "json"]
guarded_args = ["--permission-mode", "acceptEdits"]
bypass_args = ["--permission-mode", "bypassPermissions"]
model_flag = "--model"
prompt_template = "run: {prompt}"
seed_files = [".claude/settings.json"]
env_fault_patterns = ["API Error: (5[2]9 Overloaded)"]
[env]
FAKE_PROBE = "from-profile"
TOML
printf 'binary = "no-such-cli"\n' > "$WORK/profiles/absent.toml"
printf 'implement the thing\n' > "$WORK/prompt.md"
printf '{"seeded": true}\n' > "$WORK/seed/.claude/settings.json"

run() { # run [VAR=value ...] [runner args...] -> stdout in $out, exit in $rc
  local assigns=()
  while [[ $# -gt 0 && "$1" == *=* && "$1" != --* ]]; do assigns+=("$1"); shift; done
  rc=0
  out="$(env PATH="$WORK/bin:$PATH" LOOP_SPEC_SESSION_PROFILES="$WORK/profiles" LOOP_SPEC_LEAK=1 \
    CLAUDE_PLUGIN_ROOT=/nowhere CLAUDE_CODE_SESSION_ID=parent CLAUDE_CODE_MESSAGING_SOCKET=/s CLAUDE_CODE_REMOTE_SESSION_ID=r \
    ${assigns[@]+"${assigns[@]}"} \
    python3 "$RUNNER" --log-dir "$WORK/logs" "$@" 2>"$WORK/stderr")" || rc=$?
}
common=(--profile fake --cwd "$WORK/cwd" --prompt-file "$WORK/prompt.md")

rc=0; python3 "$RUNNER" >/dev/null 2>&1 || rc=$?
check "no arguments is a bad call" "2" "$rc"
run --profile missing --cwd "$WORK/cwd" --prompt-file "$WORK/prompt.md"
check "a missing profile is a bad call" "2" "$rc"
check "the missing profile is named" "1" "$(grep -c "no profile 'missing'" "$WORK/stderr")"
run --profile absent --cwd "$WORK/cwd" --prompt-file "$WORK/prompt.md"
check "a binary off PATH exits 3" "3" "$rc"
check "the absent binary is named" "1" "$(grep -c 'no-such-cli is not on PATH' "$WORK/stderr")"

run "${common[@]}" --model haiku --seed-from "$WORK/seed"
check "a clean run completes" "0" "$rc"
check "the result line says completed" "completed" "$(jq -r '.status' <<<"$out")"
check "argv is binary, launch, guarded, model, then the prompt last" \
  "fakecli -p --output-format json --permission-mode acceptEdits --model haiku run: implement the thing" \
  "$(jq -r '.argv | join(" ")' <<<"$out" | tr -d '\n')"
log="$(jq -r '.stdout' <<<"$out")"
check "the profile env reaches the child" "1" "$(grep -c '^probe=from-profile$' "$log")"
check "the child runs in --cwd" "1" "$(grep -c "^cwd=$(cd "$WORK/cwd" && pwd -P)$" "$log")"
check "LOOP_SPEC_*, the plugin bindings, and the session identity do not leak into the child" "1" "$(grep -c '^loop=unset plugin=unset session=unset$' "$log")"
check "a seed file the worktree lacks is copied in" '{"seeded": true}' "$(cat "$WORK/cwd/.claude/settings.json")"
check "the log lands under --log-dir" "$WORK/logs" "$(dirname "$log")"

printf '{"seeded": false}\n' > "$WORK/cwd/.claude/settings.json"
run "${common[@]}" --seed-from "$WORK/seed"
check "an existing worktree file is never overwritten by a seed" '{"seeded": false}' "$(cat "$WORK/cwd/.claude/settings.json")"
check "model inherit adds no model flag" "0" "$(jq -r '.argv | index("--model") // 0' <<<"$out")"

run "${common[@]}" --bypass
check "--bypass replaces the guarded arguments" "--permission-mode bypassPermissions" \
  "$(jq -r '.argv[4:6] | join(" ")' <<<"$out")"

run FAKE_EXIT=1 "${common[@]}"
check "a non-zero CLI exit is failed" "failed:1" "$(jq -r '.status + ":" + (.exit|tostring)' <<<"$out")"
check "failed exits 1" "1" "$rc"

run FAKE_EXIT=1 FAKE_SAY=$'\e[31mAPI Error: 529 Overloaded\e[0m' "${common[@]}"
check "a named provider line is an env-fault" "env-fault" "$(jq -r '.status' <<<"$out")"
check "the matching pattern is reported" "API Error: (5[2]9 Overloaded)" "$(jq -r '.envFault' <<<"$out")"
check "env-fault exits 4" "4" "$rc"

run FAKE_SAY='API Error: 529 Overloaded' "${common[@]}"
check "a provider line in a successful run is still completed" "completed" "$(jq -r '.status' <<<"$out")"

run FAKE_SLEEP=3 "${common[@]}" --timeout 1
check "the timeout kills the session" "timeout" "$(jq -r '.status' <<<"$out")"
check "timeout exits 5" "5" "$rc"
run "${common[@]}" --timeout 0
check "a non-positive timeout is a bad call" "2" "$rc"

# Shipped profiles: one per harness CLI, each launchable, and no fault pattern reads its
# own profile line as an outage.
for cli in claude codex opencode; do
  p="$ROOT/extensions/sessions/profiles/$cli.toml"
  check "profile $cli exists" "1" "$([[ -f "$p" ]] && echo 1 || echo 0)"
  check "profile $cli names its binary" "$cli" "$(python3 -c "import tomllib,sys; print(tomllib.load(open(sys.argv[1],'rb'))['binary'])" "$p")"
  check "profile $cli patterns are inert on their own profile" "0" "$(python3 - "$p" <<'PY'
import re, sys, tomllib
path = sys.argv[1]
profile = tomllib.load(open(path, "rb"))
lines = open(path, encoding="utf-8").read().splitlines()
print(sum(1 for pat in profile.get("env_fault_patterns", []) for line in lines if re.search(pat, line)))
PY
)"
done

check "the claude profile grants the implementer's tools without bypass" "1" \
  "$(grep -c 'guarded_args = .*--allowedTools' "$ROOT/extensions/sessions/profiles/claude.toml")"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
