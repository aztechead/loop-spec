#!/usr/bin/env python3
"""Convert an incomplete legacy cycle to the v1 requirements contract.

Purpose: `preview` inspects a feature directory whose requirementsContract is
"legacy" or absent and prints one canonical JSON candidate -- proposed v1 SPEC
text, proposed PLAN text, proposed requirementsContract and artifactPublication
changes -- without writing anything. `status` reports the feature's current
migration marker and journal read-only. `apply` publishes an operator-approved
preview under the publication lock, durably preserving originals first;
`resume` finishes an interrupted transaction from its recorded phase without
reallocating IDs; `rollback` restores a committed transaction's originals when
the migrated artifacts are still untouched.

Commands:
  requirements-migrate.sh preview --feature-dir DIR
  requirements-migrate.sh status  --feature-dir DIR
  requirements-migrate.sh apply   --feature-dir DIR --preview PATH --digest SHA256
  requirements-migrate.sh resume   --feature-dir DIR --transaction ID
  requirements-migrate.sh rollback --feature-dir DIR --transaction ID

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

Journal/receipt schema apply/resume/rollback use. Durable transaction state
lives at `migration-generations/<transaction-id>/` inside feature state,
mirroring lib/artifact_publication.py's publication-generations journal one
level up:
  marker.json     -- {"version":1,"id":str,"previewDigest":str,"phase":
                      "staged"|"replaced"|"published"|"committed"|"rolled-back",
                      "originalGeneration":int,"publishedHashes":{path:sha256},
                      "preview":{...the approved preview object, replayed by
                      resume so no ID is ever reallocated...},
                      "originalContract":{...the requirementsContract exactly
                      as it read before this transaction, restored verbatim by
                      rollback...},"files":[names backed up]}.
                      The public subset {id,previewDigest,phase,
                      originalGeneration,publishedHashes} is published into
                      feature.json's artifactPublication.migration as soon as
                      it is durable (SPEC "Migration preserves originals");
                      phase advances left-to-right and never back, except that
                      "committed" may become "rolled-back".
  originals/<name> -- exact pre-migration bytes of each replaced artifact
                      (SPEC.md, PLAN.md, tasks.json if present, feature.json),
                      written 0400 before any authoritative byte changes.
  receipt.json     -- written once phase reaches "published":
                      {"version":1,"id":str,"previewDigest":str,
                       "requirementsContractDigest":sha256,
                       "publishedHashes":{path:sha256},
                       "completedGeneration":int}

`apply` recomputes and rechecks the preview under the same publication lock it
mutates state through, so a change to any source or feature-state field
between preview and apply refuses naming the first differing top-level key.
`resume` re-derives every remaining step from marker.json's stored preview and
current phase, comparing live bytes to the expected target before writing, so
replaying a finished ("committed") transaction is a no-op (exit 0). `rollback`
restores the originals only when the live artifacts still hash to
publishedHashes; a later edit is refused by naming the file and both hashes.
Neither command fabricates historical observations or touches specApproval;
rollback bypasses ordinary requirementsContract monotonicity the same way
lib/artifact_publication.py's recover_locked bypasses prepare_state, because
restoring the pre-migration contract on an explicit operator rollback is the
extraordinary recovery path itself, not an ordinary write.

Two generation bumps happen per committed migration, both compare-and-swap
protection rather than an evidence-freshness test: once when the migration
marker becomes durable in feature.json (before any artifact byte changes, so
any reader holding an earlier token fails its own publish), and again when the
final contract/receipt are published. evidenceEpoch advances once, at the
final publish, invalidating prior observation records project-wide.

Failure injection: pass `failure=callable` to apply/resume/rollback (a
callable invoked as failure(point) at each durable boundary) for tests, or set
LOOP_SPEC_MIGRATION_FAIL_AT to one of backup|marker|spec|plan|state|receipt to
raise RuntimeError at that boundary in a real subprocess. Points fire only
after the corresponding write is durable, so failure always leaves a resumable
transaction, never a torn write.

Exit codes: 0 success (preview/status/apply/resume/rollback JSON on stdout);
1 refusal with a file/line or field diagnostic on stderr (a refused preview or
apply-precheck writes no repository file); 2 bad invocation.

Limits: SPEC.md and PLAN.md are each refused above requirements.MAX_BYTES (16
MiB), checked by file size before any byte is read or hashed. File hashing
streams in 64 KiB chunks (see `stream_digest`).
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
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


def artifact_targets(feature_dir, state):
    """The same {spec,plan,verification} resolution build_preview, apply and
    rollback all need, so a relocated checkout or a custom artifacts pointer
    is honored identically wherever a migration touches these paths."""
    feature_dir = Path(feature_dir)
    slug = state.get("slug")
    root = next((p for p in feature_dir.parents if (p / ".git").exists()), None)
    docs_dir = root / "docs" / "loop-spec" / "features" / slug if root is not None and isinstance(slug, str) and slug else None
    artifacts = state.get("artifacts", {}) if isinstance(state.get("artifacts"), dict) else {}
    targets = {}
    for key, default_name in (("spec", "SPEC.md"), ("plan", "PLAN.md"), ("verification", "VERIFICATION.md")):
        pointer = artifacts.get(key)
        if not pointer:
            targets[key] = docs_dir / default_name if docs_dir else None
            continue
        path = Path(pointer)
        # A persisted pointer is the same relative-to-repo-root shape publish_locked
        # writes (docs/loop-spec/features/<slug>/...); an absolute pointer is used as-is.
        targets[key] = path if path.is_absolute() or root is None else root / path
    return targets


def build_preview(feature_dir):
    feature_dir = Path(feature_dir)
    state = load_raw_state(feature_dir)
    refuse_unmigratable(state, feature_dir)

    targets = artifact_targets(feature_dir, state)
    spec_path, plan_path, verification_path = targets["spec"], targets["plan"], targets["verification"]
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
    migration_id = str(uuid.uuid5(NAMESPACE, "migration:" + digest({"spec": spec_text, "plan": plan_text, "slug": state.get("slug")})))
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


def _read_marker(transaction_dir):
    path = transaction_dir / "marker.json"
    if not path.is_file():
        return None
    with path.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def _write_json(path, value):
    from feature_write import publish
    publish(path, (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8"))


def _write_marker(transaction_dir, marker):
    _write_json(transaction_dir / "marker.json", marker)


def build_status(feature_dir):
    feature_dir = Path(feature_dir)
    state = load_raw_state(feature_dir)
    migration = (state.get("artifactPublication") or {}).get("migration")
    if migration is None:
        return {"migration": "none"}
    directory = feature_dir / "migration-generations" / migration["id"]
    marker = _read_marker(directory)
    return {"migration": migration,
            "journal": {"transactionDir": str(directory), "present": directory.is_dir(),
                        "phase": marker.get("phase") if marker else None}}


def _default_failure(point):
    """Production no-op unless a test names this exact boundary."""
    if os.environ.get("LOOP_SPEC_MIGRATION_FAIL_AT") == point:
        raise RuntimeError("LOOP_SPEC_MIGRATION_FAIL_AT=%s" % point)


def _first_difference(fresh, approved):
    """The one top-level key that no longer agrees, so a refusal names exactly
    what changed instead of forcing the operator to diff two JSON blobs."""
    for key in sorted(set(fresh) | set(approved)):
        if fresh.get(key) != approved.get(key):
            return key
    return None


ORIGINAL_NAMES = ("SPEC.md", "PLAN.md", "tasks.json", "feature.json")


def _backup_originals(feature_dir, transaction_dir, spec_path, plan_path):
    """Preserve exact pre-migration bytes 0400 before any authoritative byte
    changes; returns the subset of ORIGINAL_NAMES that actually existed."""
    from feature_write import publish, read_bounded
    originals_dir = transaction_dir / "originals"
    originals_dir.mkdir(parents=True)
    sources = {"SPEC.md": spec_path, "PLAN.md": plan_path,
               "tasks.json": feature_dir / "tasks.json", "feature.json": feature_dir / "feature.json"}
    present = []
    for name in ORIGINAL_NAMES:
        source = sources[name]
        if source is not None and source.is_file():
            content = read_bounded(source)
            target = originals_dir / name
            publish(target, content)
            os.chmod(target, 0o400)
            present.append(name)
    return present


def _advance(feature_dir, transaction_dir, marker, failure):
    """Drive marker["phase"] forward to "committed", comparing live bytes to
    the stored preview's targets before writing so every step is a no-op on
    replay. Shared by apply (from "staged") and resume (from any phase)."""
    from artifact_publication import persist_deferred
    from feature_write import publish, read_bounded, state_snapshot, write_state_locked
    from feature_read import load_state
    preview = marker["preview"]
    state = load_state(feature_dir)
    if marker["phase"] == "staged":
        current_migration = (state.get("artifactPublication") or {}).get("migration") or {}
        if current_migration.get("id") != marker["id"]:
            raise ValueError("feature state does not reference transaction %s; nothing to resume" % marker["id"])
    targets = artifact_targets(feature_dir, state)
    failures = []

    if marker["phase"] == "staged":
        for name, path, text in (("SPEC.md", targets["spec"], preview["proposedSpec"]["text"]),
                                  ("PLAN.md", targets["plan"], preview["proposedPlan"]["text"])):
            content = text.encode("utf-8")
            if not (path.is_file() and read_bounded(path) == content):
                publish(path, content)
                persist_deferred(feature_dir, failures)
            marker["publishedHashes"][name] = hashlib.sha256(content).hexdigest()
            failure("spec" if name == "SPEC.md" else "plan")
        marker["phase"] = "replaced"
        _write_marker(transaction_dir, marker)
        persist_deferred(feature_dir, failures)

    if marker["phase"] == "replaced":
        state = load_state(feature_dir)
        if (state.get("artifactPublication") or {}).get("migration") is not None:
            final_state = copy.deepcopy(state)
            final_state["requirementsContract"] = preview["proposedRequirementsContract"]
            final_state["artifactPublication"]["evidenceEpoch"] += 1
            final_state["artifactPublication"]["generation"] += 1
            final_state["artifactPublication"]["migration"] = None
            write_state_locked(feature_dir, final_state, state_snapshot(feature_dir))
            persist_deferred(feature_dir, failures)
        failure("state")
        marker["phase"] = "published"
        _write_marker(transaction_dir, marker)
        persist_deferred(feature_dir, failures)

    if marker["phase"] == "published":
        receipt_path = transaction_dir / "receipt.json"
        if not receipt_path.is_file():
            receipt = {"version": 1, "id": marker["id"], "previewDigest": marker["previewDigest"],
                       "requirementsContractDigest": digest(preview["proposedRequirementsContract"]),
                       "publishedHashes": marker["publishedHashes"],
                       "completedGeneration": load_state(feature_dir)["artifactPublication"]["generation"]}
            _write_json(receipt_path, receipt)
            persist_deferred(feature_dir, failures)
        failure("receipt")
        marker["phase"] = "committed"
        _write_marker(transaction_dir, marker)
        persist_deferred(feature_dir, failures)

    if failures:
        raise failures[0]
    return marker


def apply(feature_dir, preview_path, expected_digest, failure=None):
    from artifact_publication import locked_feature, persist_deferred, refuse_pending
    from feature_read import load_state
    from feature_write import state_snapshot, write_state_locked

    feature_dir = Path(feature_dir)
    failure = failure or _default_failure
    try:
        with open(preview_path, "r", encoding="utf-8") as stream:
            preview = json.load(stream)
    except (OSError, ValueError) as exc:
        raise ValueError("--preview %s: cannot read preview: %s" % (preview_path, exc))
    if not isinstance(preview, dict) or "previewDigest" not in preview:
        raise ValueError("--preview %s: not a migration preview file" % preview_path)
    if preview["previewDigest"] != expected_digest:
        raise ValueError("--digest %s does not match the preview file's own previewDigest %s"
                          % (expected_digest, preview["previewDigest"]))
    if digest({k: v for k, v in preview.items() if k != "previewDigest"}) != expected_digest:
        raise ValueError("--preview %s is not self-consistent; take a fresh preview" % preview_path)

    with locked_feature(feature_dir):
        state = load_state(feature_dir)
        if not state.get("artifactPublication"):
            # build_preview tolerates a not-yet-bootstrapped legacy cycle (it
            # only *reads* a default), but apply mutates real generation/
            # evidenceEpoch counters and must not silently bootstrap them here:
            # doing so would change build_preview's own "sources" digest out
            # from under the very preview being approved. Any cycle a migration
            # is offered for has already been touched by an ordinary phase
            # transition (feature_write.begin_operation's bootstrap) by the
            # time task-009 activates migration, so this is a real precondition.
            raise ValueError("feature-dir %s: run an ordinary phase transition first "
                              "to initialize artifactPublication before migrating" % feature_dir)
        migration = (state.get("artifactPublication") or {}).get("migration")
        if migration is not None:
            raise ValueError("feature-dir %s: migration %s (phase=%s) is already staged; run status/resume"
                              % (feature_dir, migration["id"], migration["phase"]))
        refuse_pending(feature_dir)

        fresh = build_preview(feature_dir)
        differing = _first_difference(fresh, preview)
        if differing:
            raise ValueError("feature-dir %s: %s changed since this preview was approved; take a fresh preview"
                              % (feature_dir, differing))
        if fresh["previewDigest"] != expected_digest:
            raise ValueError("feature-dir %s: current inputs no longer match --digest %s; take a fresh preview"
                              % (feature_dir, expected_digest))

        transaction_dir = feature_dir / "migration-generations" / preview["id"]
        if transaction_dir.is_dir() and not (transaction_dir / "marker.json").is_file():
            # Backups were written but the transaction never became durable
            # (a crash before marker.json); nothing authoritative changed, so
            # the stale directory is simply discarded and apply starts clean.
            shutil.rmtree(transaction_dir)
        if (transaction_dir / "marker.json").is_file():
            raise ValueError("feature-dir %s: transaction %s already recorded; run status/resume"
                              % (feature_dir, preview["id"]))

        targets = artifact_targets(feature_dir, state)
        transaction_dir.mkdir(parents=True)
        failures = []
        present = _backup_originals(feature_dir, transaction_dir, targets["spec"], targets["plan"])
        persist_deferred(feature_dir, failures)
        failure("backup")

        original_generation = state["artifactPublication"]["generation"]
        public_marker = {"id": preview["id"], "previewDigest": preview["previewDigest"], "phase": "staged",
                          "originalGeneration": original_generation, "publishedHashes": {}}
        marker = dict(public_marker, version=1, preview=preview,
                      originalContract=state.get("requirementsContract"), files=present)
        _write_marker(transaction_dir, marker)
        new_state = copy.deepcopy(state)
        new_state["artifactPublication"]["generation"] = original_generation + 1
        new_state["artifactPublication"]["migration"] = public_marker
        write_state_locked(feature_dir, new_state, state_snapshot(feature_dir))
        persist_deferred(feature_dir, failures)
        failure("marker")

        if failures:
            raise failures[0]
        marker = _advance(feature_dir, transaction_dir, marker, failure)

    return {"transaction": preview["id"], "phase": marker["phase"]}


def resume(feature_dir, transaction_id, failure=None):
    from artifact_publication import locked_feature
    from feature_read import load_state

    feature_dir = Path(feature_dir)
    failure = failure or _default_failure
    transaction_dir = feature_dir / "migration-generations" / transaction_id
    with locked_feature(feature_dir):
        marker = _read_marker(transaction_dir)
        if marker is None:
            if transaction_dir.is_dir():
                shutil.rmtree(transaction_dir)
                raise ValueError("transaction %s never became durable; nothing to resume, re-run apply" % transaction_id)
            raise ValueError("unknown migration transaction: %s" % transaction_id)
        if marker["phase"] == "committed":
            state = load_state(feature_dir)
            if (state.get("requirementsContract") or {}).get("inventoryDigest") != marker["preview"]["proposedRequirementsContract"]["inventoryDigest"]:
                raise ValueError("transaction %s is committed but state no longer matches; manual review required" % transaction_id)
            return {"transaction": transaction_id, "phase": "committed", "resumed": False}
        if marker["phase"] == "rolled-back":
            raise ValueError("transaction %s was already rolled back; nothing to resume" % transaction_id)
        marker = _advance(feature_dir, transaction_dir, marker, failure)
    return {"transaction": transaction_id, "phase": marker["phase"], "resumed": True}


def rollback(feature_dir, transaction_id):
    from artifact_publication import digest as file_digest, locked_feature, persist_deferred, refuse_pending
    from feature_read import load_state
    from feature_write import publish, read_bounded, state_snapshot, write_state_locked

    feature_dir = Path(feature_dir)
    transaction_dir = feature_dir / "migration-generations" / transaction_id
    with locked_feature(feature_dir):
        marker = _read_marker(transaction_dir)
        if marker is None:
            raise ValueError("unknown migration transaction: %s" % transaction_id)
        if marker["phase"] != "committed":
            raise ValueError("transaction %s is not committed (phase=%s); resume it before rollback"
                              % (transaction_id, marker["phase"]))
        refuse_pending(feature_dir)
        state = load_state(feature_dir)
        targets = artifact_targets(feature_dir, state)
        conflicts = []
        for name, path in (("SPEC.md", targets["spec"]), ("PLAN.md", targets["plan"])):
            expected = marker["publishedHashes"].get(name)
            actual = file_digest(path) if path is not None else None
            if actual != expected:
                conflicts.append("%s: expected %s, found %s" % (name, expected, actual))
        if conflicts:
            raise ValueError("rollback refuses changed artifact(s) since migration: " + "; ".join(conflicts))

        originals_dir = transaction_dir / "originals"
        failures = []
        for name, path in (("SPEC.md", targets["spec"]), ("PLAN.md", targets["plan"])):
            publish(path, read_bounded(originals_dir / name))
        persist_deferred(feature_dir, failures)

        new_state = copy.deepcopy(state)
        new_state["requirementsContract"] = marker["originalContract"]
        new_state["artifactPublication"]["evidenceEpoch"] = state["artifactPublication"]["evidenceEpoch"] + 1
        new_state["artifactPublication"]["generation"] = state["artifactPublication"]["generation"] + 1
        new_state["artifactPublication"]["migration"] = None
        # Restoring the pre-migration contract deliberately bypasses ordinary
        # requirementsContract monotonicity (prepare_state/validate_transition):
        # rollback IS the extraordinary recovery path, the same way
        # artifact_publication.recover_locked calls write_state_locked directly.
        write_state_locked(feature_dir, new_state, state_snapshot(feature_dir))
        persist_deferred(feature_dir, failures)

        marker["phase"] = "rolled-back"
        _write_marker(transaction_dir, marker)
        persist_deferred(feature_dir, failures)
        if failures:
            raise failures[0]
    return {"transaction": transaction_id, "phase": "rolled-back"}


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["preview", "status", "apply", "resume", "rollback"])
    parser.add_argument("--feature-dir", required=True)
    parser.add_argument("--preview")
    parser.add_argument("--digest")
    parser.add_argument("--transaction")
    args = parser.parse_args(argv)
    feature_dir = Path(args.feature_dir)
    if not feature_dir.is_dir():
        print("requirements-migrate: feature-dir does not exist: %s" % feature_dir, file=sys.stderr)
        return 2
    if args.command == "preview":
        print(json.dumps(build_preview(feature_dir), sort_keys=True, ensure_ascii=False))
    elif args.command == "status":
        print(json.dumps(build_status(feature_dir), sort_keys=True, ensure_ascii=False))
    elif args.command == "apply":
        if not args.preview or not args.digest:
            print("requirements-migrate: apply requires --preview PATH --digest SHA256", file=sys.stderr)
            return 2
        print(json.dumps(apply(feature_dir, args.preview, args.digest), sort_keys=True, ensure_ascii=False))
    else:
        if not args.transaction:
            print("requirements-migrate: %s requires --transaction ID" % args.command, file=sys.stderr)
            return 2
        result = resume(feature_dir, args.transaction) if args.command == "resume" else rollback(feature_dir, args.transaction)
        print(json.dumps(result, sort_keys=True, ensure_ascii=False))
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
