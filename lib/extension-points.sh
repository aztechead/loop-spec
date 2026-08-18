#!/usr/bin/env bash
# extension-points.sh - Read the project's declared extensions to the pipeline.
#
# Why: loop-spec is configurable (about sixty environment variables) but not
# extensible. A team that wants its own review layer, or one standing fact in
# front of every planner, has no move short of forking the skill markdown. This
# reads `.loop-spec/extensions.json` and hands the phase skills the additions a
# project declared.
#
# The line this file will not cross: extensions ADD, they never subtract. A
# built-in gate cannot be disabled, reordered, or shadowed here, because the
# gates are what let the loop act without a human -- a config that could switch
# one off would be an authority control wearing an accelerator's clothes. The
# scripts that authorize autonomy (trust.sh, autonomous-chain.sh, task-route.sh)
# do not read this file and must not learn to.
#
# Usage:
#   extension-points.sh layers <phase>                 # user review layers for a phase
#   extension-points.sh instructions <phase> <prepend|append>
#   extension-points.sh facts                          # standing facts, globs resolved
#   extension-points.sh validate                       # check the file, report findings
#
# Reads $LOOP_SPEC_EXTENSIONS (default `.loop-spec/extensions.json`).
#
# Exit codes:
#   0  emitted (possibly nothing) / validate found no finding
#   1  validate found findings
#   2  usage error
#
# The read paths fail OPEN: a missing, unreadable, or malformed file yields no
# extensions and a stderr note, never a blocked phase. `validate` is the checker
# and fails closed, so a project can find out its file is wrong on purpose.
set -euo pipefail

command="${1:-}"
config="${LOOP_SPEC_EXTENSIONS:-.loop-spec/extensions.json}"

case "$command" in
  layers) [[ $# -eq 2 ]] || { echo "usage: extension-points.sh layers <phase>" >&2; exit 2; } ;;
  instructions) [[ $# -eq 3 && ( "$3" == "prepend" || "$3" == "append" ) ]] || {
        echo "usage: extension-points.sh instructions <phase> <prepend|append>" >&2; exit 2; } ;;
  facts) [[ $# -eq 1 ]] || { echo "usage: extension-points.sh facts" >&2; exit 2; } ;;
  validate) [[ $# -eq 1 ]] || { echo "usage: extension-points.sh validate" >&2; exit 2; } ;;
  *) echo "usage: extension-points.sh layers <phase> | instructions <phase> <prepend|append> | facts | validate" >&2; exit 2 ;;
esac

# Ids the built-in gates own. A user layer answering to one of these names would
# be indistinguishable from the gate it shadows in every log the loop keeps.
PROTECTED_IDS="spec-compliance code-review security test-tamper acceptance marker over-engineering design-for-change human-code human-docs verification-gap grounding"
PHASES="spec discuss plan execute verify iterate deliver"
MAX_LAYERS=5
MAX_INSTRUCTION_CHARS=2000

if [[ ! -f "$config" ]]; then
  [[ "$command" == "validate" ]] && { echo "extensions=none reason=$config does not exist"; exit 0; }
  exit 0
fi

if ! parsed="$(jq -e . "$config" 2>/dev/null)"; then
  if [[ "$command" == "validate" ]]; then
    echo "finding=unparseable path=$config reason=not valid JSON"
    echo "extensions=rejected reason=1 finding"
    exit 1
  fi
  echo "extension-points: ignoring unparseable $config" >&2
  exit 0
fi

case "$command" in
  layers)
    phase="$2"
    # A layer with no readable prompt is dropped rather than dispatched empty:
    # an empty reviewer returns clean findings and reads like a pass.
    jq -r --arg phase "$phase" '
      (.reviewLayers // [])
      | map(select(.enabled != false))
      | map(select((.phase // "verify") == $phase))
      | .[]
      | select((.id // "") != "" and (.name // "") != "")
      | "layer=\(.id) name=\(.name) prompt=\(.promptFile // "") source=user"
    ' <<<"$parsed" 2>/dev/null | head -n "$MAX_LAYERS" || true
    ;;
  instructions)
    phase="$2"; position="$3"
    jq -r --arg phase "$phase" --arg position "$position" '
      (.phaseInstructions // {})[$phase][$position] // []
      | .[]
      | select(type == "string" and length > 0)
    ' <<<"$parsed" 2>/dev/null || true
    ;;
  facts)
    while IFS= read -r fact; do
      [[ -n "$fact" ]] || continue
      if [[ "$fact" == file:* ]]; then
        pattern="${fact#file:}"
        # Globs resolve here so a phase skill receives paths that exist, not a
        # pattern it would have to expand itself and get wrong.
        matched=0
        while IFS= read -r path; do
          [[ -f "$path" ]] || continue
          echo "fact=file path=$path"
          matched=1
        done < <(compgen -G "$pattern" 2>/dev/null || true)
        [[ "$matched" -eq 1 ]] || echo "fact=unresolved pattern=$pattern reason=no file matches" >&2
      else
        echo "fact=literal text=$fact"
      fi
    done < <(jq -r '(.persistentFacts // []) | .[] | select(type == "string" and length > 0)' <<<"$parsed" 2>/dev/null || true)
    ;;
  validate)
    findings=0
    report() { echo "$1"; findings=$((findings + 1)); }

    schema="$(jq -r '.schemaVersion // "missing"' <<<"$parsed")"
    [[ "$schema" == "1" ]] || report "finding=schema-version value=$schema reason=only schemaVersion 1 is supported"

    layer_count="$(jq -r '(.reviewLayers // []) | length' <<<"$parsed")"
    [[ "$layer_count" -le "$MAX_LAYERS" ]] ||
      report "finding=too-many-layers count=$layer_count reason=at most $MAX_LAYERS review layers"

    # Unit separator, not tab: bash collapses runs of IFS whitespace, so a layer
    # with no phase would shift its promptFile into the phase slot.
    while IFS=$'\037' read -r id phase prompt; do
      [[ -n "$id" ]] || { report "finding=layer-missing-id reason=every review layer needs an id"; continue; }
      for protected in $PROTECTED_IDS; do
        [[ "$id" == "$protected" ]] &&
          report "finding=protected-id id=$id reason=built-in gate ids cannot be claimed by an extension"
      done
      if [[ -n "$phase" ]]; then
        case " $PHASES " in
          *" $phase "*) ;;
          *) report "finding=unknown-phase id=$id phase=$phase reason=not one of: $PHASES" ;;
        esac
      fi
      [[ -z "$prompt" || -f "$prompt" ]] ||
        report "finding=missing-prompt id=$id path=$prompt reason=promptFile does not exist"
    done < <(jq -r '(.reviewLayers // []) | .[] | [(.id // ""), (.phase // ""), (.promptFile // "")] | join("\u001f")' <<<"$parsed" 2>/dev/null || true)

    while IFS= read -r phase; do
      [[ -n "$phase" ]] || continue
      case " $PHASES " in
        *" $phase "*) ;;
        *) report "finding=unknown-phase phase=$phase reason=not one of: $PHASES" ;;
      esac
    done < <(jq -r '(.phaseInstructions // {}) | keys[]' <<<"$parsed" 2>/dev/null || true)

    while IFS= read -r length; do
      [[ -n "$length" ]] || continue
      [[ "$length" -le "$MAX_INSTRUCTION_CHARS" ]] ||
        report "finding=instruction-too-long chars=$length reason=at most $MAX_INSTRUCTION_CHARS characters"
    done < <(jq -r '(.phaseInstructions // {}) | to_entries[] | .value | to_entries[] | .value[]? | select(type == "string") | length' <<<"$parsed" 2>/dev/null || true)

    if [[ "$findings" -eq 0 ]]; then
      echo "extensions=valid reason=$layer_count review layers, $config"
      exit 0
    fi
    echo "extensions=rejected reason=$findings finding(s)"
    exit 1
    ;;
esac
