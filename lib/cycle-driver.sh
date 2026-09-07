#!/usr/bin/env bash
# cycle-driver.sh - The cycle's mechanical loop, in one script with one-line answers.
#
# Why: the orchestration between phases (preflight, invocation parsing, feature init,
# resume adoption, watchdog, journaling, state commits, checkpoint PRs, graph stepping,
# model-map activation, completion, escalation) was two thousand lines of prose with
# embedded shell that the lead model re-executed by hand at every boundary. Every
# harness lost time there, and some lost the thread. This script IS that loop. The
# skill keeps only what needs a harness tool or a human: AskUserQuestion answers,
# EnterWorktree/ExitWorktree, Agent dispatch, and Skill(loop-spec:<phase>).
#
# Usage:
#   cycle-driver.sh start [--dir DIR] -- <invocation arguments...>
#       Preflight + parse + profile + command detection. Prints one JSON object:
#       {invocation, profile, classification, harness, teams, workflows, workspace,
#        commands, resume:{candidates,cleanup}, decisions:[...], notices:[...],
#        warnings:[...]}
#       decisions[] are the questions the caller must still answer (empty when
#       autonomous or non-interactive answered them): {id, question, options, default}.
#       ids: greenfield | resume | repos | title | commands.
#       Exit 0 answer; 2 bad invocation/env; 3 abort (message on stderr).
#
#   cycle-driver.sh init --dir DIR --slug S --title T --style ST --profile P
#       [--classification JSON] [--autonomous 0|1] [--greenfield 0|1]
#       [--spec-file PATH] [--commands JSON] [--repos JSON] [--phase-mode fresh|continuous]
#       [--backlog-entry JSON]
#       New feature: adopt-PR probe, clean guard, base, execution root, bootstrap.
#       Prints {featureDir, slug, executionRoot, enterWorktree, branch, baseBranch,
#       baseSha, greenfield}. `enterWorktree` non-null means the caller must call
#       EnterWorktree({path}) before anything else. Exit 0/1/2.
#
#   cycle-driver.sh resume --dir DIR --feature-root PATH [--slug SLUG] [--phase-mode fresh|continuous]
#       Adopt a resumable feature's execution root. Prints {featureDir, slug,
#       currentPhase, enterWorktree, tasksDone, tasksRemaining, progressTail,
#       recoverCompletion}. Exit 0; 1 refused (message says where to relaunch).
#
#   cycle-driver.sh begin [--dir DIR] -- <invocation arguments...>
#       start, then init or resume when no human decision is pending. Prints start's
#       object plus {action: "init"|"resume"|"decisions", ...the init or resume object}.
#       action=decisions means the caller answers .decisions[] and calls init or resume
#       itself, as before. Exit codes as start, init, and resume.
#
#   cycle-driver.sh phase-begin <phase> --feature-dir DIR
#       The phase's whole ingress in one call: {entry:{fields,read,flags}, mode:{...},
#       execute:{...}|verify:{...}}. The execute and verify blocks are
#       lib/execute-prepare.sh and lib/verify-prepare.sh. Exit 1 when the entry packet
#       FLAGs a missing ingress (the flags are in the JSON); 2 bad invocation.
#
#   cycle-driver.sh task dispatch|package|verdict|integrate --feature-dir DIR --task ID ...
#       One EXECUTE task step per call; lib/execute-step.sh owns the contract.
#
#   cycle-driver.sh verify gate|passes --feature-dir DIR ...
#       VERIFY's verdict application (lib/verify-gate.sh) and advisory passes
#       (lib/verify-passes.sh).
#
#   cycle-driver.sh iterate limit|record|harvest --feature-dir DIR ...
#       ITERATE's bookkeeping around the judge (lib/iterate-judged.sh).
#
#   cycle-driver.sh deliver --feature-dir DIR
#       The whole DELIVER phase: lib/deliver.sh run, then the terminal PR feedback check
#       per target with a PR. Prints {rc, status, nextPhase, route, targets, feedback}.
#       route: completed | execute | deliver | deferral (exit 3: restore the dropped scope,
#       then call again). Exit 0 completed; 1 otherwise (the route says what to do).
#
#   cycle-driver.sh next --feature-dir DIR [--returned-from PHASE] [--note TEXT]
#       Runs phase-exit for the returned phase first: a FLAG answers
#         REDO phase=<id> flags=<n> attempt=<k>   followed by the FLAG lines; fix and call again
#       The same flags LOOP_SPEC_REDO_MAX (3) times escalate the run with them as the reason.
#       then post-phase bookkeeping and the graph step. Prints exactly ONE answer line:
#         NEXT phase=<id> label="<label>" effort=<system1|system2>
#         PAUSED node=<id>            (human gate; re-invoke the cycle to continue)
#         HANDOFF next=<phase> model=<selector>   (phaseHandoff; relaunch)
#         REWIND next=<phase>         (LOOP_SPEC_ITERATE_FRESH; relaunch)
#         DONE status=<completed|escalated|paused> [reason=<r>]
#       followed by zero or more `EXT <instruction or fact=path>` lines for NEXT.
#       Exit 0 answered; 1 graph abort or failure.
#
#   cycle-driver.sh finish --feature-dir DIR [--completed N]
#       Terminal result + chain verdict. Prints {status, prUrl, targets, warnings,
#       feedback, chain, backlogCount, exitWorktree}. Exit 0; 1 delivery incomplete.
#
#   cycle-driver.sh escalate --feature-dir DIR --reason TEXT
#       Clear team state, write the escalated result, checkpoint PR. Prints
#       {gateHistory, artifacts, delivery, exitWorktree}. Exit 0.
#
# Every subcommand is idempotent on its inputs; reading state twice is free, writing
# it twice is the same write. harness-neutral: branches only via lib/harness.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GRAPH="$REPO_ROOT/graph/cycle.graph.json"

usage() { sed -n '2,60p' "$0" | grep -E '^#( |$)' | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "cycle-driver: $*" >&2; exit "${_rc:-1}"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
lib() { bash "$SCRIPT_DIR/$1.sh" "${@:2}"; }
fset() { lib feature-write set "$1" "$2" "$3"; }
fget() { jq -r "$2" "$1/feature.json"; }

# merge_invocation_stamp DIR INV_JSON: the UserPromptSubmit hook stamps the raw
# /loop-spec:<skill> arguments before the skill rewrites its prose; a token the rewrite
# dropped is taken from the stamp. Consumed on read, and ignored past
# LOOP_SPEC_STAMP_MAX_AGE_MIN (30), so a stale stamp never binds a later run.
merge_invocation_stamp() {
  local dir="$1" inv="$2" stamp="$1/.loop-spec/invocation-stamp.json" stamped ts now
  [[ -f "$stamp" ]] || { printf '%s\n' "$inv"; return 0; }
  ts="$(jq -r '.ts // 0' "$stamp" 2>/dev/null || echo 0)"; now="$(date +%s)"
  if (( now - ts > ${LOOP_SPEC_STAMP_MAX_AGE_MIN:-30} * 60 )); then
    rm -f "$stamp"; printf '%s\n' "$inv"; return 0
  fi
  stamped="$(lib parse-invocation parse -- $(jq -r '.args // ""' "$stamp"))" || stamped=""
  rm -f "$stamp"
  [[ -n "$stamped" ]] || { printf '%s\n' "$inv"; return 0; }
  jq -c --argjson s "$stamped" '
    .autonomous = (.autonomous or $s.autonomous)
    | .greenfield = (.greenfield or $s.greenfield)
    | .style = (if (.style // "") == "" then $s.style else .style end)
    | .phase_mode = (if (.phase_mode // "") == "" then $s.phase_mode else .phase_mode end)
    | .profile = (if (.profile // "") == "" then $s.profile else .profile end)' <<<"$inv"
}

# ------------------------------------------------------------------ start ----
cmd_start() {
  local dir="$PWD" args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) dir="$2"; shift 2 ;;
      --) shift; args=("$@"); break ;;
      *) args+=("$1"); shift ;;
    esac
  done
  dir="$(cd "$dir" && pwd -P)"
  cd "$dir"
  # .loop-spec/profile.json is the run's policy (docs/loop-spec/supervisor-interface.md).
  # Preflight evaluates it in its own process, which this one never saw: a supervised
  # preset that named autonomous still started an interactive run (eval finding 3).
  local profile_exports
  if profile_exports="$(lib profile env)"; then eval "$profile_exports"
  else echo "cycle-driver: profile.json is invalid; running without it" >&2; fi

  if [[ -n "${LOOP_SPEC_MAX_PARALLEL_SUBAGENTS:-}" \
        && ! "$LOOP_SPEC_MAX_PARALLEL_SUBAGENTS" =~ ^[1-9][0-9]*$ ]]; then
    _rc=2 die "LOOP_SPEC_MAX_PARALLEL_SUBAGENTS must be a positive integer."
  fi

  # Every LOOP_SPEC_PHASE_MODEL_* / LOOP_SPEC_MODEL_* value is validated here; a bad
  # selector would fail at phase activation anyway, and later is worse.
  lib feature-init validate \
    || _rc=2 die "model routing is misconfigured; startup cannot resolve the selector set."

  local pf inv
  pf="$(lib cycle-preflight run "$dir")"
  inv="$(lib parse-invocation parse -- ${args[@]+"${args[@]}"})"
  inv="$(merge_invocation_stamp "$dir" "$inv")"

  local autonomous=0 non_interactive=0
  [[ "$(jq -r '.autonomous' <<<"$inv")" == "true" || "${LOOP_SPEC_AUTONOMOUS:-}" == "1" ]] && autonomous=1
  [[ "${LOOP_SPEC_NON_INTERACTIVE:-}" == "1" || "$autonomous" == "1" ]] && non_interactive=1

  # Execution profile: resolved once, carried for the whole cycle.
  local inv_profile class_json="" profile_line
  inv_profile="$(jq -r '.profile // empty' <<<"$inv")"
  [[ -f .loop-spec/active-run.json ]] \
    && class_json="$(jq -c '.classification // empty' .loop-spec/active-run.json 2>/dev/null || true)"
  if [[ -n "$inv_profile" ]]; then
    profile_line="$(printf '%s' "${class_json:-}" | LOOP_SPEC_CYCLE_PROFILE="$inv_profile" lib cycle-profile select -)"
  else
    profile_line="$(printf '%s' "${class_json:-}" | LOOP_SPEC_CYCLE_PROFILE="${LOOP_SPEC_CYCLE_PROFILE:-auto}" lib cycle-profile select -)"
  fi
  local profile="${profile_line#profile=}"; profile="${profile%% *}"

  local mode style title spec_path slug
  mode="$(jq -r '.mode' <<<"$inv")"
  style="$(jq -r '.style // "auto"' <<<"$inv")"
  [[ "$autonomous" == "1" ]] && style=auto
  title="$(jq -r '.title // ""' <<<"$inv")"
  spec_path="$(jq -r '.spec_path // ""' <<<"$inv")"

  # Non-interactive answers come from the environment and are validated here. The
  # inline `autonomous` token counts: a live run set LOOP_SPEC_ANSWER_TITLE to escape
  # an overlong prose slug and the driver ignored it because only the env var was read.
  if [[ "$non_interactive" == "1" ]]; then
    style="${LOOP_SPEC_ANSWER_STYLE:-$style}"
    case "$style" in auto|step|interactive|review-only) ;;
      *) _rc=2 die "LOOP_SPEC_ANSWER_STYLE must be auto, step, interactive, or review-only" ;;
    esac
    if [[ -n "${LOOP_SPEC_SPEC_FILE:-}" ]]; then
      [[ -r "$LOOP_SPEC_SPEC_FILE" && "$LOOP_SPEC_SPEC_FILE" == *.md ]] \
        || _rc=2 die "LOOP_SPEC_SPEC_FILE must name a readable .md file"
      spec_path="$(cd "$(dirname "$LOOP_SPEC_SPEC_FILE")" && pwd -P)/$(basename "$LOOP_SPEC_SPEC_FILE")"
      mode=spec-file
    fi
    [[ -n "${LOOP_SPEC_ANSWER_TITLE:-}" ]] && { title="$LOOP_SPEC_ANSWER_TITLE"; [[ "$mode" == bare ]] && mode=description; }
    [[ "$autonomous" == "1" ]] && style=auto
  fi
  if [[ "$mode" == "spec-file" && -z "$title" ]]; then
    title="$(grep -m1 '^# ' "$spec_path" | sed 's/^# //')"
    [[ -n "$title" ]] || title="$(basename "${spec_path%.md}")"
  fi
  if [[ "$mode" == "backlog" ]]; then
    local entry_json
    entry_json="$(lib backlog next --json)" || { echo "backlog empty — nothing to drain" >&2; exit 3; }
    title="$(jq -r '.text' <<<"$entry_json")"
    inv="$(jq --argjson e "$entry_json" '.backlogEntry = $e' <<<"$inv")"
  fi
  [[ -n "$title" ]] && slug="$(lib git-ops slugify "$title")" || slug=""

  local decisions='[]' notices='[]' warnings
  warnings="$(jq -c '.warnings // []' <<<"$pf")"
  # Preflight runs before the invocation tokens are parsed, so its headless warning
  # cannot see the inline `autonomous` token; every documented `claude -p
  # "/loop-spec:cycle autonomous ..."` run printed it. Drop it here where both are known.
  [[ "$autonomous" == "1" ]] && warnings="$(jq -c '[.[] | select(startswith("headless invocation") | not)]' <<<"$warnings")"
  add_decision() { decisions="$(jq -c --argjson d "$1" '. + [$d]' <<<"$decisions")"; }
  add_notice() { notices="$(jq -c --arg n "$1" '. + [$n]' <<<"$notices")"; }
  record() { lib decisions add .loop-spec/decisions-staging cycle "$1" "$2" "$3" >/dev/null; }

  add_notice "loop-spec: $profile_line"
  [[ "$(jq -r '.legacy | length' <<<"$inv")" != "0" ]] \
    && add_notice "loop-spec: ignored legacy token(s) $(jq -r '.legacy | join(", ")' <<<"$inv") (single-tier operation)."

  # -- workspace / greenfield --------------------------------------------------
  local ws_mode ws_root repos
  ws_mode="$(jq -r '.workspace.mode' <<<"$pf")"
  ws_root="$(jq -r '.workspace.root' <<<"$pf")"
  repos="$(jq -c '.workspace.repos // []' <<<"$pf")"
  local greenfield=0
  if [[ "$ws_mode" == "none" ]]; then
    if [[ "$(jq -r '.greenfield' <<<"$inv")" == "true" ]] || { [[ "$autonomous" == "1" && -n "$title" ]]; }; then
      greenfield=1
      [[ "$autonomous" == "1" ]] && record "Not a git repo: bootstrap a net-new application here?" "yes" "autonomous run with a feature description"
    elif [[ "$non_interactive" == "0" && -n "$title" ]]; then
      add_decision '{"id":"greenfield","question":"Not a git repo. Start a net-new application here (git init), or abort?","options":["Start new project here","Abort"],"default":"Start new project here"}'
    else
      echo "loop-spec: not a git repo and no child repos found. cd into a repo, create .loop-spec/workspace.json, or start a net-new app with /loop-spec:cycle new <description>." >&2
      exit 3
    fi
  elif [[ "$(jq -r '.greenfield' <<<"$inv")" == "true" ]]; then
    lib greenfield-bootstrap bootstrap "$dir" >/dev/null 2>&1 || true   # prints the refusal for its exit code
    _rc=3 die "already a git repo — greenfield is for empty directories. Run the normal cycle, or cd into an empty directory for a new app."
  fi
  if [[ "$ws_mode" == "workspace" ]]; then
    add_notice "workspace mode: $(jq -r 'length' <<<"$repos") repos ($(jq -r 'map(.name) | join(", ")' <<<"$repos")); state rooted at $ws_root"
    if [[ "${LOOP_SPEC_NON_INTERACTIVE:-}" == "1" && -n "${LOOP_SPEC_ANSWER_REPOS:-}" ]]; then
      local picked='[]' name
      for name in $(tr ',' ' ' <<<"$LOOP_SPEC_ANSWER_REPOS"); do
        jq -e --arg n "$name" 'map(.name) | index($n) != null' <<<"$repos" >/dev/null \
          || _rc=2 die "LOOP_SPEC_ANSWER_REPOS names unknown repo '$name'"
        picked="$(jq -c --arg n "$name" '. + [$n]' <<<"$picked")"
      done
      repos="$(jq -c --argjson p "$picked" 'map(select(.name as $n | $p | index($n) != null))' <<<"$repos")"
      [[ "$(jq 'length' <<<"$repos")" != "0" ]] || _rc=2 die "LOOP_SPEC_ANSWER_REPOS selected no repos"
    elif [[ "$autonomous" == "1" ]]; then
      record "Which workspace repos participate?" "all discovered" "autonomous run takes every discovered repo"
    elif [[ "$non_interactive" == "0" ]]; then
      add_decision "$(jq -cn --argjson r "$repos" '{id:"repos",question:("Workspace repos: " + ($r | map(.name + " (" + .path + ")") | join(", ")) + ". A feat/{slug} branch is created in place in each participating repo. All repos, or customize?"),options:["All repos","Customize"],default:"All repos"}')"
    fi
  fi

  # -- resume ------------------------------------------------------------------
  local candidates cleanup='[]' teams_mode
  teams_mode="$(jq -r '.teams.mode' <<<"$pf")"
  candidates="$(jq -c '.resume.candidates // []' <<<"$pf")"
  if [[ "$teams_mode" != "explicit" ]]; then
    # No cross-session team can survive here: clear stale references and resume.
    local c
    while IFS= read -r c; do
      [[ -n "$c" ]] || continue
      local fr; fr="$(jq -r '.featureRoot' <<<"$c")"
      local sl; sl="$(jq -r '.slug' <<<"$c")"
      [[ -f "$fr/.loop-spec/features/$sl/feature.json" ]] || continue
      fset "$fr/.loop-spec/features/$sl" currentTeamName null >/dev/null
      add_notice "feature $sl had stale team reference $(jq -r '.currentTeamName' <<<"$c"); cleared and ready to resume"
    done < <(jq -c '.[] | select(.needs_probe == true)' <<<"$candidates")
    candidates="$(jq -c 'map(.needs_probe = false | .currentTeamName = null)' <<<"$candidates")"
  else
    cleanup="$(jq -c 'map(select(.needs_probe == true))' <<<"$candidates")"
    candidates="$(jq -c 'map(select(.needs_probe != true))' <<<"$candidates")"
  fi
  local resume_pick=""
  if [[ "$(jq 'length' <<<"$candidates")" != "0" ]]; then
    if [[ "$autonomous" == "1" ]]; then
      if [[ -n "$slug" ]] && jq -e --arg s "$slug" 'map(.slug) | index($s) != null' <<<"$candidates" >/dev/null; then
        resume_pick="$slug"
      elif [[ -z "$title" || "$(jq 'length' <<<"$candidates")" == "1" ]]; then
        # Re-issuing the same command after an interrupted round is the documented
        # headless loop; with one candidate, starting a second feature beside it is
        # never what that loop meant.
        resume_pick="$(jq -r '.[0].slug' <<<"$candidates")"
      fi
      [[ -n "$resume_pick" ]] && record "Resume $resume_pick or start new?" "resume $resume_pick" "autonomous: most recent resumable feature"
    elif [[ "$non_interactive" == "0" ]]; then
      add_decision "$(jq -cn --argjson c "$candidates" '{id:"resume",question:"Resume an in-progress feature, or start a new one?",options:(($c | map("Resume " + .slug + " - phase " + .currentPhase + " (updated " + .updatedAt + ")")) + ["New feature"]),default:"New feature"}')"
    fi
  fi

  # -- title (bare) ----------------------------------------------------------
  if [[ -z "$title" && -z "$resume_pick" && "$mode" == "bare" ]]; then
    if [[ "$autonomous" == "1" ]]; then
      echo "loop-spec: autonomous invocations must carry a feature description, a spec file path, or 'backlog'." >&2; exit 3
    elif [[ "$non_interactive" == "1" ]]; then
      _rc=2 die "LOOP_SPEC_ANSWER_TITLE is required when LOOP_SPEC_SPEC_FILE is unset"
    else
      add_decision '{"id":"title","question":"What should this cycle build? (free text)","options":[],"default":""}'
    fi
  fi

  # -- commands ------------------------------------------------------------------
  local commands='{"prepare":"","test":"","lint":"","typecheck":""}'
  if [[ "$greenfield" == "0" && "$ws_mode" == "single" ]]; then
    commands="$(detect_commands "$ws_root")"
  elif [[ "$ws_mode" == "workspace" ]]; then
    local out='[]' r
    while IFS= read -r r; do
      [[ -n "$r" ]] || continue
      local rc_json; rc_json="$(detect_commands "$ws_root/$(jq -r '.path' <<<"$r")")"
      out="$(jq -c --argjson e "$(jq -c --argjson c "$rc_json" '.commands = $c' <<<"$r")" '. + [$e]' <<<"$out")"
    done < <(jq -c '.[]' <<<"$repos")
    repos="$out"
  fi
  if [[ "$greenfield" == "0" && "$non_interactive" == "0" && -z "$resume_pick" ]]; then
    local shown
    if [[ "$ws_mode" == "workspace" ]]; then
      shown="$(jq -r 'map(.name + ": test=" + .commands.test + " lint=" + .commands.lint + " typecheck=" + .commands.typecheck) | join("; ")' <<<"$repos")"
    else
      shown="$(jq -r '"prepare=" + .prepare + " test=" + .test + " lint=" + .lint + " typecheck=" + .typecheck' <<<"$commands")"
    fi
    add_decision "$(jq -cn --arg s "$shown" '{id:"commands",question:("Detected commands: " + $s + ". Use these?"),options:["Yes","Customize"],default:"Yes"}')"
  elif [[ "$autonomous" == "1" && "$greenfield" == "0" ]]; then
    record "Use detected project commands?" "yes" "autonomous run trusts detection; LOOP_SPEC_CMD_* still wins"
  fi

  # -- teams notice ------------------------------------------------------------
  case "$teams_mode" in
    none) add_notice "loop-spec: agent teams off; continuing with one-shot subagents (loop-fleet when the harness CLI is on PATH)." ;;
    implicit) add_notice "loop-spec: agent teams on (implicit team; teammates spawn via Agent({name}))." ;;
    explicit) add_notice "loop-spec: agent teams on (explicit team; per-phase TeamCreate/TeamDelete)." ;;
  esac
  # Persist the probe answers the phase skills read.
  mkdir -p .loop-spec
  jq -n --argjson prior "$(cat .loop-spec/runtime.json 2>/dev/null || echo '{}')" \
    --arg h "$(jq -r '.harness.name' <<<"$pf")" --arg tm "$teams_mode" \
    --argjson wf "$(jq '.workflows.available' <<<"$pf")" \
    --argjson optin "$([[ "${LOOP_SPEC_EXECUTE_WORKFLOW:-}" == "1" ]] && echo true || echo false)" \
    --arg wsm "$ws_mode" --arg wsr "$ws_root" --argjson wsrepos "$repos" \
    '$prior + {harness:$h, teamsMode:$tm, teamsAvailable:($tm != "none"), workflowsAvailable:$wf,
      workflowExecuteOptIn:$optin, workspaceMode:$wsm, workspaceRoot:$wsr, workspaceRepos:$wsrepos}' \
    > .loop-spec/runtime.json.tmp && mv .loop-spec/runtime.json.tmp .loop-spec/runtime.json
  [[ "$(jq -r '.harness.name' <<<"$pf")" == "claude" ]] \
    && bash "$REPO_ROOT/hooks/pre-cycle-permission-check.sh" >&2 || true

  jq -n --argjson inv "$inv" --arg profile "$profile" --argjson class "${class_json:-null}" \
    --argjson pf "$pf" --arg mode "$mode" --arg style "$style" --arg title "$title" --arg slug "$slug" \
    --arg spec "$spec_path" --argjson auto "$autonomous" --argjson gf "$greenfield" \
    --arg wsm "$ws_mode" --arg wsr "$ws_root" --argjson repos "$repos" --argjson commands "$commands" \
    --argjson cands "$candidates" --argjson cleanup "$cleanup" --arg pick "$resume_pick" \
    --argjson decisions "$decisions" --argjson notices "$notices" --argjson warnings "$warnings" \
    '{invocation: ($inv + {mode:$mode, style:$style, title:$title, slug:$slug, spec_path:$spec}),
      profile:$profile, classification:$class, autonomous:($auto == 1), greenfield:($gf == 1),
      harness:$pf.harness.name, teams:$pf.teams, workflows:$pf.workflows,
      workspace:{mode:$wsm, root:$wsr, repos:$repos}, commands:$commands,
      resume:{candidates:$cands, cleanup:$cleanup, autoPick:($pick | select(. != "") // null)},
      decisions:$decisions, notices:$notices, warnings:$warnings}'
}

# detect_commands DIR -> {prepare,test,lint,typecheck} after env overrides.
detect_commands() {
  local root="$1" prepare test lint="" typecheck=""
  prepare="$(lib prepare-environment resolve --root "$root" 2>/dev/null | jq -r '.command // ""' || true)"
  test="$(lib detect-test-cmd "$root" 2>/dev/null || true)"
  local bin="$root/node_modules/.bin"
  if [[ -f "$root/package.json" ]]; then
    if [[ -x "$bin/eslint" ]]; then lint="node_modules/.bin/eslint ."
    elif jq -e '.scripts.lint' "$root/package.json" >/dev/null 2>&1; then lint="npm run lint"; fi
    if [[ -x "$bin/tsc" && -f "$root/tsconfig.json" ]]; then typecheck="node_modules/.bin/tsc --noEmit"
    elif jq -e '.scripts.typecheck' "$root/package.json" >/dev/null 2>&1; then typecheck="npm run typecheck"; fi
  fi
  if [[ -z "$lint" ]]; then
    if [[ -f "$root/ruff.toml" ]] || grep -qs '\[tool.ruff' "$root/pyproject.toml" 2>/dev/null; then lint="ruff check ."
    elif grep -qsE '^lint:' "$root/Makefile" 2>/dev/null; then lint="make lint"; fi
  fi
  if [[ -z "$typecheck" ]]; then
    if [[ -f "$root/mypy.ini" ]] || grep -qs '\[tool.mypy' "$root/pyproject.toml" 2>/dev/null; then typecheck="mypy ."; fi
  fi
  lib project-commands resolve --prepare "$prepare" --test "$test" --lint "$lint" --typecheck "$typecheck"
}

# ------------------------------------------------------------------- init ----
cmd_init() {
  local dir="$PWD" slug="" title="" style=auto profile=standard class_json=null autonomous=0 greenfield=0
  local spec_file="" commands='{"prepare":"","test":"","lint":"","typecheck":""}' repos='[]' phase_mode="" backlog_entry=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) dir="$2" ;; --slug) slug="$2" ;; --title) title="$2" ;; --style) style="$2" ;;
      --profile) profile="$2" ;; --classification) class_json="$2" ;; --autonomous) autonomous="$2" ;;
      --greenfield) greenfield="$2" ;; --spec-file) spec_file="$2" ;; --commands) commands="$2" ;;
      --repos) repos="$2" ;; --phase-mode) phase_mode="$2" ;; --backlog-entry) backlog_entry="$2" ;;
      *) usage ;;
    esac
    shift 2
  done
  [[ -n "$slug" && -n "$title" ]] || usage
  dir="$(cd "$dir" && pwd -P)"; cd "$dir"
  [[ -z "$spec_file" || -r "$spec_file" ]] || _rc=2 die "spec file not readable: $spec_file"
  [[ -z "$class_json" ]] && class_json=null

  if [[ "$greenfield" == "1" ]]; then
    lib greenfield-bootstrap bootstrap "$dir" >/dev/null || die "greenfield bootstrap refused (see above)"
  fi
  local ws_json ws_mode ws_root harness
  ws_json="$(lib workspace detect "$dir")"
  ws_mode="$(jq -r '.mode' <<<"$ws_json")"; ws_root="$(jq -r '.root' <<<"$ws_json")"
  harness="$(lib harness detect)"
  local active_autonomous=false; [[ "$autonomous" == "1" ]] && active_autonomous=true
  local resolved_commands; resolved_commands="$(lib project-commands resolve \
    --prepare "$(jq -r '.prepare // ""' <<<"$commands")" --test "$(jq -r '.test // ""' <<<"$commands")" \
    --lint "$(jq -r '.lint // ""' <<<"$commands")" --typecheck "$(jq -r '.typecheck // ""' <<<"$commands")")"

  if [[ "$ws_mode" == "workspace" ]]; then
    init_workspace "$ws_root" "$slug" "$title" "$style" "$profile" "$class_json" "$autonomous" "$greenfield" "$spec_file" "$repos" "$phase_mode"
    persist_backlog_entry "$ws_root/.loop-spec/features/$slug" "$backlog_entry"
    return
  fi

  local repo_root="$ws_root" feature_branch="feat/$slug" adopted=false base_branch adopt_json
  adopt_json="$(lib adopt-pr resolve --repo "$repo_root" --request "$title")"
  if jq -e '.adopt == true' <<<"$adopt_json" >/dev/null 2>&1; then
    adopted=true
    feature_branch="$(jq -r '.branch' <<<"$adopt_json")"
    base_branch="$(jq -r '.baseBranch' <<<"$adopt_json")"
    echo "loop-spec: adopting PR $(jq -r '.number' <<<"$adopt_json") on $feature_branch (base $base_branch)." >&2
  else
    base_branch="$(lib git-ops -C "$repo_root" detect-base-branch)"
  fi
  lib runtime-ignore ensure "$repo_root" >/dev/null
  local current_branch; current_branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
  if ! { [[ "$adopted" == true && "$current_branch" == "$feature_branch" ]]; }; then
    [[ "$(lib git-ops -C "$repo_root" ensure-clean-or-stash)" == "clean" ]] \
      || die "source checkout is dirty; commit or stash changes before starting autonomous delivery: $(git -C "$repo_root" status --porcelain --untracked-files=all | head -5 | tr '\n' ' ')"
  fi
  local base_ref="$base_branch"
  if git -C "$repo_root" remote get-url origin >/dev/null 2>&1; then
    git -C "$repo_root" fetch --quiet origin "$base_branch" || die "failed to fetch origin/$base_branch; refusing a stale PR base."
    base_ref="origin/$base_branch"
    [[ "$adopted" == true ]] && git -C "$repo_root" fetch --quiet origin "$feature_branch" || true
  fi
  local base_sha
  if [[ "$adopted" == true ]]; then
    local pr_head
    pr_head="$(git -C "$repo_root" rev-parse --verify "refs/heads/${feature_branch}^{commit}" 2>/dev/null \
      || git -C "$repo_root" rev-parse --verify "refs/remotes/origin/${feature_branch}^{commit}")" \
      || die "cannot resolve adopted PR branch '$feature_branch'."
    base_sha="$(git -C "$repo_root" merge-base "$pr_head" "$base_ref")" \
      || die "adopted PR branch '$feature_branch' does not share history with '$base_ref'."
  else
    base_sha="$(git -C "$repo_root" rev-parse --verify "${base_ref}^{commit}")" || die "cannot resolve base branch '$base_ref'."
  fi
  lib cycle-result begin --result-root "$repo_root" --cycle-type full --title "$title" --slug "$slug" \
    --branch "$feature_branch" --base-branch "$base_branch" --phase startup --autonomous "$active_autonomous"

  # Execution root: Claude enters a worktree; the other harnesses work in place.
  local worktrees="${LOOP_SPEC_WORKTREES:-1}" worktree_abs="" exec_root="$repo_root"
  case "$worktrees" in 0|1) ;; *) _rc=2 die "LOOP_SPEC_WORKTREES must be 0 or 1." ;; esac
  if [[ "$worktrees" == "1" && -f "$repo_root/.git" ]]; then
    # A gitfile means a submodule or a linked worktree. git adds a worktree there, but
    # Claude Code's EnterWorktree then refuses it as "not a linked worktree of <repo>",
    # so the run spent four turns tearing it down. Work in place instead.
    worktrees=0
    echo "loop-spec: $repo_root/.git is a file (submodule or linked worktree); working in place on the feature branch (LOOP_SPEC_WORKTREES=0)." >&2
  fi
  if [[ "$harness" == "claude" && "$worktrees" == "1" ]]; then
    if [[ "$adopted" == true ]]; then
      worktree_abs="$(lib git-ops -C "$repo_root" attach-feature-worktree "$slug" "$feature_branch")" \
        || die "could not attach a worktree to $feature_branch (see the helper's diagnostic above)."
    else
      worktree_abs="$(lib git-ops -C "$repo_root" create-feature-worktree "$slug" "$base_sha")" \
        || die "could not create the feature worktree (see the helper's diagnostic above)."
    fi
    exec_root="$worktree_abs"
  elif [[ "$adopted" == true ]]; then
    git -C "$repo_root" checkout -q "$feature_branch" 2>/dev/null \
      || git -C "$repo_root" checkout -q -b "$feature_branch" --track "origin/$feature_branch"
  else
    git -C "$repo_root" checkout -q -b "$feature_branch" "$base_sha"
  fi

  local cmd_test
  cmd_test="$(cd "$exec_root" && lib feature-bootstrap finalize \
    --repo-root "$repo_root" --execution-root "$exec_root" --slug "$slug" --title "$title" \
    --branch "$feature_branch" --base-branch "$base_branch" --base-sha "$base_sha" \
    --worktree "$worktree_abs" --style "$style" --profile "$profile" --classification "$class_json" \
    --autonomous "$autonomous" --greenfield "$greenfield" \
    --prepare "$(jq -r '.prepare' <<<"$resolved_commands")" --test "$(jq -r '.test' <<<"$resolved_commands")" \
    --lint "$(jq -r '.lint' <<<"$resolved_commands")" --typecheck "$(jq -r '.typecheck' <<<"$resolved_commands")")" \
    || die "feature bootstrap failed; a terminal cycle result was written (see stderr above)."
  local feature_dir="$exec_root/.loop-spec/features/$slug"
  [[ -n "$spec_file" ]] && cp "$spec_file" "$feature_dir/spec-draft.md"
  persist_phase_mode "$feature_dir" "$phase_mode"
  persist_backlog_entry "$feature_dir" "$backlog_entry"
  jq -n --arg fd "$feature_dir" --arg slug "$slug" --arg er "$exec_root" --arg wt "$worktree_abs" \
    --arg br "$feature_branch" --arg bb "$base_branch" --arg bs "$base_sha" --argjson gf "$greenfield" --arg t "$cmd_test" \
    '{featureDir:$fd, slug:$slug, executionRoot:$er, enterWorktree:($wt | select(. != "") // null),
      branch:$br, baseBranch:$bb, baseSha:$bs, greenfield:($gf == 1), testCommand:$t}'
}

# Workspace mode: every repo is checked before any branch is created, then each
# repo gets an in-place feat/{slug} branch and its own prepare/baseline pass.
init_workspace() {
  local ws_root="$1" slug="$2" title="$3" style="$4" profile="$5" class_json="$6" autonomous="$7" greenfield="$8" spec_file="$9" repos="${10}" phase_mode="${11}"
  local r rname rpath dirty=() bases='[]'
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    rname="$(jq -r '.name' <<<"$r")"; rpath="$ws_root/$(jq -r '.path' <<<"$r")"
    lib runtime-ignore ensure "$rpath" >/dev/null
    [[ "$(lib git-ops -C "$rpath" ensure-clean-or-stash 2>/dev/null)" == "clean" ]] || dirty+=("$rname ($rpath)")
  done < <(jq -c '.[]' <<<"$repos")
  if [[ ${#dirty[@]} -gt 0 ]]; then
    echo "loop-spec: cannot create feature branches -- the following repos have uncommitted changes:" >&2
    printf '  %s\n' "${dirty[@]}" >&2
    die "commit or stash changes in each repo above, then re-invoke cycle."
  fi
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    rname="$(jq -r '.name' <<<"$r")"; rpath="$ws_root/$(jq -r '.path' <<<"$r")"
    local bb ref sha
    bb="$(lib git-ops -C "$rpath" detect-base-branch)"; ref="$bb"
    if git -C "$rpath" remote get-url origin >/dev/null 2>&1; then
      git -C "$rpath" fetch --quiet origin "$bb" || die "failed to fetch $rname origin/$bb; no feature branches were created."
      ref="origin/$bb"
    fi
    sha="$(git -C "$rpath" rev-parse --verify "${ref}^{commit}")" || die "cannot resolve $rname base '$ref'; no feature branches were created."
    git -C "$rpath" show-ref --verify --quiet "refs/heads/feat/$slug" && die "$rname already has branch feat/$slug; no feature branches were created."
    bases="$(jq -c --arg n "$rname" --arg bb "$bb" --arg sha "$sha" '. + [{name:$n, baseBranch:$bb, baseSha:$sha}]' <<<"$bases")"
  done < <(jq -c '.[]' <<<"$repos")

  local entries='[]'
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    rname="$(jq -r '.name' <<<"$r")"; rpath="$ws_root/$(jq -r '.path' <<<"$r")"
    local base; base="$(jq -c --arg n "$rname" '.[] | select(.name == $n)' <<<"$bases")"
    git -C "$rpath" checkout -q -b "feat/$slug" "$(jq -r '.baseSha' <<<"$base")"
    local cmds prep
    cmds="$(lib project-commands resolve \
      --prepare "$(jq -r '.commands.prepare // ""' <<<"$r")" --test "$(jq -r '.commands.test // ""' <<<"$r")" \
      --lint "$(jq -r '.commands.lint // ""' <<<"$r")" --typecheck "$(jq -r '.commands.typecheck // ""' <<<"$r")")"
    prep="$(lib feature-bootstrap prepare-repo --root "$rpath" --result-root "$ws_root" --slug "$slug" --title "$title" \
      --branch "feat/$slug" --base-branch "$(jq -r '.baseBranch' <<<"$base")" --base-sha "$(jq -r '.baseSha' <<<"$base")" \
      --prepare "$(jq -r '.prepare' <<<"$cmds")" --test "$(jq -r '.test' <<<"$cmds")" \
      --lint "$(jq -r '.lint' <<<"$cmds")" --typecheck "$(jq -r '.typecheck' <<<"$cmds")" \
      --autonomous "$autonomous" --greenfield "$greenfield" --repo-label "$rname")" \
      || die "feature bootstrap failed for $rname; a terminal cycle result was written (see stderr above)."
    entries="$(jq -c --argjson r "$r" --argjson b "$base" --argjson c "$cmds" --argjson p "$prep" --arg br "feat/$slug" \
      '. + [{name:$r.name, path:$r.path, branch:$br, baseSha:$b.baseSha, baseBranch:$b.baseBranch,
             commands:($c + {prepare:($p.command // $c.prepare), test:($p.test // $c.test)}),
             verificationBaseline:$p.baseline}]' <<<"$entries")"
  done < <(jq -c '.[]' <<<"$repos")

  local feature_dir="$ws_root/.loop-spec/features/$slug"
  mkdir -p "$feature_dir" "$ws_root/docs/loop-spec/features/$slug"
  [[ -n "$spec_file" ]] && cp "$spec_file" "$feature_dir/spec-draft.md"
  local fj gate_plan=null effective="$profile"
  fj="$(lib feature-init skeleton --mode workspace --slug "$slug" --now "$(now)" --style "$style" --title "$title" \
    --ws-root "$ws_root" --repos "$entries")"
  if [[ "$(printf '%s' "$class_json" | LOOP_SPEC_CYCLE_PROFILE=auto lib cycle-profile select -)" == profile=compact\ * ]]; then
    gate_plan="$(jq -c '.gatePlan' <<<"$class_json")"
  fi
  [[ "$effective" == "compact" && "$gate_plan" == "null" ]] && effective=standard
  fj="$(jq --argjson c "$class_json" --argjson g "$gate_plan" --arg p "$effective" --argjson a "$autonomous" --argjson gf "$greenfield" \
    '(if $c == null then . else .autonomousClassification = $c end)
     | (if $g == null then . else .gatePlan = $g end)
     | .executionProfile = $p | .autonomous = ($a == 1) | .greenfield = ($gf == 1)' <<<"$fj")"
  lib feature-write "$feature_dir" "$fj" >/dev/null
  lib decisions migrate "$ws_root/.loop-spec/decisions-staging" "$feature_dir" >/dev/null
  lib cycle-result begin --result-root "$ws_root" --cycle-type full --title "$title" --slug "$slug" \
    --feature-dir "$feature_dir" --phase startup --autonomous "$([[ "$autonomous" == 1 ]] && echo true || echo false)"
  persist_phase_mode "$feature_dir" "$phase_mode"
  jq -n --arg fd "$feature_dir" --arg slug "$slug" --arg er "$ws_root" --argjson gf "$greenfield" \
    '{featureDir:$fd, slug:$slug, executionRoot:$er, enterWorktree:null, branch:null, baseBranch:null, baseSha:null, greenfield:($gf == 1), workspace:true}'
}

# ITERATE's terminal rule matches backlogEntryId exactly to catch a gap spending its
# rounds twice; finish marks the entry done by its text.
persist_backlog_entry() {
  local feature_dir="$1" entry="$2"
  [[ -n "$entry" ]] || return 0
  fset "$feature_dir" backlogEntry "$(jq -c '.text' <<<"$entry")" >/dev/null
  fset "$feature_dir" backlogEntryId "$(jq -c '.id // null' <<<"$entry")" >/dev/null
}

# The inline token wins, then LOOP_SPEC_PHASE_HANDOFF, then the stored value.
persist_phase_mode() {
  local feature_dir="$1" phase_mode="$2" handoff
  handoff="$(fget "$feature_dir" '.phaseHandoff // false')"
  case "${LOOP_SPEC_PHASE_HANDOFF:-}" in
    "") ;; 0) handoff=false ;; 1) handoff=true ;;
    *) _rc=2 die "LOOP_SPEC_PHASE_HANDOFF must be 0 or 1." ;;
  esac
  case "$phase_mode" in fresh) handoff=true ;; continuous) handoff=false ;; esac
  fset "$feature_dir" phaseHandoff "$handoff" >/dev/null
}

# ----------------------------------------------------------------- resume ----
cmd_resume() {
  local dir="$PWD" feature_root="" phase_mode="" selected_slug=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) dir="$2" ;; --feature-root) feature_root="$2" ;; --phase-mode) phase_mode="$2" ;;
      --slug) selected_slug="$2" ;;
      *) usage ;;
    esac
    shift 2
  done
  [[ -n "$feature_root" ]] || usage
  dir="$(cd "$dir" && pwd -P)"; cd "$dir"
  feature_root="$(cd "$feature_root" && pwd -P)"
  local fj slug feature_dir enter="" harness
  if [[ -n "$selected_slug" ]]; then
    [[ "$selected_slug" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || die "invalid feature slug: $selected_slug"
    fj="$feature_root/.loop-spec/features/$selected_slug/feature.json"
    [[ -f "$fj" ]] || die "selected feature '$selected_slug' not found under $feature_root/.loop-spec/features/"
  else
    local candidates=() candidate
    for candidate in "$feature_root"/.loop-spec/features/*/feature.json; do
      [[ -f "$candidate" ]] && candidates+=("$candidate")
    done
    (( ${#candidates[@]} > 0 )) || die "no feature.json under $feature_root/.loop-spec/features/"
    (( ${#candidates[@]} == 1 )) || die "multiple features under $feature_root; pass --slug for the selected resume candidate"
    fj="${candidates[0]}"
  fi
  feature_dir="$(dirname "$fj")"; slug="$(fget "$feature_dir" '.slug')"
  [[ "$slug" == "$(basename "$feature_dir")" ]] || die "feature slug does not match its directory: $feature_dir"
  harness="$(lib harness detect)"

  if [[ "$(fget "$feature_dir" 'if (.workspace != null and (.workspace.mode // "") != "single") then .workspace else null end')" != "null" ]]; then
    [[ "$(fget "$feature_dir" '.workspace.root')" == "$dir" ]] \
      || die "this workspace feature must be resumed from its workspace root. cd to $(fget "$feature_dir" '.workspace.root') and re-invoke cycle."
  elif [[ "$(fget "$feature_dir" '.executionRootMode // "worktree"')" == "worktree" && "$harness" == "claude" ]]; then
    local wt branch base
    wt="$(fget "$feature_dir" '.worktreePath // ""')"; branch="$(fget "$feature_dir" '.branch')"; base="$(fget "$feature_dir" '.baseSha')"
    if [[ -n "$wt" ]]; then
      [[ "${LOOP_SPEC_WORKTREES:-1}" != "0" ]] \
        || die "the recorded feature requires a worktree, but LOOP_SPEC_WORKTREES=0 forbids creating or entering one. Resume once with worktrees enabled, or start a new in-place cycle from a clean checkout."
      if ! git worktree list --porcelain | grep -qx "worktree $wt"; then
        echo "loop-spec: worktree $wt is missing; recreating it from the recorded branch." >&2
        if git show-ref --verify --quiet "refs/heads/$branch"; then
          git worktree add "$wt" "$branch" >&2 || die "could not recreate worktree $wt"
        else
          wt="$(lib git-ops create-feature-worktree "$slug" "$base")" || die "could not recreate worktree for $slug"
        fi
      fi
      enter="$wt"; feature_dir="$wt/.loop-spec/features/$slug"
    fi
  else
    # In-place harnesses: the session root must already be the feature root.
    [[ "$feature_root" == "$dir" ]] || die "resume from the feature root: cd $feature_root and re-invoke cycle."
    [[ "$(git rev-parse --abbrev-ref HEAD)" == "$(fget "$feature_dir" '.branch')" ]] \
      || die "checkout $(fget "$feature_dir" '.branch') first; the feature branch must be checked out to resume in place."
  fi
  persist_phase_mode "$feature_dir" "$phase_mode"
  fset "$feature_dir" currentTeamName null >/dev/null

  local done_ids="" remaining_ids="" sidecar
  sidecar="$(fget "$feature_dir" '.artifacts.tasks // empty')"
  if [[ -n "$sidecar" && -f "$sidecar" ]]; then
    done_ids="$(lib task-progress done "$sidecar" | paste -sd, -)"
    remaining_ids="$(lib task-progress remaining "$sidecar" | paste -sd, -)"
  fi
  local recover=false
  if [[ -f "$feature_dir/delivery.json" ]] \
     && [[ "$(jq -r '.nextPhase // ""' "$feature_dir/delivery.json")" == "completed" ]] \
     && [[ "$(jq -r '.status // ""' "$feature_dir/delivery.json")" == "ready-for-review" ]]; then
    recover=true
  fi
  local started ceiling="${LOOP_SPEC_PHASE_TIMEOUT_MINS:-60}" watchdog=""
  started="$(fget "$feature_dir" '.currentPhaseStartedAt // ""')"
  if [[ -n "$started" ]] && (( $(date -u +%s) - $(iso_epoch "$started") > ceiling * 60 )); then
    watchdog="phase $(fget "$feature_dir" '.currentPhase') exceeded its ${ceiling}m ceiling in a prior session; resuming from last durable state"
  fi
  jq -n --arg fd "$feature_dir" --arg slug "$slug" --arg cp "$(fget "$feature_dir" '.currentPhase')" \
    --arg enter "$enter" --arg d "$done_ids" --arg r "$remaining_ids" \
    --arg tail "$(tail -n 12 "$feature_dir/PROGRESS.md" 2>/dev/null || true)" --argjson recover "$recover" --arg wd "$watchdog" \
    '{featureDir:$fd, slug:$slug, currentPhase:$cp, enterWorktree:($enter | select(. != "") // null),
      tasksDone:$d, tasksRemaining:$r, progressTail:$tail, recoverCompletion:$recover, watchdog:($wd | select(. != "") // null)}'
}

iso_epoch() {
  python3 -c "import sys,datetime;print(int(datetime.datetime.strptime(sys.argv[1],'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()))" "$1" 2>/dev/null || echo 0
}

# Workspace mode is the recorded mode, never the presence of a root: lib/workspace.sh
# detect reports {root, mode:"single", repos:[]} for an ordinary repository too, and a
# consumer that read the root as the mode skipped every artifact commit (eval finding 6).
# ------------------------------------------------------------------- next ----
cmd_next() {
  local feature_dir="" returned="" note=""
  while [[ $# -gt 0 ]]; do
    case "$1" in --feature-dir) feature_dir="$2" ;; --returned-from) returned="$2" ;; --note) note="$2" ;; *) usage ;; esac
    shift 2
  done
  [[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] || usage
  feature_dir="$(cd "$feature_dir" && pwd -P)"
  local slug ws_mode=single repo_root
  slug="$(fget "$feature_dir" '.slug')"
  [[ "$(fget "$feature_dir" 'if (.workspace != null and (.workspace.mode // "") != "single") then .workspace else null end')" != "null" ]] && ws_mode=workspace
  repo_root="$(lib cycle-result resolve-root "$feature_dir/../../..")"
  cd "$repo_root"

  if [[ -n "$returned" ]]; then
    local rc=0
    returned_checks "$feature_dir" "$returned" || rc=$?
    (( rc == 10 )) && return 0   # a terminal answer line was already printed
    (( rc == 0 )) || return "$rc"
    # The phase's exit gates run here, once, whatever the phase skill did: a lead that
    # skipped them or ran them from the wrong directory was every second eval finding.
    if [[ "$returned" != "deliver" && "$(fget "$feature_dir" '.completedPhases[-1] // ""')" != "$returned" ]]; then
      local exit_out exit_rc=0 terminal_flag=()
      [[ "$returned" == "iterate" ]] && iterate_is_terminal "$feature_dir" && terminal_flag=(--terminal)
      exit_out="$(lib phase-exit "$returned" --feature-dir "$feature_dir" ${terminal_flag[@]+"${terminal_flag[@]}"} 2>&1)" || exit_rc=$?
      if (( exit_rc == 1 )); then
        # The same flags three times is a gate the phase cannot satisfy, not a phase that
        # needs one more try: the 6.2.0 haiku runs looped six times on one flag and then
        # published an invented reason. Escalate with the flags as the reason instead.
        local redo_hash redo_count=1
        redo_hash="$(grep '^FLAG' <<<"$exit_out" | cksum | cut -d' ' -f1)"
        if [[ "$(fget "$feature_dir" '.driverRedo.phase // ""')" == "$returned" && "$(fget "$feature_dir" '.driverRedo.hash // ""')" == "$redo_hash" ]]; then
          redo_count=$(( $(fget "$feature_dir" '.driverRedo.count // 1') + 1 ))
        fi
        fset "$feature_dir" driverRedo "{\"phase\":\"$returned\",\"hash\":\"$redo_hash\",\"count\":$redo_count}" >/dev/null
        if (( redo_count >= ${LOOP_SPEC_REDO_MAX:-3} )); then
          local reason; reason="$returned exit gate unsatisfied after $redo_count attempts: $(grep '^FLAG' <<<"$exit_out" | head -3 | tr '\n' ' ')"
          cmd_escalate --feature-dir "$feature_dir" --reason "$reason" >/dev/null
          echo "DONE status=escalated reason=$reason"
          return 0
        fi
        echo "REDO phase=$returned flags=$(grep -c '^FLAG' <<<"$exit_out") attempt=$redo_count"
        grep '^FLAG' <<<"$exit_out"
        return 0
      elif (( exit_rc != 0 )); then
        echo "ABORT reason=phase-exit-failed exit=$exit_rc"; printf '%s\n' "$exit_out" >&2; return 1
      fi
    fi
  fi

  # Graph step: the engine dispatches gates/functions/subgraphs itself and stops at an
  # agent node, a human pause, an abort, or the terminal node.
  local step_json step_rc answer="" next=""
  local completion_args=()
  [[ -n "$returned" ]] && completion_args=(--completed-node "$returned")
  while :; do
    set +e
    step_json="$(lib graph/run --step ${completion_args[@]+"${completion_args[@]}"} --feature-dir "$feature_dir" "$GRAPH")"
    step_rc=$?
    set -e
    completion_args=()
    case "$step_rc" in
      0) ;;
      4) next="$(jq -r '.node' <<<"$step_json")"; answer="PAUSED node=$next"; break ;;
      5) echo "ABORT reason=graph-route-blocked (see stderr for route or retry-limit diagnostics)"; return 1 ;;
      *) echo "ABORT reason=graph-step-failed exit=$step_rc"; return 1 ;;
    esac
    next="$(jq -r '.node' <<<"$step_json")"
    [[ "$(jq -r '.terminal' <<<"$step_json")" == "true" ]] && { answer="DONE status=completed"; break; }
    [[ "$(jq -r '.kind' <<<"$step_json")" == "agent" ]] && break
  done

  if [[ -n "$returned" ]]; then
    local rc=0
    record_transition "$feature_dir" "$returned" "$next" "$note" "$ws_mode" || rc=$?
    (( rc == 10 )) && return 0
    (( rc == 0 )) || return "$rc"
  fi
  [[ -n "$answer" ]] && { echo "$answer"; return 0; }

  local label effort
  label="$(jq -r '.label' <<<"$step_json")"; effort="$(jq -r '.effort' <<<"$step_json")"
  lib feature-init activate "$feature_dir" "$next" >/dev/null
  if [[ "$(jq 'has("preset") or has("tier")' "$feature_dir/feature.json")" == "true" ]]; then
    lib feature-write "$feature_dir" "$(jq 'del(.preset) | del(.tier)' "$feature_dir/feature.json")" >/dev/null
  fi
  # feature_title is the immutable goal the ITERATE judge scores against; the slug is
  # the only stand-in on features that predate it.
  [[ "$(fget "$feature_dir" '.feature_title // ""')" == "" ]] && fset "$feature_dir" feature_title "\"$slug\"" >/dev/null
  [[ "$next" != "deliver" ]] && fset "$feature_dir" currentPhaseStartedAt "\"$(now)\"" >/dev/null
  lib cycle-result begin --result-root "$repo_root" --cycle-type full \
    --title "$(fget "$feature_dir" '.feature_title')" --slug "$slug" \
    --branch "$(fget "$feature_dir" '.branch // ""')" --base-branch "$(fget "$feature_dir" '.baseBranch // ""')" \
    --feature-dir "$feature_dir" --phase "$next" --autonomous "$(fget "$feature_dir" '.autonomous // false')" >/dev/null
  # cycle-result.sh reads this: a failure published over an answered NEXT must say why.
  fset "$feature_dir" driverNext "{\"phase\":\"$next\",\"at\":\"$(now)\"}" >/dev/null
  echo "NEXT phase=$next label=\"$label\" effort=$effort"
  lib extension-points instructions "$next" prepend 2>/dev/null | sed 's/^/EXT /' || true
  lib extension-points facts 2>/dev/null | sed 's/^/EXT /' || true
}

# returned_checks FEATURE_DIR PHASE: what a returned phase may have left behind that
# ends the loop before any routing. Prints the answer and returns 10 to stop.
returned_checks() {
  local feature_dir="$1" phase="$2" result="$feature_dir/result.json"
  if [[ -f "$result" && "$(jq -r '.status // empty' "$result")" == "paused" ]]; then
    case "$(jq -r '.reason // empty' "$result")" in
      spec-confirmation-declined|spec-override-declined)
        echo "DONE status=paused reason=$(jq -r '.reason' "$result")"; return 10 ;;
    esac
  fi
  local ceiling="${LOOP_SPEC_PHASE_TIMEOUT_MINS:-60}" started
  [[ "$ceiling" =~ ^[1-9][0-9]*$ ]] || _rc=2 die "LOOP_SPEC_PHASE_TIMEOUT_MINS must be a positive integer"
  started="$(fget "$feature_dir" '.currentPhaseStartedAt // ""')"
  if [[ -n "$started" ]]; then
    local mins=$(( ( $(date -u +%s) - $(iso_epoch "$started") ) / 60 ))
    if (( mins > ceiling )); then
      # The watchdog never kills work; it makes a wedged loop visible.
      echo "loop-spec: phase $phase took ${mins}m, ceiling ${ceiling}m" >&2
      lib feature-write append "$feature_dir" warnings "\"phase $phase took ${mins}m, ceiling ${ceiling}m\"" >/dev/null
    fi
  fi
  # An ITERATE gap only an operator can close ends the run here with the fix as the
  # reason, instead of a rewind that reproduces the gap or a question to an absent human.
  if [[ "$phase" == "iterate" && "$(fget "$feature_dir" '.iterate.lastRoute // ""')" == "escalate" ]]; then
    local fix; fix="$(fget "$feature_dir" '.iterate.feedback.fix_first // .iterate.feedback.description // "iterate gap needs an operator"')"
    cmd_escalate --feature-dir "$feature_dir" --reason "operator action needed: $fix" >/dev/null
    echo "DONE status=escalated reason=\"operator action needed: $fix\""; return 10
  fi
  # deliver -> deliver is a stop that needs an external condition to change (or a
  # proven no-change completion); the graph must not re-enter DELIVER.
  if [[ "$phase" == "deliver" && -f "$feature_dir/delivery.json" \
        && "$(jq -r '.nextPhase // "deliver"' "$feature_dir/delivery.json")" == "deliver" ]]; then
    deliver_stalled "$feature_dir"; return 10
  fi
  return 0
}

# record_transition FEATURE_DIR PHASE NEXT NOTE WS_MODE: journal, commit the resume
# contract, checkpoint, then the opt-in exits (phase handoff, fresh rewind). Returns 10
# after printing an answer that ends this invocation.
record_transition() {
  local feature_dir="$1" phase="$2" next="$3" note="$4" ws_mode="$5"
  local slug; slug="$(fget "$feature_dir" '.slug')"
  # DELIVER's terminal states are observation-only: a tracked commit after them would
  # invalidate the exact SHA the PR proved. Only a remediation rewind mutates.
  if [[ "$phase" == "deliver" && "$next" != "execute" ]]; then return 0; fi

  fset "$feature_dir" updatedAt "\"$(now)\"" >/dev/null
  {
    [[ -f "$feature_dir/PROGRESS.md" ]] || printf '# Progress — %s\n' "$slug"
    printf '\n## %s — %s → %s\n- did: %s\n' "$(now)" "$phase" "$next" "${note:-phase $phase returned}"
  } >> "$feature_dir/PROGRESS.md"

  # The feature's own repository, not $PWD: the lead often calls this from the project
  # root while the feature lives in a worktree, and a state commit that silently missed
  # left feature.json untracked for DELIVER to refuse as dirt (eval finding 2).
  local root=""
  root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null)" || root=""
  if [[ "$(lib state-commit-policy mode)" == "phase" && "$ws_mode" != "workspace" && -n "$root" ]]; then
    lib owned-gitignore check "$root" || die "refusing to mix pre-existing .gitignore changes with loop-spec policy"
    lib owned-gitignore ensure "$root" '!/.loop-spec/features/*/PROGRESS.md' '!/.loop-spec/RULES.md' >/dev/null
    local rel; rel="$(python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))' "$feature_dir" "$root")"
    local git_err=""
    if ! git_err="$(git -C "$root" add -- "$rel/feature.json" "$rel/PROGRESS.md" .gitignore 2>&1)"; then
      echo "cycle-driver: state commit failed in $root: $git_err" >&2
      lib feature-write append "$feature_dir" warnings "\"state commit failed at $phase -> $next: $git_err\"" >/dev/null
    elif ! git -C "$root" diff --cached --quiet -- "$rel/feature.json" "$rel/PROGRESS.md" .gitignore 2>/dev/null; then
      git_err="$(git -C "$root" commit -q -m "chore: $slug state @ $next" -- "$rel/feature.json" "$rel/PROGRESS.md" .gitignore 2>&1)" || {
        echo "cycle-driver: state commit failed in $root: $git_err" >&2
        lib feature-write append "$feature_dir" warnings "\"state commit failed at $phase -> $next: $git_err\"" >/dev/null
      }
    fi
    local checkpoint_default=0
    [[ "$(fget "$feature_dir" '.autonomous // false')" == "true" ]] && checkpoint_default=1
    local each="${LOOP_SPEC_CHECKPOINT_EACH_PHASE:-$checkpoint_default}"
    case "$each" in 0|1) ;; *) _rc=2 die "LOOP_SPEC_CHECKPOINT_EACH_PHASE must be 0 or 1" ;; esac
    [[ "$each" == "1" && "$phase" != "deliver" ]] \
      && lib checkpoint-pr create "$feature_dir" --reason "autonomous phase checkpoint: $next" >&2 || true
  fi

  case "$next" in completed|human.*) return 0 ;; esac
  if [[ "$(fget "$feature_dir" '.phaseHandoff // false')" == "true" && "$next" != "$phase" ]]; then
    lib cycle-result write "$feature_dir" --status paused --reason phase-handoff \
      --summary "Phase $phase completed; $next is ready in durable state." >/dev/null
    local m; m="$(lib feature-init phase-model "$next" 2>/dev/null || true)"
    echo "HANDOFF next=$next model=${m:-inherit}"
    return 10
  fi
  if [[ "${LOOP_SPEC_ITERATE_FRESH:-}" == "1" && "$phase" == "iterate" ]]; then
    case "$next" in execute|plan|spec|discuss) echo "REWIND next=$next"; return 10 ;; esac
  fi
  return 0
}

# deliver -> deliver is either a proven no-change completion or a stop that needs an
# external condition to change. Never re-run DELIVER from here.
deliver_stalled() {
  local feature_dir="$1" delivery="$feature_dir/delivery.json"
  if jq -e '.status == "no-changes" and ((.targets // []) | length > 0) and
        ((.targets // []) | all(.errorCode == "no_commits" or .outcome == "skipped-no-commits"))' "$delivery" >/dev/null 2>&1 \
     && jq -e '.iterate.lastVerdict.converged == true and .iterate.lastVerdict.deterministic_gate_passed == true and
        ((.warnings // []) | map(type == "string" and (startswith("iterate-budget-spent:") or startswith("iterate-terminal:"))) | any | not) and
        ((.iterate.lastVerdict.summary // "") | test("\\S"))' "$feature_dir/feature.json" >/dev/null 2>&1; then
    lib cycle-result write "$feature_dir" --status completed --summary "$(fget "$feature_dir" '.iterate.lastVerdict.summary')" \
      --no-change-reason already-satisfied >/dev/null
    echo "DONE status=completed reason=already-satisfied"
  else
    local reason
    reason="$(jq -r '(.status // "unknown") as $s | ([.targets[]?.error // empty] | first // ("delivery stopped with status " + $s))' "$delivery")"
    lib cycle-result write "$feature_dir" --status escalated --reason "$reason" --summary "Delivery stopped: $reason" >/dev/null
    echo "DONE status=escalated reason=\"$reason\""
  fi
}

# ------------------------------------------------------------------ finish ----
cmd_finish() {
  local feature_dir="" completed=0
  while [[ $# -gt 0 ]]; do case "$1" in --feature-dir) feature_dir="$2" ;; --completed) completed="$2" ;; *) usage ;; esac; shift 2; done
  [[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] || usage
  feature_dir="$(cd "$feature_dir" && pwd -P)"
  local delivery="$feature_dir/delivery.json" status
  status="$(jq -r '.status // ""' "$delivery" 2>/dev/null || true)"
  case "$status" in ready-for-review|delivered-draft|pushed-no-pr) ;;
    *) echo "loop-spec: delivery-incomplete (sidecar status '${status:-none}'); feature.json.currentPhase stays at deliver." >&2; exit 1 ;;
  esac
  local pr_url summary
  pr_url="$(fget "$feature_dir" '.prUrl // empty')"
  summary="$(fget "$feature_dir" '.iterate.lastVerdict.summary // empty')"
  [[ "$summary" =~ [^[:space:]] ]] || summary="Cycle completed; PR delivered."
  [[ "$status" == "pushed-no-pr" ]] && summary="$summary (pushed to the remote; no gh on this host, so no PR was opened)"
  lib cycle-result write "$feature_dir" --status completed --summary "$summary" ${pr_url:+--pr-url "$pr_url"} >/dev/null \
    || { echo "cycle-result.sh write failed; retrying once" >&2
         lib cycle-result write "$feature_dir" --status completed --summary "$summary" ${pr_url:+--pr-url "$pr_url"} >/dev/null; }
  local entry; entry="$(fget "$feature_dir" '.backlogEntry // empty')"
  [[ -n "$entry" ]] && lib backlog done "$entry" >/dev/null 2>&1 || true
  local chain; chain="$(lib autonomous-chain should-chain "$feature_dir" --completed "$completed")"
  local exit_wt=false
  [[ "$(fget "$feature_dir" 'if (.workspace != null and (.workspace.mode // "") != "single") then .workspace else null end')" == "null" && -n "$(fget "$feature_dir" '.worktreePath // ""')" && "$(lib harness detect)" == "claude" ]] && exit_wt=true
  jq -n --arg s "$status" --arg pr "$pr_url" --arg sum "$summary" --argjson d "$(cat "$delivery")" \
    --argjson w "$(fget "$feature_dir" '.warnings // []')" --argjson chain "$chain" --argjson ew "$exit_wt" \
    --arg bl "$(lib backlog count 2>/dev/null || echo 0)" \
    '{status:$s, prUrl:($pr | select(. != "") // null), summary:$sum, targets:($d.targets // []),
      feedback:($d.feedback // null), warnings:$w, chain:$chain, backlogCount:($bl | tonumber), exitWorktree:$ew}'
}

# ---------------------------------------------------------------- escalate ----
cmd_escalate() {
  local feature_dir="" reason=""
  while [[ $# -gt 0 ]]; do case "$1" in --feature-dir) feature_dir="$2" ;; --reason) reason="$2" ;; *) usage ;; esac; shift 2; done
  [[ -n "$feature_dir" && -f "$feature_dir/feature.json" && -n "$reason" ]] || usage
  feature_dir="$(cd "$feature_dir" && pwd -P)"
  fset "$feature_dir" currentTeamName null >/dev/null
  fset "$feature_dir" currentTeammates '[]' >/dev/null
  local phase; phase="$(fget "$feature_dir" '.currentPhase')"
  lib cycle-result write "$feature_dir" --status escalated --reason "$reason" \
    --summary "Cycle stopped during $phase: $reason" >/dev/null || true
  lib checkpoint-pr create "$feature_dir" --reason "$reason" >&2 || true
  local exit_wt=false
  [[ "$(fget "$feature_dir" 'if (.workspace != null and (.workspace.mode // "") != "single") then .workspace else null end')" == "null" && -n "$(fget "$feature_dir" '.worktreePath // ""')" && "$(lib harness detect)" == "claude" ]] && exit_wt=true
  jq -n --arg r "$reason" --arg p "$phase" --argjson gh "$(fget "$feature_dir" '(.gateHistory // [])[-3:]')" \
    --argjson a "$(fget "$feature_dir" '.artifacts // {}')" \
    --argjson d "$(cat "$feature_dir/delivery.json" 2>/dev/null || echo null)" --argjson ew "$exit_wt" \
    '{reason:$r, phase:$p, gateHistory:$gh, artifacts:$a, delivery:$d, exitWorktree:$ew}'
}

# iterate_is_terminal FEATURE_DIR: converged, or the iteration budget spent, closes the
# phase; a rewind leaves it open for the next pass.
iterate_is_terminal() {
  jq -e '(.iterate.lastVerdict.converged == true)
         or ((.iterate.used // 0) >= (.iterate.maxIterations // 10))' "$1/feature.json" >/dev/null 2>&1
}

# kv_json LINE: `key=value key2=value with spaces key3=x` -> a JSON object. The mode
# lines end in a free-text reason, so a value runs until the next ` key=`.
kv_json() {
  python3 -c '
import json, re, sys
line = sys.argv[1].strip()
print(json.dumps({m.group(1): m.group(2) for m in re.finditer(r"(\w+)=(.*?)(?=\s+\w+=|$)", line)}))' "$1"
}

# ------------------------------------------------------------------ begin ----
cmd_begin() {
  local dir="$PWD" args=() st rc=0
  while [[ $# -gt 0 ]]; do
    case "$1" in --dir) dir="$2"; shift 2 ;; --) shift; args=("$@"); break ;; *) args+=("$1"); shift ;; esac
  done
  st="$(cmd_start --dir "$dir" -- ${args[@]+"${args[@]}"})" || return $?
  if [[ "$(jq '.decisions | length' <<<"$st")" != "0" ]]; then
    jq -c '. + {action:"decisions"}' <<<"$st"; return 0
  fi
  local pick; pick="$(jq -r '.resume.autoPick // empty' <<<"$st")"
  local out
  if [[ -n "$pick" ]]; then
    local root; root="$(jq -r --arg s "$pick" '.resume.candidates[] | select(.slug == $s) | .featureRoot' <<<"$st" | head -1)"
    out="$(cmd_resume --dir "$dir" --feature-root "$root" --slug "$pick" \
      --phase-mode "$(jq -r '.invocation.phase_mode // ""' <<<"$st")")" || rc=$?
    (( rc == 0 )) || return "$rc"
    jq -c --argjson r "$out" '. + {action:"resume"} + $r' <<<"$st"; return 0
  fi
  local title slug; title="$(jq -r '.invocation.title // ""' <<<"$st")"; slug="$(jq -r '.invocation.slug // ""' <<<"$st")"
  [[ -n "$title" && -n "$slug" ]] || { echo "cycle-driver: begin needs a feature title (start left none and asked no question)" >&2; return 3; }
  local entry; entry="$(jq -c '.invocation.backlogEntry // empty' <<<"$st")"
  out="$(cmd_init --dir "$(jq -r '.workspace.root' <<<"$st")" --slug "$slug" --title "$title" \
    --style "$(jq -r '.invocation.style' <<<"$st")" --profile "$(jq -r '.profile' <<<"$st")" \
    --classification "$(jq -c '.classification' <<<"$st")" \
    --autonomous "$(jq -r 'if .autonomous then 1 else 0 end' <<<"$st")" \
    --greenfield "$(jq -r 'if .greenfield then 1 else 0 end' <<<"$st")" \
    --spec-file "$(jq -r '.invocation.spec_path // ""' <<<"$st")" \
    --commands "$(jq -c '.commands' <<<"$st")" --repos "$(jq -c '.workspace.repos' <<<"$st")" \
    --phase-mode "$(jq -r '.invocation.phase_mode // ""' <<<"$st")" \
    ${entry:+--backlog-entry "$entry"})" || rc=$?
  (( rc == 0 )) || return "$rc"
  jq -c --argjson r "$out" '. + {action:"init"} + $r' <<<"$st"
}

# ---------------------------------------------------------------- deliver ----
cmd_deliver() {
  local feature_dir=""
  while [[ $# -gt 0 ]]; do case "$1" in --feature-dir) feature_dir="$2" ;; *) usage ;; esac; shift 2; done
  [[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] || usage
  feature_dir="$(cd "$feature_dir" && pwd -P)"
  local rc=0 out
  out="$(lib deliver run "$feature_dir" 2>&1 >/dev/null)" || rc=$?
  local sidecar="$feature_dir/delivery.json" status next route feedback='[]' frc=0
  status="$(jq -r '.status // ""' "$sidecar" 2>/dev/null || true)"
  next="$(jq -r '.nextPhase // "deliver"' "$sidecar" 2>/dev/null || echo deliver)"
  if (( rc == 3 )); then route=deferral
  elif [[ "$next" == "completed" ]]; then
    route=completed
    # Every cycle ends by reading its PR for reviews and requested changes; a target
    # without a PR (pushed-no-pr) has nothing to read.
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      local n repo fb args=()
      n="$(jq -r '.prNumber' <<<"$t")"; repo="$(jq -r '.repo // empty' <<<"$t")"
      args=("$n"); [[ -n "$repo" ]] && args+=(--repo "$repo")
      fb="$(lib pr-feedback check "${args[@]}")" || { frc=1; break; }
      lib pr-feedback record "$sidecar" "$(jq -r '.name' <<<"$t")" "$fb" || { frc=1; break; }
      feedback="$(jq -c --argjson f "$fb" '. + [$f]' <<<"$feedback")"
    done < <(jq -c '.targets[]? | select(.prNumber != null)' "$sidecar")
    (( frc == 0 )) || { route=feedback-failed; echo "cycle-driver: PR feedback persistence failed; completion blocked" >&2; }
  else route="$next"; fi
  jq -cn --argjson rc "$rc" --arg status "$status" --arg next "$next" --arg route "$route"     --argjson targets "$(jq -c '.targets // []' "$sidecar" 2>/dev/null || echo '[]')" --argjson fb "$feedback" --arg err "$out"     '{rc:$rc, status:$status, nextPhase:$next, route:$route, targets:$targets, feedback:$fb, stderr:(if $err == "" then null else $err end)}'
  [[ "$route" == "completed" ]] && return 0 || return 1
}

# ------------------------------------------------------------ phase-begin ----
cmd_phase_begin() {
  local phase="${1:-}" feature_dir=""; shift || true
  while [[ $# -gt 0 ]]; do case "$1" in --feature-dir) feature_dir="$2" ;; *) usage ;; esac; shift 2; done
  case "$phase" in spec|discuss|plan|execute|verify|iterate|deliver) ;; *) usage ;; esac
  [[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] || usage
  feature_dir="$(cd "$feature_dir" && pwd -P)"
  local entry_out entry_rc=0
  entry_out="$(lib phase-entry "$phase" --feature-dir "$feature_dir" 2>&1)" || entry_rc=$?
  (( entry_rc <= 1 )) || { printf '%s\n' "$entry_out" >&2; return 2; }
  local entry_json
  entry_json="$(python3 -c '
import json, sys
fields, reads, flags = {}, [], []
for line in sys.argv[1].splitlines():
    if line.startswith("fields="):
        try: fields = json.loads(line[7:])
        except ValueError: fields = {"raw": line[7:]}
    elif line.startswith("read="): reads.append(line[5:])
    elif line.startswith("FLAG"): flags.append(line)
print(json.dumps({"fields": fields, "read": reads, "flags": flags}))' "$entry_out")"
  local mode_json='{}'
  case "$phase" in
    spec|discuss|plan|verify) mode_json="$(kv_json "$(lib phase-mode "$phase" --feature-dir "$feature_dir")")" ;;
  esac
  local extra='{}' extra_rc=0
  if (( entry_rc == 0 )); then
    case "$phase" in
      execute) extra="$(lib execute-prepare run --feature-dir "$feature_dir")" || extra_rc=$? ;;
      verify) extra="$(lib verify-prepare run --feature-dir "$feature_dir")" || extra_rc=$? ;;
    esac
  fi
  [[ -n "$extra" ]] || extra='{}'
  jq -cn --arg phase "$phase" --argjson entry "$entry_json" --argjson mode "$mode_json" --argjson extra "$extra" \
    '{phase:$phase, entry:$entry, mode:$mode} + (if $phase == "execute" then {execute:$extra} elif $phase == "verify" then {verify:$extra} else {} end)'
  (( entry_rc == 0 )) || return 1
  return "$extra_rc"
}

case "${1:-}" in
  task) shift; lib execute-step "$@" ;;
  verify)
    shift
    case "${1:-}" in gate) shift; lib verify-gate run "$@" ;; passes) shift; lib verify-passes run "$@" ;; *) usage ;; esac ;;
  iterate) shift; lib iterate-judged "$@" ;;
  deliver) shift; cmd_deliver "$@" ;;
  begin) shift; cmd_begin "$@" ;;
  phase-begin) shift; cmd_phase_begin "$@" ;;
  start) shift; cmd_start "$@" ;;
  init) shift; cmd_init "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  next) shift; cmd_next "$@" ;;
  finish) shift; cmd_finish "$@" ;;
  escalate) shift; cmd_escalate "$@" ;;
  *) usage ;;
esac
