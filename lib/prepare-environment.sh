#!/usr/bin/env bash
# Resolve and run deterministic dependency preparation for one repository root.
# Exit: 0 prepared/shared/cached/noop; 2 invocation; 10 setup command failed;
# 11 setup left non-ignored worktree changes; 12 Git state unreadable.
set -uo pipefail

die2() { echo "prepare-environment: $*" >&2; exit 2; }
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

root=""
explicit_set=0
explicit_command=""
reuse_from=""
subcommand="${1:-}"
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="${2:-}"; shift 2 ;;
    --command) explicit_set=1; explicit_command="${2:-}"; shift 2 ;;
    --reuse-from) reuse_from="${2:-}"; shift 2 ;;
    *) die2 "unknown argument '$1'" ;;
  esac
done

[[ "$subcommand" == "resolve" || "$subcommand" == "run" ]] \
  || die2 "usage: prepare-environment.sh {resolve|run} --root ROOT [--command COMMAND] [--reuse-from ROOT]"
[[ -n "$root" && -d "$root" ]] || die2 "--root must name a directory"
root="$(cd "$root" && pwd -P)"
git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die2 "not a git worktree: $root"
top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)"
top="$(cd "$top" && pwd -P)"
[[ "$top" == "$root" ]] || die2 "--root must be the repository root: $top"
if [[ -n "$reuse_from" ]]; then
  [[ -d "$reuse_from" ]] || die2 "--reuse-from must name a directory"
  reuse_from="$(cd "$reuse_from" && pwd -P)"
  git -C "$reuse_from" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die2 "--reuse-from is not a git worktree: $reuse_from"
fi

resolve_command() {
  local workflow="$root/.loop-spec/workflow.json"
  source="none"
  command=""

  if [[ "$explicit_set" -eq 1 ]]; then
    source="explicit"
    command="$explicit_command"
    return
  fi
  if [[ -n "${LOOP_SPEC_CMD_PREPARE+x}" ]]; then
    source="environment"
    command="$LOOP_SPEC_CMD_PREPARE"
    return
  fi
  if [[ -f "$workflow" ]]; then
    command="$(jq -r 'if (.prepareCommand | type) == "string" then .prepareCommand else "" end' "$workflow" 2>/dev/null || true)"
    if [[ -n "$command" ]]; then
      source="workflow"
      return
    fi
  fi

  # Prefer lock-preserving commands. Independent Node and Python environments may
  # coexist in one repository, so compose one command per ecosystem.
  local npm=0 pnpm=0 yarn=0 yarn_command="" python_command="" requirements="" i
  local commands=()
  [[ -f "$root/package.json" && ( -f "$root/package-lock.json" || -f "$root/npm-shrinkwrap.json" ) ]] && npm=1
  [[ -f "$root/package.json" && -f "$root/pnpm-lock.yaml" ]] && pnpm=1
  [[ -f "$root/package.json" && -f "$root/yarn.lock" ]] && yarn=1
  if [[ $((npm + pnpm + yarn)) -eq 1 ]]; then
    if [[ "$npm" -eq 1 ]]; then
      commands+=("npm ci")
    elif [[ "$pnpm" -eq 1 ]]; then
      commands+=("pnpm install --frozen-lockfile")
    else
      yarn_command="yarn install --frozen-lockfile"
      if jq -e '.packageManager | strings | test("^yarn@([2-9]|[1-9][0-9])")' \
          "$root/package.json" >/dev/null 2>&1; then
        yarn_command="yarn install --immutable"
      fi
      commands+=("$yarn_command")
    fi
  fi

  if [[ -f "$root/pyproject.toml" && -f "$root/uv.lock" && ! -f "$root/poetry.lock" ]]; then
    python_command="uv sync --frozen"
  elif [[ -f "$root/pyproject.toml" && -f "$root/poetry.lock" && ! -f "$root/uv.lock" ]]; then
    python_command="poetry install --sync --no-interaction"
  elif [[ ! -f "$root/uv.lock" && ! -f "$root/poetry.lock" ]]; then
    requirements=""
    [[ -f "$root/requirements-dev.txt" ]] && requirements="requirements-dev.txt"
    [[ -z "$requirements" && -f "$root/requirements.txt" ]] && requirements="requirements.txt"
    if [[ -n "$requirements" ]]; then
      python_command="python3 -m venv .venv && .venv/bin/python -m pip install -r $requirements"
    fi
  fi
  [[ -z "$python_command" ]] || commands+=("$python_command")

  if [[ "${#commands[@]}" -gt 0 ]]; then
    source="detected"
    command="${commands[0]}"
    for ((i = 1; i < ${#commands[@]}; i++)); do
      command="$command && ${commands[$i]}"
    done
  fi
}

preparation_key() {
  PREPARE_ROOT="$root" PREPARE_COMMAND="$command" python3 - <<'PY'
import hashlib
import os

root = os.environ["PREPARE_ROOT"]
command = os.environ["PREPARE_COMMAND"]
names = (
    "package.json", "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock",
    "pyproject.toml", "poetry.lock", "uv.lock", "requirements.txt", "requirements.lock",
    "Cargo.toml", "Cargo.lock", "go.mod", "go.sum", "Gemfile", "Gemfile.lock",
    "composer.json", "composer.lock",
)
h = hashlib.sha256()
h.update(command.encode())
h.update(b"\0")
for name in names:
    path = os.path.join(root, name)
    if not os.path.isfile(path):
        continue
    h.update(name.encode())
    h.update(b"\0")
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    h.update(b"\0")
print(h.hexdigest())
PY
}

read_worktree_status() {
  git -C "$root" status --porcelain --untracked-files=all 2>/dev/null
}

state_unreadable() {
  local status="$1"
  local exit_code="${2:-null}"
  echo "prepare-environment: cannot read Git worktree status; refusing to accept preparation state" >&2
  jq -cn --arg status "$status" --arg command "$command" --arg source "$source" --arg key "$key" \
    --argjson exitCode "$exit_code" \
    '{status: $status, command: $command, source: $source, key: $key, exitCode: $exitCode}'
  exit 12
}

resolve_command
key=""
[[ -z "$command" ]] || key="$(preparation_key)"

if [[ "$subcommand" == "resolve" ]]; then
  jq -cn --arg command "$command" --arg source "$source" --arg key "$key" \
    '{command: $command, source: $source, key: (if $key == "" then null else $key end)}'
  exit 0
fi

if [[ -z "$command" ]]; then
  jq -cn --arg source "$source" '{status: "noop", command: "", source: $source, key: null}'
  exit 0
fi

git_path="$(git -C "$root" rev-parse --git-path loop-spec/prepare)"
[[ "$git_path" == /* ]] || git_path="$root/$git_path"
mkdir -p "$git_path"
record="$git_path/$key.done"
log="$git_path/$key.log"

if [[ -f "$record" ]]; then
  if ! worktree_status="$(read_worktree_status)"; then
    state_unreadable "infrastructure_error"
  fi
  if [[ -n "$worktree_status" ]]; then
    echo "prepare-environment: worktree is not clean after cached preparation; no cleanup was attempted" >&2
    jq -cn --arg command "$command" --arg source "$source" --arg key "$key" \
      '{status: "dirty", command: $command, source: $source, key: $key}'
    exit 11
  fi
  jq -cn --arg command "$command" --arg source "$source" --arg key "$key" \
    '{status: "cached", command: $command, source: $source, key: $key}'
  exit 0
fi

can_reuse_node_modules=false
case "$command" in
  "npm ci"|"pnpm install --frozen-lockfile"|"yarn install --frozen-lockfile"|"yarn install --immutable")
    can_reuse_node_modules=true ;;
esac

if [[ -n "$reuse_from" && "${LOOP_SPEC_SHARE_DEPENDENCIES:-1}" != "0" \
      && "$can_reuse_node_modules" == "true" && -d "$reuse_from/node_modules" \
      && ! -e "$root/node_modules" && ! -L "$root/node_modules" ]] \
    && git -C "$root" check-ignore -q --no-index node_modules/ 2>/dev/null; then
  source_git_path="$(git -C "$reuse_from" rev-parse --git-path loop-spec/prepare)"
  [[ "$source_git_path" == /* ]] || source_git_path="$reuse_from/$source_git_path"
  source_record="$source_git_path/$key.done"
  if [[ -f "$source_record" ]]; then
    common_dir="$(git -C "$root" rev-parse --git-common-dir)"
    [[ "$common_dir" == /* ]] || common_dir="$(cd "$root" && cd "$common_dir" && pwd -P)"
    exclude_file="$common_dir/info/exclude"
    mkdir -p "$(dirname "$exclude_file")"
    touch "$exclude_file"
    grep -qxF '/node_modules' "$exclude_file" 2>/dev/null \
      || printf '%s\n' '/node_modules' >> "$exclude_file"
    ln -s "$reuse_from/node_modules" "$root/node_modules" || die2 "cannot link shared node_modules"
    if ! worktree_status="$(read_worktree_status)"; then
      rm -f "$root/node_modules"
      state_unreadable "infrastructure_error"
    fi
    if [[ -n "$worktree_status" ]]; then
      rm -f "$root/node_modules"
      echo "prepare-environment: shared node_modules would dirty the worktree" >&2
      jq -cn --arg command "$command" --arg source "$source" --arg key "$key" \
        '{status: "dirty", command: $command, source: $source, key: $key}'
      exit 11
    fi
    printf '%s\n' "$command" > "$record"
    jq -cn --arg command "$command" --arg source "$source" --arg key "$key" \
      --arg reusedFrom "$reuse_from" \
      '{status: "shared", command: $command, source: $source, key: $key,
        reusedFrom: $reusedFrom, sharedPaths: ["node_modules"]}'
    exit 0
  fi
fi

watchdog="$script_dir/run-with-watchdog.sh"
prepare_timeout="${LOOP_SPEC_PREPARE_TIMEOUT_SECS:-1800}"
prepare_idle_timeout="${LOOP_SPEC_PREPARE_IDLE_TIMEOUT_SECS:-300}"
bash "$watchdog" --root "$root" --command "$command" --log "$log" \
  --timeout-secs "$prepare_timeout" --idle-timeout-secs "$prepare_idle_timeout"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  if ! worktree_status="$(read_worktree_status)"; then
    state_unreadable "setup_state_unreadable" "$rc"
  fi
  worktree_clean=true
  [[ -z "$worktree_status" ]] || worktree_clean=false
  failure_kind="$(jq -r '.status // "command_failed"' "$log.watchdog.json" 2>/dev/null \
    || printf 'command_failed')"
  echo "prepare-environment: setup command failed (exit $rc, $failure_kind); log: $log" >&2
  jq -cn --arg command "$command" --arg source "$source" --arg key "$key" \
    --arg failureKind "$failure_kind" --argjson exitCode "$rc" \
    --argjson worktreeClean "$worktree_clean" \
    '{status: "setup_failed", command: $command, source: $source, key: $key,
      exitCode: $exitCode, failureKind: $failureKind, worktreeClean: $worktreeClean}'
  exit 10
fi

if ! worktree_status="$(read_worktree_status)"; then
  state_unreadable "infrastructure_error"
fi
if [[ -n "$worktree_status" ]]; then
  echo "prepare-environment: setup left non-ignored worktree changes; no reset, clean, or commit was attempted; log: $log" >&2
  jq -cn --arg command "$command" --arg source "$source" --arg key "$key" \
    '{status: "dirty", command: $command, source: $source, key: $key}'
  exit 11
fi

printf '%s\n' "$command" > "$record"
jq -cn --arg command "$command" --arg source "$source" --arg key "$key" \
  '{status: "prepared", command: $command, source: $source, key: $key}'
