#!/usr/bin/env bash
# verify-live.sh - Reality-grounded VERIFY: the live-run rung (ROADMAP-3.0 C1).
#
# Extends probe-before-assert past the test suite: launch the thing that was
# built, probe that it actually serves, run acceptance probes derived from the
# SPEC, and capture every probe into the feature's EVIDENCE.md ledger
# (lib/evidence.sh) so the verifier cites EVID-NNN ids instead of asserting
# "it works". The loop ends at "observed working", not "suite green".
#
# OPT-IN PER REPO and degrade-by-design: configuration lives in
# .loop-spec/workflow.json under "verifyCommands"; when absent, `run` prints
# one line and exits 0 (suite-only VERIFY, unchanged). This script NEVER
# guesses a launch command at run time — `detect` (the lib/detect-test-cmd.sh
# sibling) only SUGGESTS one for a human or an autonomous default to confirm
# into the config.
#
# Config block (.loop-spec/workflow.json):
#   "verifyCommands": {
#     "launch": "<command that starts the app; killed after probing>",
#     "ready":  "<command that exits 0 once the app is up>",
#     "probes": ["<acceptance probe cmd>", ...],
#     "readyTimeoutSec": 30        // optional, default 30
#   }
#
# Usage:
#   verify-live.sh config [--file <workflow.json>]
#       Print the verifyCommands block. Exit 1 when unconfigured.
#   verify-live.sh detect [<dir>]
#       Suggest a launch command from repo markers (package.json scripts.start,
#       Procfile, docker-compose.yml, manage.py, main.py). Prints the
#       suggestion or nothing. Exit 0 always. NEVER writes config.
#   verify-live.sh run [--file <workflow.json>] [--evidence <EVIDENCE.md>]
#       Launch -> wait ready -> run probes -> kill. Each probe's command and
#       output tail land in the evidence ledger when --evidence is given.
#       Output: one JSON line {configured, ready, probes: [{cmd, pass, evid}],
#       allPass}. Exit 0 = all probes passed (or unconfigured); exit 1 = the
#       launch/ready/probe path failed (VERIFY routes remediation, class
#       "live-probe"); exit 2 = bad invocation.
set -uo pipefail

_die2() { echo "verify-live.sh: $*" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_FILE="${LOOP_SPEC_WORKFLOW_CONFIG:-${CLAUDE_PROJECT_DIR:-.}/.loop-spec/workflow.json}"

_config_of() { # _config_of <file> -> prints block, rc 1 when unconfigured
  local file="$1" cfg
  [[ -f "$file" ]] || return 1
  cfg="$(jq -c '.verifyCommands // empty' "$file" 2>/dev/null)" || return 1
  [[ -n "$cfg" ]] || return 1
  # A block without launch+ready+probes is not a configuration, it is a typo;
  # refuse loudly rather than half-running.
  jq -e '(.launch | type == "string" and length > 0)
         and (.ready | type == "string" and length > 0)
         and (.probes | type == "array" and length > 0)' >/dev/null 2>&1 <<<"$cfg" \
    || { echo "verify-live.sh: verifyCommands block is malformed (need launch, ready, probes[])" >&2; return 2; }
  printf '%s\n' "$cfg"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  config)
    FILE="$DEFAULT_FILE"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --file) FILE="${2:-}"; shift 2 || shift ;;
        *) _die2 "unknown flag '$1' for config" ;;
      esac
    done
    cfg="$(_config_of "$FILE")" || exit $?
    jq . <<<"$cfg"
    exit 0
    ;;

  detect)
    dir="${1:-$PWD}"
    if [[ -f "$dir/package.json" ]] && jq -e '.scripts.start' "$dir/package.json" >/dev/null 2>&1; then
      printf 'npm start\n'
    elif [[ -f "$dir/Procfile" ]] && grep -qE '^web:' "$dir/Procfile"; then
      grep -m1 -E '^web:' "$dir/Procfile" | sed 's/^web:[[:space:]]*//'
    elif [[ -f "$dir/docker-compose.yml" || -f "$dir/docker-compose.yaml" ]]; then
      printf 'docker compose up\n'
    elif [[ -f "$dir/manage.py" ]]; then
      printf 'python3 manage.py runserver\n'
    elif [[ -f "$dir/main.py" ]]; then
      printf 'python3 main.py\n'
    fi
    exit 0
    ;;

  run)
    FILE="$DEFAULT_FILE"
    EVIDENCE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --file) FILE="${2:-}"; shift 2 || shift ;;
        --evidence) EVIDENCE="${2:-}"; shift 2 || shift ;;
        *) _die2 "unknown flag '$1' for run" ;;
      esac
    done

    cfg="$(_config_of "$FILE")"; rc=$?
    if [[ "$rc" == "1" ]]; then
      echo "live-verify: not configured (no verifyCommands block) — suite-only VERIFY" >&2
      jq -cn '{configured: false, ready: null, probes: [], allPass: null}'
      exit 0
    fi
    [[ "$rc" == "0" ]] || exit 2

    launch="$(jq -r '.launch' <<<"$cfg")"
    ready="$(jq -r '.ready' <<<"$cfg")"
    timeout_s="$(jq -r '.readyTimeoutSec // 30' <<<"$cfg")"
    [[ "$timeout_s" =~ ^[0-9]+$ ]] || timeout_s=30

    # Launch in its own process group so the app AND its children die on cleanup.
    log="$(mktemp)"
    set -m
    bash -c "$launch" > "$log" 2>&1 &
    app_pid=$!
    set +m
    cleanup() {
      kill -- -"$app_pid" 2>/dev/null || kill "$app_pid" 2>/dev/null || true
      wait "$app_pid" 2>/dev/null || true
      rm -f "$log"
    }
    trap cleanup EXIT

    # Readiness: poll once per second up to readyTimeoutSec.
    is_ready=false
    for ((i = 0; i < timeout_s; i++)); do
      if ! kill -0 "$app_pid" 2>/dev/null; then
        break  # app died before becoming ready
      fi
      if bash -c "$ready" >/dev/null 2>&1; then
        is_ready=true
        break
      fi
      sleep 1
    done

    if [[ "$is_ready" != "true" ]]; then
      echo "live-verify: launch never became ready within ${timeout_s}s (launch: $launch)" >&2
      echo "live-verify: launch output tail:" >&2
      tail -n 20 "$log" >&2 || true
      jq -cn '{configured: true, ready: false, probes: [], allPass: false}'
      exit 1
    fi

    # Probes: run each, capture output, ledger it.
    probes_json="[]"
    all_pass=true
    while IFS= read -r probe; do
      [[ -n "$probe" ]] || continue
      p_out="$(bash -c "$probe" 2>&1)"; p_rc=$?
      p_pass=true; [[ "$p_rc" -eq 0 ]] || { p_pass=false; all_pass=false; }
      evid="null"
      if [[ -n "$EVIDENCE" ]]; then
        e_id="$(bash "$SCRIPT_DIR/evidence.sh" add "$EVIDENCE" \
                "live probe $([[ "$p_pass" == "true" ]] && echo passed || echo FAILED) (exit $p_rc)" \
                "$probe" "$p_out" 2>/dev/null)" || e_id=""
        [[ -n "$e_id" ]] && evid="\"$e_id\""
      fi
      probes_json="$(jq -c --arg cmd "$probe" --argjson pass "$p_pass" --argjson evid "$evid" \
        '. + [{cmd: $cmd, pass: $pass, evid: $evid}]' <<<"$probes_json")"
    done < <(jq -r '.probes[]' <<<"$cfg")

    jq -cn --argjson probes "$probes_json" --argjson allPass "$all_pass" \
      '{configured: true, ready: true, probes: $probes, allPass: $allPass}'
    [[ "$all_pass" == "true" ]] && exit 0 || exit 1
    ;;

  *)
    _die2 "unknown subcommand '${cmd:-}' (config|detect|run)"
    ;;
esac
