#!/usr/bin/env python3
"""Read versioned requirement identities without changing artifacts or state."""
import argparse
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


def load_inventory(spec_path, feature_state):
    with open(spec_path, "rb") as stream:
        data = stream.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError("%s:1: SPEC exceeds 16 MiB" % spec_path)
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError("%s:1: invalid UTF-8: %s" % (spec_path, exc))
    return parse_spec(text, str(spec_path), feature_state.get("requirementsContract"))


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
