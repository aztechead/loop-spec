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
#   - SPEC frontmatter never leaks raw: ambiguity_scores decimals are re-rendered as
#     a "Spec quality" percentage table (score + gate + pass mark per dimension);
#     the YAML block itself is stripped before excerpting.
#   - Artifact headings are demoted to bold text so the body keeps one clean H2
#     hierarchy (an inlined "# Spec" H1 breaks GitHub's rendering outline).
#   - Code fences are balanced per excerpt and after the final cap; a cut never
#     leaves an open ``` block.
#   - Hard cap ~10 KB at a line boundary with an explicit truncation notice. The
#     run-details block links committed evidence or records that an external store owns it.
#
# Exit codes: 0 ok; 1 render failure; 2 bad invocation.
set -uo pipefail

cmd="${1:-}"
[[ "$cmd" == "render" ]] || { echo "pr-body.sh: unknown subcommand '${cmd:-}' (usage: pr-body.sh render <feature.json> <artifact-root> <output-file>)" >&2; exit 2; }
shift
[[ $# -eq 3 ]] || { echo "pr-body.sh: render requires <feature.json> <artifact-root> <output-file>" >&2; exit 2; }
case "${LOOP_SPEC_PR_BODY_VERBOSE:-0}" in 0|1) ;; *)
  echo "pr-body.sh: LOOP_SPEC_PR_BODY_VERBOSE must be 0 or 1" >&2; exit 2;; esac
case "${LOOP_SPEC_ARTIFACTS_IN_PR:-1}" in 0|1) ;; *)
  echo "pr-body.sh: LOOP_SPEC_ARTIFACTS_IN_PR must be 0 or 1" >&2; exit 2;; esac

python3 - "$1" "$2" "$3" <<'PY'
import json, os, re, subprocess, sys

feature_path, root, output = sys.argv[1:]
with open(feature_path) as f:
    feature = json.load(f)

HARD_CAP = 10_000  # bytes; concise by construction, this is a backstop
REVIEW_ORDER_MAX_LINES = 30  # ~5 concerns of stops; the full trail is on the branch
VERBOSE = os.environ.get("LOOP_SPEC_PR_BODY_VERBOSE", "0") == "1"
ARTIFACTS_IN_PR = os.environ.get("LOOP_SPEC_ARTIFACTS_IN_PR", "1") == "1"


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


# `artifacts` mixes reader-facing artifact paths with provenance and runtime state
# (for example, patternsSource = "pattern-mapper").
# A PR body is a public, committed-file index, not a serialization of that internal
# object. Keep the allow-list deliberately small and prove each entry resolves to a
# tracked regular file in this repository before calling it "committed".
PUBLIC_ARTIFACT_KEYS = (
    "spec", "patterns", "plan", "execution", "verification", "iteration",
    "reviewOrder",
)


def committed_artifact_paths():
    paths = []
    artifacts = feature.get("artifacts") or {}
    for key in PUBLIC_ARTIFACT_KEYS:
        value = artifacts.get(key)
        if not isinstance(value, str) or not value.strip():
            continue
        path = value.strip()
        normalized = os.path.normpath(path)
        if os.path.isabs(path) or normalized == ".." or normalized.startswith(".." + os.sep):
            continue
        full_path = os.path.join(root, normalized)
        if not os.path.isfile(full_path):
            continue
        tracked = subprocess.run(
            ["git", "-C", root, "ls-files", "--error-unmatch", "--", normalized],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ).returncode == 0
        if tracked and normalized not in paths:
            paths.append(normalized)
    return paths


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
            out.append("_…truncated; full text remains in the run artifact._")
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


def split_frontmatter(text):
    """Separate a leading YAML frontmatter block from the document body.

    The raw block must never reach the rendered body (bare decimals convey
    nothing to a PR reviewer); the scores inside it are re-rendered as a
    percentage table by spec_quality_table().
    """
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None, text
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return "\n".join(lines[1:i]), "\n".join(lines[i + 1:])
    return None, text


def spec_quality_table(frontmatter):
    """Render ambiguity_scores as a GFM table in percentages.

    Clarity dimensions read "higher is better"; the composite ambiguity reads
    "lower is better" — each row shows its own gate so the numbers carry
    meaning without knowing the formula.
    """
    if not frontmatter:
        return None
    scores = {}
    in_block = False
    for line in frontmatter.splitlines():
        if re.match(r"^ambiguity_scores:\s*$", line):
            in_block = True
            continue
        if in_block:
            m = re.match(r"^\s+([a-z_]+):\s*([\d.]+|true|false|\[.*\])\s*$", line)
            if not m:
                if line.strip() and not line.startswith((" ", "\t")):
                    in_block = False
                continue
            scores[m.group(1)] = m.group(2)
    if "ambiguity" not in scores:
        return None

    def pct(key):
        try:
            return "%d%%" % round(float(scores[key]) * 100)
        except (KeyError, ValueError):
            return None

    # Dimension label, score key, gate (from skills/spec/SKILL.md).
    dims = [
        ("Goal clarity", "goal_clarity", ">= 60%", 0.60, False),
        ("Boundary clarity", "boundary_clarity", ">= 50%", 0.50, False),
        ("Constraint clarity", "constraint_clarity", ">= 40%", 0.40, False),
        ("Acceptance clarity", "acceptance_clarity", ">= 50%", 0.50, False),
        ("**Ambiguity (overall)**", "ambiguity", "<= 20%", 0.20, True),
    ]
    rows = ["| Dimension | Score | Gate | |", "|---|---|---|---|"]
    for label, key, gate, threshold, lower_is_better in dims:
        value = pct(key)
        if value is None:
            continue
        try:
            ok = (float(scores[key]) <= threshold) if lower_is_better \
                else (float(scores[key]) >= threshold)
        except ValueError:
            ok = False
        score_cell = "**%s**" % value if key == "ambiguity" else value
        rows.append("| %s | %s | %s | %s |" % (label, score_cell, gate, "✅" if ok else "❌"))
    if len(rows) == 2:
        return None
    gate_passed = scores.get("gate_passed") == "true"
    rounds = scores.get("rounds_completed")
    note = "Gate %s" % ("passed" if gate_passed else "**not passed**")
    if rounds is not None:
        note += " after %s interview round(s)." % rounds
    else:
        note += "."
    return "\n".join(rows) + "\n\n" + note


parts = ["**Goal:** " + (feature.get("feature_title") or feature.get("slug", ""))]
run_details = []

spec = read_artifact("spec")
quality = None
if spec:
    frontmatter, spec = split_frontmatter(spec)
    quality = spec_quality_table(frontmatter)
    summary = section(spec, ("summary", "overview"), 12)
    if summary:
        parts += ["", "## Summary", "", summary]
    criteria = section(spec, ("acceptance criteria", "acceptance", "done criteria"), 15)
    if criteria and criteria != summary:
        parts += ["", "## Acceptance criteria", "", criteria]
    if quality:
        run_details.append(("Spec quality", quality))

# The trail earns its place above the evidence sections: a reviewer needs the
# reading order before the proof, because the proof is what they are checking.
review_order = read_artifact("reviewOrder")
if review_order:
    stops = [line for line in review_order.splitlines() if not line.startswith("# ")]
    while stops and not stops[0].strip():
        stops.pop(0)
    if stops:
        parts += ["", "## Suggested review order", ""]
        parts += stops[:REVIEW_ORDER_MAX_LINES]
        if len(stops) > REVIEW_ORDER_MAX_LINES:
            parts += ["", "_Trail truncated; the full order is committed on the branch._"]

verification = read_artifact("verification")
if verification:
    evidence = section(verification, ("result", "summary", "evidence"), 20)
    if evidence:
        parts += ["", "## Verification", "", evidence]

iteration = read_artifact("iteration")
if iteration:
    verdict = section(iteration, ("verdict", "convergence", "summary"), 10)
    if verdict:
        run_details.append(("Convergence", verdict))

warnings = feature.get("warnings") or []
if warnings:
    # GFM alert so the warnings read as a visual callout, not a plain list.
    parts += ["", "## Shipped with warnings", "", "> [!WARNING]"]
    parts += ["> - " + str(item) for item in warnings]

artifact_paths = committed_artifact_paths()
if artifact_paths and ARTIFACTS_IN_PR:
    run_details.append(("Full artifacts", "Committed on this branch:\n" +
                        "\n".join("- `%s`" % p for p in artifact_paths)))
elif not ARTIFACTS_IN_PR:
    run_details.append(("Artifact audit trail",
                        "Stored outside the PR by `LOOP_SPEC_ARTIFACTS_IN_PR=0`."))

if run_details:
    if VERBOSE:
        for title, content in run_details:
            parts += ["", "## " + title, "", content]
    else:
        parts += ["", "<details>", "<summary>Run details</summary>", ""]
        for title, content in run_details:
            parts += ["### " + title, "", content, ""]
        parts += ["</details>"]

body = "\n".join(parts).strip() + "\n"
if len(body.encode("utf-8")) > HARD_CAP:
    kept, size = [], 0
    for line in body.splitlines():
        size += len(line.encode("utf-8")) + 1
        if size > HARD_CAP - 200:
            break
        kept.append(line)
    kept = balance_fences(kept)
    location = "committed on the branch" if ARTIFACTS_IN_PR else "available in the external artifact store"
    kept += ["", "_PR body truncated; full evidence is %s._" % location]
    body = "\n".join(kept) + "\n"

with open(output, "w") as f:
    f.write(body)
PY
