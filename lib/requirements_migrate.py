#!/usr/bin/env python3
"""Convert an incomplete legacy cycle to the v1 requirements contract, read-only.

Purpose: `preview` inspects a feature directory whose requirementsContract is
"legacy" or absent and prints one canonical JSON candidate -- proposed v1 SPEC
text, proposed PLAN text, proposed requirementsContract and artifactPublication
changes -- without writing anything. `status` reports the feature's current
migration marker and journal read-only. `apply`, `resume` and `rollback` are
task-011's job; here they only fix the CLI contract (see "Future commands"
below) and refuse with exit 2.

Commands:
  requirements-migrate.sh preview --feature-dir DIR
  requirements-migrate.sh status  --feature-dir DIR
  requirements-migrate.sh apply|resume|rollback --feature-dir DIR ...  (not yet)

Preview JSON schema (sorted keys, no timestamps, no absolute paths):
  {
    "historical": {"verification": {"path": str, "sha256": str} | null,
                   "note": str},
    "id": str (a deterministic uuid5, stable across repeated preview calls
               against the same inputs -- never a fresh random uuid, so two
               preview runs against unchanged sources compare identical),
    "owner": {"repository": str, "feature": str},
    "proposedArtifactPublication": {
       "evidenceEpoch": int,           # current + 1
       "migration": {"id": str, "previewDigest": null, "phase": "staged",
                     "originalGeneration": int, "publishedHashes": {}}
       # previewDigest stays null here: apply fills it in with the digest of
       # the exact preview file the operator approved (this object's own
       # "previewDigest" below), which cannot be embedded in the object being
       # hashed to produce it.
    },
    "proposedPlan": {"text": str, "unresolved": [{"file", "line", "criterion",
                                                   "tasks", "reason"}, ...]},
    "proposedRequirementsContract": {...output of reconcile_inventory...},
    "proposedSpec": {"text": str},
    "sources": {"SPEC.md": sha256|null, "PLAN.md": sha256|null,
                "tasks.json": sha256|null, "feature-state.slug": sha256, ...},
    "previewDigest": sha256 of the object above (every other key), canonical
                     JSON, sorted keys, separators (",", ":")
  }

Journal/receipt schema apply/resume/rollback will use (task-011; fixed now so
the CLI contract in the plan does not change under it):
  Durable transaction state lives at
  `migration-generations/<transaction-id>/` inside feature state, mirroring
  lib/artifact_publication.py's publication-generations journal one level up:
    marker.json    -- {"version":1,"id":str,"previewDigest":str,"phase":
                       "staged"|"replaced"|"published"|"committed",
                       "originalGeneration":int,"publishedHashes":{path:sha256}}
                       Published into feature.json's artifactPublication.migration
                       as soon as it is durable (SPEC "Migration preserves
                       originals"); phase advances left-to-right and never back.
    <n>/original   -- exact pre-migration bytes of the n-th replaced artifact
                       (SPEC.md, PLAN.md, feature.json), 0400, one per entry,
                       named the same way as publication-generations/<txn>/<n>.
    receipt.json   -- written last, once phase == "committed":
                       {"version":1,"id":str,"previewDigest":str,
                        "requirementsContractDigest":sha256,
                        "publishedHashes":{path:sha256},
                        "completedGeneration":int}
  resume reads marker.json's phase and expected hashes and finishes the same
  transaction without reallocating IDs; rollback restores the <n>/original
  bytes only when the current artifact still hashes to publishedHashes[path],
  then increments generation and clears artifactPublication.migration. Neither
  command fabricates historical observations or touches specApproval.

Exit codes: 0 success (preview or status JSON on stdout); 1 refusal with a
file/line or field diagnostic on stderr (no repository file is ever written on
this path); 2 bad invocation, or apply/resume/rollback (not implemented in
this revision).

Limits: SPEC.md and PLAN.md are each refused above requirements.MAX_BYTES (16
MiB), checked by file size before any byte is read or hashed. File hashing
streams in 64 KiB chunks (see `stream_digest`).
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import uuid

from requirements import MAX_BYTES, digest, initialize_contract, parse_spec, reconcile_inventory, valid_id, validate_state
from spec_intent import intent_digest

SUPPORTED_PARTICIPANTS_VERSION = 1
# Fixed namespace for every deterministic id this module derives; a preview run
# never mints a fresh random uuid, or two previews of the same inputs would
# disagree (task-010 acceptance: preview twice gives identical JSON/digest).
NAMESPACE = uuid.UUID("6f7c9a2e-3b1d-4b7a-9f4a-9c1b8d6e2a11")


def stream_digest(path):
    """sha256 of a file's bytes, read in 64 KiB chunks; None if it does not exist."""
    if not path.exists():
        return None
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            result.update(chunk)
    return result.hexdigest()


def refuse_oversized(path, source):
    if path.exists() and path.stat().st_size > MAX_BYTES:
        raise ValueError("%s:1: exceeds 16 MiB migration source limit" % source)


def load_raw_state(feature_dir):
    path = feature_dir / "feature.json"
    try:
        with path.open("r", encoding="utf-8") as stream:
            state = json.load(stream)
    except (OSError, ValueError) as exc:
        raise ValueError("%s: cannot read feature state: %s" % (path, exc))
    if not isinstance(state, dict):
        raise ValueError("%s: feature state must be a JSON object" % path)
    return state


def refuse_unmigratable(state, feature_dir):
    """Every check task-010 must run before any digest is computed."""
    if state.get("currentPhase") == "completed":
        raise ValueError("feature-dir %s: migration refuses a completed cycle" % feature_dir)
    publication = state.get("artifactPublication")
    if publication is not None:
        participants = publication.get("participantsVersion")
        if not isinstance(participants, int) or participants > SUPPORTED_PARTICIPANTS_VERSION:
            raise ValueError("feature-dir %s: unsupported participant (artifactPublication.participantsVersion=%r)"
                              % (feature_dir, participants))
    try:
        validate_state(state)
    except ValueError as exc:
        raise ValueError("feature-dir %s: malformed feature state: %s" % (feature_dir, exc))
    contract = state.get("requirementsContract")
    if contract is not None and contract.get("format") == "v1":
        raise ValueError("feature-dir %s: requirementsContract is already v1; nothing to migrate" % feature_dir)


NORM_RE = re.compile(r"\s+")


def norm(text):
    return NORM_RE.sub(" ", text.strip())


FRONTMATTER_KEY = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):[ \t]*(.*)$")
HEADING = re.compile(r"^(#{1,6})[ \t]+(.+?)\s*$")
CRITERION = re.compile(r"^-\s*\[[ xX]\]\s*(\S.*)$")
BACKTICK = re.compile(r"`([^`]+)`")


def scan_legacy_spec(text, source):
    """Extract legacy Good Enough criteria; refuse every unsupported shape by
    file/line before any candidate is built. Returns (frontmatter_end_line,
    frontmatter_lines, criteria_map, criteria) where criteria is an ordered
    list of {"text", "line", "command"}."""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    start = 0
    criteria_map = {}
    if lines and lines[0] == "---":
        try:
            start = lines.index("---", 1) + 1
        except ValueError:
            raise ValueError("%s:1: unclosed frontmatter" % source)
        seen = set()
        index = 1
        while index < start - 1:
            match = FRONTMATTER_KEY.match(lines[index])
            if match:
                key, value = match.groups()
                if key in seen:
                    raise ValueError("%s:%d: duplicate frontmatter key %s" % (source, index + 1, key))
                seen.add(key)
                if key == "requirements_version":
                    raise ValueError("%s:%d: SPEC already declares requirements_version; not a legacy candidate"
                                      % (source, index + 1))
                if key == "criteria":
                    try:
                        parsed = json.loads(value)
                    except ValueError as exc:
                        raise ValueError("%s:%d: malformed criteria map: %s" % (source, index + 1, exc))
                    if not isinstance(parsed, dict):
                        raise ValueError("%s:%d: criteria map must be a JSON object" % (source, index + 1))
                    criteria_map = {norm(k): v for k, v in parsed.items()}
            index += 1
    good_enough_lines = [i for i in range(start, len(lines))
                         if HEADING.match(lines[i]) and HEADING.match(lines[i]).group(2) == "Good Enough"]
    if not good_enough_lines:
        raise ValueError("%s:1: SPEC has no '### Good Enough' section to migrate" % source)
    if len(good_enough_lines) > 1:
        raise ValueError("%s:%d: duplicate Good Enough section" % (source, good_enough_lines[1] + 1))
    block_start = good_enough_lines[0] + 1
    block_end = len(lines)
    for i in range(block_start, len(lines)):
        if HEADING.match(lines[i]):
            block_end = i
            break
    criteria = []
    for i in range(block_start, block_end):
        match = CRITERION.match(lines[i].strip())
        if match:
            criteria.append({"text": match.group(1).strip(), "line": i + 1})
            continue
        stripped = lines[i].strip()
        if stripped and criteria and not stripped.startswith(("#", "-")):
            # A wrapped continuation line under the current criterion (reflow, the
            # same rule criteria-coverage.sh already applies to PLAN bullets).
            criteria[-1]["text"] += " " + stripped
    if not criteria:
        raise ValueError("%s:%d: Good Enough section has no '- [ ] ...' criteria" % (source, good_enough_lines[0] + 1))
    for entry in criteria:
        command = None
        found = BACKTICK.search(entry["text"])
        if found:
            command = found.group(1)
        else:
            command = criteria_map.get(norm(entry["text"]))
        entry["command"] = command
    return start, lines, criteria


def build_proposed_spec(text, source, owner, criteria, next_id):
    """Insert requirements_version/requirements_owner into frontmatter and
    replace only the Good Enough bullets; every other byte -- Goal, Boundary,
    Exceptional, Constraints -- is copied unchanged."""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    start = lines.index("---", 1) + 1 if lines and lines[0] == "---" else 0
    owner_json = json.dumps(owner, sort_keys=True, separators=(",", ":"))
    allocations = []
    scenario_checks = {}
    body = []
    for offset, entry in enumerate(criteria):
        rid = "GE-%03d" % (next_id + offset)
        sid = "SC-001"
        allocations.append({"id": rid, "text": entry["text"]})
        body.append("- [ ] %s: %s" % (rid, entry["text"]))
        body.append("  - %s: %s" % (sid, entry["text"]))
        body.append("")
        if entry["command"]:
            scenario_checks["%s/%s" % (rid, sid)] = {"command": entry["command"]}
    while body and body[-1] == "":
        body.pop()
    good_enough_lines = [i for i in range(start, len(lines))
                         if HEADING.match(lines[i]) and HEADING.match(lines[i]).group(2) == "Good Enough"]
    heading_line = good_enough_lines[0]
    block_end = len(lines)
    for i in range(heading_line + 1, len(lines)):
        if HEADING.match(lines[i]):
            block_end = i
            break
    candidate = list(lines[:start])
    if start:
        candidate.insert(len(candidate) - 1, "requirements_version: 1")
        candidate.insert(len(candidate) - 1, "requirements_owner: " + owner_json)
        if scenario_checks:
            checks_json = json.dumps(scenario_checks, sort_keys=True, separators=(",", ":"))
            candidate.insert(len(candidate) - 1, "scenario_checks: " + checks_json)
    candidate += lines[start:heading_line + 1]
    candidate.append("")
    candidate += body
    candidate.append("")
    candidate += lines[block_end:]
    return "\n".join(candidate), allocations


def find_task_blocks(plan_lines):
    """[(task_id, start_line, end_line)] where end_line is exclusive, matching
    lib/plan-tasks.sh's own '### task-NNN:' block boundaries."""
    heading = re.compile(r"^###\s+(task-\d+):")
    blocks = []
    starts = []
    for i, line in enumerate(plan_lines):
        match = heading.match(line.strip())
        if match:
            starts.append((match.group(1), i))
    for index, (task_id, start) in enumerate(starts):
        end = len(plan_lines)
        for j in range(start + 1, len(plan_lines)):
            stripped = plan_lines[j].strip()
            if stripped.startswith("### ") or stripped.startswith("## "):
                end = j
                break
        blocks.append((task_id, start, end))
    return blocks


PLAN_MAPPING = re.compile(r"^(.*?)\s*->\s*(task-\d+)\s*$")


def scan_legacy_plan(text):
    """Reflowed '- <criterion> -> task-NNN' bullets and the task registry,
    matching lib/criteria-coverage.sh's own legacy reading exactly."""
    lines = text.split("\n") if text else []
    bullets = []
    current = None
    current_line = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("-"):
            if current is not None:
                bullets.append((current, current_line))
            current = stripped[1:].strip()
            current_line = i + 1
        elif not stripped:
            if current is not None:
                bullets.append((current, current_line))
            current = None
        elif current is not None:
            current += " " + stripped
    if current is not None:
        bullets.append((current, current_line))
    known_tasks = set(re.findall(r"^###[ \t]+(task-\d+):", text, re.M))
    known_tasks |= set(re.findall(r"^\|\s*(task-\d+)\s*\|", text, re.M))
    mappings = []
    for bullet, line in bullets:
        match = PLAN_MAPPING.match(bullet)
        if match:
            mappings.append({"text": norm(match.group(1)), "task": match.group(2), "line": line})
    return lines, mappings, known_tasks


def build_proposed_plan(plan_text, allocations, owner):
    lines, mappings, known_tasks = scan_legacy_plan(plan_text)
    unresolved = []
    task_requirements = {}
    for allocation in allocations:
        target = norm(allocation["text"])
        matched = [m for m in mappings if m["text"] == target]
        if not matched:
            unresolved.append({"file": "PLAN.md", "line": 0, "criterion": allocation["text"],
                                "tasks": [], "reason": "no PLAN coverage mapping found"})
            continue
        dangling = [m for m in matched if known_tasks and m["task"] not in known_tasks]
        if dangling:
            unresolved.append({"file": "PLAN.md", "line": dangling[0]["line"], "criterion": allocation["text"],
                                "tasks": sorted({m["task"] for m in dangling}), "reason": "dangling task reference"})
            continue
        for match in matched:
            task_requirements.setdefault(match["task"], []).append(allocation)
    blocks = find_task_blocks(lines)
    inserts = {}
    for task_id, start, end in blocks:
        requirements = task_requirements.get(task_id)
        if not requirements:
            continue
        bullet_lines = ["", "**Requirements:**"]
        for requirement in requirements:
            bullet = {"owner": owner, "requirement": requirement["id"], "revision": requirement["revision"],
                       "scenarios": ["SC-001"]}
            bullet_lines.append("- " + json.dumps(bullet, sort_keys=True, separators=(",", ":")))
        inserts[end] = bullet_lines
    candidate = []
    for i, line in enumerate(lines):
        if i in inserts:
            candidate.extend(inserts[i])
        candidate.append(line)
    if len(lines) in inserts:
        candidate.extend(inserts[len(lines)])
    return "\n".join(candidate), unresolved


def resolve_owner(state, feature_dir):
    contract = state.get("requirementsContract")
    if contract and contract.get("owner"):
        return dict(contract["owner"])
    repository = os.environ.get("LOOP_SPEC_REPOSITORY_ID")
    if not repository:
        # Deterministic, not random: two previews of the same feature directory
        # must agree (task-010 AC1), so the id is derived from stable identity
        # rather than minted fresh on every call.
        repository = str(uuid.uuid5(NAMESPACE, "repository:" + str(feature_dir.resolve())))
    return {"repository": repository, "feature": state.get("slug", "")}


def build_preview(feature_dir):
    feature_dir = Path(feature_dir)
    state = load_raw_state(feature_dir)
    refuse_unmigratable(state, feature_dir)

    slug = state.get("slug")
    root = next((p for p in feature_dir.parents if (p / ".git").exists()), None)
    docs_dir = root / "docs" / "loop-spec" / "features" / slug if root is not None and isinstance(slug, str) and slug else None
    artifacts = state.get("artifacts", {}) if isinstance(state.get("artifacts"), dict) else {}

    def resolve(key, default_name):
        pointer = artifacts.get(key)
        if not pointer:
            return docs_dir / default_name if docs_dir else None
        path = Path(pointer)
        # A persisted pointer is the same relative-to-repo-root shape publish_locked
        # writes (docs/loop-spec/features/<slug>/...); an absolute pointer is used as-is.
        return path if path.is_absolute() or root is None else root / path

    spec_path = resolve("spec", "SPEC.md")
    plan_path = resolve("plan", "PLAN.md")
    verification_path = resolve("verification", "VERIFICATION.md")
    tasks_path = feature_dir / "tasks.json"
    if not spec_path or not spec_path.is_file():
        raise ValueError("feature-dir %s: no readable SPEC.md to migrate" % feature_dir)
    if not plan_path or not plan_path.is_file():
        raise ValueError("feature-dir %s: no readable PLAN.md to migrate" % feature_dir)

    refuse_oversized(spec_path, str(spec_path))
    refuse_oversized(plan_path, str(plan_path))

    spec_text = spec_path.read_text(encoding="utf-8")
    plan_text = plan_path.read_text(encoding="utf-8")

    owner = resolve_owner(state, feature_dir)
    contract = state.get("requirementsContract")
    next_id = contract["nextRequirementId"] if contract else 1

    _, _, criteria = scan_legacy_spec(spec_text, str(spec_path))
    proposed_spec_text, allocations = build_proposed_spec(spec_text, str(spec_path), owner, criteria, next_id)

    inventory = parse_spec(proposed_spec_text, str(spec_path), None)
    if state.get("specApproval") is not None:
        approved = state["specApproval"].get("sha256")
        try:
            candidate_intent = intent_digest(proposed_spec_text)
        except ValueError as exc:
            raise ValueError("feature-dir %s: cannot preserve approved intent: %s" % (feature_dir, exc))
        if candidate_intent != approved:
            raise ValueError("feature-dir %s: candidate SPEC Goal/Boundary bytes differ from the approved intent; refusing rather than rewrite the approval" % feature_dir)

    by_id = {r["id"]: r for r in inventory["requirements"]}
    for allocation in allocations:
        allocation["revision"] = by_id[allocation["id"]]["revision"]

    proposed_plan_text, unresolved = build_proposed_plan(plan_text, allocations, owner)

    base_contract = contract if (contract and contract.get("format") == "legacy") else initialize_contract(owner, "v1")
    if base_contract["format"] != "v1":
        base_contract = dict(base_contract, format="v1")
    proposed_contract = reconcile_inventory(base_contract, inventory)

    publication = state.get("artifactPublication") or {"version": 1, "generation": 0, "evidenceEpoch": 0,
                                                        "migration": None, "participantsVersion": 1}
    migration_id = str(uuid.uuid5(NAMESPACE, "migration:" + digest({"spec": spec_text, "plan": plan_text, "slug": slug})))
    proposed_publication = {
        "evidenceEpoch": publication["evidenceEpoch"] + 1,
        "migration": {"id": migration_id, "previewDigest": None, "phase": "staged",
                      "originalGeneration": publication["generation"], "publishedHashes": {}},
    }

    sources = {
        "SPEC.md": stream_digest(spec_path),
        "PLAN.md": stream_digest(plan_path),
        "tasks.json": stream_digest(tasks_path),
    }
    for field in ("slug", "owner", "specApproval", "requirementsContract", "artifactPublication", "completedPhases"):
        sources["feature-state." + field] = digest(state.get(field))

    historical = None
    if verification_path and verification_path.is_file():
        refuse_oversized(verification_path, str(verification_path))
        historical = {"path": str(verification_path), "sha256": stream_digest(verification_path)}

    body = {
        "historical": {"verification": historical,
                       "note": "kept as-is; the migrated candidate requires fresh v1 observations"},
        "id": migration_id,
        "owner": owner,
        "proposedArtifactPublication": proposed_publication,
        "proposedPlan": {"text": proposed_plan_text, "unresolved": unresolved},
        "proposedRequirementsContract": proposed_contract,
        "proposedSpec": {"text": proposed_spec_text},
        "sources": sources,
    }
    preview_digest = digest(body)
    body["previewDigest"] = preview_digest
    return body


def build_status(feature_dir):
    feature_dir = Path(feature_dir)
    state = load_raw_state(feature_dir)
    migration = (state.get("artifactPublication") or {}).get("migration")
    if migration is None:
        return {"migration": "none"}
    directory = feature_dir / "migration-generations" / migration["id"]
    return {"migration": migration,
            "journal": {"transactionDir": str(directory), "present": directory.is_dir()}}


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["preview", "status", "apply", "resume", "rollback"])
    parser.add_argument("--feature-dir", required=True)
    parser.add_argument("--preview")
    parser.add_argument("--digest")
    parser.add_argument("--transaction")
    args = parser.parse_args(argv)
    if args.command in ("apply", "resume", "rollback"):
        print("requirements-migrate: %s is not implemented in this revision" % args.command, file=sys.stderr)
        return 2
    feature_dir = Path(args.feature_dir)
    if not feature_dir.is_dir():
        print("requirements-migrate: feature-dir does not exist: %s" % feature_dir, file=sys.stderr)
        return 2
    if args.command == "preview":
        print(json.dumps(build_preview(feature_dir), sort_keys=True, ensure_ascii=False))
    else:
        print(json.dumps(build_status(feature_dir), sort_keys=True, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except ValueError as exc:
        print("requirements-migrate: %s" % exc, file=sys.stderr)
        sys.exit(1)
    except OSError as exc:
        print("requirements-migrate: I/O failure: %s" % exc, file=sys.stderr)
        sys.exit(1)
