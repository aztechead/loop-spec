#!/usr/bin/env bash
# Shared credential refresh and one-retry authentication seam.
# Source this file, then call loop_spec_run_authenticated with a command runner.

# shellcheck source=bounded-run.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/bounded-run.sh"

LOOP_SPEC_AUTH_ERROR_CODE=""
LOOP_SPEC_AUTH_ERROR_MESSAGE=""
LOOP_SPEC_CREDENTIAL_PREPARED_STAGES=()

loop_spec_credential_refresh() {
  local repo_dir="$1" stage="$2" reason="$3" host="$4"
  local command_text="${LOOP_SPEC_CREDENTIAL_REFRESH_CMD:-}"
  local payload rc key value

  LOOP_SPEC_AUTH_ERROR_CODE=""
  LOOP_SPEC_AUTH_ERROR_MESSAGE=""
  [[ -n "$command_text" ]] || return 0

  rc=0
  payload="$({
    umask 077
    private_dir="$(mktemp -d "${TMPDIR:-/tmp}/loop-spec-credential-refresh-XXXXXX")" || exit 12
    cleanup_refresh() { rm -rf "$private_dir"; }
    trap cleanup_refresh EXIT
    trap 'exit 125' HUP INT TERM

    cd "$repo_dir" || exit 12
    export LOOP_SPEC_CREDENTIAL_REFRESH_STAGE="$stage"
    export LOOP_SPEC_CREDENTIAL_REFRESH_REASON="$reason"
    export LOOP_SPEC_CREDENTIAL_REFRESH_HOST="$host"
    export LOOP_SPEC_CREDENTIAL_REFRESH_REPO="$repo_dir"

    # Keep the configured shell fragment and any embedded values out of argv, and
    # off disk -- loop_spec_run_bounded_stdin passes it through a pipe.
    #
    # Bounded: this hook is the first thing every gh/git stage runs, so a token-mint
    # call that STALLS -- a network partition to a metadata or token-broker service,
    # as opposed to failing fast -- blocks pr-delivery, checkpoint-pr and pr-comments
    # alike. A refresh is a short round trip; if it has not answered within the
    # deadline it is not going to, and the caller's existing non-zero path turns that
    # into a retryable authentication_failed instead of an unattended hang.
    #
    # NB: no parentheses in comments here. This block sits inside a $. . .
    # command substitution, and bash's parser counts parens in comments when it
    # scans for the closing delimiter -- an unmatched one is a syntax error.
    hook_rc=0
    hook_timeout="$(loop_spec_resolve_timeout "${LOOP_SPEC_CREDENTIAL_REFRESH_TIMEOUT_SECONDS:-}" 60)" \
      || hook_timeout=60
    loop_spec_run_bounded_stdin "$hook_timeout" \
      "$private_dir/stdout" "$private_dir/stderr" "$command_text" bash -s || hook_rc=$?
    [[ "$hook_rc" -eq 0 ]] || exit 10

    if LC_ALL=C grep -q '[^[:space:]]' "$private_dir/stdout" 2>/dev/null; then
      jq -ec '
        select(
          type == "object"
          and (keys - ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"] | length == 0)
          and all(.[]; type == "string")
        )
      ' "$private_dir/stdout" || exit 11
    fi
  } 2>/dev/null)" || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    LOOP_SPEC_AUTH_ERROR_CODE="credential_refresh_failed"
    case "$rc" in
      11) LOOP_SPEC_AUTH_ERROR_MESSAGE="credential refresh hook returned invalid JSON" ;;
      12) LOOP_SPEC_AUTH_ERROR_MESSAGE="credential refresh could not allocate private output" ;;
      *) LOOP_SPEC_AUTH_ERROR_MESSAGE="credential refresh hook failed" ;;
    esac
    return 125
  fi

  if [[ -n "$payload" ]]; then
    for key in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
      if jq -e --arg key "$key" 'has($key)' <<<"$payload" >/dev/null 2>&1; then
        value="$(jq -r --arg key "$key" '.[$key]' <<<"$payload")"
        export "$key=$value"
      fi
    done
  fi
  return 0
}

loop_spec_is_auth_failure() {
  local rc="$1" stdout_file="$2" stderr_file="$3"
  [[ "$rc" -ne 0 ]] || return 1
  LC_ALL=C grep -Eqi '(^|[^0-9])(401|403)([^0-9]|$)|bad credentials|unauthorized|forbidden|authentication (failed|required)|could not read username|terminal prompts disabled|invalid username or password|http basic: access denied|permission denied \(publickey\)|not logged in|token[^[:space:]]* (is )?(invalid|expired)' \
    "$stdout_file" "$stderr_file" 2>/dev/null
}

# loop_spec_run_authenticated <repo> <stage> <host> <stdout-file> <stderr-file>
#   <runner-function> [runner arguments...]
# The runner must write to the supplied files and return the wrapped command's status.
loop_spec_run_authenticated() {
  local repo_dir="$1" stage="$2" host="$3" stdout_file="$4" stderr_file="$5"
  shift 5
  local rc=0 stage_key prepared_stage stage_prepared=0

  LOOP_SPEC_AUTH_ERROR_CODE=""
  LOOP_SPEC_AUTH_ERROR_MESSAGE=""
  stage_key="$repo_dir|$host|$stage"
  for prepared_stage in "${LOOP_SPEC_CREDENTIAL_PREPARED_STAGES[@]-}"; do
    [[ "$prepared_stage" == "$stage_key" ]] && stage_prepared=1
  done
  if [[ "$stage_prepared" -eq 0 ]]; then
    loop_spec_credential_refresh "$repo_dir" "$stage" "pre-stage" "$host" || return 125
    LOOP_SPEC_CREDENTIAL_PREPARED_STAGES+=("$stage_key")
  fi

  "$@" || rc=$?
  if loop_spec_is_auth_failure "$rc" "$stdout_file" "$stderr_file"; then
    loop_spec_credential_refresh "$repo_dir" "$stage" "auth-retry" "$host" || return 125
    rc=0
    "$@" || rc=$?
    if loop_spec_is_auth_failure "$rc" "$stdout_file" "$stderr_file"; then
      LOOP_SPEC_AUTH_ERROR_CODE="authentication_failed"
      LOOP_SPEC_AUTH_ERROR_MESSAGE="authentication failed after credential refresh"
    fi
  fi
  return "$rc"
}
