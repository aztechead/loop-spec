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

# A workspace often keeps one ecosystem below the root: the repository root
# carries pyproject.toml + uv.lock while the frontend lives in webapp/frontend/
# with its own package.json + package-lock.json. A root-only probe reports no
# Node ecosystem there, the caller improvises, and the improvised install is the
# mutating one (`npm install`), which rewrites the lockfile and trips the
# "preparation leaves the tree unchanged" guard. So probe one level deeper, but
# only where the answer stays deterministic: tracked files (an untracked or
# ignored lockfile is not the project's declared state), bounded depth, and
# ordinary relative paths so the emitted command needs no quoting and can be
# parsed back out of the stored command string.
subdir_max_depth=3

# Relative directories below the root that hold MANIFEST and LOCK together.
ecosystem_subdirs() {
  local lock="$1" manifest="$2" path dir slashes
  git -C "$root" ls-files -z -- "*/$lock" 2>/dev/null \
    | while IFS= read -r -d '' path; do
        [[ "${path##*/}" == "$lock" ]] || continue
        dir="${path%/*}"
        case "/$dir/" in */node_modules/*|*/.*/*) continue ;; esac
        case "$dir" in ""|*[!A-Za-z0-9._/-]*|*..*) continue ;; esac
        slashes="${dir//[^\/]/}"
        (( ${#slashes} + 1 <= subdir_max_depth )) || continue
        [[ -f "$root/$dir/$manifest" && -f "$root/$dir/$lock" ]] || continue
        printf '%s\n' "$dir"
      done | sort -u
}

# Every "MANAGER<TAB>DIR" candidate for one ecosystem, so ambiguity is judged
# across managers: two managers in one directory is as unresolvable as two
# directories, and both keep the empty command rather than guessing an install.
node_subdir_candidates() {
  local dir
  while IFS= read -r dir; do [[ -z "$dir" ]] || printf 'npm\t%s\n' "$dir"; done \
    < <(ecosystem_subdirs package-lock.json package.json)
  while IFS= read -r dir; do [[ -z "$dir" ]] || printf 'npm\t%s\n' "$dir"; done \
    < <(ecosystem_subdirs npm-shrinkwrap.json package.json)
  while IFS= read -r dir; do [[ -z "$dir" ]] || printf 'pnpm\t%s\n' "$dir"; done \
    < <(ecosystem_subdirs pnpm-lock.yaml package.json)
  while IFS= read -r dir; do [[ -z "$dir" ]] || printf 'yarn\t%s\n' "$dir"; done \
    < <(ecosystem_subdirs yarn.lock package.json)
}

python_subdir_candidates() {
  local dir
  while IFS= read -r dir; do [[ -z "$dir" ]] || printf 'uv\t%s\n' "$dir"; done \
    < <(ecosystem_subdirs uv.lock pyproject.toml)
  while IFS= read -r dir; do [[ -z "$dir" ]] || printf 'poetry\t%s\n' "$dir"; done \
    < <(ecosystem_subdirs poetry.lock pyproject.toml)
}

node_install_command() {
  local manager="$1" manifest="$2" yarn_command
  case "$manager" in
    npm) printf 'npm ci' ;;
    pnpm) printf 'pnpm install --frozen-lockfile' ;;
    yarn)
      yarn_command="yarn install --frozen-lockfile"
      if jq -e '.packageManager | strings | test("^yarn@([2-9]|[1-9][0-9])")' \
          "$manifest" >/dev/null 2>&1; then
        yarn_command="yarn install --immutable"
      fi
      printf '%s' "$yarn_command" ;;
  esac
}

resolve_command() {
  local workflow="$root/.loop-spec/workflow.json"
  source="none"
  command=""
  reason=""

  if [[ "$explicit_set" -eq 1 ]]; then
    source="explicit"
    command="$explicit_command"
    reason="source=explicit"
    return
  fi
  if [[ -n "${LOOP_SPEC_CMD_PREPARE+x}" ]]; then
    source="environment"
    command="$LOOP_SPEC_CMD_PREPARE"
    reason="source=environment"
    return
  fi
  if [[ -f "$workflow" ]]; then
    command="$(jq -r 'if (.prepareCommand | type) == "string" then .prepareCommand else "" end' "$workflow" 2>/dev/null || true)"
    if [[ -n "$command" ]]; then
      source="workflow"
      reason="source=workflow"
      return
    fi
  fi

  # Prefer lock-preserving commands. Independent Node and Python environments may
  # coexist in one repository, so compose one command per ecosystem.
  local npm=0 pnpm=0 yarn=0 python_command="" requirements="" i
  local candidates="" manager="" dir="" node_reason="none" python_reason="none"
  local commands=()
  [[ -f "$root/package.json" && ( -f "$root/package-lock.json" || -f "$root/npm-shrinkwrap.json" ) ]] && npm=1
  [[ -f "$root/package.json" && -f "$root/pnpm-lock.yaml" ]] && pnpm=1
  [[ -f "$root/package.json" && -f "$root/yarn.lock" ]] && yarn=1
  if [[ $((npm + pnpm + yarn)) -eq 1 ]]; then
    manager=npm
    [[ "$pnpm" -eq 1 ]] && manager=pnpm
    [[ "$yarn" -eq 1 ]] && manager=yarn
    commands+=("$(node_install_command "$manager" "$root/package.json")")
    node_reason="root:$manager"
  elif [[ $((npm + pnpm + yarn)) -gt 1 ]]; then
    node_reason="ambiguous-root:$((npm + pnpm + yarn))"
  else
    # No Node ecosystem at the root: the lockfile may live one workspace down.
    candidates="$(node_subdir_candidates)"
    if [[ -z "$candidates" ]]; then
      node_reason="none"
    elif [[ "$(wc -l <<<"$candidates")" -ne 1 ]]; then
      node_reason="ambiguous-subdir:$(wc -l <<<"$candidates" | tr -d ' ')"
    else
      manager="${candidates%%$'\t'*}"
      dir="${candidates#*$'\t'}"
      commands+=("(cd $dir && $(node_install_command "$manager" "$root/$dir/package.json"))")
      node_reason="subdir:$dir:$manager"
    fi
  fi

  if [[ -f "$root/pyproject.toml" && -f "$root/uv.lock" && ! -f "$root/poetry.lock" ]]; then
    python_command="uv sync --frozen"
    python_reason="root:uv"
  elif [[ -f "$root/pyproject.toml" && -f "$root/poetry.lock" && ! -f "$root/uv.lock" ]]; then
    python_command="poetry install --sync --no-interaction"
    python_reason="root:poetry"
  elif [[ ! -f "$root/uv.lock" && ! -f "$root/poetry.lock" ]]; then
    requirements=""
    [[ -f "$root/requirements-dev.txt" ]] && requirements="requirements-dev.txt"
    [[ -z "$requirements" && -f "$root/requirements.txt" ]] && requirements="requirements.txt"
    if [[ -n "$requirements" ]]; then
      python_command="python3 -m venv .venv && .venv/bin/python -m pip install -r $requirements"
      python_reason="root:pip"
    fi
  fi
  if [[ -z "$python_command" && ! -f "$root/pyproject.toml" \
        && ! -f "$root/uv.lock" && ! -f "$root/poetry.lock" ]]; then
    candidates="$(python_subdir_candidates)"
    if [[ -z "$candidates" ]]; then
      python_reason="none"
    elif [[ "$(wc -l <<<"$candidates")" -ne 1 ]]; then
      python_reason="ambiguous-subdir:$(wc -l <<<"$candidates" | tr -d ' ')"
    else
      manager="${candidates%%$'\t'*}"
      dir="${candidates#*$'\t'}"
      if [[ "$manager" == "uv" ]]; then
        python_command="(cd $dir && uv sync --frozen)"
      else
        python_command="(cd $dir && poetry install --sync --no-interaction)"
      fi
      python_reason="subdir:$dir:$manager"
    fi
  fi
  [[ -z "$python_command" ]] || commands+=("$python_command")

  reason="node=$node_reason python=$python_reason"
  if [[ "${#commands[@]}" -gt 0 ]]; then
    source="detected"
    command="${commands[0]}"
    for ((i = 1; i < ${#commands[@]}; i++)); do
      command="$command && ${commands[$i]}"
    done
  fi
}

# Directories the command actually prepares: the root, plus every subdirectory
# named by a "(cd DIR && ...)" segment this script emits. Parsed from the final
# command rather than from detection, so a command persisted in feature state
# and replayed through --command keys off the same manifests it installs from.
command_dirs() {
  local rest="$command" dir
  printf '%s\n' "."
  while [[ "$rest" == *"(cd "* ]]; do
    rest="${rest#*"(cd "}"
    dir="${rest%%" && "*}"
    [[ "$dir" != "$rest" ]] || break
    case "$dir" in
      ""|*[!A-Za-z0-9._/-]*|*..*) ;;
      *) printf '%s\n' "$dir" ;;
    esac
  done
}

preparation_key() {
  PREPARE_ROOT="$root" PREPARE_COMMAND="$command" PREPARE_DIRS="$(command_dirs)" python3 - <<'PY'
import hashlib
import os

root = os.environ["PREPARE_ROOT"]
command = os.environ["PREPARE_COMMAND"]
names = (
    "package.json", "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock",
    "pyproject.toml", "poetry.lock", "uv.lock", "requirements.txt", "requirements.lock",
    "Cargo.toml", "Cargo.lock", "go.mod", "go.sum", "Gemfile", "Gemfile.lock",
    "composer.json", "composer.lock", "project.clj", "deps.edn", "mix.exs",
    "pom.xml", "build.gradle", "build.gradle.kts",
)
# The root keeps its bare manifest names so an unchanged repository keeps its
# existing key; a prepared subdirectory contributes its manifests under the
# relative path, which is what makes a workspace lockfile edit invalidate the
# cached preparation instead of silently reusing it.
dirs = ["."]
for entry in os.environ.get("PREPARE_DIRS", "").splitlines():
    entry = entry.strip()
    if entry and entry != "." and entry not in dirs:
        dirs.append(entry)
h = hashlib.sha256()
h.update(command.encode())
h.update(b"\0")
for directory in dirs:
    for name in names:
        path = os.path.join(root, directory, name)
        if not os.path.isfile(path):
            continue
        label = name if directory == "." else os.path.join(directory, name)
        h.update(label.encode())
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
    --arg reason "$reason" \
    '{command: $command, source: $source, key: (if $key == "" then null else $key end),
      reason: (if $reason == "" then null else $reason end)}'
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

# Sharing stays keyed on the whole command being one frozen Node install, now in
# either the root or the subdirectory form the resolver emits; the parsed
# directory decides which node_modules is linked, so a workspace frontend keeps
# the reuse a root-level project already had.
can_reuse_node_modules=false
node_modules_rel="node_modules"
node_modules_parent="$root"
case "$command" in
  "npm ci"|"pnpm install --frozen-lockfile"|"yarn install --frozen-lockfile"|"yarn install --immutable")
    can_reuse_node_modules=true ;;
  "(cd "*" && npm ci)"|"(cd "*" && pnpm install --frozen-lockfile)" \
  |"(cd "*" && yarn install --frozen-lockfile)"|"(cd "*" && yarn install --immutable)")
    subdir="${command#"(cd "}"
    subdir="${subdir%%" && "*}"
    case "$subdir" in
      ""|*[!A-Za-z0-9._/-]*|*..*) ;;
      *)
        can_reuse_node_modules=true
        node_modules_rel="$subdir/node_modules"
        node_modules_parent="$root/$subdir" ;;
    esac ;;
esac

if [[ -n "$reuse_from" && "${LOOP_SPEC_SHARE_DEPENDENCIES:-1}" != "0" \
      && "$can_reuse_node_modules" == "true" && -d "$reuse_from/$node_modules_rel" \
      && -d "$node_modules_parent" \
      && ! -e "$root/$node_modules_rel" && ! -L "$root/$node_modules_rel" ]] \
    && git -C "$root" check-ignore -q --no-index "$node_modules_rel/" 2>/dev/null; then
  source_git_path="$(git -C "$reuse_from" rev-parse --git-path loop-spec/prepare)"
  [[ "$source_git_path" == /* ]] || source_git_path="$reuse_from/$source_git_path"
  source_record="$source_git_path/$key.done"
  if [[ -f "$source_record" ]]; then
    common_dir="$(git -C "$root" rev-parse --git-common-dir)"
    [[ "$common_dir" == /* ]] || common_dir="$(cd "$root" && cd "$common_dir" && pwd -P)"
    exclude_file="$common_dir/info/exclude"
    mkdir -p "$(dirname "$exclude_file")"
    touch "$exclude_file"
    grep -qxF "/$node_modules_rel" "$exclude_file" 2>/dev/null \
      || printf '%s\n' "/$node_modules_rel" >> "$exclude_file"
    ln -s "$reuse_from/$node_modules_rel" "$root/$node_modules_rel" \
      || die2 "cannot link shared node_modules"
    if ! worktree_status="$(read_worktree_status)"; then
      rm -f "$root/$node_modules_rel"
      state_unreadable "infrastructure_error"
    fi
    if [[ -n "$worktree_status" ]]; then
      rm -f "$root/$node_modules_rel"
      echo "prepare-environment: shared node_modules would dirty the worktree" >&2
      jq -cn --arg command "$command" --arg source "$source" --arg key "$key" \
        '{status: "dirty", command: $command, source: $source, key: $key}'
      exit 11
    fi
    printf '%s\n' "$command" > "$record"
    jq -cn --arg command "$command" --arg source "$source" --arg key "$key" \
      --arg reusedFrom "$reuse_from" --arg sharedPath "$node_modules_rel" \
      '{status: "shared", command: $command, source: $source, key: $key,
        reusedFrom: $reusedFrom, sharedPaths: [$sharedPath]}'
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
