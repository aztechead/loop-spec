#!/usr/bin/env bash
# pr-body.sh - Render the delivery PR body as concise, well-formed GitHub-flavored
# markdown. Extracted from deliver.sh so formatting policy has one home; also the
# reference for what micro/debug PR bodies should look like (short, GFM, no dumps).
#
# Usage: pr-body.sh render <feature.json> <artifact-root> <output-file>
#
# Contract (the "clear, concise, easy to follow" rules):
#   - Bounded excerpts, never whole artifacts: Summary + Acceptance criteria from the
#     spec, the opening evidence of VERIFICATION.md, the verdict of ITERATION.md.
#   - Artifact headings are demoted to bold text so the body keeps one clean H2
#     hierarchy (an inlined "# Spec" H1 breaks GitHub's rendering outline).
#   - Code fences are balanced per excerpt and after the final cap; a cut never
#     leaves an open ``` block.
#   - Hard cap ~10 KB at a line boundary with an explicit truncation notice. Full
#     evidence stays committed on the branch and is linked in "Full artifacts".
#
# Exit codes: 0 ok; 1 render failure; 2 bad invocation.
set -uo pipefail

cmd="${1:-}"
[[ "$cmd" == "render" ]] || { echo "pr-body.sh: unknown subcommand '${cmd:-}' (usage: pr-body.sh render <feature.json> <artifact-root> <output-file>)" >&2; exit 2; }
shift
[[ $# -eq 3 ]] || { echo "pr-body.sh: render requires <feature.json> <artifact-root> <output-file>" >&2; exit 2; }

python3 - "$1" "$2" "$3" <<'PY'
import json, os, re, sys

feature_path, root, output = sys.argv[1:]
with open(feature_path) as f:
    feature = json.load(f)

HARD_CAP = 10_000  # bytes; concise by construction, this is a backstop


def read_artifact(key):
    path = (feature.get("artifacts") or {}).get(key)
    if not path:
        return None
    if not os.path.isabs(path):
        path = os.path.join(root, path)
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return None


def balance_fences(lines):
    if sum(1 for l in lines if l.startswith("```")) % 2:
        lines.append("```")
    return lines


def sanitize(text, max_lines):
    """Demote headings to bold, bound the line count, keep fences closed."""
    out = []
    for line in text.strip().splitlines():
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        out.append("**%s**" % m.group(2).strip() if m else line)
        if len(out) >= max_lines:
            out = balance_fences(out)
            out.append("")
            out.append("_…truncated; full text in the committed artifact._")
            break
    return "\n".join(balance_fences(out)).strip()


def section(text, names, max_lines):
    """First section whose heading matches a name; else the first content block."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if not m:
            continue
        title = m.group(2).strip().lower()
        if any(title.startswith(n) for n in names):
            level = len(m.group(1))
            body = []
            for nxt in lines[i + 1:]:
                m2 = re.match(r"^(#{1,6})\s+", nxt)
                if m2 and len(m2.group(1)) <= level:
                    break
                body.append(nxt)
            chunk = "\n".join(body).strip()
            if chunk:
                return sanitize(chunk, max_lines)
    # Fallback: first non-heading, non-empty block.
    body, started = [], False
    for line in lines:
        if re.match(r"^#{1,6}\s+", line):
            if started:
                break
            continue
        if line.strip():
            started = True
        if started:
            body.append(line)
    chunk = "\n".join(body).strip()
    return sanitize(chunk, max_lines) if chunk else None


parts = ["**Goal:** " + (feature.get("feature_title") or feature.get("slug", ""))]

spec = read_artifact("spec")
if spec:
    summary = section(spec, ("summary", "overview"), 12)
    if summary:
        parts += ["", "## Summary", "", summary]
    criteria = section(spec, ("acceptance criteria", "acceptance", "done criteria"), 15)
    if criteria and criteria != summary:
        parts += ["", "## Acceptance criteria", "", criteria]

verification = read_artifact("verification")
if verification:
    evidence = section(verification, ("result", "summary", "evidence"), 20)
    if evidence:
        parts += ["", "## Verification", "", evidence]

iteration = read_artifact("iteration")
if iteration:
    verdict = section(iteration, ("verdict", "convergence", "summary"), 10)
    if verdict:
        parts += ["", "## Convergence", "", verdict]

warnings = feature.get("warnings") or []
if warnings:
    parts += ["", "## Shipped with warnings", ""]
    parts += ["- " + str(item) for item in warnings]

artifact_paths = [p for p in (feature.get("artifacts") or {}).values() if p]
if artifact_paths:
    parts += ["", "## Full artifacts", "", "Committed on this branch:"]
    parts += ["- `%s`" % p for p in artifact_paths]

body = "\n".join(parts).strip() + "\n"
if len(body.encode("utf-8")) > HARD_CAP:
    kept, size = [], 0
    for line in body.splitlines():
        size += len(line.encode("utf-8")) + 1
        if size > HARD_CAP - 200:
            break
        kept.append(line)
    kept = balance_fences(kept)
    kept += ["", "_PR body truncated; full evidence is committed on the branch._"]
    body = "\n".join(kept) + "\n"

with open(output, "w") as f:
    f.write(body)
PY
