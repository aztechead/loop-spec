#!/usr/bin/env bash
# Workspace mode resolver for loop-spec.
#
# Subcommands:
#   detect [dir]
#       Print JSON describing the workspace mode of <dir> (default: $PWD).
#       Modes:
#         {"mode":"single","root":"<abs toplevel>"}
#         {"mode":"workspace","root":"<abs dir>","source":"config|discovered","repos":[{"name":"<n>","path":"<rel>"},...]}
#         {"mode":"none","root":"<abs dir>"}
#
#   list-repos [dir]
#       Print one "name<TAB>path" line per repo in workspace mode.
#       Exit 1 with a message when the mode is not workspace.
#
#   resolve-repo <root> <path>
#       Print the repo name (from the workspace at <root>) that owns <path>.
#       Uses longest-prefix match over configured/discovered repos.
#       <path> may be absolute or workspace-relative.
#       Prints empty output when no repo owns the path.
#
# Detection order for `detect`:
#   1. dir defaults to $PWD; normalize to absolute.
#   2. If <dir>/.loop-spec/workspace.json exists: mode=workspace, source=config.
#      Parse with jq: .repos[] | {name, path}. Validate each entry.
#      On any invalid entry exit 1 with a clear message.
#   3. Else if git -C "$dir" rev-parse --is-inside-work-tree succeeds: mode=single,
#      root = git -C "$dir" rev-parse --show-toplevel.
#   4. Else scan immediate children (skip names starting with '.'): a child qualifies
#      when <child>/.git exists (dir OR file). One or more -> mode=workspace,
#      source=discovered, repos sorted by name. Zero -> mode=none.
#
# Exit codes:
#   0  success (answer on stdout)
#   1  bad invocation or invalid workspace.json entry
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_usage() {
  echo "usage: workspace.sh {detect [dir]|list-repos [dir]|resolve-repo <root> <path>}" >&2
  exit 1
}

# Resolve an absolute path (bash >= 4 compatible, no realpath needed).
_abspath() {
  local p="$1"
  if [[ "$p" == /* ]]; then
    printf '%s' "$p"
  else
    printf '%s/%s' "$PWD" "$p"
  fi
}

# _detect_impl <abs-dir>  -- prints JSON, returns exit code.
_detect_impl() {
  local dir="$1"

  # Step 2: explicit workspace.json pin.
  local cfg="$dir/.loop-spec/workspace.json"
  if [[ -f "$cfg" ]]; then
    # Require jq-parseable JSON.
    if ! jq -e . "$cfg" >/dev/null 2>&1; then
      echo "workspace.json: invalid JSON in $cfg" >&2
      exit 1
    fi

    # missing schemaVersion is tolerated (PLAN: "missing schemaVersion tolerated").
    # unknown extra fields are tolerated.

    # Extract repos array.
    local repos_json
    repos_json="$(jq -c '[.repos[] | {name: .name, path: .path}]' "$cfg" 2>/dev/null)" || {
      echo "workspace.json: could not read .repos array in $cfg" >&2
      exit 1
    }

    # Validate each entry.
    local n_repos
    n_repos="$(jq 'length' <<< "$repos_json")"
    if [[ "$n_repos" -eq 0 ]]; then
      echo "workspace.json: .repos is empty in $cfg" >&2
      exit 1
    fi

    # Check for duplicate names.
    local dup_names
    dup_names="$(jq -r '.[].name' <<< "$repos_json" | sort | uniq -d)"
    if [[ -n "$dup_names" ]]; then
      echo "workspace.json: duplicate repo name(s): $dup_names" >&2
      exit 1
    fi

    # Validate each repo entry.
    local i name path abs_path resolved_path repo_top workspace_abs
    workspace_abs="$(cd "$dir" && pwd -P)"
    for (( i=0; i<n_repos; i++ )); do
      name="$(jq -r ".[$i].name" <<< "$repos_json")"
      path="$(jq -r ".[$i].path" <<< "$repos_json")"

      # Resolve path relative to workspace dir.
      if [[ "$path" == /* ]]; then
        abs_path="$path"
      else
        abs_path="$dir/$path"
      fi

      if [[ ! -d "$abs_path" ]]; then
        echo "workspace.json: repo '$name' invalid: path '$path' does not exist or is not a directory" >&2
        exit 1
      fi

      if ! git -C "$abs_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "workspace.json: repo '$name' invalid: path '$path' is not inside a git work tree" >&2
        exit 1
      fi
      resolved_path="$(cd "$abs_path" && pwd -P)"
      repo_top="$(git -C "$abs_path" rev-parse --show-toplevel 2>/dev/null)"
      repo_top="$(cd "$repo_top" && pwd -P)"
      if [[ "$resolved_path" == "$workspace_abs" ]]; then
        echo "workspace.json: repo '$name' invalid: workspace root cannot also be a workspace target; use single-repo mode for the root" >&2
        exit 1
      fi
      if [[ "$resolved_path" != "$repo_top" ]]; then
        echo "workspace.json: repo '$name' invalid: path '$path' must name the git repository root" >&2
        exit 1
      fi
    done

    # Build output JSON -- repos keep the order from the file (config-pinned).
    local out
    out="$(jq -cn \
      --arg mode "workspace" \
      --arg root "$dir" \
      --arg source "config" \
      --argjson repos "$repos_json" \
      '{mode: $mode, root: $root, source: $source, repos: $repos}')"
    printf '%s\n' "$out"
    return 0
  fi

  # Step 3: cwd is inside a git repo.
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local toplevel
    toplevel="$(git -C "$dir" rev-parse --show-toplevel)"
    jq -cn \
      --arg mode "single" \
      --arg root "$toplevel" \
      '{mode: $mode, root: $root}'
    return 0
  fi

  # Step 4: scan immediate children for git repos.
  local found_repos=()
  local child name
  for child in "$dir"/*/; do
    # Strip trailing slash.
    child="${child%/}"
    name="$(basename "$child")"
    # Skip hidden dirs (starting with '.').
    if [[ "$name" == .* ]]; then
      continue
    fi
    # Child qualifies if .git exists (dir or file).
    if [[ -e "$child/.git" ]]; then
      found_repos+=("$name")
    fi
  done

  if [[ "${#found_repos[@]}" -eq 0 ]]; then
    jq -cn --arg mode "none" --arg root "$dir" '{mode: $mode, root: $root}'
    return 0
  fi

  # Sort found repos by name.
  IFS=$'\n' sorted_repos=($(printf '%s\n' "${found_repos[@]}" | sort))
  unset IFS

  # Build repos JSON array (path = child basename, relative to workspace root).
  local repos_arr="[]"
  local r
  for r in "${sorted_repos[@]}"; do
    repos_arr="$(jq -cn \
      --argjson arr "$repos_arr" \
      --arg name "$r" \
      --arg path "$r" \
      '$arr + [{name: $name, path: $path}]')"
  done

  jq -cn \
    --arg mode "workspace" \
    --arg root "$dir" \
    --arg source "discovered" \
    --argjson repos "$repos_arr" \
    '{mode: $mode, root: $root, source: $source, repos: $repos}'
}

# _repos_from_dir <abs-dir>  -- returns JSON repos array from detect output.
_repos_from_dir() {
  local dir="$1"
  local result
  result="$(_detect_impl "$dir")"
  local mode
  mode="$(jq -r '.mode' <<< "$result")"
  if [[ "$mode" != "workspace" ]]; then
    echo "list-repos: mode is '$mode', not 'workspace'; no repos to list" >&2
    exit 1
  fi
  jq -r '.repos[]' <<< "$result"
}

cmd="${1:-}"

case "$cmd" in
  detect)
    raw_dir="${2:-$PWD}"
    # Normalize to absolute.
    if [[ "$raw_dir" == /* ]]; then
      abs_dir="$raw_dir"
    else
      abs_dir="$PWD/$raw_dir"
    fi
    _detect_impl "$abs_dir"
    ;;

  list-repos)
    raw_dir="${2:-$PWD}"
    if [[ "$raw_dir" == /* ]]; then
      abs_dir="$raw_dir"
    else
      abs_dir="$PWD/$raw_dir"
    fi
    result="$(_detect_impl "$abs_dir")"
    mode="$(jq -r '.mode' <<< "$result")"
    if [[ "$mode" != "workspace" ]]; then
      echo "list-repos: mode is '$mode', not 'workspace'; no repos to list" >&2
      exit 1
    fi
    jq -r '.repos[] | "\(.name)\t\(.path)"' <<< "$result"
    ;;

  resolve-repo)
    if [[ $# -lt 3 ]]; then
      _usage
    fi
    root="$2"
    target="$3"

    # Normalize root to absolute.
    if [[ "$root" != /* ]]; then
      root="$PWD/$root"
    fi

    # Normalize target to absolute.
    if [[ "$target" == /* ]]; then
      abs_target="$target"
    else
      abs_target="$root/$target"
    fi

    # Get repos for this root.
    result="$(_detect_impl "$root")"
    mode="$(jq -r '.mode' <<< "$result")"
    if [[ "$mode" != "workspace" ]]; then
      # Not a workspace -- print empty.
      printf ''
      exit 0
    fi

    # Longest-prefix match.
    best_name=""
    best_len=0
    while IFS=$'\t' read -r rname rpath; do
      if [[ "$rpath" == /* ]]; then
        abs_repo="$rpath"
      else
        abs_repo="$root/$rpath"
      fi
      # Ensure abs_repo ends without trailing slash for prefix matching.
      abs_repo="${abs_repo%/}"
      repo_prefix="$abs_repo/"
      prefix_len="${#abs_repo}"
      if [[ "$abs_target" == "$abs_repo" || "$abs_target" == "$repo_prefix"* ]]; then
        if [[ "$prefix_len" -gt "$best_len" ]]; then
          best_len="$prefix_len"
          best_name="$rname"
        fi
      fi
    done < <(jq -r '.repos[] | "\(.name)\t\(.path)"' <<< "$result")

    printf '%s\n' "$best_name"
    ;;

  ""|--help|-h)
    _usage
    ;;

  *)
    _usage
    ;;
esac
