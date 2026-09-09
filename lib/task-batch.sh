#!/usr/bin/env bash
# task-batch.sh - Shape PLAN tasks for dispatch: collapse batches, merge trivial chains, tier the mechanical ones.
#
# Why: twenty identical one-line edits should not cost twenty implementer
# seats. Superpowers v6.3.0 batches small same-shape work. Fail-closed: no
# batchGroup, a blockedBy edge out of the group, an outside task waiting on a
# member the collapse would erase, or overlapping files keeps today's
# one-task-one-dispatch.
#
# A live run (the 2026-09-07 tf-meldn runs) planned eleven tasks for a
# 38-file change and paid two subagent seats each, most of them a one-file edit
# verified by grep. Two more deterministic shapes fix that without a planner
# judgment: a LINEAR CHAIN of tasks whose verify commands only read local files
# (grep/test/jq/diff, never plan/apply/a test runner/the network) merges into its
# head, verifies joined with &&, up to LOOP_SPEC_TASK_BATCH_CHAIN_FILES files
# (default 6; `terragrunt hcl format` and `tofu fmt` count as local); and a task whose files are all doc/config extensions and whose
# verify is local gets `metadata.modelTier: mechanical` when no tier or pin is set,
# so lib/model-tier.sh routes it to the cheapest model. An explicit batchGroup,
# tier, or model pin always wins. LOOP_SPEC_TASK_BATCH_AUTO=0 keeps only the
# batchGroup collapse.
#
# Usage:
#   task-batch.sh collapse <tasks.json>
#
# Output: a JSON array. Ungrouped tasks pass through. A collapsed group or merged
# chain is one object with the first member's id, unioned files, memberIds[], and
# the verifyCommand. Reviewers assert every listed file appears in the diff;
# lib/execute-step.sh marks every memberId done on integrate.
#
# Exit: 0 success, 2 usage / unreadable JSON.
set -euo pipefail

[[ "${1:-}" == "collapse" && $# -eq 2 ]] || { echo "usage: task-batch.sh collapse <tasks.json>" >&2; exit 2; }
file="$2"
[[ -f "$file" ]] || { echo "task-batch.sh: no such file $file" >&2; exit 2; }

python3 - "$file" <<'PY'
from __future__ import print_function
import json, os, re, shlex, sys

path = sys.argv[1]
auto = os.environ.get("LOOP_SPEC_TASK_BATCH_AUTO", "1") != "0"
try:
    chain_files = int(os.environ.get("LOOP_SPEC_TASK_BATCH_CHAIN_FILES", "6"))
except ValueError:
    chain_files = 6

# Local means every pipeline segment starts with a program that only reads the
# checkout. Anything else (a test runner, plan, apply, curl) is a real run whose
# cost and side effects justify its own seat.
LOCAL_PROGRAMS = {"grep", "egrep", "fgrep", "test", "[", "[[", "jq", "diff", "cmp", "cat",
                  "head", "tail", "sed", "awk", "wc", "sort", "uniq", "ls", "stat", "true",
                  "false", "echo", "printf", "cd", "cut", "tr", "find", "xargs", "python3", "bash"}
CONFIG_EXT = {"md", "txt", "rst", "hcl", "tf", "tfvars", "json", "yaml", "yml", "toml", "ini",
              "cfg", "conf", "env", "example", "gitignore", "editorconfig", "gitattributes"}


# Formatters and syntax checks of the IaC tools read the checkout only; every other
# subcommand of theirs (init, validate, plan) reaches a registry or a backend.
LOCAL_SUBCOMMANDS = {("terragrunt", "hcl"), ("terragrunt", "hclfmt"), ("tofu", "fmt"), ("terraform", "fmt")}


def segments(cmd):
    """Pipeline segments split on |, ||, &&, ; OUTSIDE quotes; a quoted `a|b` in a grep
    pattern is one argument, not two programs (the live run's verifies were full of them)."""
    lex = shlex.shlex(cmd, posix=True, punctuation_chars="|&;()")
    lex.whitespace_split = True
    segs, cur = [], []
    try:
        for tok in lex:
            if tok in ("|", "||", "&&", ";", "(", ")"):
                if cur:
                    segs.append(cur)
                cur = []
            else:
                cur.append(tok)
    except ValueError:
        return None
    if cur:
        segs.append(cur)
    return segs


def is_local(cmd):
    cmd = (cmd or "").strip()
    if not cmd:
        return False
    segs = segments(cmd)
    if segs is None:
        return False
    for words in segs:
        while words and (words[0] in ("!", "env") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0])):
            words = words[1:]
        if not words:
            return False
        prog = os.path.basename(words[0])
        if len(words) > 1 and (prog, words[1]) in LOCAL_SUBCOMMANDS:
            continue
        if prog not in LOCAL_PROGRAMS:
            return False
        # `bash x.sh` / `python3 x.py` run the repo's own code, which is a real run.
        # Only a syntax check (-n) or an inline -c body that names no other program
        # stays local.
        if prog in ("bash", "python3"):
            if "-n" in words[1:2]:
                continue
            if "-c" not in words:
                return False
            body = " ".join(words[words.index("-c") + 1:])
            if re.search(r"\b(?:npm|pnpm|yarn|pytest|go|cargo|make|terragrunt|terraform|tofu|gcloud|aws|az|kubectl|curl|wget|docker)\b", body):
                return False
    return True


def is_config_only(t):
    files = files_of(t)
    if not files:
        return False
    for f in files:
        name = os.path.basename(f)
        ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
        if ext not in CONFIG_EXT:
            return False
    return True
try:
    tasks = json.load(open(path))
except (OSError, ValueError) as exc:
    sys.stderr.write("task-batch.sh: %s\n" % exc)
    sys.exit(2)
if not isinstance(tasks, list):
    sys.stderr.write("task-batch.sh: tasks must be a JSON array\n")
    sys.exit(2)

def files_of(t):
    return list(t.get("files") or [])


def pinned(t):
    meta = t.get("metadata") if isinstance(t.get("metadata"), dict) else {}
    return bool(meta.get("modelTier") or meta.get("model") or t.get("modelTier") or t.get("model"))


def merge_chain(tasks):
    """Fold B into A when B waits only on A, nothing else waits on A, both verifies
    are local, neither carries a batchGroup, and the union stays under the cap."""
    by_id = {t.get("id"): t for t in tasks if isinstance(t, dict)}
    dependents = {}
    for t in by_id.values():
        for dep in (t.get("blockedBy") or []):
            dependents.setdefault(dep, []).append(t.get("id"))
    merged_into = {}
    for head in list(tasks):
        if not isinstance(head, dict) or head.get("id") in merged_into:
            continue
        while True:
            nexts = dependents.get(head.get("id"), [])
            if len(nexts) != 1:
                break
            tail = by_id.get(nexts[0])
            if tail is None or tail.get("batchGroup") or head.get("batchGroup"):
                break
            # A pin or tier on either side is a planner decision the merge would erase.
            if pinned(tail) or pinned(head):
                break
            if list(tail.get("blockedBy") or []) != [head.get("id")]:
                break
            if not (is_local(head.get("verifyCommand")) and is_local(tail.get("verifyCommand"))):
                break
            union = files_of(head) + [f for f in files_of(tail) if f not in files_of(head)]
            if len(union) > chain_files:
                break
            head["files"] = union
            head.setdefault("memberIds", [head.get("id")]).append(tail.get("id"))
            head["verifyCommand"] = "(%s) && (%s)" % (head["verifyCommand"], tail.get("verifyCommand"))
            head["acceptanceCriteria"] = list(head.get("acceptanceCriteria") or []) + list(tail.get("acceptanceCriteria") or [])
            head["brief"] = (head.get("brief") or head.get("subject") or "") + \
                "\n\nThen %s (%s): %s" % (tail.get("id"), tail.get("subject") or "", tail.get("brief") or tail.get("subject") or "")
            merged_into[tail.get("id")] = head.get("id")
            dependents[head.get("id")] = dependents.get(tail.get("id"), [])
            # Whatever waited on the tail now waits on the surviving head.
            for t in by_id.values():
                t["blockedBy"] = [head.get("id") if b == tail.get("id") else b for b in (t.get("blockedBy") or [])]
    return [t for t in tasks if not (isinstance(t, dict) and t.get("id") in merged_into)]


def tier_mechanical(tasks):
    for t in tasks:
        if not isinstance(t, dict):
            continue
        if pinned(t):
            continue
        if is_config_only(t) and is_local(t.get("verifyCommand")):
            meta = dict(t.get("metadata") if isinstance(t.get("metadata"), dict) else {})
            meta["modelTier"] = "mechanical"; t["metadata"] = meta
    return tasks


if auto:
    tasks = tier_mechanical(merge_chain(tasks))

groups = {}
for t in tasks:
    if not isinstance(t, dict):
        continue
    key = t.get("batchGroup")
    if isinstance(key, str) and key.strip():
        groups.setdefault(key, []).append(t)

collapsible = {}
for key, members in groups.items():
    if len(members) < 2:
        continue
    ids = [m.get("id") for m in members]
    member_ids = set(ids)
    vcs = {(m.get("verifyCommand") or "").strip() for m in members}
    if len(vcs) != 1 or not next(iter(vcs)):
        continue
    blocked = False
    for m in members:
        for dep in (m.get("blockedBy") or []):
            if dep not in member_ids:
                blocked = True
    if blocked:
        continue
    seen = []
    overlap = False
    for m in members:
        for f in files_of(m):
            if f in seen:
                overlap = True
            seen.append(f)
    if overlap:
        continue
    # Collapse erases every member id but the first. A task outside the group that
    # waits on an erased id would wait forever (the DAG calls that a deadlock), so
    # an inbound edge to a non-surviving member keeps one-task-one-dispatch.
    erased = member_ids - {ids[0]}
    inbound = False
    for t in tasks:
        if not isinstance(t, dict) or t.get("id") in member_ids:
            continue
        if erased & set(t.get("blockedBy") or []):
            inbound = True
    if inbound:
        continue
    first = dict(members[0])
    first["files"] = seen
    first["memberIds"] = ids
    first["brief"] = (first.get("brief") or first.get("subject") or "") + \
        "\n\nBatch %s: apply the same change to every listed file." % key
    collapsible[key] = first

emitted = set()
out = []
for t in tasks:
    if not isinstance(t, dict):
        out.append(t)
        continue
    key = t.get("batchGroup")
    if isinstance(key, str) and key in collapsible:
        if key not in emitted:
            out.append(collapsible[key])
            emitted.add(key)
        continue
    out.append(t)

print(json.dumps(out, indent=2))
PY
