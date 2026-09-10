#!/usr/bin/env python3
"""Read versioned requirement identities without changing artifacts or state."""
import argparse
import copy
import hashlib
import json
import re
import sys

MAX_BYTES = 16 * 1024 * 1024


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key " + key)
        result[key] = value
    return result


def digest(value):
    data = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


def valid_id(value, prefix):
    if not re.fullmatch(prefix + "-[0-9]{3,}", value):
        return False
    digits = value.split("-")[1]
    return bool(digits.strip("0")) and digits == digits.lstrip("0").zfill(3)


def prose(lines):
    paragraphs = []
    current = []
    for line in lines:
        if line:
            current.append(line)
        elif current:
            paragraphs.append(" ".join(current))
            current = []
    if current:
        paragraphs.append(" ".join(current))
    return "\n\n".join(paragraphs)


def parse_spec(text, source, contract=None):
    def fail(line, message):
        raise ValueError("%s:%d: %s" % (source, line, message))

    if len(text.encode("utf-8")) > MAX_BYTES:
        fail(1, "SPEC exceeds 16 MiB")
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    metadata = {}
    start = 0
    if lines[0] == "---":
        try:
            start = lines.index("---", 1) + 1
        except ValueError:
            fail(1, "unclosed frontmatter")
        for index in range(1, start - 1):
            match = re.match("^([A-Za-z_][A-Za-z0-9_]*):[ \\t]*(.*)$", lines[index])
            if not match:
                if re.match(r"^\s*(requirements_[A-Za-z0-9_]*|scenario_checks)\b", lines[index]):
                    fail(index + 1, "malformed structured metadata declaration")
                continue
            key, value = match.groups()
            if key in metadata:
                fail(index + 1, "duplicate metadata " + key)
            metadata[key] = (value, index + 1)
    outside_fence = None
    for index in range(start, len(lines)):
        line = lines[index]
        opening = re.match("^ *(`{3,}|~{3,})", line)
        if outside_fence:
            char, length = outside_fence
            if re.fullmatch(" *" + re.escape(char) + "{" + str(length) + ",}[ \\t]*", line):
                outside_fence = None
        elif opening:
            outside_fence = (opening[1][0], len(opening[1]))
        elif re.match(r"^\s*(requirements_[A-Za-z0-9_]*|scenario_checks)\s*:", line):
            fail(index + 1, "requirements metadata must be in frontmatter")
    explicit = any(key.startswith("requirements_") for key in metadata)
    expected = contract.get("format") if contract else None
    if contract and (type(contract.get("version")) is not int or contract.get("version") != 1 or expected not in ("legacy", "v1")):
        fail(1, "unsupported requirements contract")
    if not explicit and expected != "v1":
        return {"version": 0, "owner": contract.get("owner") if contract else None,
                "requirements": [], "obligations": [], "locations": {}}
    for key in ("requirements_version", "requirements_owner"):
        if key not in metadata:
            fail(1, "missing " + key + " for v1 contract")
    raw, no = metadata["requirements_version"]
    if raw != "1":
        fail(no, "unsupported requirements_version " + raw)
    raw, no = metadata["requirements_owner"]
    try:
        owner = json.loads(raw, object_pairs_hook=unique_object)
    except ValueError as exc:
        fail(no, "requirements_owner: " + str(exc))
    if (not isinstance(owner, dict) or set(owner) != {"repository", "feature"}
            or any(not isinstance(v, str) or not v.strip() for v in owner.values())):
        fail(no, "requirements_owner needs non-empty repository and feature")
    if contract and (expected != "v1" or owner != contract.get("owner")):
        fail(no, "requirements owner/format differs from persisted contract")
    for key, (raw, no) in metadata.items():
        if key.startswith("requirements_") and key not in ("requirements_owner", "requirements_version"):
            fail(no, "unknown metadata " + key)
        if key == "scenario_checks":
            try:
                checks = json.loads(raw, object_pairs_hook=unique_object)
            except ValueError as exc:
                fail(no, "scenario_checks: " + str(exc))
            if not isinstance(checks, dict):
                fail(no, "scenario_checks must be a JSON object")
    requirements, obligations, sections = [], [], set()
    requirement_ids, scenario_ids, obligation_ids = set(), set(), set()
    section = None
    requirement = scenario = None
    fence = None
    example = []
    for index in range(start, len(lines)):
        line, no = lines[index], index + 1
        if fence:
            char, length, indent, opened, target = fence
            if re.fullmatch(" " * indent + re.escape(char) + "{" + str(length) + ",}[ \\t]*", line):
                if target is not None:
                    example.append(line[indent:])
                    target["examples"].append("\n".join(example) + "\n")
                fence = None
                continue
            if target is not None:
                if line and not line.startswith(" " * indent):
                    fail(no, "example must retain four-space indentation")
                example.append(line[indent:] if line else "")
            continue
        opening = re.match("^( *)(`{3,}|~{3,})(.*)$", line)
        if opening:
            indent = len(opening[1])
            target = scenario if section == "Good Enough" else None
            if section == "Good Enough" and (target is None or indent != 4):
                fail(no, "example fence must belong to a scenario at four spaces")
            fence = (opening[2][0], len(opening[2]), indent, no, target)
            example = [line[indent:]] if target is not None else []
            continue
        heading = re.match("^(#{1,6}) (.+?)\\s*$", line)
        if heading:
            if section == "Good Enough" and len(heading[1]) > 3:
                fail(no, "ambiguous nested heading inside Good Enough")
            name = heading[2]
            if name in ("Good Enough", "Exceptional", "Constraints"):
                if name in sections:
                    fail(no, "duplicate section " + name)
                sections.add(name)
                level = 2 if name == "Constraints" else 3
                if len(heading[1]) != level:
                    fail(no, "invalid section level for " + name)
            section = name
            requirement = scenario = None
            continue
        if section == "Constraints" and line.startswith("- OBL-"):
            match = re.fullmatch("- (OBL-[A-Za-z0-9][A-Za-z0-9-]*): (\\S.*)", line)
            if not match or match[1] in obligation_ids:
                fail(no, "malformed or duplicate obligation")
            obligation_ids.add(match[1])
            obligations.append({"id": match[1], "text": match[2], "location": {"source": source, "line": no}})
        if section != "Good Enough":
            continue
        if not line.strip():
            if scenario:
                scenario["_prose"].append("")
            elif requirement:
                requirement["_prose"].append("")
            continue
        match = re.fullmatch("- \\[[ xX]\\] ([^:]+):[ ]?(.*)", line)
        if match:
            rid, value = match.groups()
            if not valid_id(rid, "GE") or rid in requirement_ids:
                fail(no, "malformed or duplicate requirement " + rid)
            requirement = {"id": rid, "_prose": [value], "scenarios": [], "location": {"source": source, "line": no}}
            requirement_ids.add(rid)
            scenario_ids = set()
            requirements.append(requirement)
            scenario = None
            continue
        match = re.fullmatch("  - ([^:]+):[ ]?(.*)", line)
        if match:
            sid, value = match.groups()
            if requirement is None or not valid_id(sid, "SC"):
                fail(no, "malformed or orphan scenario " + sid)
            if sid in scenario_ids:
                fail(no, "duplicate scenario " + requirement["id"] + "/" + sid)
            scenario = {"id": sid, "_prose": [value], "examples": [], "location": {"source": source, "line": no}}
            scenario_ids.add(sid)
            requirement["scenarios"].append(scenario)
            continue
        indent = 4 if scenario else 2
        target = scenario or requirement
        if (target is None or not line.startswith(" " * indent)
                or line[indent:indent + 1].isspace() or line[indent:].startswith(("-", "#"))):
            fail(no, "invalid indentation or ambiguous requirement nesting")
        target["_prose"].append(line[indent:])
    if fence:
        fail(fence[3], "unclosed fence")
    if "Good Enough" not in sections or not requirements:
        fail(1, "Good Enough requires at least one requirement with scenarios")
    locations = {}
    for requirement in requirements:
        requirement["text"] = prose(requirement.pop("_prose"))
        if not requirement["text"].strip() or not requirement["scenarios"]:
            fail(requirement["location"]["line"], requirement["id"] + " needs text and scenarios")
        for scenario in requirement["scenarios"]:
            scenario["text"] = prose(scenario.pop("_prose"))
            if not scenario["text"].strip():
                fail(scenario["location"]["line"], requirement["id"] + "/" + scenario["id"] + " needs text")
        scenarios = sorted(requirement["scenarios"], key=lambda s: (len(s["id"]), s["id"]))
        requirement["revision"] = digest({"text": requirement["text"], "scenarios": [
            {k: s[k] for k in ("id", "text", "examples")} for s in scenarios]})
        locations[requirement["id"]] = requirement["location"]
    return {"version": 1, "owner": owner, "requirements": requirements,
            "obligations": obligations, "locations": locations}


def inventory_digest(inventory):
    requirements = []
    for requirement in inventory["requirements"]:
        requirements.append({"id": requirement["id"], "revision": requirement["revision"]})
    return digest({"version": inventory["version"], "owner": inventory["owner"],
                   "requirements": sorted(requirements, key=lambda r: (len(r["id"]), r["id"])),
                   "obligations": sorted([{"id": o["id"], "text": o["text"]} for o in inventory["obligations"]], key=lambda o: o["id"])})



def object_fields(value, fields, path):
    if not isinstance(value, dict) or set(value) != set(fields):
        raise ValueError(path + " requires exactly: " + ", ".join(fields))


def integer(value, minimum, path):
    if type(value) is not int or value < minimum:
        raise ValueError(path + " must be an integer >= " + str(minimum))


def sha256(value, path):
    if not isinstance(value, str) or not re.fullmatch("[0-9a-f]{64}", value):
        raise ValueError(path + " must be lowercase SHA-256")


def identity_list(value, prefix, path):
    if (not isinstance(value, list) or any(not isinstance(v, str) or not valid_id(v, prefix) for v in value)
            or len(set(value)) != len(value)):
        raise ValueError(path + " must contain unique canonical " + prefix + " IDs")
    return set(value)


def validate_state(state):
    """Validate optional identity fields; absent fields retain legacy readability."""
    if "requirementsContract" in state:
        c = state["requirementsContract"]
        object_fields(c, ("version", "format", "owner", "inventoryDigest", "nextRequirementId", "issued", "retired", "retiredScenarios"), "requirementsContract")
        if type(c["version"]) is not int or c["version"] != 1 or c["format"] not in ("legacy", "v1"):
            raise ValueError("requirementsContract unsupported version/format")
        object_fields(c["owner"], ("repository", "feature"), "requirementsContract.owner")
        if any(not isinstance(v, str) or not v.strip() for v in c["owner"].values()):
            raise ValueError("requirementsContract.owner needs non-empty identities")
        if c["inventoryDigest"] is not None:
            sha256(c["inventoryDigest"], "requirementsContract.inventoryDigest")
        integer(c["nextRequirementId"], 1, "requirementsContract.nextRequirementId")
        if not isinstance(c["issued"], dict) or not isinstance(c["retiredScenarios"], dict):
            raise ValueError("requirementsContract issued/retiredScenarios must be objects")
        issued = identity_list(list(c["issued"]), "GE", "requirementsContract.issued")
        retired = identity_list(c["retired"], "GE", "requirementsContract.retired")
        if not retired <= issued or not set(c["retiredScenarios"]) <= issued:
            raise ValueError("requirementsContract has dangling retired history")
        for rid, entry in c["issued"].items():
            path = "requirementsContract.issued." + rid
            object_fields(entry, ("revision", "nextScenarioId", "scenarios"), path)
            sha256(entry["revision"], path + ".revision")
            integer(entry["nextScenarioId"], 1, path + ".nextScenarioId")
            scenarios = identity_list(entry["scenarios"], "SC", path + ".scenarios")
            removed = identity_list(c["retiredScenarios"].get(rid, []), "SC", "requirementsContract.retiredScenarios." + rid)
            if not removed <= scenarios:
                raise ValueError(path + " has dangling retired scenarios")
            if any(int(s[3:]) >= entry["nextScenarioId"] for s in scenarios):
                raise ValueError(path + ".nextScenarioId must exceed issued IDs")
        if any(int(r[3:]) >= c["nextRequirementId"] for r in issued):
            raise ValueError("requirementsContract.nextRequirementId must exceed issued IDs")
        if c["format"] == "legacy" and (issued or retired or c["retiredScenarios"] or c["inventoryDigest"] is not None or c["nextRequirementId"] != 1):
            raise ValueError("legacy requirementsContract cannot carry v1 history")
    if "artifactPublication" in state:
        p = state["artifactPublication"]
        object_fields(p, ("version", "generation", "evidenceEpoch", "migration", "participantsVersion"), "artifactPublication")
        for key in ("version", "participantsVersion"):
            if type(p[key]) is not int or p[key] != 1:
                raise ValueError("artifactPublication." + key + " must be 1")
        for key in ("generation", "evidenceEpoch"):
            integer(p[key], 0, "artifactPublication." + key)
        m = p["migration"]
        if m is not None:
            object_fields(m, ("id", "previewDigest", "phase", "originalGeneration", "publishedHashes"), "artifactPublication.migration")
            for key in ("id", "phase"):
                if not isinstance(m[key], str) or not m[key].strip():
                    raise ValueError("artifactPublication.migration." + key + " must be non-empty")
            sha256(m["previewDigest"], "artifactPublication.migration.previewDigest")
            integer(m["originalGeneration"], 0, "artifactPublication.migration.originalGeneration")
            if m["originalGeneration"] > p["generation"]:
                raise ValueError("migration originalGeneration exceeds generation")
            if not isinstance(m["publishedHashes"], dict):
                raise ValueError("artifactPublication.migration.publishedHashes must be an object")
            for path, value in m["publishedHashes"].items():
                if not isinstance(path, str) or not path.strip():
                    raise ValueError("migration publishedHashes path must be non-empty")
                sha256(value, "artifactPublication.migration.publishedHashes." + path)


def validate_transition(previous, state):
    validate_state(state)
    validate_state(previous)
    for field in ("requirementsContract", "artifactPublication"):
        if field in previous and field not in state:
            raise ValueError(field + " cannot be removed")
    old, new = previous.get("requirementsContract"), state.get("requirementsContract")
    if old:
        for key in ("version", "format", "owner"):
            if old[key] != new[key]:
                raise ValueError("requirementsContract." + key + " is immutable")
        if new["nextRequirementId"] < old["nextRequirementId"] or not set(old["retired"]) <= set(new["retired"]):
            raise ValueError("requirementsContract history cannot roll back")
        retired_requirements = set(old["retired"])
        for rid, entry in old["issued"].items():
            candidate = new["issued"].get(rid)
            if candidate is None or candidate["nextScenarioId"] < entry["nextScenarioId"] or not set(entry["scenarios"]) <= set(candidate["scenarios"]):
                raise ValueError("requirementsContract issued history cannot roll back: " + rid)
            if not set(old["retiredScenarios"].get(rid, [])) <= set(new["retiredScenarios"].get(rid, [])):
                raise ValueError("requirementsContract retired scenario history cannot roll back: " + rid)
            if rid in retired_requirements and candidate != entry:
                raise ValueError("requirementsContract retired requirement cannot change: " + rid)
            for sid in set(candidate["scenarios"]) - set(entry["scenarios"]):
                if int(sid[3:]) < entry["nextScenarioId"]:
                    raise ValueError("requirementsContract scenario ID below allocation counter: " + rid + "/" + sid)
        for rid in set(new["issued"]) - set(old["issued"]):
            if int(rid[3:]) < old["nextRequirementId"]:
                raise ValueError("requirementsContract requirement ID below allocation counter: " + rid)
    old, new = previous.get("artifactPublication"), state.get("artifactPublication")
    if old:
        for key in ("generation", "evidenceEpoch", "version", "participantsVersion"):
            if new[key] < old[key]:
                raise ValueError("artifactPublication." + key + " cannot roll back")


def initialize_contract(owner, format):
    """Explicit bootstrap primitive; callers persist the stable owner once."""
    contract = {"version": 1, "format": format, "owner": copy.deepcopy(owner), "inventoryDigest": None,
                "nextRequirementId": 1, "issued": {}, "retired": [], "retiredScenarios": {}}
    validate_state({"requirementsContract": contract})
    return contract


def bootstrap_state(state, owner, format="legacy"):
    """Bootstrap product-legacy schema-7 state; completed history stays unchanged."""
    validate_state(state)
    if state.get("currentPhase") == "completed":
        return copy.deepcopy(state)
    if type(state.get("schemaVersion")) is not int or state["schemaVersion"] != 7:
        raise ValueError("bootstrap requires supported feature schemaVersion 7")
    if "requirementsContract" in state:
        return copy.deepcopy(state)
    candidate = copy.deepcopy(state)
    candidate["requirementsContract"] = initialize_contract(owner, format)
    candidate["artifactPublication"] = {"version": 1, "generation": 0, "evidenceEpoch": 0,
                                        "migration": None, "participantsVersion": 1}
    validate_transition(state, candidate)
    return candidate


def reconcile_inventory(previous_contract, inventory):
    """Return a candidate history without mutating the accepted contract or inventory."""
    validate_state({"requirementsContract": previous_contract})
    c = copy.deepcopy(previous_contract)
    if (not isinstance(inventory, dict) or not {"owner", "version", "requirements", "obligations"} <= set(inventory)
            or type(inventory["version"]) is not int or not isinstance(inventory["requirements"], list)
            or not isinstance(inventory["obligations"], list)):
        raise ValueError("inventory requires version, owner, requirements and obligations")
    for requirement in inventory["requirements"]:
        if (not isinstance(requirement, dict) or not {"id", "revision", "scenarios"} <= set(requirement)
                or not isinstance(requirement["id"], str) or not valid_id(requirement["id"], "GE")
                or not isinstance(requirement["scenarios"], list) or not requirement["scenarios"]):
            raise ValueError("inventory requirement requires canonical ID, revision and scenarios")
        sha256(requirement["revision"], "inventory." + requirement["id"] + ".revision")
        if any(not isinstance(s, dict) or "id" not in s for s in requirement["scenarios"]):
            raise ValueError("inventory scenario requires ID")
    for obligation in inventory["obligations"]:
        if (not isinstance(obligation, dict) or not isinstance(obligation.get("id"), str)
                or not isinstance(obligation.get("text"), str)):
            raise ValueError("inventory obligation requires ID and text")
    if inventory["owner"] != c["owner"] or inventory["version"] != (1 if c["format"] == "v1" else 0):
        raise ValueError("inventory owner/version differs from requirementsContract")
    if c["format"] == "legacy":
        return c
    active = set()
    retired_requirements = set(c["retired"])
    for requirement in inventory["requirements"]:
        rid = requirement["id"]
        if rid in active or rid in retired_requirements:
            raise ValueError("duplicate or retired requirement " + rid)
        active.add(rid)
        scenarios = [s["id"] for s in requirement["scenarios"]]
        identity_list(scenarios, "SC", rid)
        entry = c["issued"].get(rid)
        if entry is None:
            entry = {"revision": requirement["revision"], "nextScenarioId": 1, "scenarios": []}
            c["issued"][rid] = entry
        retired = set(c["retiredScenarios"].get(rid, []))
        if retired & set(scenarios):
            raise ValueError("retired scenario reused in " + rid)
        retired.update(set(entry["scenarios"]) - set(scenarios))
        c["retiredScenarios"][rid] = sorted(retired)
        entry["scenarios"] = sorted(set(entry["scenarios"]) | set(scenarios))
        entry["revision"] = requirement["revision"]
        entry["nextScenarioId"] = max([entry["nextScenarioId"]] + [int(s[3:]) + 1 for s in scenarios])
    c["retired"] = sorted(set(c["issued"]) - active)
    c["nextRequirementId"] = max([c["nextRequirementId"]] + [int(r[3:]) + 1 for r in active])
    c["inventoryDigest"] = inventory_digest(inventory)
    validate_transition({"requirementsContract": previous_contract}, {"requirementsContract": c})
    return c


def load_inventory(spec_path, feature_state):
    with open(spec_path, "rb") as stream:
        data = stream.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError("%s:1: SPEC exceeds 16 MiB" % spec_path)
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError("%s:1: invalid UTF-8: %s" % (spec_path, exc))
    inventory = parse_spec(text, str(spec_path), feature_state.get("requirementsContract"))
    if feature_state.get("requirementsContract"):
        reconcile_inventory(feature_state["requirementsContract"], inventory)
    return inventory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["inventory"])
    parser.add_argument("--spec", required=True)
    parser.add_argument("--feature-dir", required=True)
    args = parser.parse_args()
    try:
        from feature_read import load_state
        inventory = load_inventory(args.spec, load_state(args.feature_dir))
        print(json.dumps(inventory, sort_keys=True, ensure_ascii=False))
        return 0
    except (OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
