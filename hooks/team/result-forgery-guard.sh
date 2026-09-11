#!/usr/bin/env bash
# PreToolUse hook (Bash): the terminal result and the feature state are written by
# lib/cycle-result.sh and lib/feature-write.sh, never by a shell redirection.
#
# Claude Code contract:
#   exit 0 = allow
#   exit 2 = deny (stderr shown to the model)
#
# Why: twice in the evals a lead whose result the writer refused wrote
# .loop-spec/last-result.json itself -- once with the Write tool, once with a heredoc --
# and a supervisor read a completed run that had never reached DELIVER
# (the 2026-09-06 live evals). hooks/restrict-agent-paths.sh covers Write and Edit;
# this covers the shell: `>`, `>>`, `tee`, `cp`, `mv`, `install`, `rm`, `sed -i`,
# `patch`, `git apply`, and a Python `open(..., "w")` whose target is one of the
# contract files. Reading them stays free.
#
# Contract files (by basename, anywhere under .loop-spec/):
#   last-result.json result.json active-run.json feature.json delivery.json
# Driver-owned publication paths (lib/harness.sh protected-path decides; this hook
# only locates the candidate path and the feature slug it belongs to): SPEC.md,
# PLAN.md, VERIFICATION.md, and PATTERNS.md under a feature's docs tree when the
# route is oneshot or the requirements format is v1; feature.json[.bak],
# tasks.json, observations/**, publication-generations/**, and
# migration-generations/** under its runtime tree -- never
# publication-staging/**, which stays a maker's to write. A shell write onto any
# of these was the writer hooks/restrict-agent-paths.sh could not see
# (port audit 4, N1's remaining writers).
#
# Stands down (exit 0) when the project has no .loop-spec/ dir, when python3 is
# missing, or when the payload is malformed. Kill switch: LOOP_SPEC_FORGERY_GUARD=0.
set -uo pipefail

[[ "${LOOP_SPEC_FORGERY_GUARD:-1}" == "0" ]] && exit 0
if [[ ! -d "${CLAUDE_PROJECT_DIR:-$PWD}/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then exit 0; fi
command -v python3 >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
# Bash 3.2 misparses this heredoc inside quoted command substitution; assignments
# already preserve whitespace without word splitting.
VERDICT=$(LOOP_SPEC_GUARD_INPUT="$INPUT" python3 - <<'PY' 2>/dev/null || true
import json, os, re, sys
try:
    payload = json.loads(os.environ.get("LOOP_SPEC_GUARD_INPUT") or "")
except ValueError:
    sys.exit(0)
if payload.get("tool_name") != "Bash":
    sys.exit(0)
command = str((payload.get("tool_input") or {}).get("command") or "")
files = r"(?:last-result|result|active-run|feature|delivery)\.json"
target = r"\S*" + files + r"\b"
patterns = [
    r">>?\s*" + target,                                   # cat > x.json, jq ... >> x.json
    r"\btee\b[^\n;&|]*" + target,                         # ... | tee x.json
    r"\b(?:cp|mv|install)\b[^\n;&|]*\s" + target,         # cp tmp x.json
    r"\bsed\b[^\n;&|]*-i[^\n;&|]*" + target,              # sed -i ... x.json
    r"open\(\s*\\?['\"][^'\"]*" + files + r"\\?['\"]\s*,\s*\\?['\"][wa]",  # open("x.json", "w"), quotes maybe \-escaped
]
for pat in patterns:
    m = re.search(pat, command)
    if m:
        print(m.group(0)[:120])
        break
else:
    # The same write shapes aimed at a driver-owned publication path (docs
    # artifact or runtime-state file). lib/harness.sh protected-path decides
    # whether the candidate is actually protected; this only locates it and
    # the feature slug, printed as `candidate <slug> <resolved-path>`.
    #
    # The path text this regex matches is deliberately ANY file under a feature's
    # docs or runtime tree, not just the canonical protected names: a maker
    # allowed to write under publication-staging could plant a symlink there
    # literally named anything and point it at SPEC.md/feature.json/tasks.json,
    # and a regex keyed on the literal target name would never see it (the
    # redirection target in the command text is the symlink's own name, not what
    # it resolves to). So every candidate found here is resolved with realpath
    # below BEFORE being handed to lib/harness.sh protected-path -- the literal
    # match is only the trigger; the resolved location is what gets judged.
    ops = [
        r">>?\s*(?P<path>{p})",                              # cat > x, jq ... >> x
        r"\btee\b[^\n;&|]*(?P<path>{p})",                    # ... | tee x
        r"\b(?:cp|mv|install|rm)\b[^\n;&|]*\s(?P<path>{p})", # cp/mv/install/rm x
        r"\bsed\b[^\n;&|]*-i[^\n;&|]*(?P<path>{p})",         # sed -i ... x
        r"\bpatch\b[^\n;&|]*(?P<path>{p})",                  # patch ... x
        r"\bgit\s+apply\b[^\n;&|]*(?P<path>{p})",            # git apply ... x
        r"open\(\s*\\?['\"](?P<path>{p})\\?['\"]\s*,\s*\\?['\"][wa]",  # open("x", "w")
    ]
    # [^\s'"\\]+ rather than \S+: excludes the quote/backslash characters a
    # quoted shell or Python string wraps the path in, so a trailing \" (as in
    # `open("...VERIFICATION.md", "w")`) is not swallowed into the captured path.
    candidates = (
        r"\S*docs/loop-spec/features/(?P<slug>[A-Za-z0-9._-]+)/[^\s'\"\\]+",
        r"\S*\.loop-spec/features/(?P<slug>[A-Za-z0-9._-]+)/[^\s'\"\\]+",
    )
    found = None
    for path_re in candidates:
        for op in ops:
            found = re.search(op.format(p=path_re), command)
            if found:
                break
        if found:
            break
    if found:
        slug = found.group("slug")
        raw_path = found.group("path")[:200]
        candidate_path = raw_path if raw_path.startswith("/") else os.path.join(os.getcwd(), raw_path)
        try:
            if os.path.islink(candidate_path) or os.path.exists(candidate_path):
                resolved = os.path.realpath(candidate_path)
            else:
                parent = os.path.dirname(candidate_path) or "."
                resolved = os.path.join(os.path.realpath(parent), os.path.basename(candidate_path))
        except OSError:
            resolved = candidate_path
        print("candidate %s %s" % (slug, resolved))
PY
)
[[ -n "$VERDICT" ]] || exit 0
if [[ "$VERDICT" == candidate\ * ]]; then
  slug="$(cut -d' ' -f2 <<<"$VERDICT")"; cpath="$(cut -d' ' -f3- <<<"$VERDICT")"
  fd=""
  for root in "${CLAUDE_PROJECT_DIR:-$PWD}" "$PWD"; do
    [[ -f "$root/.loop-spec/features/$slug/feature.json" ]] && { fd="$root/.loop-spec/features/$slug"; break; }
  done
  [[ -n "$fd" ]] || exit 0
  verdict2="$(bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/harness.sh" protected-path --path "$cpath" --feature-dir "$fd" 2>/dev/null)" \
    || verdict2="protected=yes reason=the protected-path probe failed to answer"
  [[ "${verdict2%% *}" == "protected=yes" ]] || exit 0
  reason="${verdict2#*reason=}"
  echo "DENY: '$cpath' writes a driver-owned publication path of feature '$slug' by shell ($reason). Fill it through the driver: cycle-driver.sh spec fill|escalate|footprint drop, verification fill|run|review|verdict --feature-dir $fd, a token-bound feature write (. lib/feature-write.sh; loop_spec_publication_begin <fd>; loop_spec_feature_write set|reconcile-inventory ...), or lib/artifact-publication.sh capture|publish. (Disable: LOOP_SPEC_FORGERY_GUARD=0)" >&2
  exit 2
fi
echo "DENY: '$VERDICT' writes a loop-spec contract file by hand. The terminal result is published only by lib/cycle-result.sh (write, write-terminal) and feature state only by lib/feature-write.sh under a publication token (usage: . lib/feature-write.sh; loop_spec_publication_begin <feature_dir>; loop_spec_feature_write set <feature_dir> <dot.path> '<json-value>' -- strings JSON-quoted, e.g. '\"in-flight\"'; the helper mints the token itself, a lead needs nothing else); a result those writers refuse is a run that has not earned it. Return to the cycle, or publish the honest status with --reason. (Disable: LOOP_SPEC_FORGERY_GUARD=0)" >&2
exit 2
