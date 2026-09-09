#!/usr/bin/env bash
# Shared placeholder resolver for a phase node's ingress and egress data.
#
# Source this file after setting docs, feature_dir, root, slug, spec, tasks, and an
# fget FILTER function that reads feature.json; then call:
#
#   loop_spec_resolve_phase_path <text>
#       Print <text> with {docs} {featureDir} {root} {slug} {spec} {tasks} and every
#       {f:<dotted.key>} replaced. The set is closed: lib/graph/validate.sh refuses any
#       other placeholder in graph/cycle.graph.json, so nothing unresolved reaches a gate.
#
# It exists because lib/phase-entry.sh and lib/phase-exit.sh read the same node data and
# a resolver each would drift: a placeholder one of them learned would silently reach
# the other's gates as a literal path. What {docs} resolves TO is the caller's (absolute
# in phase-entry.sh so a `read=` line opens from any cwd, relative in phase-exit.sh
# because that is what artifacts.* pointers record); this file only substitutes.
loop_spec_resolve_phase_path() {
  local s="$1" key
  s="${s//\{docs\}/$docs}"; s="${s//\{featureDir\}/$feature_dir}"; s="${s//\{root\}/$root}"
  s="${s//\{slug\}/$slug}"; s="${s//\{spec\}/$spec}"; s="${s//\{tasks\}/$tasks}"
  while [[ "$s" =~ \{f:([A-Za-z0-9_.]+)\} ]]; do
    key="${BASH_REMATCH[1]}"
    s="${s//\{f:$key\}/$(fget ".$key // \"\"")}"
  done
  printf '%s' "$s"
}
