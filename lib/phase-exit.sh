#!/usr/bin/env bash
# phase-exit.sh - One command closes a phase: gates, artifact pointers, commit, tag.
#
# Why: every phase ended with the same scattered bookkeeping written as prose — run
# three lints, set four feature.json keys, git add two files, tag a checkpoint, clear
# the team — and a phase that got one of them wrong stalled the next phase on a
# repair it should never have had to do. This script is that ending. A phase skill
# runs it once; a FLAG means the phase fixes its own artifact and runs it again.
#
# What a phase checks and records is DATA on its graph node, not a case branch here:
# the `egress` block of the phase's agent node in graph/cycle.graph.json (schema
# `phaseEgress`, contract skills/shared/graph-contract.md, Phase ingress and egress).
# This script is the loop over that block, in the order the schema lists:
#   misplaced   the artifact is absent here but present in another checkout: name the move
#   required    FLAG [label] <path> missing
#   gates       each body runs like a gate node; a non-zero exit relays its findings as
#               FLAG [label] lines (a `when` clause keys the gate on a feature.json value)
#   oracle      a named supervisor was asked at least once this phase
#   writes      the egress guard's allow-list (below)
# and on ok: artifacts / artifactsIfPresent / artifactsDefault pointers, onOk bodies,
# the commit, the checkpoint tag, `set` resets, and close (always, or only --terminal).
# Placeholders in that data resolve here: {docs} {featureDir} {root} {slug} {spec}
# {tasks} {f:<dotted.key>}; lib/graph/validate.sh refuses any other.
# Adding a phase is one edit in graph/cycle.graph.json plus its SKILL.md; a graph copy
# is selected with LOOP_SPEC_GRAPH (tests/lib/graph-phases.test.sh).
#
# Usage:
#   phase-exit.sh <phase> --feature-dir DIR [--terminal]
# A phase whose node declares no `egress` (DELIVER: its terminal states are
# observation-only, cycle-driver.sh) is a bad invocation.
#
# Egress guard: when phase-entry.sh left <DIR>/.phase-entry.json, every feature.json
# path the phase changed is checked against the node's `egress.writes` plus the paths
# every phase may touch (WRITES_ALL below). A key outside both is state no later phase
# reads, the churn a resumed session pays for.
#   LOOP_SPEC_EGRESS_GUARD=warn   default: `WARN [egress] <path> ...`, never blocks
#   LOOP_SPEC_EGRESS_GUARD=deny   the same finding is a FLAG and the phase stays open
#   LOOP_SPEC_EGRESS_GUARD=off    no comparison
# The snapshot is removed on ok. No snapshot means nothing to judge.
#
# Output: `FLAG <what>` per finding, then one answer line:
#   phase-exit: ok (<phase>)                 exit 0
#   phase-exit: <n> flag(s) (<phase>)        exit 1
# Exit 2 is a bad invocation.
#
# On ok: records artifacts.* and completedPhases, clears currentTeamName and
# currentTeammates, commits the phase artifacts (single-repo only; a workspace root
# is orchestration state, never a delivery target), and tags the checkpoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GRAPH="${LOOP_SPEC_GRAPH:-$PLUGIN_ROOT/graph/cycle.graph.json}"

phase="${1:-}"; shift || true
feature_dir="" terminal=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; shift 2 ;;
    --terminal) terminal=1; shift ;;
    *) echo "usage: phase-exit.sh <phase> --feature-dir DIR [--terminal]" >&2; exit 2 ;;
  esac
done
bash "$SCRIPT_DIR/graph/phases.sh" validate "$phase" >/dev/null 2>&1 \
  || { echo "usage: phase-exit.sh <phase> --feature-dir DIR [--terminal] ($(bash "$SCRIPT_DIR/graph/phases.sh" validate "$phase" 2>&1 || true))" >&2; exit 2; }
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] \
  || { echo "phase-exit: --feature-dir must hold a feature.json" >&2; exit 2; }
node="$(jq -c --arg p "$phase" '.nodes[] | select(.id == $p) | .egress // empty' "$GRAPH" 2>/dev/null || true)"
[[ -n "$node" ]] \
  || { echo "phase-exit: the '$phase' node of $GRAPH declares no egress block; nothing closes it here" >&2; exit 2; }
feature_dir="$(cd "$feature_dir" && pwd -P)"
fj="$feature_dir/feature.json"

lib() { bash "$SCRIPT_DIR/$1.sh" "${@:2}"; }
fget() { bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" -r --filter "$1"; }
fset() { lib feature-write set "$feature_dir" "$1" "$2" >/dev/null; }
# nget FILTER: a field of the node's egress block, raw.
nget() { jq -r "$1" <<<"$node"; }

slug="$(fget '.slug')"
ws_root="$(fget 'if (.workspace != null and (.workspace.mode // "") != "single") then .workspace.root else "" end')"
if [[ -n "$ws_root" ]]; then root="$ws_root"; else root="$(git -C "$feature_dir" rev-parse --show-toplevel)"; fi
cd "$root"
docs="docs/loop-spec/features/$slug"
spec="$(fget '.artifacts.spec // ""')"; [[ -n "$spec" ]] || spec="$docs/SPEC.md"
tasks="$(fget '.artifacts.tasks // ""')"; [[ -n "$tasks" ]] || tasks="$feature_dir/tasks.json"
flags=0
flag() { echo "FLAG $*"; flags=$((flags + 1)); }

# {docs} resolves relative
# to the root it runs in, which is what artifacts.* pointers record.
. "$SCRIPT_DIR/phase-placeholders.sh"
resolve() { loop_spec_resolve_phase_path "$1"; }
# misplaced_hint NAME: the artifact is absent here but present under another checkout
# of this repository. Agents share the lead's cwd, so a writer given a relative path
# lands in the main checkout while this gate reads the feature worktree; the lead
# then re-runs the phase blind (four REDO attempts in the 6.3.0 fastapi bug-fix run).
misplaced_hint() {
  local name="$1" wt
  [[ -f "$docs/$name" ]] && return 0
  while IFS= read -r wt; do
    wt="${wt#worktree }"
    [[ -d "$wt" && ! "$wt" -ef "$root" && -f "$wt/$docs/$name" ]] || continue
    flag "[misplaced] $name was written to $wt/$docs/$name, another checkout of this repository; this gate reads $root/$docs/$name. Move it: mv $wt/$docs/$name $root/$docs/$name"
  done < <(git -C "$root" worktree list --porcelain 2>/dev/null | grep '^worktree ' || true)
}
# run_gate LABEL CMD...: relay the gate's own FLAG/output lines, count a failure once.
# Indented lines are the gate's detail (decision-coverage lists each uncovered entry under
# its heading); dropping them left the lead a bare "Uncovered decisions:" to act on. A
# line a body already labeled (`FLAG [tasks] ...` from lib/plan-exit-gate.sh) passes
# through as is: the body speaks this script's dialect, and a second label reads as noise.
run_gate() {
  local label="$1"; shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    printf '%s\n' "$out" | grep -E '^(FLAG|FLOOR)|^[^ ]|^ +- ' \
      | sed -E "/^FLAG \[/! s/^/FLAG [$label] /" | grep -Ev '^(FLAG \[[^]]*\] )?phase-exit:' || true
    flags=$((flags + 1))
  fi
}
# run_bodies FIELD: the node's gate list under FIELD, each `bash <body> <args>` with
# its placeholders resolved; a `when` clause skips the gate unless the feature.json
# value matches.
run_bodies() {
  local field="$1" entry label body when_field when_equals
  local -a args
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    label="$(jq -r '.label' <<<"$entry")"; body="$(jq -r '.body' <<<"$entry")"
    when_field="$(jq -r '.when.field // ""' <<<"$entry")"
    if [[ -n "$when_field" ]]; then
      when_equals="$(jq -r '.when.equals' <<<"$entry")"
      [[ "$(fget ".$when_field // \"\"")" == "$when_equals" ]] || continue
    fi
    args=()
    while IFS= read -r a; do args+=("$(resolve "$a")"); done < <(jq -r '.args[]?' <<<"$entry")
    run_gate "$label" bash "$PLUGIN_ROOT/$body" ${args[@]+"${args[@]}"}
  done < <(nget ".$field[]? | @json")
}

# oracle_gate: when the run named a supervisor as its oracle, this phase must have put
# at least one question to it (a `supervised` decision) or the question tool must
# have failed (`oracle-unavailable`). On Claude Code both kinds come only from
# hooks/team/oracle-record.sh, so a rationale cannot stand in for a question: the
# live run that bit us self-answered the interview, was flagged, and wrote a note.
oracle_gate() {
  local mode
  mode="$(lib supervisor/oracle mode --feature-dir "$feature_dir" 2>/dev/null || true)"
  [[ "$mode" == oracle=supervisor* ]] || return 0
  if ! jq -e --arg p "$phase" 'select(.phase == $p and (.kind == "supervised" or .kind == "oracle-unavailable"))' \
      "$feature_dir/decisions.jsonl" >/dev/null 2>&1; then
    flag "[oracle] LOOP_SPEC_ORACLE=supervisor but no $phase question reached it: ask through the question tool (skills/shared/autonomous-mode.md, The supervised path); the hook records the answer"
  fi
}

# commit_paths MESSAGE PATH...: single-repo commit of the paths that exist; nothing
# else is swept in. Workspace mode leaves the docs as local orchestration evidence.
commit_paths() {
  local msg="$1"; shift
  [[ -z "$ws_root" ]] || { echo "phase-exit: workspace root is not a delivery target; artifacts stay local" >&2; return 0; }
  # An ignored path (a transcript under .loop-spec/features/) is skipped, not forced.
  local existing=() p
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    git add -- "$p" 2>/dev/null || true
    git ls-files --error-unmatch -- "$p" >/dev/null 2>&1 && existing+=("$p")
  done
  [[ ${#existing[@]} -gt 0 ]] || return 0
  git diff --cached --quiet -- "${existing[@]}" 2>/dev/null || git commit -q -m "$msg" -- "${existing[@]}"
}

tag_checkpoint() {
  if [[ -n "$ws_root" ]]; then
    local r; while IFS= read -r r; do
      [[ -n "$r" ]] && lib checkpoint -C "$ws_root/$r" tag "$1" >/dev/null 2>&1 || true
    done < <(fget '.workspace.repos[]?.path')
  else
    lib checkpoint tag "$1" >/dev/null 2>&1 || true
  fi
}

# WRITES_ALL: the feature.json paths every phase may change between entry and exit, by
# prefix (gate rounds, team state, journaling). What one phase's skill or in-phase
# scripts own is that node's `egress.writes`. phase-exit's own artifacts.* and
# completedPhases writes happen after the check, so they are not listed.
WRITES_ALL="currentGate gateHistory currentTeamName currentTeammates updatedAt warnings activeWorkflow checkpointPrUrl"

egress_check() {
  local mode="${LOOP_SPEC_EGRESS_GUARD:-warn}" snap="$feature_dir/.phase-entry.json"
  case "$mode" in warn|deny) ;; off) return 0 ;;
    *) echo "phase-exit: LOOP_SPEC_EGRESS_GUARD must be warn, deny, or off (got '$mode')" >&2; exit 2 ;;
  esac
  [[ -f "$snap" ]] || return 0
  local allowed changed p a ok
  allowed="$WRITES_ALL $(nget '.writes | join(" ")')"
  # Every non-object path whose value differs, reduced to its key segments: an appended
  # array element reports as the array's own path.
  # The typed view plus the keys the schema does not declare: a write outside the
  # schema is exactly what this guard exists to name, so it is the one reader of --strays.
  changed="$(jq -rn --slurpfile a "$snap" \
      --argjson B "$(bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" --all --drop-strays)" \
      --argjson S "$(bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" --strays)" '
    ($a[0]) as $A | ($B + $S) as $B
    | ([($A, $B) | paths(type != "object")] | unique)
    | map(select(. as $p | ($A | getpath($p)) != ($B | getpath($p))))
    | map(map(select(type == "string")) | join(".")) | unique | .[]')"
  for p in $changed; do
    ok=0
    for a in $allowed; do [[ "$p" == "$a" || "$p" == "$a".* ]] && { ok=1; break; }; done
    (( ok )) && continue
    if [[ "$mode" == "deny" ]]; then
      flag "[egress] $p changed during $phase: no later phase reads it (allow-list: egress.writes on the $phase node of graph/cycle.graph.json)"
    else
      echo "WARN [egress] $p changed during $phase: no later phase reads it (allow-list: egress.writes on the $phase node of graph/cycle.graph.json; LOOP_SPEC_EGRESS_GUARD=deny blocks)"
    fi
  done
}

close_phase() {
  lib feature-write append "$feature_dir" completedPhases "\"$phase\"" >/dev/null
  fset currentTeamName null
  fset currentTeammates '[]'
}

egress_check

misplaced="$(nget '.misplaced // ""')"
[[ -z "$misplaced" ]] || misplaced_hint "$misplaced"
while IFS=$'\t' read -r label path; do
  [[ -n "$label" ]] || continue
  path="$(resolve "$path")"
  [[ -f "$path" ]] || flag "[$label] $path missing"
done < <(nget '.required[]? | [.label, .path] | @tsv')
run_bodies gates
[[ "$(nget '.oracle // false')" != "true" ]] || oracle_gate

if (( flags == 0 )); then
  while IFS=$'\t' read -r key path; do
    [[ -n "$key" ]] || continue
    fset "artifacts.$key" "\"$(resolve "$path")\""
  done < <(nget '.artifacts // {} | to_entries[] | [.key, .value] | @tsv')
  while IFS=$'\t' read -r key path; do
    [[ -n "$key" ]] || continue
    path="$(resolve "$path")"
    [[ -f "$path" ]] && fset "artifacts.$key" "\"$path\""
  done < <(nget '.artifactsIfPresent // {} | to_entries[] | [.key, .value] | @tsv')
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] || continue
    [[ "$(fget ".artifacts.$key // \"null\"")" != "null" ]] || fset "artifacts.$key" "\"$value\""
  done < <(nget '.artifactsDefault // {} | to_entries[] | [.key, .value] | @tsv')
  run_bodies onOk
fi
if (( flags == 0 )); then
  if [[ "$(nget '.commit // ""')" != "" ]]; then
    paths=()
    while IFS= read -r p; do paths+=("$(resolve "$p")"); done < <(nget '.commit.paths[]')
    commit_paths "$(resolve "$(nget '.commit.message')")" ${paths[@]+"${paths[@]}"}
  fi
  checkpoint="$(nget '.checkpoint // ""')"
  [[ -z "$checkpoint" ]] || tag_checkpoint "$checkpoint"
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] || continue
    fset "$key" "$value"
  done < <(nget '.set // {} | to_entries[] | [.key, (.value | @json)] | @tsv')
  case "$(nget '.close // "always"')" in
    always) close_phase ;;
    terminal) (( terminal == 1 )) && close_phase ;;
  esac
  rm -f "$feature_dir/.phase-entry.json"
  bash "$SCRIPT_DIR/supervisor/store.sh" persist "$feature_dir" "phase-exit:$phase" >/dev/null \
    || flag "[store] persist failed for $feature_dir (LOOP_SPEC_STORE)"
fi
if (( flags == 0 )); then
  echo "phase-exit: ok ($phase)"
else
  echo "phase-exit: $flags flag(s) ($phase)"; exit 1
fi
