#!/usr/bin/env bash
# Select the cycle's execution profile: full gate ladder, or the lightened
# maintenance path.
#
# Why: a dependency version bump that routes to the full cycle still pays the SPEC
# interview, the DISCUSS critique, and the PLAN critique. Those gates exist for changes
# that can be wrong in ways a reviewer would not catch; on mechanical low-risk work they
# are the largest avoidable cost in the run. This is the probe that decides, so the
# decision is one auditable line rather than a per-phase judgment call.
#
# The lightened profile NEVER removes a gate that can still fail: SPEC still scores
# ambiguity and still gates on it, VERIFY is untouched, and a security signal still
# escalates the critique gates. What it removes is gate OVERHEAD the classification has
# already ruled out — a seam, an interface change, a security surface, a migration, a
# multi-repo blast radius, or scope beyond a handful of files each disqualify it.
#
# Usage:
#   cycle-profile.sh select [<classification.json> | -]
#   cycle-profile.sh --answers
#
# Input is the normalized object `lib/task-route.sh validate` prints. No classification
# means no evidence, which resolves `standard` — the profile is opt-in on evidence, never
# a default the absence of data can select.
#
# Output: one line, ANSWER + REASON: `profile=<maintenance|standard> reason=<text>`.
# Exit: 0 resolved, 2 bad invocation.
set -uo pipefail

if [[ "${1:-}" == "--answers" ]]; then
  printf 'profile=maintenance\nprofile=standard\n'
  exit 0
fi

[[ "${1:-}" == "select" ]] || {
  echo "usage: cycle-profile.sh select [<classification.json> | -] | --answers" >&2
  exit 2
}

emit() {
  printf 'profile=%s reason=%s\n' "$1" "$2"
  exit 0
}

# An explicit operator setting outranks the probe (CLAUDE.md: probes, not judgments).
case "${LOOP_SPEC_CYCLE_PROFILE:-auto}" in
  maintenance) emit maintenance "LOOP_SPEC_CYCLE_PROFILE=maintenance" ;;
  standard) emit standard "LOOP_SPEC_CYCLE_PROFILE=standard" ;;
  auto) ;;
  *) emit standard "LOOP_SPEC_CYCLE_PROFILE must be maintenance, standard, or auto" ;;
esac

source_path="${2:-}"
if [[ -z "$source_path" ]]; then
  emit standard "no classification supplied"
elif [[ "$source_path" == "-" ]]; then
  raw="$(cat)"
elif [[ -f "$source_path" ]]; then
  raw="$(<"$source_path")"
else
  emit standard "classification file not found: $source_path"
fi

[[ -n "${raw//[[:space:]]/}" ]] || emit standard "empty classification"
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$raw" || emit standard "classification is not a JSON object"

# One jq expression, so a missing field reads as disqualifying rather than as an
# absent test. `risk` answers true for anything that is not an explicit `false`:
# unknown risk is risk. (jq's `//` cannot express that -- it treats `false` as
# absent, which would read every cleared flag as unknown.)
verdict="$(jq -r '
  def risk($k): if (.[$k] == false) then false else true end;
  def dependency_risk:
    if has("introducesNewDependency") then risk("introducesNewDependency")
    else risk("introducesDependency") end;
  def risky: risk("introducesSeam") or risk("changesInterface") or
             risk("securitySensitive") or risk("dataMigration") or
             risk("multiRepo") or risk("destructive") or dependency_risk;
  def files: (.reviewableEstimatedFiles // .estimatedFiles // 999);
  (.taskKind // "unknown") as $kind |
  if ((["docs", "config", "maintenance"] | index($kind)) == null)
    then "standard\ttaskKind=\($kind) is not maintenance-shaped"
  elif risky
    then "standard\tclassification reports a seam, interface, security, migration, dependency, multi-repo, or destructive change"
  elif (.ambiguity // "high") != "low"
    then "standard\tambiguity=\(.ambiguity // "unknown") is not low"
  elif ((.confidence // 0) < 0.8)
    then "standard\tconfidence=\(.confidence // 0) is below 0.8"
  elif (files > 5)
    then "standard\t\(files) reviewable file(s) exceeds the 5-file maintenance bound"
  elif ((.criteriaCount // 999) > 3)
    then "standard\t\(.criteriaCount) acceptance criteria exceeds the 3-criterion maintenance bound"
  else "maintenance\ttaskKind=\($kind), \(files) reviewable file(s), low ambiguity, no risk flag"
  end
' <<<"$raw" 2>/dev/null)" || emit standard "classification could not be evaluated"

[[ -n "$verdict" ]] || emit standard "classification could not be evaluated"
emit "${verdict%%$'\t'*}" "${verdict#*$'\t'}"
