#!/usr/bin/env bash
# execute-prepare.sh - EXECUTE's pre-dispatch bookkeeping in one call, as one JSON object.
#
# Why: the sonnet eval's two-line fix spent 47 lead Bash calls in EXECUTE, and the first
# dozen were this bookkeeping run one script at a time, each call a turn that re-read the
# whole context (the 2026-09-06 live evals, finding 7). Every step here is
# deterministic and already bundled; this is the one call that runs them in order.
#
# Usage:
#   execute-prepare.sh run --feature-dir DIR
#
# Output (one JSON object):
#   {branch:{ok,expected,actual}, sidecar, sidecarOk, sidecarFlags[], done[], remaining[],
#    tasks[]           the dispatch list: collapsed batches, synthetic blockedBy edges added
#    conflicts:{rows, stops:[{summary,reason,matched}], rulings:[summary]},
#    width, rung:{...lib/execute-rung.sh...}, maxRetries, featureRoot, worktreeBase,
#    workspace:{root, repos:[{name,path}]}|null, greenfield, remediationRegistered,
#    remediationError:string|null, stop:bool, artifactsCommitted:sha|null}
#
# artifactsCommitted (single-repo mode only) is the commit sha when a pending phase
# artifact under docs/loop-spec/features/<slug> was still uncommitted at prepare time
# (a human-gate approval that never landed a commit), null when nothing was pending.
#
# featureRoot is the git toplevel in single mode and the workspace root (orchestration
# only, never a git target) in workspace mode; lib/execute-step.sh resolves each task's
# repo from `workspace` and runs every git call there.
#
# Side effects: pendingRemediationTasks[] are normalized to full shape, appended to the
# sidecar, and acknowledged only after publication; dispatch/conflict-table.json,
# dispatch/tasks-collapsed.json, and dispatch/prepare.json (read by execute-step.sh) are
# written; each
# conflict ruling is recorded with lib/decisions.sh.
#
# Exit: 0 ready to dispatch; 1 not ready (branch mismatch, unreadable sidecar, or a
# stop-class conflict; .stop and the reason are in the JSON); 2 bad invocation;
# 3 dependency cycle (dag-width).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib() { bash "$SCRIPT_DIR/$1.sh" "${@:2}"; }

[[ "${1:-}" == "run" ]] || { echo "usage: execute-prepare.sh run --feature-dir DIR" >&2; exit 2; }
shift
feature_dir=""
while [[ $# -gt 0 ]]; do case "$1" in --feature-dir) feature_dir="${2:-}"; shift 2 || { echo "execute-prepare: $1 needs a value" >&2; exit 2; } ;; *) echo "execute-prepare: unknown argument '$1'" >&2; exit 2 ;; esac; done
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] || { echo "usage: execute-prepare.sh run --feature-dir DIR" >&2; exit 2; }
feature_dir="$(cd "$feature_dir" && pwd -P)"
fj="$feature_dir/feature.json"
fget() { bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" -r --filter "$1"; }

slug="$(fget '.slug')"
workspace="$(fget 'if (.workspace != null and (.workspace.mode // "") != "single") then .workspace else null end')"
# A live workspace run left root empty here, so every task step downstream recorded an
# empty base SHA and ran verify outside the repo. The workspace root owns the feature
# dir, the sidecar, and the runtime file; the task's repo is resolved per task.
if [[ "$workspace" == "null" ]]; then
  root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null)" || { echo "execute-prepare: $feature_dir is not inside a git work tree" >&2; exit 2; }
else
  root="$(fget '.workspace.root')"
  [[ -n "$root" && -d "$root" ]] || { echo "execute-prepare: feature.workspace.root '$root' is not a directory" >&2; exit 2; }
fi

# -- commit pending phase artifacts ------------------------------------------------------
# Single-repo only: in workspace mode the artifacts live at the workspace root, outside
# every repo, so no repo's integrate-task can see them as dirt and there is nothing to
# commit before dispatch.
artifacts_committed=""
if [[ "$workspace" == "null" ]]; then
  # SPEC.md approved at a human gate stayed uncommitted in the feature worktree, and
  # integrate-task refused task-001 as dirty (Codex live run): commit any pending
  # phase artifact before dispatch so the first task starts from a clean base.
  # A commit that fails (no identity, a hook) leaves the same dirty SPEC that blocked
  # integrate-task, so it is this call's failure, never a stale HEAD reported as committed.
  if [[ -n "$(git -C "$root" status --porcelain -- "docs/loop-spec/features/$slug" 2>/dev/null)" ]]; then
    git -C "$root" add -- "docs/loop-spec/features/$slug" \
      && git -C "$root" commit -q -m "docs: loop-spec artifacts before EXECUTE ($slug)" >/dev/null \
      || { echo "execute-prepare: could not commit pending docs/loop-spec/features/$slug artifacts (git exit $?); the first task would start from a dirty base" >&2; exit 2; }
    artifacts_committed="$(git -C "$root" rev-parse HEAD)"
  fi
fi

# -- branch check --------------------------------------------------------------------
branch_json='{"ok":true,"expected":null,"actual":null}'
if [[ "$workspace" == "null" ]]; then
  expected="$(fget '.branch // ""')"; actual="$(git -C "$root" branch --show-current 2>/dev/null || true)"
  ok=true; [[ -z "$expected" || "$expected" == "$actual" ]] || ok=false
  branch_json="$(jq -cn --argjson ok "$ok" --arg e "$expected" --arg a "$actual" '{ok:$ok,expected:$e,actual:$a}')"
else
  branch_json="$(bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" -c --filter '[.workspace.repos[] | {name, path, expected:("feat/" + $slug)}]' -- --arg slug "$slug" \
    | python3 -c '
import json, subprocess, sys
root = sys.argv[1]; repos = json.load(sys.stdin); bad = []
for r in repos:
    actual = subprocess.run(["git", "-C", root + "/" + r["path"], "branch", "--show-current"], capture_output=True, text=True).stdout.strip()
    if actual != r["expected"]: bad.append({"repo": r["name"], "expected": r["expected"], "actual": actual})
print(json.dumps({"ok": not bad, "expected": None, "actual": None, "repos": bad}))' "$root")"
fi

# -- sidecar + remediation intake -------------------------------------------------------
sidecar="$(fget '.artifacts.tasks // ""')"; [[ -n "$sidecar" ]] || sidecar="$feature_dir/tasks.json"
[[ "$sidecar" == /* ]] || sidecar="$root/$sidecar"
sidecar_ok=true; sidecar_flags='[]'
if lint_out="$(lib artifact-lint tasks "$sidecar" 2>&1)"; then :; else
  sidecar_ok=false; sidecar_flags="$(grep '^FLAG' <<<"$lint_out" | jq -R . | jq -cs .)"
fi
remediation_registered=0; remediation_error=null
if [[ "$sidecar_ok" == true ]]; then
  if intake="$(python3 "$SCRIPT_DIR/execute_remediation.py" "$feature_dir" "$sidecar")"; then
    remediation_registered="$(jq -r '.registered' <<<"$intake")"
  else
    remediation_error="$(jq -Rsc 'try (fromjson | .error // "remediation intake failed; retry preparation") catch "remediation intake failed; retry preparation"' <<<"$intake")"
  fi
fi

done_json='[]'; remaining_json='[]'; dispatch='[]'; conflicts='{"rows":0,"stops":[],"rulings":[]}'; width=0; stop=false
[[ "$remediation_error" == null ]] || stop=true
if [[ "$sidecar_ok" == true && "$stop" == false ]]; then
  done_json="$(lib task-progress done "$sidecar" | jq -R . | jq -cs .)"
  remaining_json="$(lib task-progress remaining "$sidecar" | jq -R . | jq -cs .)"
  mkdir -p "$feature_dir/dispatch"
  lib plan-conflicts table "$sidecar" > "$feature_dir/dispatch/conflict-table.json"
  lib task-batch collapse "$sidecar" > "$feature_dir/dispatch/tasks-collapsed.json"
  # Tool versions, probed once here and inlined into every brief (lib/dispatch-files.sh),
  # so implementers stop re-running `tofu version` and friends per seat. Programs are the
  # first word of each verify/prepare/test pipeline segment; shell builtins and coreutils
  # are skipped. Each probe is bounded so an interactive tool cannot hang preparation.
  python3 - "$feature_dir/dispatch/tasks-collapsed.json" <(bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" --all --drop-strays) > "$feature_dir/dispatch/environment.txt" <<'PYENV' || true
import json, os, re, shlex, shutil, subprocess, sys
tasks = json.load(open(sys.argv[1])); feature = json.load(open(sys.argv[2]))
cmds = [t.get("verifyCommand") or "" for t in tasks if isinstance(t, dict)]
cmds += [v for v in (feature.get("commands") or {}).values() if isinstance(v, str)]
skip = {"true", "false", "test", "[", "[[", "cd", "echo", "printf", "cat", "head", "tail", "sed", "awk", "wc",
        "sort", "uniq", "ls", "stat", "cut", "tr", "find", "xargs", "cmp", "diff", "grep", "egrep", "fgrep", "env", "!"}
names = []
for cmd in cmds:
    # Split outside quotes: a `|` inside a grep pattern is one argument. The first cut of
    # this probe ran /usr/bin/apply --version because "apply" sat inside a quoted regex.
    lex = shlex.shlex(cmd, posix=True, punctuation_chars="|&;()"); lex.whitespace_split = True
    try:
        toks = list(lex)
    except ValueError:
        continue
    at_start = True
    for tok in toks:
        if tok in ("|", "||", "&&", ";", "(", ")"):
            at_start = True; continue
        if at_start:
            if tok in ("!", "env") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tok):
                continue
            at_start = False
            if re.match(r"^[A-Za-z0-9_.+-]+$", tok) and tok not in skip and tok not in names:
                names.append(tok)
for name in names:
    if not shutil.which(name):
        print("%s: not on PATH" % name); continue
    line = ""
    for flag in ("--version", "version"):
        try:
            out = subprocess.run([name, flag], capture_output=True, text=True, timeout=5, stdin=subprocess.DEVNULL)
        except (OSError, subprocess.TimeoutExpired):
            continue
        text = (out.stdout or out.stderr or "").strip().splitlines()
        if out.returncode == 0 and text:
            line = text[0].strip(); break
    print("%s: %s" % (name, line or "present (no version output)"))
PYENV
  excludes="$(fget '(.fileConflictExcludeGlobs // []) | join("\n")')"
  [[ -f "$root/.loop-spec/file-conflict-exclude.txt" ]] && excludes="$excludes
$(cat "$root/.loop-spec/file-conflict-exclude.txt")"
  # Pending tasks whose files overlap get a synthetic edge, lower id first, unless every
  # overlapping file matches an exclusion glob or the planner already declared the reverse
  # edge. Done tasks fall out of the dispatch list and out of every blockedBy so the width
  # is measured over what is left.
  dispatch="$(EXCLUDES="$excludes" python3 - "$feature_dir/dispatch/tasks-collapsed.json" "$done_json" <<'PY'
import fnmatch, json, os, sys
tasks = json.load(open(sys.argv[1])); done = set(json.loads(sys.argv[2]))
globs = [g.strip() for g in os.environ.get("EXCLUDES", "").splitlines() if g.strip()]
pending = [t for t in tasks if t.get("id") not in done]
for t in pending:
    t["blockedBy"] = [b for b in (t.get("blockedBy") or []) if b not in done]
def excluded(path): return any(fnmatch.fnmatch(path, g) for g in globs)
ordered = sorted(pending, key=lambda t: str(t.get("id")))
for i, a in enumerate(ordered):
    for b in ordered[i + 1:]:
        shared = [f for f in (a.get("files") or []) if f in (b.get("files") or []) and not excluded(f)]
        # A planner-declared edge wins over a synthetic one: adding both directions makes a
        # 2-cycle that dag-width refuses to dispatch (the 6.6.1 live run had to renumber 29 tasks
        # by hand to work around it).
        if shared and a["id"] not in b["blockedBy"] and b["id"] not in a["blockedBy"]:
            b["blockedBy"].append(a["id"]); b.setdefault("syntheticBlockedBy", []).append(a["id"])
print(json.dumps(pending))
PY
)"
  # Conflict rows: a stop-class row ends preparation; every other row is a recorded ruling.
  conflicts="$(python3 - "$feature_dir/dispatch/conflict-table.json" "$SCRIPT_DIR" "$feature_dir" <<'PY'
import json, subprocess, sys
table = json.load(open(sys.argv[1])); libdir, fd = sys.argv[2], sys.argv[3]
stops, rulings = [], []
rows = list(table.get("pairs") or []) + list(table.get("interfaces") or [])
for row in rows:
    if "a" in row: summary = "%s and %s share %s" % (row.get("a"), row.get("b"), ", ".join(row.get("files") or []))
    else: summary = "%s: %s" % (row.get("task"), row.get("problem"))
    out = subprocess.run(["bash", libdir + "/execute-stop.sh", "classify", summary], capture_output=True, text=True).stdout.strip()
    fields = dict(p.split("=", 1) for p in out.split() if "=" in p)
    if fields.get("stop") == "true":
        stops.append({"summary": summary, "reason": fields.get("reason"), "matched": fields.get("matched")})
    else:
        rulings.append(summary)
        if "a" in row:
            answer, why = "serialized by a synthetic blockedBy edge", "reversible file overlap; execute-stop.sh ruled continue"
        else:
            answer, why = "dispatched as planned; the interface is prose, not a contract another task produces", "interface row without a producer; execute-stop.sh ruled continue"
        subprocess.run(["bash", libdir + "/decisions.sh", "add", fd, "execute", summary, answer, why, "ruling"],
                       capture_output=True, text=True)
print(json.dumps({"rows": len(rows), "stops": stops, "rulings": rulings}))
PY
)"
  [[ "$(jq '.stops | length' <<<"$conflicts")" == "0" ]] || stop=true
  width_rc=0; width="$(printf '%s' "$dispatch" | lib dag-width)" || width_rc=$?
  if (( width_rc == 3 )); then
    jq -cn --argjson b "$branch_json" --arg s "$sidecar" '{branch:$b, sidecar:$s, stop:true, reason:"dependency cycle"}'; exit 3
  fi
fi

# -- rung, caps, roots -------------------------------------------------------------------
runtime="$root/.loop-spec/runtime.json"
rung='{}'
if [[ "$workspace" == "null" ]]; then
  rung="$(lib execute-rung select --width "${width:-0}" \
    --teams-mode "$(jq -r '.teamsMode // "none"' "$runtime" 2>/dev/null || echo none)" \
    --workflows-available "$(jq -r '.workflowsAvailable // false' "$runtime" 2>/dev/null || echo false)" \
    --workflow-optin "$(jq -r '.workflowExecuteOptIn // false' "$runtime" 2>/dev/null || echo false)" \
    --implementer-model "$(fget '.models.implementer // "inherit"')")" || { echo "execute-prepare: rung selection failed" >&2; exit 2; }
else
  rung='{"rung":"subagent","reason":"workspace mode always dispatches one-shot subagents","worktreesEnabled":false,"subagentIsolation":"none"}'
fi
max_retries="$(lib tuning get executeMaxRetriesPerTask 6 2>/dev/null || echo 6)"
worktree_base=""
if [[ "$workspace" == "null" && "$(jq -r '.worktreesEnabled // false' <<<"$rung")" == "true" ]]; then
  worktree_base="$(lib worktree-base resolve "$root" task "$slug" | jq -r '.path')"
fi
greenfield="$(fget '.greenfield // false')"
workspace_json=null
[[ "$workspace" == "null" ]] || workspace_json="$(bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" -c --filter '{root:.workspace.root, repos:[.workspace.repos[] | {name, path}]}')"

mkdir -p "$feature_dir/dispatch"
answer="$(jq -cn --argjson b "$branch_json" --arg sidecar "$sidecar" --argjson sok "$sidecar_ok" --argjson sflags "$sidecar_flags" \
  --argjson done "$done_json" --argjson remaining "$remaining_json" --argjson tasks "$dispatch" \
  --argjson conflicts "$conflicts" --argjson width "${width:-0}" --argjson rung "$rung" --argjson retries "$max_retries" \
  --arg root "$root" --arg wtb "$worktree_base" --argjson ws "$workspace_json" --argjson gf "$greenfield" --argjson reg "$remediation_registered" --argjson error "$remediation_error" --argjson stop "$stop" \
  --arg ac "$artifacts_committed" \
  '{branch:$b, sidecar:$sidecar, sidecarOk:$sok, sidecarFlags:$sflags, done:$done, remaining:$remaining, tasks:$tasks,
    conflicts:$conflicts, width:$width, rung:$rung, maxRetries:$retries, featureRoot:$root,
    worktreeBase:(if $wtb == "" then null else $wtb end), workspace:$ws, greenfield:$gf, remediationRegistered:$reg, remediationError:$error, stop:$stop,
    artifactsCommitted:(if $ac == "" then null else $ac end)}')"
# lib/execute-step.sh reads the rung and roots from here per task instead of re-measuring.
printf '%s\n' "$answer" > "$feature_dir/dispatch/prepare.json"
printf '%s\n' "$answer"
if [[ "$(jq -r '.ok' <<<"$branch_json")" != "true" || "$sidecar_ok" != true || "$stop" == true ]]; then exit 1; fi
exit 0
