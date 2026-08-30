#!/usr/bin/env bash
# Select the cycle's execution profile: standard, maintenance, or classifier-planned
# compact gates.
#
# Why: a dependency version bump that routes to the full cycle still pays the SPEC
# interview, the DISCUSS critique, and the PLAN critique. Those gates exist for changes
# that can be wrong in ways a reviewer would not catch; on mechanical low-risk work they
# are the largest avoidable cost in the run. This is the probe that decides, so the
# decision is one auditable line rather than a per-phase judgment call.
#
# The lightened profile never removes a gate that can still fail on the work: SPEC still
# scores ambiguity and still gates on it, and a security signal still lengthens the path.
# What it removes is gate OVERHEAD the classification has already ruled out — a seam, an
# interface change, a security surface, a migration, a multi-repo blast radius, or scope
# beyond a handful of files each disqualify it. The graph short path
# (`lib/graph/probes/short-path.sh`), selected from this profile, additionally routes
# around discuss, the spec-critique subgraph, and the code-review agent — that last one
# is coverage, and only behind this classification. PLAN critique is still decided by
# `plan-critique.sh`, not by this probe.
#
# Usage:
#   cycle-profile.sh select [<classification.json> | -]
#   cycle-profile.sh --answers
#
# Input is the normalized object `lib/task-route.sh validate` prints. No classification
# means no evidence, which resolves `standard` — the profile is opt-in on evidence, never
# a default the absence of data can select.
#
# Output: one line, ANSWER + REASON: `profile=<compact|maintenance|standard> reason=<text>`.
# Exit: 0 resolved, 2 bad invocation.
set -uo pipefail

validate_gate_plan() {
  jq -e '
    def gate_names: [
      "specInterview", "discuss", "specCritique", "planCritique",
      "repositoryValidation", "placeholderScan", "tamperScan", "acceptance",
      "codeReview", "iterate"
    ];
    .gatePlan as $plan |
    ($plan | type == "object") and
    (($plan | keys | sort) == (gate_names | sort)) and
    all(gate_names[]; . as $name |
      ($plan[$name] | type == "object") and
      (($plan[$name] | keys | sort) == ["reason", "run"]) and
      ($plan[$name].run | type == "boolean") and
      ($plan[$name].reason | type == "string" and
        (length <= 240) and
        test("^[^\\r\\n]+$") and
        (gsub("[[:space:]]"; "") | length > 0))) and
    ((.gatePlan.specCritique.run | not) or .gatePlan.discuss.run)
  ' >/dev/null 2>&1 <<<"$1"
}

if [[ "${1:-}" == "validate-gate-plan" ]]; then
  source_path="${2:-}"
  [[ -n "$source_path" ]] || {
    echo "usage: cycle-profile.sh validate-gate-plan <classification.json | ->" >&2
    exit 2
  }
  if [[ "$source_path" == "-" ]]; then
    raw="$(cat)"
  elif [[ -f "$source_path" ]]; then
    raw="$(<"$source_path")"
  else
    echo "cycle-profile.sh: classification file not found: $source_path" >&2
    exit 2
  fi
  validate_gate_plan "$raw"
  exit $?
fi

if [[ "${1:-}" == "--answers" ]]; then
  printf 'profile=compact\nprofile=maintenance\nprofile=standard\n'
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

# Maintenance and standard remain explicit operator choices. Compact is different: it
# can omit named safeguards, so even an operator request needs the classifier evidence
# that says exactly which safeguards remain and why.
compact_requested=false
case "${LOOP_SPEC_CYCLE_PROFILE:-auto}" in
  compact) compact_requested=true ;;
  maintenance) emit maintenance "LOOP_SPEC_CYCLE_PROFILE=maintenance" ;;
  standard) emit standard "LOOP_SPEC_CYCLE_PROFILE=standard" ;;
  auto) ;;
  *) emit standard "LOOP_SPEC_CYCLE_PROFILE must be compact, maintenance, standard, or auto" ;;
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

# Compact is evidence-driven: route=compact is accepted only with the full typed plan
# and its deliberately broader, but still bounded, classifier evidence. Risk flags are
# not category hard gates here; destructive work is the one non-negotiable promotion.
compact_verdict="$(jq -r '
  .taskKind as $kind |
  if .route == "compact" and
     ((["feature", "refactor"] | index($kind)) != null) and
     (.confidence | type == "number" and . >= 0.7 and . <= 1) and
     (.reviewableEstimatedFiles | type == "number" and floor == . and . >= 0 and . <= 12) and
     (.criteriaCount | type == "number" and floor == . and . >= 1 and . <= 6) and
     (.ambiguity == "low" or .ambiguity == "medium") and
     (.destructive == false)
  then "compact\troute=compact with a valid bounded gate plan"
  else empty end
' <<<"$raw" 2>/dev/null)" || compact_verdict=""

if [[ -n "$compact_verdict" ]] && validate_gate_plan "$raw"; then
  if [[ "$compact_requested" == true ]]; then
    emit compact "LOOP_SPEC_CYCLE_PROFILE=compact with ${compact_verdict#*$'\t'}"
  fi
  emit "${compact_verdict%%$'\t'*}" "${compact_verdict#*$'\t'}"
fi

if [[ "$compact_requested" == true ]]; then
  emit standard "LOOP_SPEC_CYCLE_PROFILE=compact requires valid normalized compact classification"
fi

[[ "$(jq -r '.route // ""' <<<"$raw")" != "compact" ]] || \
  emit standard "route=compact lacks valid bounded compact evidence"

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
